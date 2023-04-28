import Darwin
import Foundation

public struct ScanProgress: Sendable {
    public let currentPath: String
    public let countedFileObjects: Int
}

public enum FolderScanner {
    private static let maximumDirectorySummaries = 100
    private static let maximumProjectDirectorySummaries = 20
    private static let maximumLargestFileSummaries = 20
    private static let maximumFileExtensionSummaries = 30
    private static let maximumExcludedSymlinkPathSummaries = 32
    private static let maximumInventoryEntriesPerRoot = 500_000

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
        let allocatedBytesOverflowed: Bool
        let extensionName: String
        var lastModifiedAt: Date?
    }

    private struct LinkedFileRecord {
        var file: FileRecord
        let firstObservedMetadata: ScannedFileMetadata
        var modificationDateWithheld: Bool
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

        func differs(from other: ScannedFileMetadata) -> Bool {
            identity != other.identity
                || fileType != other.fileType
                || size != other.size
                || allocatedBlocks != other.allocatedBlocks
                || modifiedSeconds != other.modifiedSeconds
                || modifiedNanoseconds != other.modifiedNanoseconds
                || changedSeconds != other.changedSeconds
                || changedNanoseconds != other.changedNanoseconds
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

    private enum SelectedRootOpenResult {
        case openedDirectory(Int32, stat)
        case metadata(stat)
        case symbolicLink
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
        var excludedVolumeBoundaryCount = 0
        var changedDuringScanCount = 0
        var gitMetadataEntryDetected = false
    }

    public static func scan(
        roots: [URL],
        shouldCancel: () -> Bool = { Task.isCancelled },
        progress: (ScanProgress) -> Void = { _ in }
    ) -> ScanObservation {
        var inventories: [FileInventorySnapshot] = []
        return scanInternal(
            roots: roots, simulatedDeviceIDsByPath: [:], shouldCancel: shouldCancel,
            progress: progress, collectFileInventories: false, fileInventories: &inventories
        )
    }

    public static func scanWithFileInventories(
        roots: [URL], shouldCancel: () -> Bool = { Task.isCancelled },
        progress: (ScanProgress) -> Void = { _ in }
    ) -> DetailedScanObservation {
        var inventories: [FileInventorySnapshot] = []
        let observation = scanInternal(
            roots: roots, simulatedDeviceIDsByPath: [:], shouldCancel: shouldCancel,
            progress: progress, collectFileInventories: true, fileInventories: &inventories
        )
        return DetailedScanObservation(observation: observation, fileInventories: inventories)
    }

    /// Device-ID injection for deterministic synthetic filesystem boundary checks.
    @_spi(DiskerTesting)
    public static func scan(
        roots: [URL], simulatedDeviceIDsByPath: [String: UInt64],
        treatRootsAsSecurityScoped: Bool = false,
        shouldCancel: () -> Bool = { Task.isCancelled },
        progress: (ScanProgress) -> Void = { _ in },
        directoryDidFinish: (String) -> Void = { _ in }
    ) -> ScanObservation {
        var inventories: [FileInventorySnapshot] = []
        return scanInternal(
            roots: roots, simulatedDeviceIDsByPath: simulatedDeviceIDsByPath,
            sandboxedRootAccessOverride: treatRootsAsSecurityScoped,
            shouldCancel: shouldCancel, progress: progress, directoryDidFinish: directoryDidFinish,
            collectFileInventories: false, fileInventories: &inventories
        )
    }

    private static func scanInternal(
        roots: [URL], simulatedDeviceIDsByPath: [String: UInt64],
        sandboxedRootAccessOverride: Bool? = nil,
        shouldCancel: () -> Bool,
        progress: (ScanProgress) -> Void,
        directoryDidFinish: (String) -> Void = { _ in },
        collectFileInventories: Bool,
        fileInventories: inout [FileInventorySnapshot]
    ) -> ScanObservation {
        let startedAt = Date.now
        var results: [FolderObservation] = []
        var selectedFileRoots: [(index: Int, inventoryIndex: Int?, path: URL, metadata: ScannedFileMetadata)] = []
        var cancelled = false
        let sandboxedProcess = sandboxedRootAccessOverride
            ?? ((try? SelectedScopeBookmarkStore.isCurrentProcessSandboxed()) ?? false)

        for root in roots {
            if shouldCancel() {
                cancelled = true
                break
            }

            let accessGranted = root.startAccessingSecurityScopedResource()
            defer {
                if accessGranted { root.stopAccessingSecurityScopedResource() }
            }
            let rootMetadata: stat
            let directoryRootDescriptor: Int32?
            let rootType: UInt32
            switch openSelectedRootWithoutFollowingLinks(
                root.path, scopedAccessGranted: sandboxedProcess && accessGranted
            ) {
            case .openedDirectory(let descriptor, let metadata):
                directoryRootDescriptor = descriptor
                rootMetadata = metadata
                rootType = UInt32(S_IFDIR)
            case .metadata(let metadata):
                directoryRootDescriptor = nil
                rootMetadata = metadata
                rootType = UInt32(metadata.st_mode & S_IFMT)
            case .symbolicLink:
                results.append(emptyObservation(root: root, excludedSymlinkCount: 1))
                continue
            case .changed:
                results.append(emptyObservation(root: root, changedDuringScanCount: 1))
                continue
            case .unavailable:
                results.append(emptyObservation(root: root, inaccessibleCount: 1))
                continue
            }
            var rootVolumeDeviceID = UInt64(truncatingIfNeeded: rootMetadata.st_dev)

            var linkedFilesByIdentity: [FileIdentity: LinkedFileRecord] = [:]
            // Keep the scanner's prior identity-only dedup set. Path-bearing
            // records are retained only for objects known to have multiple links.
            var seenFileIdentities = Set<FileIdentity>()
            var metrics: [String: DirectoryMetrics] = ["": DirectoryMetrics()]
            var inaccessibleCount = 0
            var excludedSymlinkCount = 0
            var excludedSymlinkPaths: [String] = []
            var excludedVolumeBoundaryCount = 0
            var fileCountForProgress = 0
            var visitedEntryCountForProgress = 0
            var scanComplete = true
            var inventoryRootStable = true
            var accountingOverflow = false
            let selectedFileMetadata = rootType == UInt32(S_IFREG)
                ? ScannedFileMetadata(name: root.lastPathComponent, metadata: rootMetadata)
                : nil
            var rootLogicalBytes: Int64 = 0
            var rootAllocatedBytes: Int64 = 0
            var rootFileCount = 0
            var excludedSpecialFileCount = 0
            var extensionMetrics: [String: FileExtensionMetrics] = [:]
            var largestUniqueFiles: [FileUsageSummary] = []
            var inventoryEntries: [FileInventoryEntry] = []
            var inventoryTruncated = false

            if rootType != UInt32(S_IFDIR) {
                guard rootType == UInt32(S_IFREG) else {
                    results.append(emptyObservation(root: root, volumeDeviceID: rootVolumeDeviceID, excludedSpecialFileCount: 1))
                    continue
                }
                let file = fileRecord(metadata: rootMetadata, relativePath: root.lastPathComponent, parentPath: "")
                if rootMetadata.st_nlink > 1 {
                    seenFileIdentities.insert(file.identity)
                    linkedFilesByIdentity[file.identity] = LinkedFileRecord(
                        file: file,
                        firstObservedMetadata: ScannedFileMetadata(name: root.lastPathComponent, metadata: rootMetadata),
                        modificationDateWithheld: false
                    )
                } else if seenFileIdentities.insert(file.identity).inserted {
                    addFile(file, to: "", metrics: &metrics, overflowed: &accountingOverflow)
                    accumulate(file.logicalBytes, into: &rootLogicalBytes, overflowed: &accountingOverflow)
                    accumulate(file.allocatedBytes, into: &rootAllocatedBytes, overflowed: &accountingOverflow)
                    rootFileCount += 1
                    addFileExtension(file, to: &extensionMetrics, overflowed: &accountingOverflow)
                    retainLargestFile(
                        FileUsageSummary(rootRelativePath: "", logicalBytes: file.logicalBytes,
                                         allocatedBytes: file.allocatedBytes,
                                         lastModifiedAt: file.lastModifiedAt),
                        in: &largestUniqueFiles
                    )
                    if collectFileInventories {
                        appendInventoryEntry(file, to: &inventoryEntries, truncated: &inventoryTruncated)
                    }
                }
            } else {
                guard let rootFD = directoryRootDescriptor else { continue }
                defer { close(rootFD) }

                rootVolumeDeviceID = UInt64(truncatingIfNeeded: rootMetadata.st_dev)

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

                        let relativePath = directory.relativePath.isEmpty
                            ? name
                            : directory.relativePath + "/" + name
                        visitedEntryCountForProgress += 1
                        var metadata = stat()
                        let statResult = name.withCString {
                            fstatat(directoryFD, $0, &metadata, AT_SYMLINK_NOFOLLOW)
                        }
                        guard statResult == 0 else {
                            inaccessibleCount += 1
                            scanComplete = false
                            addCoverageEvent(directory.relativePath, symlink: false, to: &metrics)
                            if visitedEntryCountForProgress.isMultiple(of: 256) {
                                progress(ScanProgress(
                                    currentPath: (directory.path as NSString).appendingPathComponent(name),
                                    countedFileObjects: fileCountForProgress
                                ))
                            }
                            continue
                        }
                        let type = metadata.st_mode & S_IFMT
                        // Absolute child paths are only needed for injected device IDs,
                        // directory traversal, and occasional progress updates. Avoid
                        // allocating one for every regular file in ordinary scans.
                        let simulatedLookupPath = simulatedDeviceIDsByPath.isEmpty
                            ? nil
                            : (directory.path as NSString).appendingPathComponent(name)
                        let entryDeviceID = simulatedLookupPath.flatMap { simulatedDeviceIDsByPath[$0] }
                            ?? UInt64(truncatingIfNeeded: metadata.st_dev)
                        var reachedFileProgressInterval = false
                        if name == ".git", type == S_IFDIR || type == S_IFREG {
                            var parentMetrics = metrics[directory.relativePath, default: DirectoryMetrics()]
                            parentMetrics.gitMetadataEntryDetected = true
                            metrics[directory.relativePath] = parentMetrics
                        }
                        if type == S_IFLNK {
                            excludedSymlinkCount += 1
                            retainExcludedSymlinkPath(relativePath, in: &excludedSymlinkPaths)
                            addCoverageEvent(directory.relativePath, symlink: true, to: &metrics)
                        } else if type == S_IFDIR {
                            if entryDeviceID != rootVolumeDeviceID {
                                excludedVolumeBoundaryCount += 1
                                scanComplete = false
                                metrics[relativePath] = DirectoryMetrics(excludedVolumeBoundaryCount: 1)
                            } else {
                                metrics[relativePath] = DirectoryMetrics()
                                discoveredDirectories.append(PendingDirectory(
                                    components: directory.components + [name],
                                    relativePath: relativePath,
                                    path: simulatedLookupPath
                                        ?? (directory.path as NSString).appendingPathComponent(name),
                                    expectedIdentity: identity(of: metadata)
                                ))
                            }
                        } else if entryDeviceID != rootVolumeDeviceID {
                            excludedVolumeBoundaryCount += 1
                            scanComplete = false
                            var parentMetrics = metrics[directory.relativePath, default: DirectoryMetrics()]
                            parentMetrics.excludedVolumeBoundaryCount += 1
                            metrics[directory.relativePath] = parentMetrics
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
                                let fileMetadata = ScannedFileMetadata(name: name, metadata: metadata)
                                if var existing = linkedFilesByIdentity[file.identity] {
                                    if fileMetadata.differs(from: existing.firstObservedMetadata) {
                                        existing.modificationDateWithheld = true
                                        existing.file.lastModifiedAt = nil
                                        scanComplete = false
                                        addCoverageEvent(directory.relativePath, symlink: false, changed: true, to: &metrics)
                                    }
                                    if utf8LessThan(file.relativePath, existing.file.relativePath) {
                                        existing.file = file
                                    }
                                    if existing.modificationDateWithheld {
                                        existing.file.lastModifiedAt = nil
                                    }
                                    linkedFilesByIdentity[file.identity] = existing
                                } else if seenFileIdentities.insert(file.identity).inserted {
                                    linkedFilesByIdentity[file.identity] = LinkedFileRecord(
                                        file: file,
                                        firstObservedMetadata: fileMetadata,
                                        modificationDateWithheld: false
                                    )
                                    isNewFileObject = true
                                }
                            } else if seenFileIdentities.insert(file.identity).inserted {
                                addFile(file, to: directory.relativePath, metrics: &metrics, overflowed: &accountingOverflow)
                                accumulate(file.logicalBytes, into: &rootLogicalBytes, overflowed: &accountingOverflow)
                                accumulate(file.allocatedBytes, into: &rootAllocatedBytes, overflowed: &accountingOverflow)
                                rootFileCount += 1
                                addFileExtension(file, to: &extensionMetrics, overflowed: &accountingOverflow)
                                isNewFileObject = true
                            }
                            if isNewFileObject {
                                fileCountForProgress += 1
                                reachedFileProgressInterval = fileCountForProgress.isMultiple(of: 256)
                                if metadata.st_nlink == 1 {
                                    retainLargestFile(
                                        FileUsageSummary(
                                            rootRelativePath: file.relativePath,
                                            logicalBytes: file.logicalBytes,
                                            allocatedBytes: file.allocatedBytes,
                                            lastModifiedAt: file.lastModifiedAt
                                        ),
                                        in: &largestUniqueFiles
                                    )
                                    if collectFileInventories {
                                        appendInventoryEntry(file, to: &inventoryEntries, truncated: &inventoryTruncated)
                                    }
                                }
                            }
                        }
                        if reachedFileProgressInterval || visitedEntryCountForProgress.isMultiple(of: 256) {
                            progress(ScanProgress(
                                currentPath: (directory.path as NSString).appendingPathComponent(name),
                                countedFileObjects: fileCountForProgress
                            ))
                        }
                    }
                    var revalidationInterrupted = false
                    if !interrupted {
                        for (index, file) in scannedFiles.enumerated() {
                            if shouldCancel() {
                                cancelled = true
                                scanComplete = false
                                addCoverageEvent(directory.relativePath, symlink: false, to: &metrics)
                                for unverifiedFile in scannedFiles[index...] {
                                    withholdFileModificationDate(
                                        for: unverifiedFile,
                                        relativePath: directory.relativePath.isEmpty
                                            ? unverifiedFile.name
                                            : directory.relativePath + "/" + unverifiedFile.name,
                                        largestUniqueFiles: &largestUniqueFiles,
                                        linkedFilesByIdentity: &linkedFilesByIdentity
                                    )
                                }
                                revalidationInterrupted = true
                                break
                            }
                            var current = stat()
                            let result = file.name.withCString {
                                fstatat(directoryFD, $0, &current, AT_SYMLINK_NOFOLLOW)
                            }
                            if result != 0 {
                                let relativePath = directory.relativePath.isEmpty
                                    ? file.name
                                    : directory.relativePath + "/" + file.name
                                withholdFileModificationDate(
                                    for: file, relativePath: relativePath,
                                    largestUniqueFiles: &largestUniqueFiles,
                                    linkedFilesByIdentity: &linkedFilesByIdentity
                                )
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
                                let relativePath = directory.relativePath.isEmpty
                                    ? file.name
                                    : directory.relativePath + "/" + file.name
                                withholdFileModificationDate(
                                    for: file, relativePath: relativePath,
                                    largestUniqueFiles: &largestUniqueFiles,
                                    linkedFilesByIdentity: &linkedFilesByIdentity
                                )
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
                    if !interrupted && !revalidationInterrupted {
                        directoryDidFinish(directory.relativePath)
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
            let linkedFiles = linkedFilesByIdentity.values.map { linkedRecord -> FileRecord in
                var file = linkedRecord.file
                if linkedRecord.modificationDateWithheld {
                    file.lastModifiedAt = nil
                }
                return file
            }.sorted {
                utf8LessThan($0.relativePath, $1.relativePath)
            }
            for file in linkedFiles {
                addFile(file, to: file.parentPath, metrics: &metrics, overflowed: &accountingOverflow)
                accumulate(file.logicalBytes, into: &rootLogicalBytes, overflowed: &accountingOverflow)
                accumulate(file.allocatedBytes, into: &rootAllocatedBytes, overflowed: &accountingOverflow)
                rootFileCount += 1
                addFileExtension(file, to: &extensionMetrics, overflowed: &accountingOverflow)
                if collectFileInventories {
                    appendInventoryEntry(file, to: &inventoryEntries, truncated: &inventoryTruncated)
                }
            }
            let rankedLargestFiles = (largestUniqueFiles + linkedFiles.map {
                FileUsageSummary(
                    rootRelativePath: rootType == S_IFDIR ? $0.relativePath : "",
                    logicalBytes: $0.logicalBytes,
                    allocatedBytes: $0.allocatedBytes,
                    lastModifiedAt: $0.lastModifiedAt
                )
            }).sorted(by: largestFilePrecedes)
            let retainedLargestFiles = Array(rankedLargestFiles.prefix(maximumLargestFileSummaries))

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
                accumulate(child.logicalBytes, into: &parentMetrics.logicalBytes, overflowed: &accountingOverflow)
                accumulate(child.allocatedBytes, into: &parentMetrics.allocatedBytes, overflowed: &accountingOverflow)
                parentMetrics.fileCount += child.fileCount
                parentMetrics.incompleteCount += child.incompleteCount
                parentMetrics.excludedSymlinkCount += child.excludedSymlinkCount
                parentMetrics.excludedSpecialFileCount += child.excludedSpecialFileCount
                parentMetrics.excludedVolumeBoundaryCount += child.excludedVolumeBoundaryCount
                parentMetrics.changedDuringScanCount += child.changedDuringScanCount
                metrics[parent] = parentMetrics
            }

            let summaries = directoryPaths.compactMap { path -> DirectoryUsage? in
                guard let value = metrics[path] else { return nil }
                return directoryUsage(path: path, metrics: value, accountingOverflowed: accountingOverflow)
            }.sorted {
                if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
                return utf8LessThan($0.rootRelativePath, $1.rootRelativePath)
            }
            let wasTruncated = summaries.count > maximumDirectorySummaries
            let projectSummaries = summaries.filter {
                $0.gitMetadataEntryDetected
                    || StorageAreaHint.matchingDirectory(relativePath: $0.rootRelativePath) != nil
            }
            // Keep the direct repository metadata component independently of
            // the leaderboard cap; `.git` itself remains an explicitly
            // selected-root-relative measurement, not proof of project ownership.
            let gitMetadataUsage = metrics[".git"].map {
                directoryUsage(path: ".git", metrics: $0, accountingOverflowed: accountingOverflow)
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
            var omittedLogicalBytes: Int64 = 0
            var omittedAllocatedBytes: Int64 = 0
            var omittedFileCount = 0
            for extensionUsage in omittedExtensions {
                accumulate(extensionUsage.logicalBytes, into: &omittedLogicalBytes, overflowed: &accountingOverflow)
                accumulate(extensionUsage.allocatedBytes, into: &omittedAllocatedBytes, overflowed: &accountingOverflow)
                omittedFileCount += extensionUsage.fileCount
            }
            let otherExtensionUsage: FileExtensionUsage? = omittedExtensions.isEmpty ? nil : FileExtensionUsage(
                extensionName: "other extensions",
                logicalBytes: omittedLogicalBytes,
                allocatedBytes: omittedAllocatedBytes,
                fileCount: omittedFileCount
            )

            if rootType == S_IFDIR {
                switch openSelectedRootWithoutFollowingLinks(
                    root.path, scopedAccessGranted: sandboxedProcess && accessGranted
                ) {
                case .openedDirectory(let finalRootFD, let finalRootMetadata):
                    close(finalRootFD)
                    if !sameIdentity(rootMetadata, finalRootMetadata) {
                        scanComplete = false
                        inventoryRootStable = false
                        var rootMetrics = metrics["", default: DirectoryMetrics()]
                        rootMetrics.changedDuringScanCount += 1
                        metrics[""] = rootMetrics
                    }
                case .metadata:
                    scanComplete = false
                    inventoryRootStable = false
                    var rootMetrics = metrics["", default: DirectoryMetrics()]
                    rootMetrics.changedDuringScanCount += 1
                    metrics[""] = rootMetrics
                case .symbolicLink:
                    scanComplete = false
                    inventoryRootStable = false
                    excludedSymlinkCount += 1
                    retainExcludedSymlinkPath(".", in: &excludedSymlinkPaths)
                    addCoverageEvent("", symlink: true, to: &metrics)
                case .changed:
                    scanComplete = false
                    inventoryRootStable = false
                    var rootMetrics = metrics["", default: DirectoryMetrics()]
                    rootMetrics.changedDuringScanCount += 1
                    metrics[""] = rootMetrics
                case .unavailable:
                    scanComplete = false
                    inventoryRootStable = false
                    inaccessibleCount += 1
                    var rootMetrics = metrics["", default: DirectoryMetrics()]
                    rootMetrics.incompleteCount += 1
                    metrics[""] = rootMetrics
                }
            }

            let folderComplete = scanComplete && !accountingOverflow && inaccessibleCount == 0
                && excludedSymlinkCount == 0 && excludedSpecialFileCount == 0
                && excludedVolumeBoundaryCount == 0
                && metrics[""]?.changedDuringScanCount == 0
            let retainedExtensions = Array(rankedExtensions.prefix(maximumFileExtensionSummaries))
            let retainedSubdirectories = Array(summaries.prefix(maximumDirectorySummaries))
            let retainedProjectDirectories = Array(projectSummaries.prefix(maximumProjectDirectorySummaries))
            let rootMetrics = metrics["", default: DirectoryMetrics()]
            let folderResult = FolderObservation(
                path: root.path,
                volumeDeviceID: rootVolumeDeviceID,
                displayName: root.lastPathComponent,
                logicalBytes: rootLogicalBytes,
                allocatedBytes: rootAllocatedBytes,
                fileCount: rootFileCount,
                isFileRoot: selectedFileMetadata != nil,
                fileExtensionSummaries: retainedExtensions,
                fileExtensionSummariesTruncated: rankedExtensions.count > maximumFileExtensionSummaries,
                otherFileExtensionUsage: otherExtensionUsage,
                otherFileExtensionCategoryCount: max(0, rankedExtensions.count - maximumFileExtensionSummaries),
                inaccessibleCount: inaccessibleCount,
                complete: folderComplete,
                excludedSymlinkCount: excludedSymlinkCount,
                excludedSymlinkPaths: excludedSymlinkPaths.sorted(by: utf8LessThan),
                excludedSymlinkPathsTruncated: excludedSymlinkCount > excludedSymlinkPaths.count,
                excludedSpecialFileCount: excludedSpecialFileCount,
                excludedVolumeBoundaryCount: excludedVolumeBoundaryCount,
                changedDuringScanCount: rootMetrics.changedDuringScanCount,
                byteAccountingOverflowed: accountingOverflow,
                gitMetadataEntryDetected: rootMetrics.gitMetadataEntryDetected,
                gitMetadataUsage: gitMetadataUsage,
                subdirectorySummaries: retainedSubdirectories,
                subdirectorySummariesTruncated: wasTruncated,
                projectDirectorySummaries: retainedProjectDirectories,
                projectDirectorySummariesTruncated: projectSummaries.count > maximumProjectDirectorySummaries,
                largestFiles: retainedLargestFiles,
                largestFilesTruncated: rootFileCount > retainedLargestFiles.count
            )
            results.append(folderResult)

            if collectFileInventories {
                let inventoryComplete = !inventoryTruncated && !cancelled && !accountingOverflow
                    && inaccessibleCount == 0 && excludedSpecialFileCount == 0
                    && excludedVolumeBoundaryCount == 0
                    && inventoryRootStable
                    && rootMetrics.changedDuringScanCount == 0
                if inventoryComplete {
                    inventoryEntries.sort { utf8LessThan($0.relativePath, $1.relativePath) }
                }
                fileInventories.append(FileInventorySnapshot(
                    rootPath: root.path,
                    folderObservationID: folderResult.id,
                    volumeDeviceID: rootVolumeDeviceID,
                    observedAt: folderResult.finishedAt,
                    entries: inventoryComplete ? inventoryEntries : [],
                    complete: inventoryComplete,
                    excludedSymlinkCount: excludedSymlinkCount
                ))
            }

            if let selectedFileMetadata {
                selectedFileRoots.append((
                    results.count - 1,
                    collectFileInventories ? fileInventories.indices.last : nil,
                    root,
                    selectedFileMetadata
                ))
            }

            if cancelled { break }
        }

        // File roots have no containing directory whose enumeration can
        // revalidate them. Recheck after all selected roots have been scanned,
        // because callbacks or other work during a later root may coincide
        // with changes to an earlier selected file.
        for selected in selectedFileRoots {
            let accessGranted = selected.path.startAccessingSecurityScopedResource()
            let current: stat?
            switch openSelectedRootWithoutFollowingLinks(
                selected.path.path, scopedAccessGranted: sandboxedProcess && accessGranted
            ) {
            case .metadata(let metadata):
                current = metadata
            case .openedDirectory(let descriptor, let metadata):
                close(descriptor)
                current = metadata
            case .symbolicLink, .changed:
                current = nil
            case .unavailable:
                current = nil
            }
            if accessGranted { selected.path.stopAccessingSecurityScopedResource() }

            guard let current else {
                results[selected.index] = markingChangedDuringScan(results[selected.index])
                markInventoryIncomplete(at: selected.inventoryIndex, in: &fileInventories)
                continue
            }
            if selected.metadata.differs(from: current) {
                results[selected.index] = markingChangedDuringScan(results[selected.index])
                markInventoryIncomplete(at: selected.inventoryIndex, in: &fileInventories)
            }
        }

        return ScanObservation(startedAt: startedAt, folders: results, cancelled: cancelled)
    }

    private static func appendInventoryEntry(
        _ file: FileRecord, to entries: inout [FileInventoryEntry], truncated: inout Bool
    ) {
        guard entries.count < maximumInventoryEntriesPerRoot else {
            truncated = true
            return
        }
        entries.append(FileInventoryEntry(
            relativePath: file.relativePath,
            logicalBytes: file.logicalBytes,
            allocatedBytes: file.allocatedBytes
        ))
    }

    private static func markInventoryIncomplete(
        at index: Int?, in inventories: inout [FileInventorySnapshot]
    ) {
        guard let index, inventories.indices.contains(index) else { return }
        let current = inventories[index]
        inventories[index] = FileInventorySnapshot(
            rootPath: current.rootPath, folderObservationID: current.folderObservationID,
            volumeDeviceID: current.volumeDeviceID,
            observedAt: current.observedAt, entries: [], complete: false,
            excludedSymlinkCount: current.excludedSymlinkCount
        )
    }

    private static func markingChangedDuringScan(_ folder: FolderObservation) -> FolderObservation {
        FolderObservation(
            id: folder.id, path: folder.path, volumeDeviceID: folder.volumeDeviceID, displayName: folder.displayName,
            logicalBytes: folder.logicalBytes, allocatedBytes: folder.allocatedBytes, fileCount: folder.fileCount,
            isFileRoot: folder.isFileRoot,
            fileExtensionSummaries: folder.fileExtensionSummaries,
            fileExtensionSummariesTruncated: folder.fileExtensionSummariesTruncated,
            otherFileExtensionUsage: folder.otherFileExtensionUsage,
            otherFileExtensionCategoryCount: folder.otherFileExtensionCategoryCount,
            inaccessibleCount: folder.inaccessibleCount, finishedAt: folder.finishedAt, complete: false,
            excludedSymlinkCount: folder.excludedSymlinkCount,
            excludedSymlinkPaths: folder.excludedSymlinkPaths,
            excludedSymlinkPathsTruncated: folder.excludedSymlinkPathsTruncated,
            excludedSpecialFileCount: folder.excludedSpecialFileCount,
            excludedVolumeBoundaryCount: folder.excludedVolumeBoundaryCount,
            changedDuringScanCount: folder.changedDuringScanCount + 1,
            byteAccountingOverflowed: folder.byteAccountingOverflowed,
            gitMetadataEntryDetected: folder.gitMetadataEntryDetected,
            gitMetadataUsage: folder.gitMetadataUsage,
            subdirectorySummaries: folder.subdirectorySummaries,
            subdirectorySummariesTruncated: folder.subdirectorySummariesTruncated,
            projectDirectorySummaries: folder.projectDirectorySummaries,
            projectDirectorySummariesTruncated: folder.projectDirectorySummariesTruncated,
            largestFiles: folder.largestFiles.map { file in
                FileUsageSummary(
                    rootRelativePath: file.rootRelativePath,
                    logicalBytes: file.logicalBytes,
                    allocatedBytes: file.allocatedBytes,
                    lastModifiedAt: nil
                )
            },
            largestFilesTruncated: folder.largestFilesTruncated,
            applicationBundleIdentifier: folder.applicationBundleIdentifier,
            applicationGroupIdentifiers: folder.applicationGroupIdentifiers,
            applicationSignatureValidated: folder.applicationSignatureValidated,
            applicationSignedBundleIdentifier: folder.applicationSignedBundleIdentifier,
            selectedAsApplicationBundle: folder.selectedAsApplicationBundle
        )
    }

    private static func markingInaccessible(_ folder: FolderObservation) -> FolderObservation {
        FolderObservation(
            id: folder.id, path: folder.path, volumeDeviceID: folder.volumeDeviceID, displayName: folder.displayName,
            logicalBytes: folder.logicalBytes, allocatedBytes: folder.allocatedBytes, fileCount: folder.fileCount,
            isFileRoot: folder.isFileRoot,
            fileExtensionSummaries: folder.fileExtensionSummaries,
            fileExtensionSummariesTruncated: folder.fileExtensionSummariesTruncated,
            otherFileExtensionUsage: folder.otherFileExtensionUsage,
            otherFileExtensionCategoryCount: folder.otherFileExtensionCategoryCount,
            inaccessibleCount: folder.inaccessibleCount + 1, finishedAt: folder.finishedAt, complete: false,
            excludedSymlinkCount: folder.excludedSymlinkCount,
            excludedSymlinkPaths: folder.excludedSymlinkPaths,
            excludedSymlinkPathsTruncated: folder.excludedSymlinkPathsTruncated,
            excludedSpecialFileCount: folder.excludedSpecialFileCount,
            excludedVolumeBoundaryCount: folder.excludedVolumeBoundaryCount,
            changedDuringScanCount: folder.changedDuringScanCount,
            byteAccountingOverflowed: folder.byteAccountingOverflowed,
            gitMetadataEntryDetected: folder.gitMetadataEntryDetected,
            gitMetadataUsage: folder.gitMetadataUsage,
            subdirectorySummaries: folder.subdirectorySummaries,
            subdirectorySummariesTruncated: folder.subdirectorySummariesTruncated,
            projectDirectorySummaries: folder.projectDirectorySummaries,
            projectDirectorySummariesTruncated: folder.projectDirectorySummariesTruncated,
            largestFiles: folder.largestFiles.map { file in
                FileUsageSummary(
                    rootRelativePath: file.rootRelativePath,
                    logicalBytes: file.logicalBytes,
                    allocatedBytes: file.allocatedBytes,
                    lastModifiedAt: nil
                )
            },
            largestFilesTruncated: folder.largestFilesTruncated,
            applicationBundleIdentifier: folder.applicationBundleIdentifier,
            applicationGroupIdentifiers: folder.applicationGroupIdentifiers,
            applicationSignatureValidated: folder.applicationSignatureValidated,
            applicationSignedBundleIdentifier: folder.applicationSignedBundleIdentifier,
            selectedAsApplicationBundle: folder.selectedAsApplicationBundle
        )
    }

    private static func directoryUsage(
        path: String, metrics value: DirectoryMetrics, accountingOverflowed: Bool = false
    ) -> DirectoryUsage {
        DirectoryUsage(
            rootRelativePath: path,
            logicalBytes: value.logicalBytes,
            allocatedBytes: value.allocatedBytes,
            fileCount: value.fileCount,
            incompleteCount: value.incompleteCount,
            excludedSymlinkCount: value.excludedSymlinkCount,
            excludedSpecialFileCount: value.excludedSpecialFileCount,
            excludedVolumeBoundaryCount: value.excludedVolumeBoundaryCount,
            changedDuringScanCount: value.changedDuringScanCount,
            gitMetadataEntryDetected: value.gitMetadataEntryDetected,
            complete: value.incompleteCount == 0 && value.excludedSymlinkCount == 0
                && value.excludedSpecialFileCount == 0
                && value.excludedVolumeBoundaryCount == 0
                && value.changedDuringScanCount == 0 && !accountingOverflowed
        )
    }

    private static func emptyObservation(
        root: URL, volumeDeviceID: UInt64? = nil, inaccessibleCount: Int = 0, excludedSymlinkCount: Int = 0,
        excludedSpecialFileCount: Int = 0, excludedVolumeBoundaryCount: Int = 0,
        changedDuringScanCount: Int = 0
    ) -> FolderObservation {
        FolderObservation(
            path: root.path, volumeDeviceID: volumeDeviceID,
            displayName: root.lastPathComponent,
            logicalBytes: 0,
            allocatedBytes: 0,
            fileCount: 0,
            inaccessibleCount: inaccessibleCount,
            complete: false,
            excludedSymlinkCount: excludedSymlinkCount,
            excludedSpecialFileCount: excludedSpecialFileCount,
            excludedVolumeBoundaryCount: excludedVolumeBoundaryCount,
            changedDuringScanCount: changedDuringScanCount
        )
    }

    private static func fileRecord(metadata: stat, relativePath: String, parentPath: String) -> FileRecord {
        let allocated = CheckedByteCount.multiplying(Int64(max(0, metadata.st_blocks)), 512)
        return FileRecord(
            relativePath: relativePath,
            parentPath: parentPath,
            identity: FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino)),
            logicalBytes: Int64(max(0, metadata.st_size)),
            allocatedBytes: allocated.value,
            allocatedBytesOverflowed: allocated.overflowed,
            extensionName: fileExtensionName(relativePath: relativePath),
            lastModifiedAt: Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
                + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000)
        )
    }

    private static func withholdFileModificationDate(
        for scannedFile: ScannedFileMetadata,
        relativePath: String,
        largestUniqueFiles: inout [FileUsageSummary],
        linkedFilesByIdentity: inout [FileIdentity: LinkedFileRecord]
    ) {
        if let index = largestUniqueFiles.firstIndex(where: { $0.rootRelativePath == relativePath }) {
            let summary = largestUniqueFiles[index]
            largestUniqueFiles[index] = FileUsageSummary(
                rootRelativePath: summary.rootRelativePath,
                logicalBytes: summary.logicalBytes,
                allocatedBytes: summary.allocatedBytes,
                lastModifiedAt: nil
            )
        }
        if var linkedFile = linkedFilesByIdentity[scannedFile.identity] {
            linkedFile.file.lastModifiedAt = nil
            linkedFile.modificationDateWithheld = true
            linkedFilesByIdentity[scannedFile.identity] = linkedFile
        }
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
        _ file: FileRecord, to summaries: inout [String: FileExtensionMetrics], overflowed: inout Bool
    ) {
        var value = summaries[file.extensionName, default: FileExtensionMetrics()]
        overflowed = overflowed || file.allocatedBytesOverflowed
        accumulate(file.logicalBytes, into: &value.logicalBytes, overflowed: &overflowed)
        accumulate(file.allocatedBytes, into: &value.allocatedBytes, overflowed: &overflowed)
        value.fileCount += 1
        summaries[file.extensionName] = value
    }

    private static func retainLargestFile(
        _ candidate: FileUsageSummary,
        in retained: inout [FileUsageSummary]
    ) {
        retained.append(candidate)
        retained.sort(by: largestFilePrecedes)
        if retained.count > maximumLargestFileSummaries {
            retained.removeLast()
        }
    }

    private static func largestFilePrecedes(_ lhs: FileUsageSummary, _ rhs: FileUsageSummary) -> Bool {
        if lhs.allocatedBytes != rhs.allocatedBytes { return lhs.allocatedBytes > rhs.allocatedBytes }
        if lhs.logicalBytes != rhs.logicalBytes { return lhs.logicalBytes > rhs.logicalBytes }
        return utf8LessThan(lhs.rootRelativePath, rhs.rootRelativePath)
    }

    private static func addFile(
        _ file: FileRecord, to parentPath: String, metrics: inout [String: DirectoryMetrics], overflowed: inout Bool
    ) {
        var value = metrics[parentPath, default: DirectoryMetrics()]
        overflowed = overflowed || file.allocatedBytesOverflowed
        accumulate(file.logicalBytes, into: &value.logicalBytes, overflowed: &overflowed)
        accumulate(file.allocatedBytes, into: &value.allocatedBytes, overflowed: &overflowed)
        value.fileCount += 1
        metrics[parentPath] = value
    }

    private static func accumulate(_ amount: Int64, into total: inout Int64, overflowed: inout Bool) {
        let result = CheckedByteCount.adding(total, amount)
        total = result.value
        overflowed = overflowed || result.overflowed
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

    private static func retainExcludedSymlinkPath(_ path: String, in paths: inout [String]) {
        guard !paths.contains(path) else { return }
        if paths.count < maximumExcludedSymlinkPathSummaries {
            paths.append(path)
            return
        }
        guard let largestIndex = paths.indices.max(by: { utf8LessThan(paths[$0], paths[$1]) }),
              utf8LessThan(path, paths[largestIndex]) else { return }
        paths[largestIndex] = path
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

    /// Resolves an exact selected root by walking every absolute path component
    /// with no-follow metadata and descriptor-relative opens. Only directories
    /// are opened; a selected regular file is inspected with `fstatat` metadata.
    private static func openSelectedRootWithoutFollowingLinks(
        _ path: String,
        scopedAccessGranted: Bool = false
    ) -> SelectedRootOpenResult {
        let rawComponents = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"),
              !rawComponents.contains("."), !rawComponents.contains("..") else {
            return .unavailable
        }

        // App Sandbox grants access to the selected bookmark, not to `/` or
        // its ancestors. In that case open the exact picked root under the
        // active security scope. O_NOFOLLOW still rejects a selected symlink,
        // and descendants continue to be opened descriptor-relatively with
        // O_NOFOLLOW. Unsandboxed builds retain the stronger component walk
        // from `/`, which also rejects symlink ancestors.
        if scopedAccessGranted {
            var selectedMetadata = stat()
            var checkedAncestors: [(path: String, identity: FileIdentity)] = []
            var currentPath = ""
            for (index, component) in rawComponents.enumerated() {
                currentPath += "/" + component
                var componentMetadata = stat()
                let metadataResult = currentPath.withCString { lstat($0, &componentMetadata) }
                guard metadataResult == 0 else { return .unavailable }
                let componentType = componentMetadata.st_mode & S_IFMT
                if componentType == S_IFLNK { return .symbolicLink }
                if index < rawComponents.count - 1, componentType != S_IFDIR { return .changed }
                checkedAncestors.append((currentPath, identity(of: componentMetadata)))
                if index == rawComponents.count - 1 { selectedMetadata = componentMetadata }
            }
            let selectedType = selectedMetadata.st_mode & S_IFMT
            if selectedType == S_IFLNK { return .symbolicLink }
            guard selectedType == S_IFDIR else {
                return .metadata(selectedMetadata)
            }

            let selectedDescriptor = path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard selectedDescriptor >= 0 else {
                return errno == ELOOP ? .symbolicLink : .unavailable
            }
            var openedMetadata = stat()
            guard fstat(selectedDescriptor, &openedMetadata) == 0 else {
                close(selectedDescriptor)
                return .unavailable
            }
            guard sameIdentity(selectedMetadata, openedMetadata),
                  openedMetadata.st_mode & S_IFMT == S_IFDIR else {
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
                      identity(of: currentMetadata) == ancestor.identity else {
                    close(selectedDescriptor)
                    return .changed
                }
            }
            return .openedDirectory(selectedDescriptor, openedMetadata)
        }

        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .unavailable }
        let components = Array(URL(fileURLWithPath: path).standardizedFileURL.pathComponents.dropFirst())
        guard !components.isEmpty else {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                close(descriptor)
                return .unavailable
            }
            return .openedDirectory(descriptor, metadata)
        }

        for component in components.dropLast() {
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
                if error == ENOTDIR { return .changed }
                return .unavailable
            }
            guard enumerated.st_mode & S_IFMT == S_IFDIR else {
                close(descriptor)
                return enumerated.st_mode & S_IFMT == S_IFLNK ? .symbolicLink : .changed
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
        }

        guard let finalComponent = components.last else {
            close(descriptor)
            return .unavailable
        }
        var metadata = stat()
        let lookup = finalComponent.withCString {
            fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard lookup == 0 else {
            let error = errno
            close(descriptor)
            return error == ENOTDIR ? .changed : .unavailable
        }
        let type = metadata.st_mode & S_IFMT
        if type == S_IFLNK {
            close(descriptor)
            return .symbolicLink
        }
        guard type == S_IFDIR else {
            close(descriptor)
            return .metadata(metadata)
        }

        let rootDescriptor = finalComponent.withCString {
            openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else {
            let error = errno
            close(descriptor)
            if error == ELOOP { return .symbolicLink }
            if error == ENOENT || error == ENOTDIR { return .changed }
            return .unavailable
        }
        var openedRoot = stat()
        guard fstat(rootDescriptor, &openedRoot) == 0 else {
            close(rootDescriptor)
            close(descriptor)
            return .unavailable
        }
        close(descriptor)
        guard sameIdentity(metadata, openedRoot), openedRoot.st_mode & S_IFMT == S_IFDIR else {
            close(rootDescriptor)
            return .changed
        }
        return .openedDirectory(rootDescriptor, openedRoot)
    }

    private static func directoryMetadataChanged(_ before: stat, _ after: stat) -> Bool {
        before.st_nlink != after.st_nlink
            || before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec
            || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec
            || before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec
            || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec
    }

}
