import Foundation

/// A conservative metadata-only review of large files with old modification
/// timestamps. Age is not evidence that a file is unused or safe to remove.
public enum LargeFileModificationReview {
    public static let minimumAllocatedBytes: Int64 = 100 * 1_024 * 1_024
    public static let minimumAge: TimeInterval = 180 * 24 * 60 * 60
    public static let maximumEntries = 20

    public struct Entry: Equatable, Identifiable, Sendable {
        public var id: String { path }
        public let path: String
        public let rootRelativePath: String
        public let logicalBytes: Int64
        public let allocatedBytes: Int64
        public let lastModifiedAt: Date
        public let ageDays: Int
    }

    /// Returns review candidates only from one complete, non-cancelled scan
    /// with an untruncated largest-file inventory. No file contents are read.
    public static func make(
        from folder: FolderObservation,
        scanCancelled: Bool,
        asOf: Date = .now
    ) -> [Entry] {
        guard folder.complete, !scanCancelled, !folder.largestFilesTruncated,
              asOf.timeIntervalSince1970.isFinite else { return [] }

        let root = URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let candidates = folder.largestFiles.compactMap { file -> Entry? in
            let isSelectedFile = file.rootRelativePath.isEmpty && folder.fileCount == 1
            guard isSelectedFile || isSafeRelativePath(file.rootRelativePath),
                  file.allocatedBytes >= minimumAllocatedBytes,
                  file.logicalBytes >= 0,
                  let modifiedAt = file.lastModifiedAt else { return nil }

            let age = asOf.timeIntervalSince(modifiedAt)
            guard age.isFinite, age >= minimumAge else { return nil }
            let path = isSelectedFile
                ? root.path
                : root.appendingPathComponent(file.rootRelativePath).standardizedFileURL.path
            guard isSelectedFile || path.hasPrefix(rootPath) else { return nil }
            return Entry(
                path: path,
                rootRelativePath: file.rootRelativePath,
                logicalBytes: file.logicalBytes,
                allocatedBytes: file.allocatedBytes,
                lastModifiedAt: modifiedAt,
                ageDays: Int(age / (24 * 60 * 60))
            )
        }
        return Array(candidates.sorted {
            if $0.allocatedBytes == $1.allocatedBytes { return $0.path < $1.path }
            return $0.allocatedBytes > $1.allocatedBytes
        }.prefix(maximumEntries))
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}
