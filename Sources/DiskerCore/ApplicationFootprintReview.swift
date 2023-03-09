import Foundation

/// Read-only evidence for reviewing the measured paths related to one selected app.
/// The entries are deliberately not summed into an app footprint or reclaimable total.
public struct ApplicationFootprintReview: Equatable, Sendable {
    public enum CleanupReviewClass: Equatable, Sendable {
        case sharedOrMultiOwner
        case possibleCache
        case selectedBundle
        case unknownOrPotentiallyUnique

        public var title: String {
            switch self {
            case .sharedOrMultiOwner: "Shared or multi-owner · review all consumers"
            case .possibleCache: "Possible cache · regeneration unverified"
            case .selectedBundle: "Application bundle · replacement unverified"
            case .unknownOrPotentiallyUnique: "Unknown or user data · preserve"
            }
        }

        public var guidance: String {
            switch self {
            case .sharedOrMultiOwner:
                "Current use is unknown. Removing this path for one app may affect other consumers; do not treat it as app-exclusive data."
            case .possibleCache:
                "This path matches a conventional Caches location by name only. Freshness, current use, and whether its contents can be regenerated are unverified."
            case .selectedBundle:
                "Reinstallation might restore the app, but a trusted installer has not been verified. Related support data can remain."
            case .unknownOrPotentiallyUnique:
                "Ownership, current use, and recovery options are unknown. Treat this as potentially unique user data and preserve it until verified."
            }
        }
    }

    public enum ScopeKind: Equatable, Sendable {
        case applicationBundle
        case associatedFolder
    }

    public struct Entry: Equatable, Identifiable, Sendable {
        public var id: String { path }
        public let path: String
        public let kind: ScopeKind
        public let observation: FolderObservation?
        public let scanWasCancelled: Bool
        public let attribution: ApplicationPathAttribution?
        /// Other app records that link this exact path. This is association evidence,
        /// not proof that another app currently uses the location.
        public let otherAssociatedBundlePaths: [String]
        /// Other reviewed paths that contain or are contained by this scope.
        public let overlappingPaths: [String]

        public var isShared: Bool {
            !otherAssociatedBundlePaths.isEmpty
                || attribution?.evidence == .declaredSharedGroupContainerClaim
                || attribution?.evidence == .signatureCoveredSharedGroupClaim
        }

        public var cleanupReviewClass: CleanupReviewClass {
            if isShared { return .sharedOrMultiOwner }
            if kind == .applicationBundle { return .selectedBundle }
            if attribution?.evidence == .probableNamedSupportPathMatch,
               URL(fileURLWithPath: path).pathComponents.contains("Caches") {
                return .possibleCache
            }
            return .unknownOrPotentiallyUnique
        }
    }

    public let bundlePath: String
    public let entries: [Entry]

    /// Physical space reclaimable by removing the app cannot be attributed from
    /// independent path scans, shared scopes, and allocated-byte estimates.
    public let reclaimableBytes: Int64? = nil

    public static func make(
        for bundle: FolderObservation,
        in history: LocalHistory,
        homeDirectoryPath: String
    ) -> ApplicationFootprintReview {
        let bundlePath = standardized(bundle.path)
        let associatedPaths = history.applicationAssociations
            .first(where: { standardized($0.bundlePath) == bundlePath })?.relatedFolderPaths ?? []
        var paths: [(String, ScopeKind)] = [(bundlePath, .applicationBundle)]
        var seen: Set<String> = [bundlePath]
        for path in associatedPaths {
            let normalized = standardized(path)
            guard seen.insert(normalized).inserted else { continue }
            paths.append((normalized, .associatedFolder))
        }

        let observationsByPath = latestObservations(in: history)
        let otherAssociationsByPath = otherAssociations(in: history, for: bundlePath)
        let entries = paths.map { path, kind in
            let attribution: ApplicationPathAttribution?
            if kind == .associatedFolder {
                attribution = ApplicationPathAttribution.classify(
                    bundleIdentifier: bundle.applicationBundleIdentifier,
                    associatedFolderPath: path,
                    homeDirectoryPath: homeDirectoryPath,
                    claimedGroupIdentifiers: bundle.applicationGroupIdentifiers,
                    signatureValidated: bundle.applicationSignatureValidated,
                    signedBundleIdentifier: bundle.applicationSignedBundleIdentifier
                )
            } else {
                attribution = nil
            }
            let overlaps = paths.compactMap { otherPath, _ -> String? in
                guard otherPath != path,
                      isWithin(otherPath, root: path) || isWithin(path, root: otherPath) else { return nil }
                return otherPath
            }
            return Entry(
                path: path, kind: kind,
                observation: observationsByPath[path],
                scanWasCancelled: history.observations.first(where: { scan in
                    scan.folders.contains(where: { $0.id == observationsByPath[path]?.id })
                })?.cancelled ?? false,
                attribution: attribution,
                otherAssociatedBundlePaths: otherAssociationsByPath[path, default: []],
                overlappingPaths: overlaps.sorted()
            )
        }
        return ApplicationFootprintReview(bundlePath: bundlePath, entries: entries)
    }

    private init(bundlePath: String, entries: [Entry]) {
        self.bundlePath = bundlePath
        self.entries = entries
    }

    private static func latestObservations(in history: LocalHistory) -> [String: FolderObservation] {
        var latest: [String: FolderObservation] = [:]
        for scan in history.observations.reversed() {
            for observation in scan.folders where latest[standardized(observation.path)] == nil {
                latest[standardized(observation.path)] = observation
            }
        }
        return latest
    }

    private static func otherAssociations(
        in history: LocalHistory, for bundlePath: String
    ) -> [String: [String]] {
        var result: [String: Set<String>] = [:]
        for association in history.applicationAssociations
        where standardized(association.bundlePath) != bundlePath {
            let otherBundlePath = standardized(association.bundlePath)
            for path in association.relatedFolderPaths {
                result[standardized(path), default: []].insert(otherBundlePath)
            }
        }
        return result.mapValues { $0.sorted() }
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isWithin(_ path: String, root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") && path != "/" }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
