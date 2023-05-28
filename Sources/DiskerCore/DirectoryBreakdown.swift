import Foundation

/// Ranks measured immediate child directories for one selected root.
/// Nested summaries are excluded so the bars never double-count ancestors.
public enum DirectoryBreakdown {
    public static let maximumDisplayedDirectories = 8

    public enum SizeBasis: String, CaseIterable, Hashable, Identifiable, Sendable {
        case logical
        case allocated

        public var id: String { rawValue }

        public func bytes(in directory: DirectoryUsage) -> Int64 {
            switch self {
            case .logical: directory.logicalBytes
            case .allocated: directory.allocatedBytes
            }
        }
    }

    /// Incomplete, nested, malformed, and negative summaries remain unknown
    /// or out of scope. The caller must disclose a truncated source inventory.
    public static func ranked(
        _ directories: [DirectoryUsage],
        by sizeBasis: SizeBasis,
        limit: Int = maximumDisplayedDirectories
    ) -> [DirectoryUsage] {
        guard limit > 0 else { return [] }
        return directories
            .filter { directory in
                let path = directory.rootRelativePath
                return !path.isEmpty && path != "." && path != ".."
                    && !path.contains("/") && !path.utf8.contains(0)
                    && directory.complete
                    && directory.logicalBytes >= 0 && directory.allocatedBytes >= 0
                    && directory.fileCount >= 0
                    && directory.incompleteCount == 0 && directory.excludedSymlinkCount == 0
                    && directory.excludedSpecialFileCount == 0
                    && directory.excludedVolumeBoundaryCount == 0 && directory.changedDuringScanCount == 0
                    && (directory.logicalBytes > 0 || directory.allocatedBytes > 0)
            }
            .sorted { left, right in
                let leftBytes = sizeBasis.bytes(in: left)
                let rightBytes = sizeBasis.bytes(in: right)
                if leftBytes != rightBytes { return leftBytes > rightBytes }
                return left.rootRelativePath < right.rootRelativePath
            }
            .prefix(limit)
            .map { $0 }
    }
}
