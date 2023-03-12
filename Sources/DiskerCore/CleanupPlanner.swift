import Foundation

public struct CleanupPlanEntry: Equatable, Sendable, Identifiable {
    public var id: String { targetPath }
    public let targetPath: String
    public let preservedPath: String
    public let verifiedSHA256: String
    public let logicalBytes: UInt64
    public let allocatedBytesEstimate: UInt64
    /// File identity does not establish actual physical blocks that removal frees.
    public let reclaimableBytes: UInt64? = nil
    /// A verified duplicate still may be shared, referenced, or intentionally retained.
    public let risk: Risk = .unknown

    public init(
        targetPath: String, preservedPath: String, verifiedSHA256: String,
        logicalBytes: UInt64, allocatedBytesEstimate: UInt64
    ) {
        self.targetPath = targetPath
        self.preservedPath = preservedPath
        self.verifiedSHA256 = verifiedSHA256
        self.logicalBytes = logicalBytes
        self.allocatedBytesEstimate = allocatedBytesEstimate
    }

    /// A path-name heuristic only; it does not establish ownership or removability.
    public var targetPathContext: PathContext { PathContext.classify(path: targetPath) }
    /// The retained copy may also have important or shared path context.
    public var preservedPathContext: PathContext { PathContext.classify(path: preservedPath) }

    public enum Risk: String, Equatable, Sendable {
        case unknown
    }

    public enum PathContext: String, Equatable, Sendable {
        case applicationBundle
        case gitMetadata
        case applicationOrSharedData
        case ordinaryPath

        public var caution: String {
            switch self {
            case .applicationBundle:
                "Inside an app bundle; removing a file may break the installed app or its resources."
            case .gitMetadata:
                "Inside Git metadata; removing a file may corrupt repository history or indexes."
            case .applicationOrSharedData:
                "In an application-data location; it may contain unique state or data shared with another app."
            case .ordinaryPath:
                "No special path context was detected; duplicate equality still does not establish safe removal."
            }
        }

        fileprivate static func classify(path: String) -> Self {
            let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            if components.contains(where: { $0.lowercased().hasSuffix(".app") }) {
                return .applicationBundle
            }
            if components.contains(".git") {
                return .gitMetadata
            }
            let applicationDataComponents: Set<String> = [
                "Application Support", "Caches", "Containers", "Group Containers",
                "Logs", "Preferences", "Saved Application State"
            ]
            if components.contains(where: applicationDataComponents.contains) {
                return .applicationOrSharedData
            }
            return .ordinaryPath
        }
    }
}

public struct CleanupPlan: Equatable, Sendable {
    public let verifiedAt: Date?
    public let selectedRootPaths: [String]
    public let sourceCoverageComplete: Bool
    public let entries: [CleanupPlanEntry]

    public init(
        verifiedAt: Date? = .now, selectedRootPaths: [String] = [],
        sourceCoverageComplete: Bool = false, entries: [CleanupPlanEntry]
    ) {
        self.verifiedAt = verifiedAt
        self.selectedRootPaths = selectedRootPaths
        self.sourceCoverageComplete = sourceCoverageComplete
        self.entries = entries
    }
}

public enum CleanupPlanError: Error, LocalizedError {
    case keeperNotInVerifiedGroup
    case pathOutsideSelectedScope
    case invalidDuplicateGroup

    public var errorDescription: String? {
        switch self {
        case .keeperNotInVerifiedGroup:
            return "The chosen preserved file is not part of its verified duplicate group."
        case .pathOutsideSelectedScope:
            return "A duplicate path is outside the folders selected for this check."
        case .invalidDuplicateGroup:
            return "A cleanup review needs at least two distinct files with one verified digest."
        }
    }
}

/// Creates a review-only plan from confirmed duplicate groups and the user's
/// explicit choice of which exact path to preserve. It never executes a change.
public enum CleanupPlanner {
    public static func makePlan(
        from result: DuplicateVerificationResult,
        preserving preservedPaths: [String: String]
    ) throws -> CleanupPlan {
        var entries: [CleanupPlanEntry] = []
        for group in result.groups {
            guard let preservedPath = preservedPaths[group.sha256] else { continue }
            guard group.files.count > 1,
                  Set(group.files.map(\.path)).count == group.files.count else {
                throw CleanupPlanError.invalidDuplicateGroup
            }
            guard group.files.contains(where: { $0.path == preservedPath }) else {
                throw CleanupPlanError.keeperNotInVerifiedGroup
            }
            guard group.files.allSatisfy({ file in
                result.selectedRootPaths.contains(where: { isWithinScope(file.path, root: $0) })
            }) else {
                throw CleanupPlanError.pathOutsideSelectedScope
            }

            for file in group.files where file.path != preservedPath {
                entries.append(CleanupPlanEntry(
                    targetPath: file.path,
                    preservedPath: preservedPath,
                    verifiedSHA256: group.sha256,
                    logicalBytes: file.logicalBytes,
                    allocatedBytesEstimate: file.allocatedBytes
                ))
            }
        }

        return CleanupPlan(
            verifiedAt: result.verifiedAt,
            selectedRootPaths: result.selectedRootPaths,
            sourceCoverageComplete: result.complete,
            entries: entries.sorted {
                $0.targetPath.utf8.lexicographicallyPrecedes($1.targetPath.utf8)
            }
        )
    }

    private static func isWithinScope(_ path: String, root: String) -> Bool {
        let targetPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        if rootPath == "/" { return targetPath.hasPrefix("/") && targetPath != "/" }
        return targetPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

/// Read-only application-removal review. This type describes evidence and
/// exclusions only; it does not identify executable cleanup targets.
public struct ApplicationRemovalReviewPlan: Equatable, Sendable {
    public enum Disposition: String, Equatable, Sendable {
        /// Evidence is incomplete or structurally unsafe for a removal review.
        case excludedFromCleanup
        /// A person may inspect this path, but no cleanup candidacy is implied.
        case inspectOnly
        /// The selected app bundle may be reviewed only after recovery or
        /// replacement has been independently confirmed.
        case ownerReviewCandidate

        public var title: String {
            switch self {
            case .excludedFromCleanup: "Excluded from cleanup review"
            case .inspectOnly: "Inspect only · preserve"
            case .ownerReviewCandidate: "Owner review only · confirm replacement first"
            }
        }
    }

    public enum Reason: String, Equatable, Sendable {
        case sharedOrMultiOwner
        case overlappingScope
        case missingObservation
        case staleObservation
        case futureDatedObservation
        case incompleteObservation
        case cancelledObservation
        case byteAccountingOverflow
        case invalidByteCount
        case inaccessibleCoverage
        case symlinkCoverage
        case specialEntryCoverage
        case nestedVolumeCoverage
        case changedDuringObservation
        case measurementPathMismatch
        case invalidSelectedPath
        case protectedSystemPath
        case bundleSelectionUnconfirmed
        case unknownOrPotentiallyUniqueData
        case cacheRegenerationUnverified
        case bundleRecoveryUnverified

        public var explanation: String {
            switch self {
            case .sharedOrMultiOwner:
                "This path is shared or linked to another app; current consumers are unknown."
            case .overlappingScope:
                "This path overlaps another reviewed scope, so its measurement may be double-counted."
            case .missingObservation:
                "No current measurement exists for this exact path."
            case .staleObservation:
                "The latest measurement is older than the review freshness window."
            case .futureDatedObservation:
                "The measurement timestamp is later than this review and cannot be treated as current."
            case .incompleteObservation:
                "The selected-path observation is partial."
            case .cancelledObservation:
                "The scan was cancelled, so this observation is not complete evidence."
            case .byteAccountingOverflow:
                "Byte accounting overflowed; the displayed measurement may be capped."
            case .invalidByteCount:
                "The observation contains a negative byte count."
            case .inaccessibleCoverage:
                "Some selected-path items were inaccessible."
            case .symlinkCoverage:
                "Symlink entries were excluded from the selected-path measurement."
            case .specialEntryCoverage:
                "Special filesystem entries were excluded from the selected-path measurement."
            case .nestedVolumeCoverage:
                "A nested volume was excluded from the selected-path measurement."
            case .changedDuringObservation:
                "The path or its contents changed during observation."
            case .measurementPathMismatch:
                "The measurement belongs to a different path."
            case .invalidSelectedPath:
                "The selected path is not a safe absolute path for an exact review."
            case .protectedSystemPath:
                "This path is inside a macOS-managed system location and is excluded from app-removal candidacy."
            case .bundleSelectionUnconfirmed:
                "This bundle path lacks explicit app-picker provenance."
            case .unknownOrPotentiallyUniqueData:
                "Ownership or recovery is unknown; this may be unique user data. Preserve it."
            case .cacheRegenerationUnverified:
                "A cache name is only a weak clue; current use and regeneration are unverified."
            case .bundleRecoveryUnverified:
                "The app bundle is only an owner-review candidate until a trusted replacement or recovery path is confirmed."
            }
        }
    }

    public struct Measurement: Equatable, Sendable {
        public let observedPath: String
        public let finishedAt: Date
        public let logicalBytes: Int64
        public let allocatedBytesEstimate: Int64
        public let complete: Bool
        public let wasCancelled: Bool
        public let inaccessibleCount: Int
        public let excludedSymlinkCount: Int
        public let excludedSpecialFileCount: Int
        public let excludedVolumeBoundaryCount: Int
        public let changedDuringScanCount: Int
        public let byteAccountingOverflowed: Bool

        fileprivate init(observation: FolderObservation, wasCancelled: Bool) {
            observedPath = observation.path
            finishedAt = observation.finishedAt
            logicalBytes = observation.logicalBytes
            allocatedBytesEstimate = observation.allocatedBytes
            complete = observation.complete
            self.wasCancelled = wasCancelled
            inaccessibleCount = observation.inaccessibleCount
            excludedSymlinkCount = observation.excludedSymlinkCount
            excludedSpecialFileCount = observation.excludedSpecialFileCount
            excludedVolumeBoundaryCount = observation.excludedVolumeBoundaryCount
            changedDuringScanCount = observation.changedDuringScanCount
            byteAccountingOverflowed = observation.byteAccountingOverflowed
        }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String { path }
        /// Exact path retained from the application footprint review.
        public let path: String
        public let kind: ApplicationFootprintReview.ScopeKind
        public let disposition: Disposition
        public let reasons: [Reason]
        public let measurement: Measurement?
        /// Original typed ownership attribution. It is evidence, not a claim
        /// of exclusive ownership or safe removal.
        public let attribution: ApplicationPathAttribution?
        /// Exact bundle paths that also associate with this selected scope.
        public let otherAssociatedBundlePaths: [String]
        /// Exact reviewed paths that overlap this scope by containment.
        public let overlappingPaths: [String]
    }

    public static let defaultMaximumMeasurementAge: TimeInterval = 24 * 60 * 60

    public let bundlePath: String
    public let reviewedAt: Date
    public let maximumMeasurementAge: TimeInterval
    public let rows: [Row]

    public static func make(
        from review: ApplicationFootprintReview,
        asOf reviewedAt: Date = .now,
        maximumMeasurementAge: TimeInterval = defaultMaximumMeasurementAge
    ) -> ApplicationRemovalReviewPlan {
        let maximumAge = max(0, maximumMeasurementAge.isFinite ? maximumMeasurementAge : 0)
        let pathOverlaps = overlappingPaths(in: review.entries.map(\.path))
        let rows = review.entries.map { entry -> Row in
            var reasons: [Reason] = []
            func add(_ reason: Reason) {
                if !reasons.contains(reason) { reasons.append(reason) }
            }

            if !isSafeAbsolutePath(entry.path) { add(.invalidSelectedPath) }
            if isProtectedSystemPath(entry.path) { add(.protectedSystemPath) }
            if entry.kind == .applicationBundle,
               entry.observation?.selectedAsApplicationBundle != true {
                add(.bundleSelectionUnconfirmed)
            }
            if entry.isShared { add(.sharedOrMultiOwner) }
            if !entry.overlappingPaths.isEmpty || pathOverlaps.contains(entry.path) {
                add(.overlappingScope)
            }

            let measurement = entry.observation.map {
                Measurement(observation: $0, wasCancelled: entry.scanWasCancelled)
            }
            if let observation = entry.observation {
                if !sameLexicalPath(observation.path, entry.path) { add(.measurementPathMismatch) }
                if entry.scanWasCancelled { add(.cancelledObservation) }
                if !observation.complete { add(.incompleteObservation) }
                if observation.byteAccountingOverflowed { add(.byteAccountingOverflow) }
                if observation.logicalBytes < 0 || observation.allocatedBytes < 0 { add(.invalidByteCount) }
                if observation.inaccessibleCount > 0 { add(.inaccessibleCoverage) }
                if observation.excludedSymlinkCount > 0 { add(.symlinkCoverage) }
                if observation.excludedSpecialFileCount > 0 { add(.specialEntryCoverage) }
                if observation.excludedVolumeBoundaryCount > 0 { add(.nestedVolumeCoverage) }
                if observation.changedDuringScanCount > 0 { add(.changedDuringObservation) }
                if observation.finishedAt > reviewedAt {
                    add(.futureDatedObservation)
                } else if reviewedAt.timeIntervalSince(observation.finishedAt) > maximumAge {
                    add(.staleObservation)
                }
            } else {
                add(.missingObservation)
            }

            let hasEvidenceBlocker = reasons.contains(where: Self.isEvidenceBlocker)
            let disposition: Disposition
            if hasEvidenceBlocker {
                disposition = .excludedFromCleanup
            } else {
                switch entry.cleanupReviewClass {
                case .sharedOrMultiOwner:
                    add(.sharedOrMultiOwner)
                    disposition = .excludedFromCleanup
                case .possibleCache:
                    add(.cacheRegenerationUnverified)
                    disposition = .inspectOnly
                case .selectedBundle:
                    add(.bundleRecoveryUnverified)
                    disposition = .ownerReviewCandidate
                case .unknownOrPotentiallyUnique:
                    add(.unknownOrPotentiallyUniqueData)
                    disposition = .inspectOnly
                }
            }
            return Row(
                path: entry.path, kind: entry.kind, disposition: disposition,
                reasons: reasons, measurement: measurement, attribution: entry.attribution,
                otherAssociatedBundlePaths: entry.otherAssociatedBundlePaths,
                overlappingPaths: entry.overlappingPaths
            )
        }
        return ApplicationRemovalReviewPlan(
            bundlePath: review.bundlePath, reviewedAt: reviewedAt,
            maximumMeasurementAge: maximumAge, rows: rows
        )
    }

    private static func isEvidenceBlocker(_ reason: Reason) -> Bool {
        switch reason {
        case .sharedOrMultiOwner, .overlappingScope, .missingObservation, .staleObservation,
             .futureDatedObservation, .incompleteObservation, .cancelledObservation,
             .byteAccountingOverflow, .invalidByteCount, .inaccessibleCoverage,
             .symlinkCoverage, .specialEntryCoverage, .nestedVolumeCoverage,
             .changedDuringObservation, .measurementPathMismatch, .invalidSelectedPath,
             .protectedSystemPath, .bundleSelectionUnconfirmed:
            true
        case .unknownOrPotentiallyUniqueData, .cacheRegenerationUnverified, .bundleRecoveryUnverified:
            false
        }
    }

    private static func isSafeAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", !path.utf8.contains(0) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return !components.contains(".") && !components.contains("..")
    }

    private static func isProtectedSystemPath(_ path: String) -> Bool {
        let candidate = standardizedLexically(path).lowercased()
        let protectedRoots = ["/system", "/usr", "/bin", "/sbin", "/private"]
        return protectedRoots.contains { root in
            candidate == root || isWithin(candidate, root: root)
        }
    }

    private static func sameLexicalPath(_ lhs: String, _ rhs: String) -> Bool {
        standardizedLexically(lhs) == standardizedLexically(rhs)
    }

    private static func overlappingPaths(in paths: [String]) -> Set<String> {
        var overlaps = Set<String>()
        for firstIndex in paths.indices {
            for secondIndex in paths.indices where secondIndex > firstIndex {
                let first = standardizedLexically(paths[firstIndex])
                let second = standardizedLexically(paths[secondIndex])
                if first == second || isWithin(first, root: second) || isWithin(second, root: first) {
                    overlaps.insert(paths[firstIndex])
                    overlaps.insert(paths[secondIndex])
                }
            }
        }
        return overlaps
    }

    private static func standardizedLexically(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isWithin(_ path: String, root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") && path != "/" }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

/// Builds conservative app-removal review rows from existing footprint evidence.
/// It has no file-system mutation or cleanup execution API.
public enum ApplicationRemovalReviewPlanner {
    public static func makePlan(
        from review: ApplicationFootprintReview,
        asOf reviewedAt: Date = .now,
        maximumMeasurementAge: TimeInterval = ApplicationRemovalReviewPlan.defaultMaximumMeasurementAge
    ) -> ApplicationRemovalReviewPlan {
        ApplicationRemovalReviewPlan.make(
            from: review, asOf: reviewedAt, maximumMeasurementAge: maximumMeasurementAge
        )
    }
}
