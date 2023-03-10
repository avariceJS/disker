import Foundation

/// Read-only review of explicitly scanned directories whose names commonly
/// identify development data. A match is a lead for the user to inspect, not
/// proof that data is unused, disposable, or owned by a particular app.
public struct DeveloperArtifactReview: Equatable, Sendable {
    public let selectedRootPath: String
    public let observedAt: Date
    public let selectedRootComplete: Bool
    /// True when the scanner omitted matching summaries after its retention cap.
    public let candidatesTruncated: Bool
    public let entries: [Entry]

    public struct Entry: Equatable, Identifiable, Sendable {
        public let selectedRootPath: String
        public let relativePath: String
        /// Exact path under the selected root; this is a review location only.
        public let path: String
        public let category: Category
        public let logicalBytes: Int64
        /// Filesystem allocation estimate; logical bytes are reported separately.
        public let allocatedBytesEstimate: Int64
        public let fileCount: Int
        public let subtreeComplete: Bool
        public let selectedRootComplete: Bool
        public let observedAt: Date
        public let evidence: String
        public let risk: String
        public let possibleConsequence: String
        public let caution: String
        /// Exact candidate paths whose measured subtrees intersect this entry.
        /// Entries remain separate and must not be added together.
        public let overlappingCandidatePaths: [String]
        /// A signed change in the filesystem's allocated-byte estimate, only
        /// when this exact retained candidate appeared in two complete scans
        /// of this same selected root and volume.
        public let historicalChange: HistoricalChange?

        public var id: String { path }
    }

    public struct HistoricalChange: Equatable, Sendable {
        public let previousObservedAt: Date
        public let currentObservedAt: Date
        public let allocatedBytesChange: Int64

        /// A descriptive straight-line pace, shown only for increases over
        /// intervals long enough to reduce timestamp noise.
        public var observedBytesPerDay: Double? {
            let interval = currentObservedAt.timeIntervalSince(previousObservedAt)
            guard allocatedBytesChange > 0, interval.isFinite, interval >= 5 * 60 else { return nil }
            return Double(allocatedBytesChange) * 86_400 / interval
        }
    }

    public enum Category: String, CaseIterable, Equatable, Sendable {
        case sourceControl
        case buildProducts
        case dependencies
        case packageManagerData
        case runtimeAndSimulatorData
        case userData
        case logs
        case archiveOrSymbols
        case testOutput

        public var title: String {
            switch self {
            case .sourceControl: "Source control metadata"
            case .buildProducts: "Build products"
            case .dependencies: "Project dependencies"
            case .packageManagerData: "Package manager data"
            case .runtimeAndSimulatorData: "Runtime or simulator data"
            case .userData: "Model or dataset files"
            case .logs: "Logs"
            case .archiveOrSymbols: "Archives or debug symbols"
            case .testOutput: "Test or web output"
            }
        }
    }

    /// Creates deterministic rows from the bounded project-directory
    /// summaries. No file contents, ownership, last-use, or reclaimable bytes
    /// are inferred. Since summaries are subtree measurements, overlapping
    /// candidate sizes are intentionally never aggregated.
    public static func make(
        from folder: FolderObservation,
        in history: LocalHistory? = nil
    ) -> DeveloperArtifactReview {
        var summariesByPath: [String: DirectoryUsage] = [:]
        for summary in folder.projectDirectorySummaries {
            summariesByPath[summary.rootRelativePath] = summary
        }
        if let gitUsage = folder.gitMetadataUsage {
            summariesByPath[gitUsage.rootRelativePath] = gitUsage
        }

        let candidates: [(String, DirectoryUsage, Category, String)] = summariesByPath.compactMap { relativePath, summary in
            guard isSafeRelativePath(relativePath) else { return nil }
            let isGitMarker = summary.gitMetadataEntryDetected
                || (relativePath == ".git" && folder.gitMetadataEntryDetected)
            guard isGitMarker || StorageAreaHint.matchingDirectory(relativePath: relativePath) != nil else {
                return nil
            }
            let hint = StorageAreaHint.matchingDirectory(relativePath: relativePath)
            let category = isGitMarker ? Category.sourceControl : category(for: hint!)
            let evidence: String
            if isGitMarker {
                evidence = relativePath == ".git"
                    ? "A direct .git directory marker was detected in the selected folder. Its metadata footprint is measured separately; the marker was not followed or parsed."
                    : "A direct .git entry was detected inside this directory. The marker was not followed or parsed."
            } else {
                evidence = "The directory name matches “\(hint!.title)”. This is name-only evidence; contents and purpose were not inspected."
            }
            return (relativePath, summary, category, evidence)
        }

        let sortedCandidates = candidates.sorted { $0.0 < $1.0 }
        let absolutePaths = sortedCandidates.map { absolutePath(root: folder.path, relative: $0.0) }
        let historyByPath = historicalChanges(for: folder, in: history)
        let entries = sortedCandidates.enumerated().map { index, candidate in
            let (relativePath, summary, category, evidence) = candidate
            let path = absolutePaths[index]
            let overlaps = sortedCandidates.enumerated().compactMap { otherIndex, other -> String? in
                guard otherIndex != index, isAncestor(relative: relativePath, of: other.0)
                        || isAncestor(relative: other.0, of: relativePath) else { return nil }
                return absolutePaths[otherIndex]
            }
            let caution: String
            if !summary.complete {
                caution = "This subtree has partial coverage. Its measurements may omit inaccessible, changing, excluded, or boundary-crossing items; do not treat them as complete."
            } else if !folder.complete {
                caution = "This subtree summary is complete, but the selected-root scan is partial. Other candidates or data may be omitted."
            } else {
                caution = "A complete metadata scan does not establish whether the data is still needed or safe to remove. Review it in its owning tool before taking action."
            }
            let overlapNote = overlaps.isEmpty ? "" : " This subtree overlaps other candidate measurements; do not add their sizes."
            return Entry(
                selectedRootPath: folder.path,
                relativePath: relativePath,
                path: path,
                category: category,
                logicalBytes: max(0, summary.logicalBytes),
                allocatedBytesEstimate: max(0, summary.allocatedBytes),
                fileCount: max(0, summary.fileCount),
                subtreeComplete: summary.complete,
                selectedRootComplete: folder.complete,
                observedAt: folder.finishedAt,
                evidence: evidence,
                risk: risk(for: category),
                possibleConsequence: consequence(for: category),
                caution: caution + overlapNote,
                overlappingCandidatePaths: overlaps.sorted(),
                historicalChange: historyByPath[relativePath]
            )
        }

        return DeveloperArtifactReview(
            selectedRootPath: folder.path,
            observedAt: folder.finishedAt,
            selectedRootComplete: folder.complete,
            candidatesTruncated: folder.projectDirectorySummariesTruncated,
            entries: entries
        )
    }

    private static func historicalChanges(
        for folder: FolderObservation,
        in history: LocalHistory?
    ) -> [String: HistoricalChange] {
        guard folder.complete, let history,
              history.observations.reversed().lazy.compactMap({ observation in
                  observation.folders.first(where: { $0.path == folder.path })
              }).first?.id == folder.id
        else { return [:] }

        var currentSummaries = Dictionary(
            folder.projectDirectorySummaries.map { ($0.rootRelativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        if let gitUsage = folder.gitMetadataUsage {
            currentSummaries[gitUsage.rootRelativePath] = gitUsage
        }
        var changes: [String: HistoricalChange] = [:]
        for (relativePath, current) in currentSummaries where current.complete {
            guard let previous = ObservationComparison.previousCompleteDirectoryObservation(
                for: current, in: folder, history: history
            ),
                  let delta = ObservationComparison.allocatedByteDelta(
                      current: current, previous: previous.directory
                  ) else { continue }
            changes[relativePath] = HistoricalChange(
                previousObservedAt: previous.folder.finishedAt,
                currentObservedAt: folder.finishedAt,
                allocatedBytesChange: delta
            )
        }
        return changes
    }

    private static func category(for hint: StorageAreaHint?) -> Category {
        switch hint {
        case .swiftPackageBuild, .xcodeDerivedData, .buildOutputCandidate, .webBuildOutput:
            .buildProducts
        case .javascriptDependencies, .pythonEnvironment, .cocoaPodsDependencies, .carthageDependencies:
            .dependencies
        case .npmData, .pnpmStore, .yarnData, .pythonBytecode, .gradleData, .mavenData, .cargoData, .webBuildCache:
            .packageManagerData
        case .simulatorData, .dockerData:
            .runtimeAndSimulatorData
        case .modelDataDirectory, .datasetDirectory:
            .userData
        case .logDirectory:
            .logs
        case .xcodeArchives, .xcodeArchiveBundle, .debugSymbols:
            .archiveOrSymbols
        case .testCoverageOutput:
            .testOutput
        case nil:
            .buildProducts
        }
    }

    private static func risk(for category: Category) -> String {
        switch category {
        case .sourceControl: "High: may contain the only local repository history or uncommitted work."
        case .buildProducts: "Medium: often reproducible, but may include state or outputs still needed by a project."
        case .dependencies, .packageManagerData: "Medium: may be reproducible, but can be costly or impossible to restore offline."
        case .runtimeAndSimulatorData: "High: may include machine state, images, or environments used by active tools."
        case .userData: "High: may be original models, checkpoints, or datasets with no recoverable copy."
        case .logs: "Medium: may be needed for debugging, auditing, or incident investigation."
        case .archiveOrSymbols: "High: archives and symbols may be needed for release, support, or crash analysis."
        case .testOutput: "Low to medium: often regenerable, but current workflows may depend on retained results."
        }
    }

    private static func consequence(for category: Category) -> String {
        switch category {
        case .sourceControl: "Removing it could destroy commit history, branches, or uncommitted changes."
        case .buildProducts: "Removing it could force a rebuild or remove generated artifacts needed by a workflow."
        case .dependencies, .packageManagerData: "Removing it could require downloads or package reconstruction before work can continue."
        case .runtimeAndSimulatorData: "Removing it could reset emulators, containers, or local runtime state."
        case .userData: "Removing it could permanently lose valuable user or research data."
        case .logs: "Removing it could erase diagnostic evidence."
        case .archiveOrSymbols: "Removing it could prevent re-signing, submission, or symbolication of a release."
        case .testOutput: "Removing it could discard reports or require test and frontend work to run again."
        }
    }

    private static func absolutePath(root: String, relative: String) -> String {
        URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true).standardizedFileURL.path
    }

    private static func isAncestor(relative parent: String, of child: String) -> Bool {
        child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
