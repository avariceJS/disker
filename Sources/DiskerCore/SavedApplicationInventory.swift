import Foundation

public enum SavedApplicationSpotlightState: Equatable, Sendable {
    case visibleInCurrentCatalog
    case availableInExtendedSearch
    case notObservedInCurrentSample
    case unknown
}

public struct SavedApplicationLocation: Equatable, Identifiable, Sendable {
    public let path: String
    public let latestObservation: FolderObservation?
    public let latestObservationWasCancelled: Bool

    public var id: String { path }

    public init(path: String, latestObservation: FolderObservation?, latestObservationWasCancelled: Bool) {
        self.path = path
        self.latestObservation = latestObservation
        self.latestObservationWasCancelled = latestObservationWasCancelled
    }
}

public struct SavedApplicationInventoryEntry: Equatable, Identifiable, Sendable {
    public let bundlePath: String
    public let displayName: String
    public let bundleIdentifier: String?
    public let firstSeenInSpotlightAt: Date?
    public let lastSeenInSpotlightAt: Date?
    public let launchServicesLastOpenedAt: Date?
    public let bundleObservation: FolderObservation?
    public let bundleObservationWasCancelled: Bool
    public let relatedLocations: [SavedApplicationLocation]
    public let spotlightState: SavedApplicationSpotlightState

    public var id: String { bundlePath }
}

public struct SavedApplicationInventory: Equatable, Sendable {
    public static let maximumDisplayedEntries = 500

    public let entries: [SavedApplicationInventoryEntry]
    public let hasMore: Bool

    public static func make(
        from history: LocalHistory,
        visibleSpotlightPaths: Set<String>,
        extendedSpotlightPaths: Set<String>,
        spotlightQueryCompleted: Bool,
        searchText: String = "",
        limit: Int = maximumDisplayedEntries
    ) -> SavedApplicationInventory {
        guard limit > 0 else { return SavedApplicationInventory(entries: [], hasMore: false) }

        let visiblePaths = Set(visibleSpotlightPaths.map(normalize))
        let extendedPaths = Set(extendedSpotlightPaths.map(normalize))

        var discoveryByPath: [String: ApplicationDiscoveryRecord] = [:]
        for record in history.discoveredApplications {
            guard let path = normalizeApplicationPath(record.path) else { continue }
            if discoveryByPath[path] == nil { discoveryByPath[path] = record }
        }

        var associationByBundlePath: [String: ApplicationFolderAssociation] = [:]
        for association in history.applicationAssociations.sorted(by: {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.bundlePath < $1.bundlePath
        }) {
            guard let path = normalizeApplicationPath(association.bundlePath) else { continue }
            if associationByBundlePath[path] == nil { associationByBundlePath[path] = association }
        }

        var latestByPath: [String: (observation: FolderObservation, wasCancelled: Bool)] = [:]
        for scan in history.observations.reversed() {
            for folder in scan.folders {
                let path = normalize(folder.path)
                if latestByPath[path] == nil {
                    latestByPath[path] = (folder, scan.cancelled)
                }
            }
        }

        let bundleMeasurements = Dictionary(
            ApplicationBundleIndex.latestMeasurements(in: history)
                .compactMap { measurement in
                    normalizeApplicationPath(measurement.path).map { ($0, measurement) }
                },
            uniquingKeysWith: { first, _ in first }
        )

        let bundlePaths = Set(discoveryByPath.keys)
            .union(associationByBundlePath.keys)
            .union(bundleMeasurements.keys)

        let allEntries = bundlePaths.map { bundlePath -> SavedApplicationInventoryEntry in
            let discovery = discoveryByPath[bundlePath]
            let association = associationByBundlePath[bundlePath]
            let bundleMeasurement = bundleMeasurements[bundlePath]
            let displayName = discovery?.displayName
                ?? bundleMeasurement?.displayName
                ?? URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent

            let relatedLocations = (association?.relatedFolderPaths ?? []).compactMap { rawPath -> SavedApplicationLocation? in
                guard !rawPath.isEmpty else { return nil }
                let path = normalize(rawPath)
                let latest = latestByPath[path]
                return SavedApplicationLocation(
                    path: path,
                    latestObservation: latest?.observation,
                    latestObservationWasCancelled: latest?.wasCancelled ?? false
                )
            }

            let spotlightState: SavedApplicationSpotlightState
            if visiblePaths.contains(bundlePath) {
                spotlightState = .visibleInCurrentCatalog
            } else if extendedPaths.contains(bundlePath) {
                spotlightState = .availableInExtendedSearch
            } else if spotlightQueryCompleted {
                spotlightState = .notObservedInCurrentSample
            } else {
                spotlightState = .unknown
            }

            return SavedApplicationInventoryEntry(
                bundlePath: bundlePath,
                displayName: displayName,
                bundleIdentifier: association?.bundleIdentifier ?? bundleMeasurement?.applicationBundleIdentifier,
                firstSeenInSpotlightAt: discovery?.firstSeenAt,
                lastSeenInSpotlightAt: discovery?.lastSeenAt,
                launchServicesLastOpenedAt: discovery?.launchServicesLastOpenedAt,
                bundleObservation: bundleMeasurement,
                bundleObservationWasCancelled: latestByPath[bundlePath]?.wasCancelled ?? false,
                relatedLocations: relatedLocations,
                spotlightState: spotlightState
            )
        }

        let matchingEntries = allEntries.filter { entry in
            searchText.isEmpty
                || entry.displayName.localizedStandardContains(searchText)
                || entry.bundlePath.localizedStandardContains(searchText)
                || entry.bundleIdentifier?.localizedStandardContains(searchText) == true
        }
        let rankedEntries = matchingEntries.map { entry in
            (entry: entry, latestActivity: latestActivity(for: entry),
             isSavedOnly: entry.spotlightState != .visibleInCurrentCatalog)
        }
        let sorted = rankedEntries.sorted { lhs, rhs in
            if lhs.isSavedOnly != rhs.isSavedOnly { return lhs.isSavedOnly }
            if lhs.latestActivity != rhs.latestActivity { return lhs.latestActivity > rhs.latestActivity }
            return lhs.entry.bundlePath.utf8.lexicographicallyPrecedes(rhs.entry.bundlePath.utf8)
        }
        return SavedApplicationInventory(
            entries: sorted.prefix(limit).map(\.entry),
            hasMore: sorted.count > limit
        )
    }

    private static func normalizeApplicationPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL
        guard normalized.pathExtension.lowercased() == "app" else { return nil }
        return normalized.path
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func latestActivity(for entry: SavedApplicationInventoryEntry) -> Date {
        let dates = [entry.lastSeenInSpotlightAt, entry.bundleObservation?.finishedAt]
            .compactMap { $0 }
            + entry.relatedLocations.compactMap { $0.latestObservation?.finishedAt }
        return dates.max() ?? .distantPast
    }
}
