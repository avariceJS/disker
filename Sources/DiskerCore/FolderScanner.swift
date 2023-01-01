import Darwin
import Foundation

public struct ScanProgress: Sendable {
    public let currentPath: String
    public let visitedFiles: Int
}

public enum FolderScanner {
    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct PendingDirectory {
        let descriptor: Int32
        let path: String
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

            var logicalBytes: Int64 = 0
            var allocatedBytes: Int64 = 0
            var fileCount = 0
            var inaccessibleCount = 0
            var complete = true
            var seenFiles = Set<FileIdentity>()

            var rootMetadata = stat()
            guard root.path.withCString({ lstat($0, &rootMetadata) }) == 0 else {
                results.append(FolderObservation(
                    path: root.path, displayName: root.lastPathComponent,
                    logicalBytes: 0, allocatedBytes: 0, fileCount: 0,
                    inaccessibleCount: 1, complete: false
                ))
                continue
            }

            let rootType = rootMetadata.st_mode & S_IFMT
            if rootType == S_IFLNK {
                // A symlink selected as the root is excluded, so report that it was
                // not measured instead of presenting a complete zero-byte result.
                results.append(FolderObservation(
                    path: root.path, displayName: root.lastPathComponent,
                    logicalBytes: 0, allocatedBytes: 0, fileCount: 0,
                    inaccessibleCount: 1, complete: false
                ))
                continue
            }
            if rootType != S_IFDIR {
                record(rootMetadata)
                results.append(FolderObservation(
                    path: root.path, displayName: root.lastPathComponent,
                    logicalBytes: logicalBytes, allocatedBytes: allocatedBytes,
                    fileCount: fileCount, inaccessibleCount: inaccessibleCount,
                    complete: complete
                ))
                continue
            }

            let rootFD = root.path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard rootFD >= 0 else {
                results.append(FolderObservation(
                    path: root.path, displayName: root.lastPathComponent,
                    logicalBytes: 0, allocatedBytes: 0, fileCount: 0,
                    inaccessibleCount: 1, complete: false
                ))
                continue
            }

            var pending = [PendingDirectory(descriptor: rootFD, path: root.path)]
            defer { for directory in pending { close(directory.descriptor) } }

            while let directory = pending.popLast() {
                defer { close(directory.descriptor) }
                if shouldCancel() {
                    cancelled = true
                    complete = false
                    break
                }
                let streamFD = dup(directory.descriptor)
                guard streamFD >= 0, let stream = fdopendir(streamFD) else {
                    if streamFD >= 0 { close(streamFD) }
                    inaccessibleCount += 1
                    complete = false
                    continue
                }
                defer { closedir(stream) }

                while true {
                    errno = 0
                    guard let entry = readdir(stream) else {
                        if errno != 0 {
                            inaccessibleCount += 1
                            complete = false
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
                        complete = false
                        break
                    }

                    var metadata = stat()
                    let statResult = name.withCString {
                        fstatat(directory.descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
                    }
                    guard statResult == 0 else {
                        inaccessibleCount += 1
                        complete = false
                        continue
                    }
                    let type = metadata.st_mode & S_IFMT
                    let fullPath = (directory.path as NSString).appendingPathComponent(name)
                    if type == S_IFLNK { continue }
                    if type == S_IFDIR {
                        let childFD = name.withCString {
                            openat(directory.descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        }
                        if childFD < 0 {
                            inaccessibleCount += 1
                            complete = false
                        } else {
                            pending.append(PendingDirectory(descriptor: childFD, path: fullPath))
                        }
                        continue
                    }
                    record(metadata)
                    if fileCount.isMultiple(of: 256) {
                        progress(ScanProgress(currentPath: fullPath, visitedFiles: fileCount))
                    }
                }
                if cancelled { break }
            }

            results.append(FolderObservation(
                path: root.path, displayName: root.lastPathComponent,
                logicalBytes: logicalBytes, allocatedBytes: allocatedBytes,
                fileCount: fileCount, inaccessibleCount: inaccessibleCount,
                complete: complete
            ))

            func record(_ metadata: stat) {
                let identity = FileIdentity(
                    device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino)
                )
                guard seenFiles.insert(identity).inserted else { return }
                logicalBytes += Int64(max(0, metadata.st_size))
                allocatedBytes += Int64(max(0, metadata.st_blocks)) * 512
                fileCount += 1
            }

            if cancelled { break }
        }

        return ScanObservation(startedAt: startedAt, folders: results, cancelled: cancelled)
    }
}
