import Darwin
import Foundation

enum LocalStoreFileError: Error, LocalizedError {
    case notRegularFile
    case exceedsSizeLimit

    var errorDescription: String? {
        switch self {
        case .notRegularFile:
            return "Disker's local data file is not a regular file and was not read."
        case .exceedsSizeLimit:
            return "Disker's local data file exceeds the supported size limit and was not read."
        }
    }
}

/// Reads only a bounded regular file and refuses to follow a final path symlink.
enum LocalStoreFile {
    private static let readChunkSize = 64 * 1024

    static func read(at url: URL, maximumBytes: Int) throws -> Data? {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
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
        guard metadata.st_size <= maximumBytes else {
            throw LocalStoreFileError.exceedsSizeLimit
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while true {
            let bytesRemainingIncludingOverflowProbe = maximumBytes - data.count + 1
            let chunkSize = min(readChunkSize, bytesRemainingIncludingOverflowProbe)
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            guard !chunk.isEmpty else { break }
            guard chunk.count <= maximumBytes - data.count else {
                throw LocalStoreFileError.exceedsSizeLimit
            }
            data.append(chunk)
        }
        return data
    }
}
