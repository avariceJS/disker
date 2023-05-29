import CryptoKit
import Darwin
import Foundation

public enum DuplicateVerificationPhase: Sendable, Equatable {
    case readingMetadata
    case awaitingContentAuthorization
    case readingContents
}

public struct DuplicateVerificationProgress: Sendable {
    public let phase: DuplicateVerificationPhase
    public let currentPath: String
    public let entriesVisited: Int
    public let bytesHashed: UInt64
    public let candidateFileCount: Int
    public let candidateBytes: UInt64
}

public struct DuplicateVerificationReadEstimate: Sendable {
    public let selectedRootPaths: [String]
    public let candidateFileCount: Int
    public let candidateBytes: UInt64
    public let entriesVisited: Int
    public let inaccessibleCount: Int
    public let excludedSymlinkCount: Int
    public let excludedSpecialFileCount: Int
    public let excludedVolumeBoundaryCount: Int
    public let changedDuringCheckCount: Int
    public let byteAccountingOverflowed: Bool

    public var metadataCoverageComplete: Bool {
        inaccessibleCount == 0 && excludedSymlinkCount == 0 && excludedSpecialFileCount == 0
            && excludedVolumeBoundaryCount == 0 && changedDuringCheckCount == 0
            && !byteAccountingOverflowed
    }
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
    public let verifiedAt: Date?
    public let selectedRootPaths: [String]
    public let groups: [DuplicateGroup]
    public let checkedFileCount: Int
    public let inaccessibleCount: Int
    public let excludedSymlinkCount: Int
    public let excludedSpecialFileCount: Int
    public let excludedVolumeBoundaryCount: Int
    public let changedDuringCheckCount: Int
    public let byteAccountingOverflowed: Bool
    public let cancelled: Bool
    /// The requested root count exceeded the supported bound; no files were read.
    public let selectedRootLimitExceeded: Bool

    public init(
        verifiedAt: Date? = .now, selectedRootPaths: [String], groups: [DuplicateGroup], checkedFileCount: Int,
        inaccessibleCount: Int, excludedSymlinkCount: Int, excludedSpecialFileCount: Int,
        excludedVolumeBoundaryCount: Int = 0,
        changedDuringCheckCount: Int, cancelled: Bool, byteAccountingOverflowed: Bool = false,
        selectedRootLimitExceeded: Bool = false
    ) {
        self.verifiedAt = verifiedAt
        self.selectedRootPaths = selectedRootPaths
        self.groups = groups
        self.checkedFileCount = checkedFileCount
        self.inaccessibleCount = inaccessibleCount
        self.excludedSymlinkCount = excludedSymlinkCount
        self.excludedSpecialFileCount = excludedSpecialFileCount
        self.excludedVolumeBoundaryCount = excludedVolumeBoundaryCount
        self.changedDuringCheckCount = changedDuringCheckCount
        self.byteAccountingOverflowed = byteAccountingOverflowed
        self.cancelled = cancelled
        self.selectedRootLimitExceeded = selectedRootLimitExceeded
    }

    public var complete: Bool {
        !selectedRootLimitExceeded && !cancelled && inaccessibleCount == 0 && excludedSymlinkCount == 0
            && excludedSpecialFileCount == 0 && excludedVolumeBoundaryCount == 0 && changedDuringCheckCount == 0
            && !byteAccountingOverflowed
    }

    private enum CodingKeys: String, CodingKey {
        case verifiedAt, selectedRootPaths, groups, checkedFileCount, inaccessibleCount
        case excludedSymlinkCount, excludedSpecialFileCount, excludedVolumeBoundaryCount, changedDuringCheckCount
        case byteAccountingOverflowed, cancelled, selectedRootLimitExceeded
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        verifiedAt = try values.decodeIfPresent(Date.self, forKey: .verifiedAt)
        selectedRootPaths = try values.decode([String].self, forKey: .selectedRootPaths)
        groups = try values.decode([DuplicateGroup].self, forKey: .groups)
        checkedFileCount = try values.decode(Int.self, forKey: .checkedFileCount)
        inaccessibleCount = try values.decode(Int.self, forKey: .inaccessibleCount)
        excludedSymlinkCount = try values.decode(Int.self, forKey: .excludedSymlinkCount)
        excludedSpecialFileCount = try values.decode(Int.self, forKey: .excludedSpecialFileCount)
        excludedVolumeBoundaryCount = try values.decodeIfPresent(Int.self, forKey: .excludedVolumeBoundaryCount) ?? 0
        changedDuringCheckCount = try values.decode(Int.self, forKey: .changedDuringCheckCount)
        byteAccountingOverflowed = try values.decodeIfPresent(Bool.self, forKey: .byteAccountingOverflowed) ?? false
        cancelled = try values.decode(Bool.self, forKey: .cancelled)
        selectedRootLimitExceeded = try values.decodeIfPresent(Bool.self, forKey: .selectedRootLimitExceeded) ?? false
    }
}

/// Byte-verifies only regular files under folders explicitly selected for this
/// operation. Metadata filters candidates before any file content is read.
/// This reports identical bytes, not safe-to-delete files or reclaimable space.
public enum DuplicateVerifier {
    public static let maximumSelectedRootCount = ApplicationFolderAssociation.maximumRelatedFolderCount

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

    private enum SelectedRootOpenResult {
        case opened(Int32, stat)
        case symbolicLink
        case changed
        case unavailable
    }

    private enum MetadataResult {
        case unchanged
        case changed
        case unavailable
    }

    public static func verify(
        roots: [URL],
        shouldCancel: () -> Bool = { Task.isCancelled },
        progress: (DuplicateVerificationProgress) -> Void = { _ in },
        authorizeContentRead: (DuplicateVerificationReadEstimate) -> Bool
    ) -> DuplicateVerificationResult {
        verifyInternal(
            roots: roots, simulatedDeviceIDsByPath: [:], scopedAccessGrantedByPath: [], shouldCancel: shouldCancel,
            progress: progress, authorizeContentRead: authorizeContentRead
        )
    }

    /// Device-ID injection for deterministic synthetic filesystem boundary checks.
    @_spi(DiskerTesting)
    public static func verify(
        roots: [URL], simulatedDeviceIDsByPath: [String: UInt64],
        scopedAccessGrantedByPath: Set<String> = [],
        shouldCancel: () -> Bool = { Task.isCancelled },
        progress: (DuplicateVerificationProgress) -> Void = { _ in },
        authorizeContentRead: (DuplicateVerificationReadEstimate) -> Bool
    ) -> DuplicateVerificationResult {
        verifyInternal(
            roots: roots, simulatedDeviceIDsByPath: simulatedDeviceIDsByPath,
            scopedAccessGrantedByPath: scopedAccessGrantedByPath,
            shouldCancel: shouldCancel, progress: progress, authorizeContentRead: authorizeContentRead
        )
    }

    private static func verifyInternal(
        roots: [URL], simulatedDeviceIDsByPath: [String: UInt64],
        scopedAccessGrantedByPath: Set<String>,
        shouldCancel: () -> Bool,
        progress: (DuplicateVerificationProgress) -> Void,
        authorizeContentRead: (DuplicateVerificationReadEstimate) -> Bool
    ) -> DuplicateVerificationResult {
        guard roots.count <= maximumSelectedRootCount else {
            return DuplicateVerificationResult(
                verifiedAt: nil, selectedRootPaths: [], groups: [], checkedFileCount: 0,
                inaccessibleCount: 0, excludedSymlinkCount: 0, excludedSpecialFileCount: 0,
                changedDuringCheckCount: 0, cancelled: false, selectedRootLimitExceeded: true
            )
        }

        var rootDescriptors: [Int32] = []
        var scopedURLs: [URL] = []
        var rootIdentityByPath: [String: FileIdentity] = [:]
        var rootsWithScopedAccess = Set<String>()
        defer {
            rootDescriptors.forEach { close($0) }
            scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        }

        var candidatesBySize: [UInt64: [Candidate]] = [:]
        var scannedDirectories: [ScannedDirectory] = []
        var inaccessibleCount = 0
        var excludedSymlinkCount = 0
        var excludedSpecialFileCount = 0
        var excludedVolumeBoundaryCount = 0
        var changedDuringCheckCount = 0
        var byteAccountingOverflowed = false
        var cancelled = false
        var entriesVisited = 0
        var lastMetadataProgressCount = 0

        for root in roots {
            if shouldCancel() { cancelled = true; break }
            let startedSecurityScope = root.startAccessingSecurityScopedResource()
            if startedSecurityScope { scopedURLs.append(root) }
            let scopedAccessGranted = startedSecurityScope
                || scopedAccessGrantedByPath.contains(root.path)
                || scopedAccessGrantedByPath.contains(root.standardizedFileURL.path)
            if scopedAccessGranted { rootsWithScopedAccess.insert(root.path) }
            let rootDescriptor: Int32
            let metadata: stat
            switch openSelectedRootWithoutFollowingLinks(root.path, scopedAccessGranted: scopedAccessGranted) {
            case .opened(let descriptor, let openedMetadata):
                rootDescriptor = descriptor
                metadata = openedMetadata
            case .symbolicLink:
                excludedSymlinkCount += 1
                continue
            case .changed:
                changedDuringCheckCount += 1
                continue
            case .unavailable:
                inaccessibleCount += 1
                continue
            }
            rootDescriptors.append(rootDescriptor)
            rootIdentityByPath[root.path] = fileIdentity(metadata)
            let rootDeviceID = UInt64(truncatingIfNeeded: metadata.st_dev)

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

                    let components = directory.components + [name]
                    let path = (directory.path as NSString).appendingPathComponent(name)
                    entriesVisited += 1
                    if entriesVisited - lastMetadataProgressCount >= 128 {
                        lastMetadataProgressCount = entriesVisited
                        progress(DuplicateVerificationProgress(
                            phase: .readingMetadata, currentPath: path, entriesVisited: entriesVisited,
                            bytesHashed: 0, candidateFileCount: 0, candidateBytes: 0
                        ))
                    }
                    var child = stat()
                    let statResult = name.withCString {
                        fstatat(directoryFD, $0, &child, AT_SYMLINK_NOFOLLOW)
                    }
                    guard statResult == 0 else { inaccessibleCount += 1; continue }
                    let childDeviceID = simulatedDeviceIDsByPath[path]
                        ?? UInt64(truncatingIfNeeded: child.st_dev)
                    if child.st_mode & S_IFMT != S_IFLNK && childDeviceID != rootDeviceID {
                        excludedVolumeBoundaryCount += 1
                        continue
                    }
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
                        let allocated = CheckedByteCount.multiplying(Int64(max(0, child.st_blocks)), 512)
                        byteAccountingOverflowed = byteAccountingOverflowed || allocated.overflowed
                        candidatesBySize[size, default: []].append(Candidate(
                            rootDescriptor: rootDescriptor, components: components, path: path,
                            identity: identity, logicalBytes: size,
                            allocatedBytes: UInt64(allocated.value),
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
                if entriesVisited > lastMetadataProgressCount {
                    lastMetadataProgressCount = entriesVisited
                    progress(DuplicateVerificationProgress(
                        phase: .readingMetadata, currentPath: directory.path, entriesVisited: entriesVisited,
                        bytesHashed: 0, candidateFileCount: 0, candidateBytes: 0
                    ))
                }
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
        var candidateBytes: UInt64 = 0
        var candidateFileCount = 0
        var candidateByteOverflowed = false
        for bucket in buckets {
            for candidate in bucket {
                candidateFileCount = candidateFileCount == Int.max ? Int.max : candidateFileCount + 1
                let (sum, overflow) = candidateBytes.addingReportingOverflow(candidate.logicalBytes)
                candidateBytes = overflow ? UInt64.max : sum
                candidateByteOverflowed = candidateByteOverflowed || overflow
            }
        }
        byteAccountingOverflowed = byteAccountingOverflowed || candidateByteOverflowed
        progress(DuplicateVerificationProgress(
            phase: .awaitingContentAuthorization, currentPath: "", entriesVisited: entriesVisited,
            bytesHashed: 0, candidateFileCount: candidateFileCount, candidateBytes: candidateBytes
        ))
        if shouldCancel() {
            cancelled = true
        } else if candidateFileCount > 0 && !authorizeContentRead(DuplicateVerificationReadEstimate(
            selectedRootPaths: roots.map(\.path), candidateFileCount: candidateFileCount,
            candidateBytes: candidateBytes, entriesVisited: entriesVisited,
            inaccessibleCount: inaccessibleCount, excludedSymlinkCount: excludedSymlinkCount,
            excludedSpecialFileCount: excludedSpecialFileCount,
            excludedVolumeBoundaryCount: excludedVolumeBoundaryCount,
            changedDuringCheckCount: changedDuringCheckCount,
            byteAccountingOverflowed: byteAccountingOverflowed
        )) {
            cancelled = true
        }
        if !cancelled && candidateFileCount > 0 {
            progress(DuplicateVerificationProgress(
                phase: .readingContents, currentPath: "", entriesVisited: entriesVisited,
                bytesHashed: 0, candidateFileCount: candidateFileCount, candidateBytes: candidateBytes
            ))
        }
        var bytesHashed: UInt64 = 0
        var lastProgressBytes: UInt64 = 0
        var checkedFileCount = 0
        var filesByHash: [String: [DuplicateFile]] = [:]
        var finalMetadataValidatedPaths = Set<String>()

        if !cancelled {
            outer: for bucket in buckets {
                for candidate in bucket.sorted(by: { utf8LessThan($0.path, $1.path) }) {
                    if shouldCancel() { cancelled = true; break outer }
                    switch hash(candidate, shouldCancel: shouldCancel, progress: { path, bytes in
                        let (sum, overflow) = bytesHashed.addingReportingOverflow(bytes)
                        bytesHashed = overflow ? UInt64.max : sum
                        if bytesHashed - lastProgressBytes >= 16 * 1024 * 1024 || bytesHashed == candidateBytes {
                            lastProgressBytes = bytesHashed
                            progress(DuplicateVerificationProgress(
                                phase: .readingContents, currentPath: path, entriesVisited: entriesVisited,
                                bytesHashed: bytesHashed,
                                candidateFileCount: candidateFileCount,
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

        if !cancelled {
            for candidate in candidatesBySize.values.joined() {
                if shouldCancel() { cancelled = true; break }
                switch revalidateMetadata(candidate) {
                case .unchanged:
                    finalMetadataValidatedPaths.insert(candidate.path)
                case .changed:
                    changedDuringCheckCount += 1
                case .unavailable:
                    inaccessibleCount += 1
                }
            }
        }

        var selectedRootPathsStable = true
        for (path, expectedIdentity) in rootIdentityByPath {
            switch openSelectedRootWithoutFollowingLinks(
                path, scopedAccessGranted: rootsWithScopedAccess.contains(path)
            ) {
            case .opened(let descriptor, let metadata):
                close(descriptor)
                if fileIdentity(metadata) != expectedIdentity {
                    changedDuringCheckCount += 1
                    selectedRootPathsStable = false
                }
            case .symbolicLink:
                excludedSymlinkCount += 1
                selectedRootPathsStable = false
            case .changed:
                changedDuringCheckCount += 1
                selectedRootPathsStable = false
            case .unavailable:
                inaccessibleCount += 1
                selectedRootPathsStable = false
            }
        }

        let groups = filesByHash.compactMap { digest, files -> DuplicateGroup? in
            let validatedFiles = files.filter { finalMetadataValidatedPaths.contains($0.path) }
            guard validatedFiles.count > 1 else { return nil }
            return DuplicateGroup(sha256: digest, files: validatedFiles.sorted { utf8LessThan($0.path, $1.path) })
        }.sorted { utf8LessThan($0.sha256, $1.sha256) }

        return DuplicateVerificationResult(
            verifiedAt: .now, selectedRootPaths: roots.map(\.path),
            groups: selectedRootPathsStable ? groups : [],
            checkedFileCount: checkedFileCount,
            inaccessibleCount: inaccessibleCount,
            excludedSymlinkCount: excludedSymlinkCount,
            excludedSpecialFileCount: excludedSpecialFileCount,
            excludedVolumeBoundaryCount: excludedVolumeBoundaryCount,
            changedDuringCheckCount: changedDuringCheckCount,
            cancelled: cancelled,
            byteAccountingOverflowed: byteAccountingOverflowed
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

    private static func revalidateMetadata(_ candidate: Candidate) -> MetadataResult {
        guard let name = candidate.components.last else { return .unavailable }
        var parentFD = dup(candidate.rootDescriptor)
        guard parentFD >= 0 else { return .unavailable }
        defer { close(parentFD) }

        for component in candidate.components.dropLast() {
            let next = component.withCString {
                openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                return itemChanged(errno) ? .changed : .unavailable
            }
            close(parentFD)
            parentFD = next
        }

        var current = stat()
        let result = name.withCString {
            fstatat(parentFD, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { return itemChanged(errno) ? .changed : .unavailable }
        return fileMetadataChanged(candidate.metadata, current) ? .changed : .unchanged
    }

    /// Opens a selected directory root without following symlinks in any path
    /// component. The returned descriptor is pinned to the metadata identity
    /// that will seed the traversal.
    private static func openSelectedRootWithoutFollowingLinks(
        _ path: String, scopedAccessGranted: Bool = false
    ) -> SelectedRootOpenResult {
        let rawComponents = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"),
              !rawComponents.contains("."), !rawComponents.contains("..") else {
            return .unavailable
        }

        // A security-scoped URL authorizes the selected root and its descendants,
        // but not a descriptor walk from `/` through every parent directory.
        // Open only that exact URL while the scope is active, reject symlinked
        // ancestors with `lstat`, and recheck their identities after opening.
        if scopedAccessGranted {
            let components = Array(URL(fileURLWithPath: path).standardizedFileURL.pathComponents.dropFirst())
            guard !components.isEmpty else { return .unavailable }
            var checkedAncestors: [(path: String, identity: FileIdentity)] = []
            var currentPath = ""
            var selectedMetadata = stat()
            for (index, component) in components.enumerated() {
                currentPath += "/" + component
                var componentMetadata = stat()
                let lookup = currentPath.withCString { lstat($0, &componentMetadata) }
                guard lookup == 0 else { return .unavailable }
                let type = componentMetadata.st_mode & S_IFMT
                if type == S_IFLNK { return .symbolicLink }
                if index < components.count - 1, type != S_IFDIR { return .changed }
                checkedAncestors.append((currentPath, fileIdentity(componentMetadata)))
                if index == components.count - 1 { selectedMetadata = componentMetadata }
            }
            guard selectedMetadata.st_mode & S_IFMT == S_IFDIR else { return .unavailable }
            let selectedDescriptor = path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard selectedDescriptor >= 0 else {
                if errno == ELOOP { return .symbolicLink }
                if errno == ENOENT || errno == ENOTDIR { return .changed }
                return .unavailable
            }
            var openedMetadata = stat()
            guard fstat(selectedDescriptor, &openedMetadata) == 0 else {
                close(selectedDescriptor)
                return .unavailable
            }
            guard sameIdentity(selectedMetadata, openedMetadata), openedMetadata.st_mode & S_IFMT == S_IFDIR else {
                close(selectedDescriptor)
                return .changed
            }
            for ancestor in checkedAncestors {
                var currentMetadata = stat()
                let recheck = ancestor.path.withCString { lstat($0, &currentMetadata) }
                guard recheck == 0 else {
                    close(selectedDescriptor)
                    return .unavailable
                }
                guard currentMetadata.st_mode & S_IFMT != S_IFLNK,
                      fileIdentity(currentMetadata) == ancestor.identity else {
                    close(selectedDescriptor)
                    return .changed
                }
            }
            return .opened(selectedDescriptor, openedMetadata)
        }

        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .unavailable }
        let components = Array(URL(fileURLWithPath: path).standardizedFileURL.pathComponents.dropFirst())
        var metadata = stat()
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                close(descriptor)
                return .unavailable
            }
            var enumerated = stat()
            let lookup = component.withCString {
                fstatat(descriptor, $0, &enumerated, AT_SYMLINK_NOFOLLOW)
            }
            guard lookup == 0 else {
                let error = errno
                close(descriptor)
                return error == ELOOP ? .symbolicLink : .unavailable
            }
            guard enumerated.st_mode & S_IFMT == S_IFDIR else {
                close(descriptor)
                return enumerated.st_mode & S_IFMT == S_IFLNK ? .symbolicLink : .unavailable
            }

            let nextDescriptor = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard nextDescriptor >= 0 else {
                let error = errno
                close(descriptor)
                if error == ELOOP { return .symbolicLink }
                if error == ENOENT || error == ENOTDIR { return .changed }
                return .unavailable
            }
            var opened = stat()
            guard fstat(nextDescriptor, &opened) == 0 else {
                close(nextDescriptor)
                close(descriptor)
                return .unavailable
            }
            guard sameIdentity(enumerated, opened), opened.st_mode & S_IFMT == S_IFDIR else {
                close(nextDescriptor)
                close(descriptor)
                return .changed
            }
            close(descriptor)
            descriptor = nextDescriptor
            metadata = opened
        }

        if components.isEmpty {
            guard fstat(descriptor, &metadata) == 0 else {
                close(descriptor)
                return .unavailable
            }
        }
        return .opened(descriptor, metadata)
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
        !sameIdentity(lhs, rhs) || lhs.st_mode & S_IFMT != rhs.st_mode & S_IFMT
            || lhs.st_size != rhs.st_size || lhs.st_blocks != rhs.st_blocks
            || lhs.st_mtimespec.tv_sec != rhs.st_mtimespec.tv_sec
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
