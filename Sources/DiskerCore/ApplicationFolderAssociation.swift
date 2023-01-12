import Foundation

public struct ApplicationFolderAssociation: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bundlePath }
    public let bundlePath: String
    public let relatedFolderPaths: [String]
    public let updatedAt: Date

    public init(bundlePath: String, relatedFolderPaths: [String], updatedAt: Date = .now) {
        self.bundlePath = bundlePath
        var uniquePaths: [String] = []
        var seen = Set<String>()
        for path in relatedFolderPaths where !path.isEmpty && seen.insert(path).inserted {
            uniquePaths.append(path)
        }
        self.relatedFolderPaths = Array(uniquePaths.suffix(50))
        self.updatedAt = updatedAt
    }

    public func adding(_ paths: [String], at date: Date = .now) -> ApplicationFolderAssociation {
        ApplicationFolderAssociation(
            bundlePath: bundlePath,
            relatedFolderPaths: relatedFolderPaths + paths,
            updatedAt: date
        )
    }

    public func removing(_ path: String, at date: Date = .now) -> ApplicationFolderAssociation? {
        let remaining = relatedFolderPaths.filter { $0 != path }
        guard !remaining.isEmpty else { return nil }
        return ApplicationFolderAssociation(
            bundlePath: bundlePath, relatedFolderPaths: remaining, updatedAt: date
        )
    }
}
