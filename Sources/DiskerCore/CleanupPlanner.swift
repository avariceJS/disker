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
