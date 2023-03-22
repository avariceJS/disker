import Darwin
import Foundation

public struct ApplicationDiscoveryRecord: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let displayName: String
    public let firstSeenAt: Date
    public let lastSeenAt: Date

    public var id: String { path }

    public init(path: String, displayName: String, firstSeenAt: Date, lastSeenAt: Date) {
        self.path = path
        self.displayName = displayName
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct ApplicationDiscoveryCandidate: Equatable, Identifiable, Sendable {
    public let path: String
    public let displayName: String

    public var id: String { path }

    public init(path: String, displayName: String) {
        self.path = path
        self.displayName = displayName
    }
}

/// A bounded view of indexed application candidates and whether the bound omitted any.
public struct ApplicationDiscoverySample: Equatable, Sendable {
    public let candidates: [ApplicationDiscoveryCandidate]
    public let hasMore: Bool
}

public enum ApplicationBundleIndex {
    public static let maximumDiscoveryRecords = 500

    /// Applies lexical scope and bundle-name checks to metadata-index results.
    /// Filesystem identity and symlink checks remain the caller's responsibility.
    public static func scopedCandidates(
        _ candidates: [ApplicationDiscoveryCandidate], within scopes: [String], limit: Int = maximumDiscoveryRecords
    ) -> [ApplicationDiscoveryCandidate] {
        guard limit > 0 else { return [] }
        let normalizedScopes = Set(scopes.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let path = URL(fileURLWithPath: candidate.path).standardizedFileURL.path
            guard URL(fileURLWithPath: path).pathExtension.lowercased() == "app",
                  !URL(fileURLWithPath: path).pathComponents.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }),
                  normalizedScopes.contains(where: { isDescendant(path, of: $0) }),
                  seen.insert(path).inserted
            else { return nil }
            return ApplicationDiscoveryCandidate(path: path, displayName: candidate.displayName)
        }
        .sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }
    }

    /// Returns a sorted display sample and accurately reports when valid scoped
    /// candidates were omitted by the requested bound.
    public static func scopedCandidateSample(
        _ candidates: [ApplicationDiscoveryCandidate], within scopes: [String], limit: Int
    ) -> ApplicationDiscoverySample {
        guard limit > 0 else {
            return ApplicationDiscoverySample(
                candidates: [], hasMore: !scopedCandidates(candidates, within: scopes).isEmpty
            )
        }
        let lookaheadLimit = limit == Int.max ? Int.max : limit + 1
        let bounded = scopedCandidates(candidates, within: scopes, limit: lookaheadLimit)
        return ApplicationDiscoverySample(
            candidates: Array(bounded.prefix(limit)), hasMore: bounded.count > limit
        )
    }

    /// Confirms every existing path component with lstat; no symlink is followed.
    public static func isDirectoryWithoutFollowingSymlinks(at url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            var metadata = stat()
            let isDirectory = current.withUnsafeFileSystemRepresentation { path in
                guard let path else { return false }
                return lstat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFDIR
            }
            if !isDirectory { return false }
        }
        return true
    }

    /// Updates a bounded in-memory discovery history. Previously seen paths keep
    /// their first-seen timestamp, including when absent from an intermediate query.
    public static func updatingDiscoveryHistory(
        _ history: [ApplicationDiscoveryRecord], with candidates: [ApplicationDiscoveryCandidate],
        at date: Date = .now, limit: Int = maximumDiscoveryRecords
    ) -> [ApplicationDiscoveryRecord] {
        guard limit > 0 else { return [] }
        var byPath = Dictionary(history.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for candidate in candidates {
            let normalizedPath = URL(fileURLWithPath: candidate.path).standardizedFileURL.path
            guard URL(fileURLWithPath: normalizedPath).pathExtension.lowercased() == "app",
                  !URL(fileURLWithPath: normalizedPath).pathComponents.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") })
            else { continue }
            let old = byPath[normalizedPath]
            byPath[normalizedPath] = ApplicationDiscoveryRecord(
                path: normalizedPath, displayName: candidate.displayName,
                firstSeenAt: old?.firstSeenAt ?? date, lastSeenAt: date
            )
        }
        return byPath.values.sorted {
            if $0.lastSeenAt != $1.lastSeenAt { return $0.lastSeenAt > $1.lastSeenAt }
            return $0.path < $1.path
        }.prefix(limit).map { $0 }
    }

    private static func isDescendant(_ path: String, of scope: String) -> Bool {
        path != scope && path.hasPrefix(scope.hasSuffix("/") ? scope : scope + "/")
    }

    /// Latest measurements for paths the user explicitly selected through
    /// the app-bundle picker. Later scans of the same path remain current even
    /// when they came from a saved folder bookmark. Bundle identity and
    /// signature details come only from the measurement that recorded them.
    /// This does not discover or attribute support data outside the bundle.
    public static func latestMeasurements(in history: LocalHistory) -> [FolderObservation] {
        let explicitlySelectedPaths = Set(history.observations.lazy
            .flatMap(\.folders)
            .filter(\.selectedAsApplicationBundle)
            .map(\.path))
        var latestByPath: [String: FolderObservation] = [:]
        for observation in history.observations.reversed() {
            for folder in observation.folders
            where explicitlySelectedPaths.contains(folder.path) {
                if latestByPath[folder.path] == nil { latestByPath[folder.path] = folder }
            }
        }
        return latestByPath.values.sorted {
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
        }
    }
}
