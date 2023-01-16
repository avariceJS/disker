import Foundation

public struct ApplicationFolderAssociation: Codable, Equatable, Identifiable, Sendable {
    public static let maximumRelatedFolderCount = 50
    public var id: String { bundlePath }
    public let bundlePath: String
    /// Read from the selected app bundle's Info.plist only when the user
    /// explicitly associates folders. It is an identifier hint, not a signer.
    public let bundleIdentifier: String?
    public let relatedFolderPaths: [String]
    public let updatedAt: Date

    public init(
        bundlePath: String, bundleIdentifier: String? = nil,
        relatedFolderPaths: [String], updatedAt: Date = .now
    ) {
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        var uniquePaths: [String] = []
        var seen = Set<String>()
        for path in relatedFolderPaths where !path.isEmpty && seen.insert(path).inserted {
            uniquePaths.append(path)
        }
        self.relatedFolderPaths = Array(uniquePaths.suffix(Self.maximumRelatedFolderCount))
        self.updatedAt = updatedAt
    }

    public func adding(_ paths: [String], at date: Date = .now) -> ApplicationFolderAssociation? {
        let combinedPaths = relatedFolderPaths + paths
        guard Set(combinedPaths.filter { !$0.isEmpty }).count <= Self.maximumRelatedFolderCount else { return nil }
        return ApplicationFolderAssociation(
            bundlePath: bundlePath,
            bundleIdentifier: bundleIdentifier,
            relatedFolderPaths: combinedPaths,
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

public enum ApplicationFolderAssociationError: Error, LocalizedError {
    case tooManyRelatedFolders

    public var errorDescription: String? {
        "An app can have at most \(ApplicationFolderAssociation.maximumRelatedFolderCount) associated folders. Remove an existing link before adding more."
    }
}
