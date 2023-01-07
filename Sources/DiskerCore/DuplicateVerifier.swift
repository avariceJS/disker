import CryptoKit
import Darwin
import Foundation

public struct DuplicateVerificationProgress: Sendable {
    public let currentPath: String
    public let bytesHashed: UInt64
    public let candidateBytes: UInt64
}

public struct DuplicateFile: Codable, Equatable, Sendable {
    public let path: String
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64

    public init(path: String, logicalBytes: UInt64, allocatedBytes: UInt64) {
        self.path = path
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
    }
}

public struct DuplicateGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: String { sha256 }
    public let sha256: String
    public let files: [DuplicateFile]

    public init(sha256: String, files: [DuplicateFile]) {
        self.sha256 = sha256
        self.files = files
    }
}

public struct DuplicateVerificationResult: Codable, Equatable, Sendable {
    public let selectedRootPaths: [String]
    public let groups: [DuplicateGroup]
    public let checkedFileCount: Int
    public let inaccessibleCount: Int
    public let excludedSymlinkCount: Int
    public let excludedSpecialFileCount: Int
    public let changedDuringCheckCount: Int
    public let cancelled: Bool

    public init(
        selectedRootPaths: [String], groups: [DuplicateGroup], checkedFileCount: Int,
        inaccessibleCount: Int, excludedSymlinkCount: Int, excludedSpecialFileCount: Int,
        changedDuringCheckCount: Int, cancelled: Bool
    ) {
        self.selectedRootPaths = selectedRootPaths
        self.groups = groups
        self.checkedFileCount = checkedFileCount
        self.inaccessibleCount = inaccessibleCount
        self.excludedSymlinkCount = excludedSymlinkCount
        self.excludedSpecialFileCount = excludedSpecialFileCount
        self.changedDuringCheckCount = changedDuringCheckCount
        self.cancelled = cancelled
    }

    public var complete: Bool {
        !cancelled && inaccessibleCount == 0 && excludedSymlinkCount == 0
            && excludedSpecialFileCount == 0 && changedDuringCheckCount == 0
    }
}

/// Byte-verifies only regular files under folders explicitly selected for this
/// operation. Metadata filters candidates before any file content is read.
/// This reports identical bytes, not safe-to-delete files or reclaimable space.
public enum DuplicateVerifier {
    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct DirectoryIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct PendingDirectory {
        let components: [String]
        let path: String
        let identity: DirectoryIdentity
    }

    private struct Candidate {
        let rootDescriptor: Int32
        let components: [String]
        let path: String
        let identity: FileIdentity
        let logicalBytes: UInt64
        let allocatedBytes: UInt64
        let metadata: stat
    }

    private struct ScannedDirectory {
        let rootDescriptor: Int32
        let components: [String]
        let path: String
        let identity: DirectoryIdentity
        let metadata: stat
    }

    private enum OpenResult {
        case opened(Int32)
        case changed
        case unavailable
    }

    public static func verify(
        roots: [URL],
        shouldCancel: () -> Bool = { Task.isCancelled },
        progress: (DuplicateVerificationProgress) -> Void = { _ in }
    ) -> DuplicateVerificationResult {
        var rootDescriptors: [Int32] = []
        var scopedURLs: [URL] = []
        defer {
            rootDescriptors.forEach { close($0) }
            scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        }

        var candidatesBySize: [UInt64: [Candidate]] = [:]
        var scannedDirectories: [ScannedDirectory] = []
        var inaccessibleCount = 0
        var excludedSymlinkCount = 0
        var excludedSpecialFileCount = 0
        var changedDuringCheckCount = 0
        var cancelled = false

        for root in roots {
            if shouldCancel() { cancelled = true; break }
            if root.startAccessingSecurityScopedResource() { scopedURLs.append(root) }
            var metadata = stat()
            guard root.path.withCString({ lstat($0, &metadata) }) == 0 else {
                inaccessibleCount += 1
                continue
            }
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                if metadata.st_mode & S_IFMT == S_IFLNK { excludedSymlinkCount += 1 }
                else { inaccessibleCount += 1 }
                continue
            }
            let rootDescriptor = root.path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard rootDescriptor >= 0 else { inaccessibleCount += 1; continue }
            var openedRoot = stat()
            guard fstat(rootDescriptor, &openedRoot) == 0,
                  sameIdentity(metadata, openedRoot) else {
                close(rootDescriptor)
                changedDuringCheckCount += 1
                continue
            }
            rootDescriptors.append(rootDescriptor)

            var pending = [PendingDirectory(
                components: [], path: root.path, identity: directoryIdentity(metadata)
            )]
            while let directory = pending.popLast() {
                if shouldCancel() { cancelled = true; break }
                let directoryFD: Int32
                switch openDirectory(rootFD: rootDescriptor, directory: directory) {
                case .opened(let descriptor): directoryFD = descriptor
                case .changed:
                    changedDuringCheckCount += 1
                    continue
                case .unavailable:
                    inaccessibleCount += 1
                    continue
                }

                var before = stat()
                guard fstat(directoryFD, &before) == 0 else {
                    close(directoryFD)
                    inaccessibleCount += 1
                    continue
                }
                let streamDescriptor = dup(directoryFD)
                guard streamDescriptor >= 0, let stream = fdopendir(streamDescriptor) else {
                    if streamDescriptor >= 0 { close(streamDescriptor) }
                    close(directoryFD)
                    inaccessibleCount += 1
                    continue
                }

                var discovered: [PendingDirectory] = []
                while true {
                    errno = 0
                    guard let entry = readdir(stream) else {
                        if errno != 0 { inaccessibleCount += 1 }
                        break
                    }
                    let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                            String(cString: $0)
                        }
                    }
                    if name == "." || name == ".." { continue }
                    if shouldCancel() { cancelled = true; break }

                    var child = stat()
                    let statResult = name.withCString {
                        fstatat(directoryFD, $0, &child, AT_SYMLINK_NOFOLLOW)
                    }
                    guard statResult == 0 else { inaccessibleCount += 1; continue }
                    let components = directory.components + [name]
                    let path = (directory.path as NSString).appendingPathComponent(name)
                    switch child.st_mode & S_IFMT {
                    case S_IFLNK:
                        excludedSymlinkCount += 1
                    case S_IFDIR:
                        discovered.append(PendingDirectory(
                            components: components, path: path,
                            identity: directoryIdentity(child)
                        ))
                    case S_IFREG:
                        let identity = fileIdentity(child)
                        let size = UInt64(max(0, child.st_size))
                        candidatesBySize[size, default: []].append(Candidate(
                            rootDescriptor: rootDescriptor, components: components, path: path,
                            identity: identity, logicalBytes: size,
                            allocatedBytes: UInt64(max(0, child.st_blocks)) * 512,
                            metadata: child
                        ))
                    default:
                        excludedSpecialFileCount += 1
                    }
                }
                var after = stat()
                if fstat(directoryFD, &after) != 0 {
                    inaccessibleCount += 1
                } else {
                    if directoryMetadataChanged(before, after) { changedDuringCheckCount += 1 }
                    scannedDirectories.append(ScannedDirectory(
                        rootDescriptor: rootDescriptor,
                        components: directory.components,
                        path: directory.path,
                        identity: directory.identity,
                        metadata: after
                    ))
                }
                closedir(stream)
                close(directoryFD)
                pending.append(contentsOf: discovered)
            }
            if cancelled { break }
        }

        var representativeByIdentity: [FileIdentity: Candidate] = [:]
        for candidate in candidatesBySize.values.joined() {
            if let existing = representativeByIdentity[candidate.identity] {
                if utf8LessThan(candidate.path, existing.path) {
                    representativeByIdentity[candidate.identity] = candidate
                }
            } else {
                representativeByIdentity[candidate.identity] = candidate
            }
        }
        var uniqueCandidatesBySize: [UInt64: [Candidate]] = [:]
        for candidate in representativeByIdentity.values {
            uniqueCandidatesBySize[candidate.logicalBytes, default: []].append(candidate)
        }
        let buckets = uniqueCandidatesBySize.values.filter { $0.count > 1 }
        let candidateBytes = buckets.reduce(UInt64(0)) { total, bucket in
            bucket.reduce(total) { partial, file in
                let (sum, overflow) = partial.addingReportingOverflow(file.logicalBytes)
                return overflow ? UInt64.max : sum
            }
        }
        var bytesHashed: UInt64 = 0
        var lastProgressBytes: UInt64 = 0
        var checkedFileCount = 0
        var filesByHash: [String: [DuplicateFile]] = [:]

        outer: for bucket in buckets {
            for candidate in bucket.sorted(by: { utf8LessThan($0.path, $1.path) }) {
                if shouldCancel() { cancelled = true; break outer }
                switch hash(candidate, shouldCancel: shouldCancel, progress: { path, bytes in
                    let (sum, overflow) = bytesHashed.addingReportingOverflow(bytes)
                    bytesHashed = overflow ? UInt64.max : sum
                    if bytesHashed - lastProgressBytes >= 16 * 1024 * 1024 || bytesHashed == candidateBytes {
                        lastProgressBytes = bytesHashed
                        progress(DuplicateVerificationProgress(
                            currentPath: path, bytesHashed: bytesHashed,
                            candidateBytes: candidateBytes
                        ))
                    }
                }) {
                case .hashed(let digest):
                    checkedFileCount += 1
                    filesByHash[digest, default: []].append(DuplicateFile(
                        path: candidate.path,
                        logicalBytes: candidate.logicalBytes,
                        allocatedBytes: candidate.allocatedBytes
                    ))
                case .changed:
                    changedDuringCheckCount += 1
                case .unavailable:
                    inaccessibleCount += 1
                case .cancelled:
                    cancelled = true
                    break outer
                }
            }
        }

        if !cancelled {
            for directory in scannedDirectories {
                let pending = PendingDirectory(
                    components: directory.components,
                    path: directory.path,
                    identity: directory.identity
                )
                switch openDirectory(rootFD: directory.rootDescriptor, directory: pending) {
                case .opened(let descriptor):
                    var current = stat()
                    if fstat(descriptor, &current) != 0 {
                        inaccessibleCount += 1
                    } else if directoryMetadataChanged(directory.metadata, current) {
                        changedDuringCheckCount += 1
                    }
                    close(descriptor)
                case .changed:
                    changedDuringCheckCount += 1
                case .unavailable:
                    inaccessibleCount += 1
                }
            }
        }

        let groups = filesByHash.compactMap { digest, files -> DuplicateGroup? in
            guard files.count > 1 else { return nil }
            return DuplicateGroup(sha256: digest, files: files.sorted { utf8LessThan($0.path, $1.path) })
        }.sorted { utf8LessThan($0.sha256, $1.sha256) }

        return DuplicateVerificationResult(
            selectedRootPaths: roots.map(\.path), groups: groups,
            checkedFileCount: checkedFileCount,
            inaccessibleCount: inaccessibleCount,
            excludedSymlinkCount: excludedSymlinkCount,
            excludedSpecialFileCount: excludedSpecialFileCount,
            changedDuringCheckCount: changedDuringCheckCount,
            cancelled: cancelled
        )
    }

    private enum HashResult {
        case hashed(String)
        case changed
        case unavailable
        case cancelled
    }

    private static func hash(
        _ candidate: Candidate,
        shouldCancel: () -> Bool,
        progress: (String, UInt64) -> Void
    ) -> HashResult {
        guard !candidate.components.isEmpty else { return .unavailable }
        var parentFD = dup(candidate.rootDescriptor)
        guard parentFD >= 0 else { return .unavailable }
        defer { close(parentFD) }

        for component in candidate.components.dropLast() {
            let next = component.withCString {
                openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                let error = errno
                return itemChanged(error) ? .changed : .unavailable
            }
            close(parentFD)
            parentFD = next
        }

        guard let name = candidate.components.last else { return .unavailable }
        let fileFD = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fileFD >= 0 else { return itemChanged(errno) ? .changed : .unavailable }
        defer { close(fileFD) }

        var before = stat()
        guard fstat(fileFD, &before) == 0 else { return .unavailable }
        guard sameIdentity(candidate.metadata, before),
              fileIdentity(before) == candidate.identity,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              UInt64(before.st_size) == candidate.logicalBytes,
              !fileMetadataChanged(candidate.metadata, before) else { return .changed }

        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            if shouldCancel() { return .cancelled }
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(fileFD, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .unavailable
            }
            if count == 0 { break }
            digest.update(data: Data(buffer[0..<count]))
            progress(candidate.path, UInt64(count))
        }
        var after = stat()
        guard fstat(fileFD, &after) == 0 else { return .unavailable }
        guard !fileMetadataChanged(before, after), UInt64(max(0, after.st_size)) == candidate.logicalBytes else {
            return .changed
        }
        return .hashed(digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func openDirectory(
        rootFD: Int32, directory: PendingDirectory
    ) -> OpenResult {
        var descriptor = dup(rootFD)
        guard descriptor >= 0 else { return .unavailable }
        for component in directory.components {
            let next = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                let error = errno
                close(descriptor)
                return itemChanged(error) ? .changed : .unavailable
            }
            close(descriptor)
            descriptor = next
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { close(descriptor); return .unavailable }
        guard directoryIdentity(metadata) == directory.identity else { close(descriptor); return .changed }
        return .opened(descriptor)
    }

    private static func fileIdentity(_ value: stat) -> FileIdentity {
        FileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }

    private static func directoryIdentity(_ value: stat) -> DirectoryIdentity {
        DirectoryIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func fileMetadataChanged(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_size != rhs.st_size || lhs.st_mtimespec.tv_sec != rhs.st_mtimespec.tv_sec
            || lhs.st_mtimespec.tv_nsec != rhs.st_mtimespec.tv_nsec
            || lhs.st_ctimespec.tv_sec != rhs.st_ctimespec.tv_sec
            || lhs.st_ctimespec.tv_nsec != rhs.st_ctimespec.tv_nsec
    }

    private static func directoryMetadataChanged(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_nlink != rhs.st_nlink || fileMetadataChanged(lhs, rhs)
    }

    private static func itemChanged(_ error: Int32) -> Bool {
        error == ELOOP || error == ENOTDIR || error == ENOENT
    }

    private static func utf8LessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
