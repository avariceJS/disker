import Foundation

/// A bounded projection of Git-marked roots found by scans the user already
/// selected. It never starts a filesystem query or treats a marker as ownership.
public struct ProjectCandidateInventory: Equatable, Sendable {
    public static let maximumDisplayedCandidates = 100
    public static let maximumSourcesPerCandidate = 5

    public struct Source: Equatable, Sendable, Identifiable {
        public var id: String { scopePath }
        /// The exact selected root whose latest saved observation found this candidate.
        public let scopePath: String
        public let observedAt: Date
        public let selectedRootComplete: Bool
        public let scanWasCancelled: Bool
        public let candidateSummaryComplete: Bool
        public let isSelectedRoot: Bool
        public let logicalBytes: Int64
        public let allocatedBytesEstimate: Int64
        public let fileCount: Int
        public let projectCandidateListTruncated: Bool

        public var coverageComplete: Bool {
            selectedRootComplete && !scanWasCancelled && candidateSummaryComplete
        }
    }

    public struct Entry: Equatable, Identifiable, Sendable {
        public let path: String
        public let sources: [Source]
        public let omittedSourceCount: Int
        public let isTracked: Bool

        public var id: String { path }
        public var isSelectedRoot: Bool { sources.contains(where: \.isSelectedRoot) }
        public var latestSource: Source? { sources.max { $0.observedAt < $1.observedAt } }
        public var selectedRootSource: Source? { sources.first(where: \.isSelectedRoot) }
        public var displaySource: Source? { selectedRootSource ?? latestSource }
    }

    public let entries: [Entry]
    public let hasMoreCandidates: Bool
    public let latestSelectedRootCount: Int
    public let partialSelectedRootCount: Int
    public let truncatedProjectCandidateScopeCount: Int

    public static let empty = ProjectCandidateInventory(
        entries: [], hasMoreCandidates: false, latestSelectedRootCount: 0,
        partialSelectedRootCount: 0, truncatedProjectCandidateScopeCount: 0
    )

    public static func make(
        from history: LocalHistory, limit: Int = maximumDisplayedCandidates
    ) -> ProjectCandidateInventory {
        var latestByRoot: [String: (folder: FolderObservation, cancelled: Bool, scanFinishedAt: Date)] = [:]
        for scan in history.observations {
            for folder in scan.folders where !folder.isFileRoot {
                if let latest = latestByRoot[folder.path] {
                    let isLaterFolder = folder.finishedAt > latest.folder.finishedAt
                    let isLaterScan = folder.finishedAt == latest.folder.finishedAt
                        && scan.finishedAt > latest.scanFinishedAt
                    let stableTieBreak = folder.finishedAt == latest.folder.finishedAt
                        && scan.finishedAt == latest.scanFinishedAt
                        && folder.id.uuidString > latest.folder.id.uuidString
                    guard isLaterFolder || isLaterScan || stableTieBreak else { continue }
                }
                latestByRoot[folder.path] = (folder, scan.cancelled, scan.finishedAt)
            }
        }

        var sourcesByCandidate: [String: [Source]] = [:]
        var partialRootCount = 0
        var truncatedRootCount = 0
        for (rootPath, latest) in latestByRoot {
            let folder = latest.folder
            let isPartial = latest.cancelled || !folder.complete
            if isPartial { partialRootCount += 1 }
            if folder.projectDirectorySummariesTruncated { truncatedRootCount += 1 }

            if folder.gitMetadataEntryDetected {
                append(Source(
                    scopePath: rootPath, observedAt: folder.finishedAt,
                    selectedRootComplete: folder.complete, scanWasCancelled: latest.cancelled,
                    candidateSummaryComplete: folder.complete, isSelectedRoot: true,
                    logicalBytes: folder.logicalBytes, allocatedBytesEstimate: folder.allocatedBytes,
                    fileCount: folder.fileCount,
                    projectCandidateListTruncated: folder.projectDirectorySummariesTruncated
                ), for: rootPath, to: &sourcesByCandidate)
            }

            for summary in folder.projectDirectorySummaries
            where summary.gitMetadataEntryDetected && isSafeRelativePath(summary.rootRelativePath) {
                let candidatePath = absolutePath(root: rootPath, relativePath: summary.rootRelativePath)
                guard candidatePath != rootPath else { continue }
                append(Source(
                    scopePath: rootPath, observedAt: folder.finishedAt,
                    selectedRootComplete: folder.complete, scanWasCancelled: latest.cancelled,
                    candidateSummaryComplete: summary.complete, isSelectedRoot: false,
                    logicalBytes: summary.logicalBytes, allocatedBytesEstimate: summary.allocatedBytes,
                    fileCount: summary.fileCount,
                    projectCandidateListTruncated: folder.projectDirectorySummariesTruncated
                ), for: candidatePath, to: &sourcesByCandidate)
            }
        }

        let trackedPaths = Set(history.projectResourceAssociations.compactMap { association -> String? in
            let path = URL(fileURLWithPath: association.projectRootPath, isDirectory: true).standardizedFileURL.path
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
            return path
        })
        for path in trackedPaths where sourcesByCandidate[path] == nil {
            sourcesByCandidate[path] = []
        }

        let sortedPaths = sourcesByCandidate.keys.sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0.utf8.lexicographicallyPrecedes($1.utf8) : order == .orderedAscending
        }
        let boundedLimit = max(0, min(limit, maximumDisplayedCandidates))
        let entries = sortedPaths.prefix(boundedLimit).map { path in
            let allSources = sourcesByCandidate[path, default: []].sorted {
                if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
                if $0.isSelectedRoot != $1.isSelectedRoot { return $0.isSelectedRoot }
                return $0.scopePath.utf8.lexicographicallyPrecedes($1.scopePath.utf8)
            }
            return Entry(
                path: path,
                sources: Array(allSources.prefix(maximumSourcesPerCandidate)),
                omittedSourceCount: max(0, allSources.count - maximumSourcesPerCandidate),
                isTracked: trackedPaths.contains(path)
            )
        }
        return ProjectCandidateInventory(
            entries: entries, hasMoreCandidates: sortedPaths.count > entries.count,
            latestSelectedRootCount: latestByRoot.count,
            partialSelectedRootCount: partialRootCount,
            truncatedProjectCandidateScopeCount: truncatedRootCount
        )
    }

    private static func append(
        _ source: Source, for path: String, to sourcesByCandidate: inout [String: [Source]]
    ) {
        var sources = sourcesByCandidate[path, default: []]
        if let index = sources.firstIndex(where: { $0.scopePath == source.scopePath }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        sourcesByCandidate[path] = sources
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func absolutePath(root: String, relativePath: String) -> String {
        URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: true)
            .standardizedFileURL.path
    }
}
