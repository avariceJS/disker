import Foundation

/// A user-authored relationship between one selected project root and other
/// exact paths. It records context only; it does not establish ownership.
public struct ProjectResourceAssociation: Codable, Equatable, Identifiable, Sendable {
    public static let maximumRelatedFolderCount = 50

    public var id: String { projectRootPath }
    public let projectRootPath: String
    public let relatedFolderPaths: [String]
    public let updatedAt: Date

    public init(
        projectRootPath: String,
        relatedFolderPaths: [String],
        updatedAt: Date = .now
    ) throws {
        let root = Self.standardizedAbsolutePath(projectRootPath)
        guard let root else { throw ProjectResourceAssociationError.invalidPath }

        var uniquePaths: [String] = []
        var seen = Set<String>([root])
        for path in relatedFolderPaths {
            guard let normalized = Self.standardizedAbsolutePath(path) else {
                throw ProjectResourceAssociationError.invalidPath
            }
            if seen.insert(normalized).inserted { uniquePaths.append(normalized) }
        }
        guard uniquePaths.count <= Self.maximumRelatedFolderCount else {
            throw ProjectResourceAssociationError.tooManyRelatedFolders
        }

        self.projectRootPath = root
        self.relatedFolderPaths = uniquePaths.sorted()
        self.updatedAt = updatedAt
    }

    public func adding(_ paths: [String], at date: Date = .now) throws -> ProjectResourceAssociation {
        try ProjectResourceAssociation(
            projectRootPath: projectRootPath,
            relatedFolderPaths: relatedFolderPaths + paths,
            updatedAt: date
        )
    }

    public func removing(_ path: String, at date: Date = .now) -> ProjectResourceAssociation? {
        guard let normalized = Self.standardizedAbsolutePath(path) else { return self }
        let remaining = relatedFolderPaths.filter { $0 != normalized }
        guard remaining.count != relatedFolderPaths.count else { return self }
        return try? ProjectResourceAssociation(
            projectRootPath: projectRootPath,
            relatedFolderPaths: remaining,
            updatedAt: date
        )
    }

    private enum CodingKeys: String, CodingKey {
        case projectRootPath, relatedFolderPaths, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let root = try values.decode(String.self, forKey: .projectRootPath)
        let paths = try values.decode([String].self, forKey: .relatedFolderPaths)
        let date = try values.decode(Date.self, forKey: .updatedAt)
        do {
            try self.init(projectRootPath: root, relatedFolderPaths: paths, updatedAt: date)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .relatedFolderPaths,
                in: values,
                debugDescription: "Invalid stored project resource association: \(error.localizedDescription)"
            )
        }
    }

    private static func standardizedAbsolutePath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}

public enum ProjectResourceAssociationError: Error, LocalizedError {
    case invalidPath
    case tooManyRelatedFolders
    case tooManyProjectRoots
    case projectHasLinkedFolders

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            "Project resource paths must be absolute filesystem paths."
        case .tooManyRelatedFolders:
            "A selected project root can have at most \(ProjectResourceAssociation.maximumRelatedFolderCount) explicitly linked folders."
        case .tooManyProjectRoots:
            "Disker can store at most \(ObservationStore.maximumProjectResourceAssociationCount) project roots."
        case .projectHasLinkedFolders:
            "Remove linked locations before stopping project tracking."
        }
    }
}

/// A bounded read-only projection of the latest observations for paths a user
/// explicitly grouped under a selected project root. Entries are never summed.
public struct ProjectResourceReview: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case selectedProjectRoot
        case userLinkedFolder
    }

    public struct Entry: Equatable, Identifiable, Sendable {
        public var id: String { path }
        public let path: String
        public let kind: Kind
        public let observation: FolderObservation?
        public let scanWasCancelled: Bool
        public let overlappingPaths: [String]
        public let linkedFromOtherProjectRoots: [String]

        public var isSharedLink: Bool { !linkedFromOtherProjectRoots.isEmpty }
    }

    public let projectRootPath: String
    public let entries: [Entry]

    public static func make(for projectRootPath: String, in history: LocalHistory) -> ProjectResourceReview {
        let root = standardized(projectRootPath)
        let association = history.projectResourceAssociations.first {
            standardized($0.projectRootPath) == root
        }
        let relatedPaths = association?.relatedFolderPaths ?? []
        let paths = [(root, Kind.selectedProjectRoot)] + relatedPaths.map {
            (standardized($0), Kind.userLinkedFolder)
        }
        let latest = latestObservations(in: history)
        let otherProjects = otherProjectLinks(in: history, for: root)

        let entries = paths.map { path, kind in
            let observation = latest[path]
            let cancelled = history.observations.first(where: { scan in
                scan.folders.contains(where: { $0.id == observation?.id })
            })?.cancelled ?? false
            let overlaps = paths.compactMap { otherPath, _ -> String? in
                guard otherPath != path,
                      isWithin(otherPath, root: path) || isWithin(path, root: otherPath) else { return nil }
                return otherPath
            }.sorted()
            return Entry(
                path: path,
                kind: kind,
                observation: observation,
                scanWasCancelled: cancelled,
                overlappingPaths: overlaps,
                linkedFromOtherProjectRoots: otherProjects[path, default: []]
            )
        }
        return ProjectResourceReview(projectRootPath: root, entries: entries)
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

    private static func otherProjectLinks(
        in history: LocalHistory, for projectRootPath: String
    ) -> [String: [String]] {
        var links: [String: Set<String>] = [:]
        for association in history.projectResourceAssociations
        where standardized(association.projectRootPath) != projectRootPath {
            let otherRoot = standardized(association.projectRootPath)
            for path in association.relatedFolderPaths {
                links[standardized(path), default: []].insert(otherRoot)
            }
        }
        return links.mapValues { $0.sorted() }
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private static func isWithin(_ path: String, root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") && path != "/" }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

/// Independent growth evidence for the exact paths in a project resource review.
/// No values are combined because linked and nested paths can overlap.
public struct ProjectResourceGrowthReview: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case compared
        case unmeasured
        case cancelled
        case partial
        case overflowed
        case needsBaseline
        case volumeChanged
        case timeOrderInvalid
        case previousOverflowed
        case deltaOverflowed
    }

    public struct Entry: Equatable, Identifiable, Sendable {
        public var id: String { path }
        public let path: String
        public let current: FolderObservation?
        public let previous: FolderObservation?
        public let logicalDelta: Int64?
        public let allocatedDelta: Int64?
        public let status: Status
    }

    public let entries: [Entry]

    /// Complete comparisons ordered by allocated-byte estimate delta, largest
    /// increases first. This ranks review attention without combining paths.
    public var rankedComparisonsByAllocatedDelta: [Entry] {
        entries.filter { $0.status == .compared }.sorted { lhs, rhs in
            if let left = lhs.allocatedDelta, let right = rhs.allocatedDelta, left != right {
                return left > right
            }
            return lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8)
        }
    }

    private struct RecordedFolder {
        let scanIndex: Int
        let scanWasCancelled: Bool
        let folder: FolderObservation
    }

    public static func make(for review: ProjectResourceReview, in history: LocalHistory) -> Self {
        var recordsByPath: [String: [RecordedFolder]] = [:]
        var scanIndexByFolderID: [UUID: Int] = [:]
        for (scanIndex, scan) in history.observations.enumerated() {
            for folder in scan.folders {
                scanIndexByFolderID[folder.id] = scanIndex
                recordsByPath[folder.path, default: []].append(RecordedFolder(
                    scanIndex: scanIndex,
                    scanWasCancelled: scan.cancelled,
                    folder: folder
                ))
            }
        }

        let entries = review.entries.map { resource -> Entry in
            guard let current = resource.observation else {
                return Entry(
                    path: resource.path, current: nil, previous: nil,
                    logicalDelta: nil, allocatedDelta: nil, status: .unmeasured
                )
            }
            if resource.scanWasCancelled {
                return unavailable(resource.path, current, .cancelled)
            }
            if !current.complete {
                return unavailable(resource.path, current, .partial)
            }
            if current.byteAccountingOverflowed || current.logicalBytes < 0 || current.allocatedBytes < 0 {
                return unavailable(resource.path, current, .overflowed)
            }
            guard let currentIndex = scanIndexByFolderID[current.id] else {
                return unavailable(resource.path, current, .needsBaseline)
            }

            for record in (recordsByPath[current.path] ?? []).reversed()
            where record.scanIndex < currentIndex {
                let candidate = record.folder
                guard candidate.complete else { continue }
                if record.scanWasCancelled { continue }
                guard sameVolume(candidate, current) else {
                    return unavailable(resource.path, current, .volumeChanged)
                }
                guard candidate.finishedAt < current.finishedAt else {
                    return unavailable(resource.path, current, .timeOrderInvalid)
                }
                guard !candidate.byteAccountingOverflowed,
                      candidate.logicalBytes >= 0, candidate.allocatedBytes >= 0 else {
                    return unavailable(resource.path, current, .previousOverflowed)
                }
                let (logicalDelta, logicalOverflow) = current.logicalBytes.subtractingReportingOverflow(
                    candidate.logicalBytes
                )
                let (allocatedDelta, allocatedOverflow) = current.allocatedBytes.subtractingReportingOverflow(
                    candidate.allocatedBytes
                )
                guard !logicalOverflow, !allocatedOverflow else {
                    return unavailable(resource.path, current, .deltaOverflowed)
                }
                return Entry(
                    path: resource.path, current: current, previous: candidate,
                    logicalDelta: logicalDelta, allocatedDelta: allocatedDelta, status: .compared
                )
            }
            return unavailable(resource.path, current, .needsBaseline)
        }
        return Self(entries: entries)
    }

    private static func unavailable(
        _ path: String, _ current: FolderObservation, _ status: Status
    ) -> Entry {
        Entry(
            path: path, current: current, previous: nil,
            logicalDelta: nil, allocatedDelta: nil, status: status
        )
    }

    private static func sameVolume(_ lhs: FolderObservation, _ rhs: FolderObservation) -> Bool {
        switch (lhs.volumeDeviceID, rhs.volumeDeviceID) {
        case let (left?, right?): left == right
        case (nil, nil): true
        default: false
        }
    }
}
