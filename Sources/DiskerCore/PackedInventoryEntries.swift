import Compression
import Foundation

enum PackedInventoryEntriesError: Error, LocalizedError {
    case invalidPayload
    case exceedsLimit
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .invalidPayload: "The saved compressed file inventory is invalid."
        case .exceedsLimit: "The packed file inventory exceeds its size limit."
        case .compressionFailed: "The file inventory could not be compressed safely."
        }
    }
}

/// A bounded, streaming encoding for sorted file-inventory entries. The path
/// bytes remain compressed in the plist and are expanded only for comparison.
enum PackedInventoryEntries {
    static let maximumEntryCount = 750_000
    static let maximumPathByteCount = 1_048_576
    static let maximumPayloadByteCount = 128 * 1_048_576

    private static let outputChunkSize = 64 * 1_024
    private static let header = Array("DIN1".utf8)

    static func encode(_ entries: [FileInventoryEntry]) throws -> Data {
        guard entries.count <= maximumEntryCount else { throw PackedInventoryEntriesError.exceedsLimit }
        let writer = try StreamWriter()
        var streamHeader = header
        append(UInt32(entries.count), to: &streamHeader)
        try writer.append(streamHeader)

        var previousPath: String?
        for entry in entries {
            let pathLength = entry.relativePath.utf8.count
            guard pathLength > 0, pathLength <= maximumPathByteCount,
                  entry.logicalBytes >= 0, entry.allocatedBytes >= 0,
                  isSafeRelativePath(entry.relativePath),
                  previousPath.map({ $0.utf8.lexicographicallyPrecedes(entry.relativePath.utf8) }) ?? true else {
                throw PackedInventoryEntriesError.invalidPayload
            }
            previousPath = entry.relativePath
            var recordHeader = [UInt8]()
            recordHeader.reserveCapacity(20)
            append(UInt32(pathLength), to: &recordHeader)
            append(UInt64(entry.logicalBytes), to: &recordHeader)
            append(UInt64(entry.allocatedBytes), to: &recordHeader)
            try writer.append(recordHeader)

            if let _ = try entry.relativePath.utf8.withContiguousStorageIfAvailable({ bytes in
                try writer.append(bytes)
            }) {
                continue
            } else {
                let bytes = Array(entry.relativePath.utf8)
                try writer.append(bytes)
            }
        }

        return try writer.finish()
    }

    static func decode(_ payload: Data, entryCount: Int) throws -> [FileInventoryEntry] {
        guard !payload.isEmpty, payload.count <= maximumPayloadByteCount,
              (0...maximumEntryCount).contains(entryCount) else {
            throw PackedInventoryEntriesError.invalidPayload
        }
        var stream = emptyStream()
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE)
                == COMPRESSION_STATUS_OK else {
            throw PackedInventoryEntriesError.compressionFailed
        }
        defer { compression_stream_destroy(&stream) }

        var parser = EntryParser(expectedEntryCount: entryCount)
        var output = [UInt8](repeating: 0, count: outputChunkSize)
        let status: compression_status = try payload.withUnsafeBytes { source in
            stream.src_ptr = source.baseAddress!.assumingMemoryBound(to: UInt8.self)
            stream.src_size = source.count
            while true {
                let processStatus = output.withUnsafeMutableBufferPointer { destination -> compression_status in
                    stream.dst_ptr = destination.baseAddress!
                    stream.dst_size = destination.count
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = output.count - stream.dst_size
                if produced > 0 {
                    try parser.append(output[0..<produced])
                }
                if processStatus == COMPRESSION_STATUS_END {
                    return processStatus
                }
                guard processStatus == COMPRESSION_STATUS_OK,
                      stream.src_size > 0 || produced > 0 else {
                    throw PackedInventoryEntriesError.invalidPayload
                }
            }
        }
        guard status == COMPRESSION_STATUS_END, stream.src_size == 0 else {
            throw PackedInventoryEntriesError.invalidPayload
        }
        return try parser.finish()
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        let value = value.bigEndian
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt64, to bytes: inout [UInt8]) {
        let value = value.bigEndian
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func emptyStream() -> compression_stream {
        compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
    }

    private final class StreamWriter {
        private var stream = PackedInventoryEntries.emptyStream()
        private var output = Data()
        private var chunk = [UInt8](repeating: 0, count: outputChunkSize)
        private var inputByteCount = 0

        init() throws {
            guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZFSE)
                    == COMPRESSION_STATUS_OK else {
                throw PackedInventoryEntriesError.compressionFailed
            }
        }

        deinit {
            compression_stream_destroy(&stream)
        }

        func append(_ bytes: [UInt8]) throws {
            try bytes.withUnsafeBufferPointer { try append($0) }
        }

        func append(_ bytes: UnsafeBufferPointer<UInt8>) throws {
            guard inputByteCount <= maximumPayloadByteCount - bytes.count else {
                throw PackedInventoryEntriesError.exceedsLimit
            }
            inputByteCount += bytes.count
            guard let baseAddress = bytes.baseAddress else { return }
            stream.src_ptr = baseAddress
            stream.src_size = bytes.count
            while stream.src_size > 0 {
                _ = try process(finalize: false)
            }
        }

        func finish() throws -> Data {
            stream.src_ptr = UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_size = 0
            while true {
                let status = try process(finalize: true)
                if status == COMPRESSION_STATUS_END { break }
            }
            return output
        }

        private func process(finalize: Bool) throws -> compression_status {
            var produced = 0
            let status = chunk.withUnsafeMutableBufferPointer { destination in
                stream.dst_ptr = destination.baseAddress!
                stream.dst_size = destination.count
                let flags = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                return compression_stream_process(&stream, flags)
            }
            produced = chunk.count - stream.dst_size
            guard status != COMPRESSION_STATUS_ERROR else {
                throw PackedInventoryEntriesError.compressionFailed
            }
            guard output.count <= maximumPayloadByteCount - produced else {
                throw PackedInventoryEntriesError.exceedsLimit
            }
            if produced > 0 {
                output.append(contentsOf: chunk[..<produced])
            }
            if status == COMPRESSION_STATUS_OK, stream.src_size == 0, produced == 0, finalize {
                throw PackedInventoryEntriesError.compressionFailed
            }
            return status
        }
    }

    private struct EntryParser {
        private let expectedEntryCount: Int
        private var pending = [UInt8]()
        private var cursor = 0
        private var hasHeader = false
        private var entries: [FileInventoryEntry] = []
        private var previousPath: String?

        init(expectedEntryCount: Int) {
            self.expectedEntryCount = expectedEntryCount
            entries.reserveCapacity(expectedEntryCount)
        }

        mutating func append(_ bytes: ArraySlice<UInt8>) throws {
            pending.append(contentsOf: bytes)
            while true {
                if !hasHeader {
                    guard pending.count - cursor >= 8 else { break }
                    guard Array(pending[cursor..<(cursor + 4)]) == PackedInventoryEntries.header,
                          Int(readUInt32(at: cursor + 4)) == expectedEntryCount else {
                        throw PackedInventoryEntriesError.invalidPayload
                    }
                    cursor += 8
                    hasHeader = true
                }
                guard entries.count < expectedEntryCount,
                      pending.count - cursor >= 20 else { break }
                let pathLength = Int(readUInt32(at: cursor))
                let logicalBytes = Int64(bitPattern: readUInt64(at: cursor + 4))
                let allocatedBytes = Int64(bitPattern: readUInt64(at: cursor + 12))
                guard pathLength > 0, pathLength <= maximumPathByteCount,
                      logicalBytes >= 0, allocatedBytes >= 0,
                      pending.count - cursor - 20 >= pathLength else { break }
                let pathStart = cursor + 20
                guard let path = String(
                    bytes: pending[pathStart..<(pathStart + pathLength)], encoding: .utf8
                ), PackedInventoryEntries.isSafeRelativePath(path),
                    previousPath.map({ $0.utf8.lexicographicallyPrecedes(path.utf8) }) ?? true else {
                    throw PackedInventoryEntriesError.invalidPayload
                }
                entries.append(FileInventoryEntry(
                    relativePath: path, logicalBytes: logicalBytes, allocatedBytes: allocatedBytes
                ))
                previousPath = path
                cursor = pathStart + pathLength
            }
            if cursor > 0 {
                pending.removeFirst(cursor)
                cursor = 0
            }
            guard pending.count <= maximumPathByteCount + outputChunkSize else {
                throw PackedInventoryEntriesError.invalidPayload
            }
        }

        func finish() throws -> [FileInventoryEntry] {
            guard hasHeader, entries.count == expectedEntryCount, pending.isEmpty else {
                throw PackedInventoryEntriesError.invalidPayload
            }
            return entries
        }

        private func readUInt32(at offset: Int) -> UInt32 {
            (UInt32(pending[offset]) << 24)
                | (UInt32(pending[offset + 1]) << 16)
                | (UInt32(pending[offset + 2]) << 8)
                | UInt32(pending[offset + 3])
        }

        private func readUInt64(at offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in offset..<(offset + 8) {
                value = (value << 8) | UInt64(pending[index])
            }
            return value
        }
    }
}
