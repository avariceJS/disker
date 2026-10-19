import Foundation

/// A conservative, metadata-only review of large paths that appear in a new
/// complete selected-root inventory. Presence does not establish ownership,
/// usefulness, or safe removal.
public enum NewlyObservedLargeFileReview {
    public static let minimumAllocatedBytes: Int64 = 100 * 1_024 * 1_024
    public static let maximumEntries = 20
    public static let evidenceDescription = "Not present in prior complete inventory"

    public struct Entry: Equatable, Identifiable, Sendable {
        public var id: String { path }
        public let path: String
        public let rootRelativePath: String
        public let logicalBytes: Int64
        public let allocatedBytes: Int64
        public let evidence: String
        /// No reclaimable-space conclusion can be drawn from a metadata scan.
        public let reclaimableBytes: Int64? = nil
    }

    /// Finds large paths absent from the immediately comparable prior
    /// complete inventory. This inspects saved metadata only and never reads
    /// file contents.
    public static func make(
        from current: FolderObservation,
        in history: LocalHistory,
        scanCancelled: Bool,
        limit: Int = maximumEntries
    ) -> [Entry] {
        guard limit > 0, current.complete, !scanCancelled,
              !current.largestFilesTruncated,
              let latestObservation = history.observations.reversed().first(where: {
                  $0.folders.contains(where: { $0.path == current.path })
              }),
              !latestObservation.cancelled,
              latestObservation.folders.contains(where: { $0.id == current.id }),
              let previous = ObservationComparison.previousCompleteFolder(for: current, in: history),
              previous.complete,
              !previous.largestFilesTruncated,
              sameVolume(previous, current)
        else { return [] }

        let previousPaths = Set(previous.largestFiles.map(\.rootRelativePath))
        let root = URL(fileURLWithPath: current.path, isDirectory: true).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let candidates = current.largestFiles.compactMap { file -> Entry? in
            let isSelectedFile = file.rootRelativePath.isEmpty && current.fileCount == 1
            guard isSelectedFile || isSafeRelativePath(file.rootRelativePath),
                  !previousPaths.contains(file.rootRelativePath),
                  file.allocatedBytes >= minimumAllocatedBytes,
                  file.logicalBytes >= 0 else { return nil }

            let path = isSelectedFile
                ? root.path
                : root.appendingPathComponent(file.rootRelativePath).standardizedFileURL.path
            guard isSelectedFile || path.hasPrefix(rootPath) else { return nil }
            return Entry(
                path: path,
                rootRelativePath: file.rootRelativePath,
                logicalBytes: file.logicalBytes,
                allocatedBytes: file.allocatedBytes,
                evidence: evidenceDescription
            )
        }

        return Array(candidates.sorted {
            if $0.allocatedBytes != $1.allocatedBytes {
                return $0.allocatedBytes > $1.allocatedBytes
            }
            return $0.rootRelativePath.utf8.lexicographicallyPrecedes(
                $1.rootRelativePath.utf8
            )
        }.prefix(min(limit, maximumEntries)))
    }

    private static func sameVolume(_ lhs: FolderObservation, _ rhs: FolderObservation) -> Bool {
        switch (lhs.volumeDeviceID, rhs.volumeDeviceID) {
        case let (left?, right?): return left == right
        case (nil, nil): return true
        default: return false
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}
