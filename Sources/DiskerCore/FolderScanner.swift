import Darwin
import Foundation

public struct ScanProgress: Sendable {
    public let currentPath: String
    public let visitedFiles: Int
}

public enum FolderScanner {
    private static let maximumDirectorySummaries = 100
    private static let maximumProjectDirectorySummaries = 20
    private static let maximumFileExtensionSummaries = 30

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct FileRecord {
        let relativePath: String
        let parentPath: String
        let identity: FileIdentity
        let logicalBytes: Int64
        let allocatedBytes: Int64
        let extensionName: String
    }

    private struct ScannedFileMetadata {
        let name: String
        let identity: FileIdentity
        let fileType: UInt32
        let size: Int64
        let allocatedBlocks: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(name: String, metadata: stat) {
            self.name = name
            identity = FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
            fileType = UInt32(metadata.st_mode & S_IFMT)
            size = Int64(metadata.st_size)
            allocatedBlocks = Int64(metadata.st_blocks)
            modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
            changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
        }

        func differs(from metadata: stat) -> Bool {
            identity != FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
                || fileType != UInt32(metadata.st_mode & S_IFMT)
                || size != Int64(metadata.st_size)
                || allocatedBlocks != Int64(metadata.st_blocks)
                || modifiedSeconds != Int64(metadata.st_mtimespec.tv_sec)
                || modifiedNanoseconds != Int64(metadata.st_mtimespec.tv_nsec)
                || changedSeconds != Int64(metadata.st_ctimespec.tv_sec)
                || changedNanoseconds != Int64(metadata.st_ctimespec.tv_nsec)
        }
    }

    private struct FileExtensionMetrics {
        var logicalBytes: Int64 = 0
        var allocatedBytes: Int64 = 0
        var fileCount = 0
    }

    private struct PendingDirectory {
        let components: [String]
        let relativePath: String
        let path: String
        let expectedIdentity: FileIdentity
    }

    private enum DirectoryOpenResult {
        case opened(Int32)
        case changed
        case unavailable
    }

    private struct DirectoryMetrics {
        var logicalBytes: Int64 = 0
        var allocatedBytes: Int64 = 0
        var fileCount = 0
        var incompleteCount = 0
        var excludedSymlinkCount = 0
        var excludedSpecialFileCount = 0
        var changedDuringScanCount = 0
        var gitMetadataEntryDetected = false
    }

    public static func scan(
        roots: [URL],
        shouldCancel: () -> Bool = { Task.isCancelled },
        progress: (ScanProgress) -> Void = { _ in }
    ) -> ScanObservation {
        let startedAt = Date.now
        var results: [FolderObservation] = []
        var cancelled = false

        for root in roots {
            if shouldCancel() {
                cancelled = true
                break
            }

            let accessGranted = root.startAccessingSecurityScopedResource()
            defer {
                if accessGranted { root.stopAccessingSecurityScopedResource() }
            }

            var rootMetadata = stat()
            guard root.path.withCString({ lstat($0, &rootMetadata) }) == 0 else {
                results.append(emptyObservation(root: root, inaccessibleCount: 1))
                continue
            }

            let rootType = rootMetadata.st_mode & S_IFMT
            if rootType == S_IFLNK {
                // The selected link is explicitly excluded, not reported as an
                // inaccessible metadata lookup. Its target is never opened.
                results.append(emptyObservation(root: root, excludedSymlinkCount: 1))
                continue
            }

            var linkedFilesByIdentity: [FileIdentity: FileRecord] = [:]
            // Keep the scanner's prior identity-only dedup set. Path-bearing
            // records are retained only for objects known to have multiple links.
            var seenFileIdentities = Set<FileIdentity>()
            var metrics: [String: DirectoryMetrics] = ["": DirectoryMetrics()]
            var inaccessibleCount = 0
            var excludedSymlinkCount = 0
            var fileCountForProgress = 0
            var scanComplete = true
            var rootLogicalBytes: Int64 = 0
            var rootAllocatedBytes: Int64 = 0
            var rootFileCount = 0
            var excludedSpecialFileCount = 0
            var extensionMetrics: [String: FileExtensionMetrics] = [:]

            if rootType != S_IFDIR {
                guard rootType == S_IFREG else {
                    results.append(emptyObservation(root: root, excludedSpecialFileCount: 1))
                    continue
                }
                let file = fileRecord(metadata: rootMetadata, relativePath: root.lastPathComponent, parentPath: "")
                if rootMetadata.st_nlink > 1 {
                    seenFileIdentities.insert(file.identity)
                    linkedFilesByIdentity[file.identity] = file
                } else if seenFileIdentities.insert(file.identity).inserted {
                    addFile(file, to: "", metrics: &metrics)
                    rootLogicalBytes += file.logicalBytes
                    rootAllocatedBytes += file.allocatedBytes
                    rootFileCount += 1
                    addFileExtension(file, to: &extensionMetrics)
                }
            } else {
                let rootFD = root.path.withCString {
                    open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard rootFD >= 0 else {
                    results.append(emptyObservation(root: root, inaccessibleCount: 1))
                    continue
                }
                defer { close(rootFD) }

                var openedRootMetadata = stat()
                guard fstat(rootFD, &openedRootMetadata) == 0 else {
                    results.append(emptyObservation(root: root, inaccessibleCount: 1))
                    continue
                }
                guard sameIdentity(rootMetadata, openedRootMetadata) else {
                    results.append(emptyObservation(root: root, changedDuringScanCount: 1))
                    continue
                }

                var pending = [PendingDirectory(
                    components: [], relativePath: "", path: root.path,
                    expectedIdentity: identity(of: rootMetadata)
                )]
                while !pending.isEmpty {
                    if shouldCancel() {
                        cancelled = true
                        scanComplete = false
                        for directory in pending {
                            addCoverageEvent(directory.relativePath, symlink: false, to: &metrics)
                        }
                        break
                    }
                    let directory = pending.removeLast()
                    let directoryFD: Int32
                    switch openDirectory(rootFD: rootFD, directory: directory) {
                    case .opened(let descriptor):
                        directoryFD = descriptor
                    case .changed:
                        scanComplete = false
                        addCoverageEvent(directory.relativePath, symlink: false, changed: true, to: &metrics)
                        continue
                    case .unavailable:
                        inaccessibleCount += 1
                        scanComplete = false
                        addCoverageEvent(directory.relativePath, symlink: false, to: &metrics)
                        continue
                    }

                    var beforeDirectoryRead = stat()
                    guard fstat(directoryFD, &beforeDirectoryRead) == 0 else {
                        close(directoryFD)
                        inaccessibleCount += 1
                        scanComplete = false
                        addCoverageEvent(directory.relativePath, symlink: false, to: &metrics)
                        continue
                    }

                    let streamFD = dup(directoryFD)
                    guard streamFD >= 0, let stream = fdopendir(streamFD) else {
                        if streamFD >= 0 { close(streamFD) }
                        close(directoryFD)
                        inaccessibleCount += 1
                        scanComplete = false
                        addCoverageEvent(directory.relativePath, symlink: false, to: &metrics)
                        continue
                    }

                    var discoveredDirectories: [PendingDirectory] = []
                    var scannedFiles: [ScannedFileMetadata] = []
                    var interrupted = false
                    while true {
                        errno = 0
                        guard let entry = readdir(stream) else {
                            if errno != 0 {
                                inaccessibleCount += 1
                                scanComplete = false
                                addCoverageEvent(directory.relativePath, symlink: false, to: &metrics)
                            }
                            break
                        }
                        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                                String(cString: $0)
                            }
                        }
                        if name == "." || name == ".." { continue }
                        if shouldCancel() {
                            cancelled = true
                            scanComplete = false
                            addCoverageEvent(directory.relativePath, symlink: false, to: &metrics)
                            interrupted = true
                            break
                        }

                        var metadata = stat()
                        let statResult = name.withCString {
                            fstatat(directoryFD, $0, &metadata, AT_SYMLINK_NOFOLLOW)
                        }
                        guard statResult == 0 else {
                            inaccessibleCount += 1
                            scanComplete = false
                            addCoverageEvent(directory.relativePath, symlink: false, to: &metrics)
                            continue
                        }
                        let relativePath = directory.relativePath.isEmpty
                            ? name
                            : directory.relativePath + "/" + name
                        let fullPath = (directory.path as NSString).appendingPathComponent(name)
                        let type = metadata.st_mode & S_IFMT
                        if name == ".git", type == S_IFDIR || type == S_IFREG {
                            var parentMetrics = metrics[directory.relativePath, default: DirectoryMetrics()]
                            parentMetrics.gitMetadataEntryDetected = true
                            metrics[directory.relativePath] = parentMetrics
                        }
                        if type == S_IFLNK {
                            excludedSymlinkCount += 1
                            addCoverageEvent(directory.relativePath, symlink: true, to: &metrics)
                        } else if type == S_IFDIR {
                            metrics[relativePath] = DirectoryMetrics()
                            discoveredDirectories.append(PendingDirectory(
                                components: directory.components + [name],
                                relativePath: relativePath,
                                path: fullPath,
                                expectedIdentity: identity(of: metadata)
                            ))
                        } else if type != S_IFREG {
                            excludedSpecialFileCount += 1
                            addCoverageEvent(directory.relativePath, symlink: false, specialFile: true, to: &metrics)
                        } else {
                            // Keep only the current directory's file metadata
                            // and revalidate it after enumeration. This catches
                            // in-place writes that directory timestamps cannot.
                            scannedFiles.append(ScannedFileMetadata(name: name, metadata: metadata))
                            let file = fileRecord(
                                metadata: metadata,
                                relativePath: relativePath,
                                parentPath: directory.relativePath
                            )
                            var isNewFileObject = false
                            if metadata.st_nlink > 1 {
                                if let existing = linkedFilesByIdentity[file.identity] {
                                    if utf8LessThan(file.relativePath, existing.relativePath) {
                                        linkedFilesByIdentity[file.identity] = file
                                    }
                                } else if seenFileIdentities.insert(file.identity).inserted {
                                    linkedFilesByIdentity[file.identity] = file
                                    isNewFileObject = true
                                }
                            } else if seenFileIdentities.insert(file.identity).inserted {
                                addFile(file, to: directory.relativePath, metrics: &metrics)
                                rootLogicalBytes += file.logicalBytes
                                rootAllocatedBytes += file.allocatedBytes
                                rootFileCount += 1
                                addFileExtension(file, to: &extensionMetrics)
                                isNewFileObject = true
                            }
                            if isNewFileObject {
                                fileCountForProgress += 1
                                if fileCountForProgress.isMultiple(of: 256) {
                                    progress(ScanProgress(currentPath: fullPath, visitedFiles: fileCountForProgress))
                                }
                            }
                        }
                    }
                    if !interrupted {
                        for file in scannedFiles {
                            var current = stat()
                            let result = file.name.withCString {
                                fstatat(directoryFD, $0, &current, AT_SYMLINK_NOFOLLOW)
                            }
                            if result != 0 {
                                if errno == ENOENT || errno == ENOTDIR || errno == ELOOP {
                                    scanComplete = false
                                    addCoverageEvent(directory.relativePath, symlink: false, changed: true, to: &metrics)
                                } else {
                                    inaccessibleCount += 1
                                    scanComplete = false
                                    addCoverageEvent(directory.relativePath, symlink: false, to: &metrics)
                                }
                            } else if file.differs(from: current) {
                                scanComplete = false
                                addCoverageEvent(directory.relativePath, symlink: false, changed: true, to: &metrics)
                            }
                        }
                    }
                    var afterDirectoryRead = stat()
                    if fstat(directoryFD, &afterDirectoryRead) == 0,
                       directoryMetadataChanged(beforeDirectoryRead, afterDirectoryRead) {
                        scanComplete = false
                        addCoverageEvent(directory.relativePath, symlink: false, changed: true, to: &metrics)
                    }
                    closedir(stream)
                    close(directoryFD)
                    pending.append(contentsOf: discoveredDirectories)
                    if interrupted {
                        for unvisited in pending {
                            addCoverageEvent(unvisited.relativePath, symlink: false, to: &metrics)
                        }
                        break
                    }
                }
            }

            // Among multiply-linked paths, the smallest UTF-8 relative path owns
            // the object's bytes. Unique files never need to retain their paths.
            let linkedFiles = linkedFilesByIdentity.values.sorted {
                utf8LessThan($0.relativePath, $1.relativePath)
            }
            for file in linkedFiles {
                addFile(file, to: file.parentPath, metrics: &metrics)
                rootLogicalBytes += file.logicalBytes
                rootAllocatedBytes += file.allocatedBytes
                rootFileCount += 1
                addFileExtension(file, to: &extensionMetrics)
            }

            // Aggregate each directory into its parent once, deepest first.
            let directoryPaths = metrics.keys.filter { !$0.isEmpty }.sorted { lhs, rhs in
                let leftDepth = lhs.split(separator: "/").count
                let rightDepth = rhs.split(separator: "/").count
                if leftDepth != rightDepth { return leftDepth > rightDepth }
                return utf8LessThan(lhs, rhs)
            }
            for path in directoryPaths {
                guard let child = metrics[path] else { continue }
                let parent = parentPath(of: path)
                var parentMetrics = metrics[parent, default: DirectoryMetrics()]
                parentMetrics.logicalBytes += child.logicalBytes
                parentMetrics.allocatedBytes += child.allocatedBytes
                parentMetrics.fileCount += child.fileCount
                parentMetrics.incompleteCount += child.incompleteCount
                parentMetrics.excludedSymlinkCount += child.excludedSymlinkCount
                parentMetrics.excludedSpecialFileCount += child.excludedSpecialFileCount
                parentMetrics.changedDuringScanCount += child.changedDuringScanCount
                metrics[parent] = parentMetrics
            }

            let summaries = directoryPaths.compactMap { path -> DirectoryUsage? in
                guard let value = metrics[path] else { return nil }
                return directoryUsage(path: path, metrics: value)
            }.sorted {
                if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
                return utf8LessThan($0.rootRelativePath, $1.rootRelativePath)
            }
            let wasTruncated = summaries.count > maximumDirectorySummaries
            let projectSummaries = summaries.filter(\.gitMetadataEntryDetected)
            // Keep the direct repository metadata component independently of
            // the leaderboard cap; `.git` itself remains an explicitly
            // selected-root-relative measurement, not proof of project ownership.
            let gitMetadataUsage = metrics[".git"].map {
                directoryUsage(path: ".git", metrics: $0)
            }
            let rankedExtensions = extensionMetrics.map { name, value in
                FileExtensionUsage(
                    extensionName: name,
                    logicalBytes: value.logicalBytes,
                    allocatedBytes: value.allocatedBytes,
                    fileCount: value.fileCount
                )
            }.sorted {
                if $0.allocatedBytes != $1.allocatedBytes {
                    return $0.allocatedBytes > $1.allocatedBytes
                }
                return $0.extensionName < $1.extensionName
            }
            let omittedExtensions = rankedExtensions.dropFirst(maximumFileExtensionSummaries)
            let otherExtensionUsage: FileExtensionUsage? = omittedExtensions.isEmpty ? nil : FileExtensionUsage(
                extensionName: "other extensions",
                logicalBytes: omittedExtensions.reduce(Int64(0)) { $0 + $1.logicalBytes },
                allocatedBytes: omittedExtensions.reduce(Int64(0)) { $0 + $1.allocatedBytes },
                fileCount: omittedExtensions.reduce(0) { $0 + $1.fileCount }
            )

            results.append(FolderObservation(
                path: root.path,
                displayName: root.lastPathComponent,
                logicalBytes: rootLogicalBytes,
                allocatedBytes: rootAllocatedBytes,
                fileCount: rootFileCount,
                fileExtensionSummaries: Array(rankedExtensions.prefix(maximumFileExtensionSummaries)),
                fileExtensionSummariesTruncated: rankedExtensions.count > maximumFileExtensionSummaries,
                otherFileExtensionUsage: otherExtensionUsage,
                otherFileExtensionCategoryCount: max(0, rankedExtensions.count - maximumFileExtensionSummaries),
                inaccessibleCount: inaccessibleCount,
                complete: scanComplete && inaccessibleCount == 0 && excludedSymlinkCount == 0
                    && excludedSpecialFileCount == 0
                    && metrics[""]?.changedDuringScanCount == 0,
                excludedSymlinkCount: excludedSymlinkCount,
                excludedSpecialFileCount: excludedSpecialFileCount,
                changedDuringScanCount: metrics[""]?.changedDuringScanCount ?? 0,
                gitMetadataEntryDetected: metrics[""]?.gitMetadataEntryDetected ?? false,
                gitMetadataUsage: gitMetadataUsage,
                subdirectorySummaries: Array(summaries.prefix(maximumDirectorySummaries)),
                subdirectorySummariesTruncated: wasTruncated,
                projectDirectorySummaries: Array(projectSummaries.prefix(maximumProjectDirectorySummaries)),
                projectDirectorySummariesTruncated: projectSummaries.count > maximumProjectDirectorySummaries
            ))

            if cancelled { break }
        }

        return ScanObservation(startedAt: startedAt, folders: results, cancelled: cancelled)
    }

    private static func directoryUsage(path: String, metrics value: DirectoryMetrics) -> DirectoryUsage {
        DirectoryUsage(
            rootRelativePath: path,
            logicalBytes: value.logicalBytes,
            allocatedBytes: value.allocatedBytes,
            fileCount: value.fileCount,
            incompleteCount: value.incompleteCount,
            excludedSymlinkCount: value.excludedSymlinkCount,
            excludedSpecialFileCount: value.excludedSpecialFileCount,
            changedDuringScanCount: value.changedDuringScanCount,
            gitMetadataEntryDetected: value.gitMetadataEntryDetected,
            complete: value.incompleteCount == 0 && value.excludedSymlinkCount == 0
                && value.excludedSpecialFileCount == 0
                && value.changedDuringScanCount == 0
        )
    }

    private static func emptyObservation(
        root: URL, inaccessibleCount: Int = 0, excludedSymlinkCount: Int = 0,
        excludedSpecialFileCount: Int = 0, changedDuringScanCount: Int = 0
    ) -> FolderObservation {
        FolderObservation(
            path: root.path,
            displayName: root.lastPathComponent,
            logicalBytes: 0,
            allocatedBytes: 0,
            fileCount: 0,
            inaccessibleCount: inaccessibleCount,
            complete: false,
            excludedSymlinkCount: excludedSymlinkCount,
            excludedSpecialFileCount: excludedSpecialFileCount,
            changedDuringScanCount: changedDuringScanCount
        )
    }

    private static func fileRecord(metadata: stat, relativePath: String, parentPath: String) -> FileRecord {
        FileRecord(
            relativePath: relativePath,
            parentPath: parentPath,
            identity: FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino)),
            logicalBytes: Int64(max(0, metadata.st_size)),
            allocatedBytes: Int64(max(0, metadata.st_blocks)) * 512,
            extensionName: fileExtensionName(relativePath: relativePath)
        )
    }

    private static func fileExtensionName(relativePath: String) -> String {
        let fileName = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        let pathExtension = (fileName as NSString).pathExtension.lowercased()
        guard !pathExtension.isEmpty else { return "no extension" }
        guard pathExtension.utf8.count <= 32,
              pathExtension.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                    || (97...122).contains(scalar.value)
                    || scalar == "-" || scalar == "_" || scalar == "+"
              }) else { return "other" }
        return pathExtension
    }

    private static func addFileExtension(
        _ file: FileRecord, to summaries: inout [String: FileExtensionMetrics]
    ) {
        var value = summaries[file.extensionName, default: FileExtensionMetrics()]
        value.logicalBytes += file.logicalBytes
        value.allocatedBytes += file.allocatedBytes
        value.fileCount += 1
        summaries[file.extensionName] = value
    }

    private static func addFile(
        _ file: FileRecord, to parentPath: String, metrics: inout [String: DirectoryMetrics]
    ) {
        var value = metrics[parentPath, default: DirectoryMetrics()]
        value.logicalBytes += file.logicalBytes
        value.allocatedBytes += file.allocatedBytes
        value.fileCount += 1
        metrics[parentPath] = value
    }

    private static func addCoverageEvent(
        _ path: String, symlink: Bool, specialFile: Bool = false, changed: Bool = false,
        to metrics: inout [String: DirectoryMetrics]
    ) {
        var value = metrics[path, default: DirectoryMetrics()]
        if symlink { value.excludedSymlinkCount += 1 }
        else if specialFile { value.excludedSpecialFileCount += 1 }
        else if changed { value.changedDuringScanCount += 1 }
        else { value.incompleteCount += 1 }
        metrics[path] = value
    }

    private static func parentPath(of path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return "" }
        return String(path[..<separator])
    }

    private static func utf8LessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func openDirectory(rootFD: Int32, directory: PendingDirectory) -> DirectoryOpenResult {
        var descriptor = dup(rootFD)
        guard descriptor >= 0 else { return .unavailable }
        for component in directory.components {
            let child = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            let openError = errno
            close(descriptor)
            guard child >= 0 else {
                return openError == ENOENT || openError == ENOTDIR || openError == ELOOP
                    ? .changed : .unavailable
            }
            descriptor = child
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            close(descriptor)
            return .unavailable
        }
        guard identity(of: metadata) == directory.expectedIdentity else {
            close(descriptor)
            return .changed
        }
        return .opened(descriptor)
    }

    private static func identity(of metadata: stat) -> FileIdentity {
        FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        identity(of: lhs) == identity(of: rhs)
    }

    private static func directoryMetadataChanged(_ before: stat, _ after: stat) -> Bool {
        before.st_nlink != after.st_nlink
            || before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec
            || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec
            || before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec
            || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec
    }

}
