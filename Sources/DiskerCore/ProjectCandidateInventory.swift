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
        /// The newest source across all scopes, even when its row is beyond the source cap.
        public let latestSource: Source?

        public var id: String { path }
        public var isSelectedRoot: Bool { sources.contains(where: \.isSelectedRoot) }
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

    private struct SourceAccumulator {
        var sources: [Source] = []
        var totalSourceCount = 0
        var latestSource: Source?
    }

    public static func make(
        from history: LocalHistory, limit: Int = maximumDisplayedCandidates
    ) -> ProjectCandidateInventory {
        let visibleLimit = max(0, min(limit, maximumDisplayedCandidates))
        let candidatePathCapacity = visibleLimit + 1
        var candidatePaths: [String] = []
        var retainedCandidatePaths = Set<String>()
        var sourceAccumulators: [String: SourceAccumulator] = [:]
        var hasOverflowCandidates = false

        func considerPath(_ path: String) -> String? {
            guard !retainedCandidatePaths.contains(path) else { return nil }
            if candidatePaths.count < candidatePathCapacity {
                let index = insertionIndex(for: path, in: candidatePaths, orderedBy: candidatePathPrecedes)
                candidatePaths.insert(path, at: index)
                retainedCandidatePaths.insert(path)
                return nil
            }

            hasOverflowCandidates = true
            guard let last = candidatePaths.last, candidatePathPrecedes(path, last) else { return nil }
            retainedCandidatePaths.remove(last)
            let index = insertionIndex(for: path, in: candidatePaths, orderedBy: candidatePathPrecedes)
            candidatePaths.insert(path, at: index)
            retainedCandidatePaths.insert(path)
            return last
        }

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

        var partialRootCount = 0
        var truncatedRootCount = 0
        for (rootPath, latest) in latestByRoot {
            let folder = latest.folder
            let isPartial = latest.cancelled || !folder.complete
            if isPartial { partialRootCount += 1 }
            if folder.projectDirectorySummariesTruncated { truncatedRootCount += 1 }

            if folder.gitMetadataEntryDetected {
                let evictedPath = considerPath(rootPath)
                if let evictedPath { sourceAccumulators.removeValue(forKey: evictedPath) }
                append(Source(
                    scopePath: rootPath, observedAt: folder.finishedAt,
                    selectedRootComplete: folder.complete, scanWasCancelled: latest.cancelled,
                    candidateSummaryComplete: folder.complete, isSelectedRoot: true,
                    logicalBytes: folder.logicalBytes, allocatedBytesEstimate: folder.allocatedBytes,
                    fileCount: folder.fileCount,
                    projectCandidateListTruncated: folder.projectDirectorySummariesTruncated
                ), for: rootPath, retainedPaths: retainedCandidatePaths, to: &sourceAccumulators)
            }

            var seenSummaryCandidatePaths = Set<String>()
            for summary in folder.projectDirectorySummaries
            where summary.gitMetadataEntryDetected && isSafeRelativePath(summary.rootRelativePath) {
                let candidatePath = absolutePath(root: rootPath, relativePath: summary.rootRelativePath)
                guard candidatePath != rootPath,
                      seenSummaryCandidatePaths.insert(candidatePath).inserted else { continue }
                let evictedPath = considerPath(candidatePath)
                if let evictedPath { sourceAccumulators.removeValue(forKey: evictedPath) }
                append(Source(
                    scopePath: rootPath, observedAt: folder.finishedAt,
                    selectedRootComplete: folder.complete, scanWasCancelled: latest.cancelled,
                    candidateSummaryComplete: summary.complete, isSelectedRoot: false,
                    logicalBytes: summary.logicalBytes, allocatedBytesEstimate: summary.allocatedBytes,
                    fileCount: summary.fileCount,
                    projectCandidateListTruncated: folder.projectDirectorySummariesTruncated
                ), for: candidatePath, retainedPaths: retainedCandidatePaths, to: &sourceAccumulators)
            }
        }

        let trackedPaths = Set(history.projectResourceAssociations.compactMap { association -> String? in
            let path = URL(fileURLWithPath: association.projectRootPath, isDirectory: true).standardizedFileURL.path
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
            return path
        })
        for path in trackedPaths {
            let evictedPath = considerPath(path)
            if let evictedPath { sourceAccumulators.removeValue(forKey: evictedPath) }
        }

        let displayedPaths = candidatePaths.prefix(visibleLimit)
        let entries = displayedPaths.map { path in
            let sourceAccumulator = sourceAccumulators[path, default: SourceAccumulator()]
            return Entry(
                path: path,
                sources: sourceAccumulator.sources,
                omittedSourceCount: max(0, sourceAccumulator.totalSourceCount - sourceAccumulator.sources.count),
                isTracked: trackedPaths.contains(path),
                latestSource: sourceAccumulator.latestSource
            )
        }
        return ProjectCandidateInventory(
            entries: entries,
            hasMoreCandidates: hasOverflowCandidates || candidatePaths.count > visibleLimit,
            latestSelectedRootCount: latestByRoot.count,
            partialSelectedRootCount: partialRootCount,
            truncatedProjectCandidateScopeCount: truncatedRootCount
        )
    }

    private static func append(
        _ source: Source,
        for path: String,
        retainedPaths: Set<String>,
        to sourceAccumulators: inout [String: SourceAccumulator]
    ) {
        guard retainedPaths.contains(path) else { return }
        var accumulator = sourceAccumulators[path, default: SourceAccumulator()]
        guard !accumulator.sources.contains(where: { $0.scopePath == source.scopePath }) else { return }
        accumulator.totalSourceCount += 1
        if let latestSource = accumulator.latestSource {
            if sourceIsNewer(source, than: latestSource) { accumulator.latestSource = source }
        } else {
            accumulator.latestSource = source
        }
        let index = insertionIndex(for: source, in: accumulator.sources, orderedBy: sourceRetentionPrecedes)
        if index < maximumSourcesPerCandidate {
            accumulator.sources.insert(source, at: index)
            if accumulator.sources.count > maximumSourcesPerCandidate {
                accumulator.sources.removeLast()
            }
        }
        sourceAccumulators[path] = accumulator
    }

    private static func candidatePathPrecedes(_ first: String, _ second: String) -> Bool {
        let order = first.localizedStandardCompare(second)
        return order == .orderedSame ? first.utf8.lexicographicallyPrecedes(second.utf8) : order == .orderedAscending
    }

    private static func sourceRetentionPrecedes(_ first: Source, _ second: Source) -> Bool {
        if first.isSelectedRoot != second.isSelectedRoot { return first.isSelectedRoot }
        if first.observedAt != second.observedAt { return first.observedAt > second.observedAt }
        return first.scopePath.utf8.lexicographicallyPrecedes(second.scopePath.utf8)
    }

    private static func sourceIsNewer(_ first: Source, than second: Source) -> Bool {
        if first.observedAt != second.observedAt { return first.observedAt > second.observedAt }
        if first.isSelectedRoot != second.isSelectedRoot { return first.isSelectedRoot }
        return first.scopePath.utf8.lexicographicallyPrecedes(second.scopePath.utf8)
    }

    private static func insertionIndex<Element>(
        for value: Element, in sortedValues: [Element], orderedBy precedes: (Element, Element) -> Bool
    ) -> Int {
        var lowerBound = 0
        var upperBound = sortedValues.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if precedes(sortedValues[midpoint], value) {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func absolutePath(root: String, relativePath: String) -> String {
        let parent = root.hasSuffix("/") ? String(root.dropLast()) : root
        return parent + "/" + relativePath
    }
}
