import Darwin
import Foundation

enum LocalStoreFileError: Error, LocalizedError {
    case unsafeDirectory
    case notRegularFile
    case exceedsSizeLimit
    case readFailed
    case removalFailed

    var errorDescription: String? {
        switch self {
        case .unsafeDirectory:
            return "Disker's private data folder could not be opened safely and was left untouched."
        case .notRegularFile:
            return "Disker's local data file is not a regular file and was not read."
        case .exceedsSizeLimit:
            return "Disker's local data file exceeds the supported size limit and was not read."
        case .readFailed:
            return "Disker's local data file could not be mapped safely and was not read."
        case .removalFailed:
            return "Disker's local data file could not be removed."
        }
    }
}

/// Reads only a bounded regular file and refuses to follow a final path symlink.
enum LocalStoreFile {
    static func read(at url: URL, maximumBytes: Int) throws -> Data? {
        let directoryURL = url.deletingLastPathComponent()
        let directoryDescriptor = directoryURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw LocalStoreFileError.unsafeDirectory
        }
        defer { close(directoryDescriptor) }

        var directoryMetadata = stat()
        guard fstat(directoryDescriptor, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR
        else {
            throw LocalStoreFileError.unsafeDirectory
        }

        let descriptor = url.lastPathComponent.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw LocalStoreFileError.notRegularFile
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0
        else {
            throw LocalStoreFileError.notRegularFile
        }
        guard maximumBytes >= 0, metadata.st_size <= maximumBytes else {
            throw LocalStoreFileError.exceedsSizeLimit
        }
        guard metadata.st_size > 0 else { return Data() }

        let fileSize = Int(metadata.st_size)
        guard let address = mmap(nil, fileSize, PROT_READ, MAP_PRIVATE, descriptor, 0),
              address != MAP_FAILED
        else {
            throw LocalStoreFileError.readFailed
        }
        return Data(
            bytesNoCopy: address,
            count: fileSize,
            deallocator: .custom { address, length in _ = munmap(address, length) }
        )
    }

    static func ensurePrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw LocalStoreFileError.unsafeDirectory }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              fchmod(descriptor, 0o700) == 0
        else {
            throw LocalStoreFileError.unsafeDirectory
        }
    }

    static func remove(at url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        let directoryDescriptor = directoryURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            if errno == ENOENT { return }
            throw LocalStoreFileError.unsafeDirectory
        }
        defer { close(directoryDescriptor) }

        var directoryMetadata = stat()
        guard fstat(directoryDescriptor, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR
        else {
            throw LocalStoreFileError.unsafeDirectory
        }

        let result = url.lastPathComponent.withCString {
            unlinkat(directoryDescriptor, $0, 0)
        }
        if result != 0 && errno != ENOENT {
            throw LocalStoreFileError.removalFailed
        }
    }
}
