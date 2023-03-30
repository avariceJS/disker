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

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            "Project resource paths must be absolute filesystem paths."
        case .tooManyRelatedFolders:
            "A selected project root can have at most \(ProjectResourceAssociation.maximumRelatedFolderCount) explicitly linked folders."
        case .tooManyProjectRoots:
            "Disker can store at most \(ObservationStore.maximumProjectResourceAssociationCount) project roots."
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
