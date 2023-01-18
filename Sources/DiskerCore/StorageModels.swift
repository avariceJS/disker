import Foundation

public enum CapacityAvailabilityBasis: String, Codable, Sendable {
    case importantUsage
    case standardVolume
}

public struct CapacityObservation: Codable, Equatable, Sendable {
    public let observedAt: Date
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let availabilityBasis: CapacityAvailabilityBasis
    public let volumeName: String?
    public let volumeUUID: String?
    public let volumeIsLocal: Bool?

    public var notAvailableBytes: Int64 {
        max(0, totalBytes - availableBytes)
    }

    public init(
        observedAt: Date = .now, totalBytes: Int64, availableBytes: Int64,
        availabilityBasis: CapacityAvailabilityBasis = .importantUsage,
        volumeName: String? = nil, volumeUUID: String? = nil, volumeIsLocal: Bool? = nil
    ) {
        self.observedAt = observedAt
        self.totalBytes = max(0, totalBytes)
        self.availableBytes = min(max(0, availableBytes), max(0, totalBytes))
        self.availabilityBasis = availabilityBasis
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.volumeIsLocal = volumeIsLocal
    }

    public static func current(at url: URL = URL(fileURLWithPath: "/")) throws -> CapacityObservation {
        let values = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeIsLocalKey,
        ])
        guard let total = values.volumeTotalCapacity else {
            throw StorageReadError.capacityUnavailable
        }
        guard let availability = resolvedAvailableCapacity(
            importantUsage: values.volumeAvailableCapacityForImportantUsage,
            standard: values.volumeAvailableCapacity
        ) else {
            throw StorageReadError.capacityUnavailable
        }
        return CapacityObservation(
            totalBytes: Int64(total), availableBytes: availability.bytes,
            availabilityBasis: availability.basis,
            volumeName: values.volumeName,
            volumeUUID: values.volumeUUIDString,
            volumeIsLocal: values.volumeIsLocal
        )
    }

    public static func resolvedAvailableCapacity(
        importantUsage: Int64?, standard: Int?
    ) -> (bytes: Int64, basis: CapacityAvailabilityBasis)? {
        if let importantUsage, importantUsage > 0 {
            return (importantUsage, .importantUsage)
        }
        if let standard, standard >= 0 {
            return (Int64(standard), .standardVolume)
        }
        if importantUsage == 0 {
            return (0, .importantUsage)
        }
        return nil
    }
}

/// A bounded, metadata-only aggregate grouped by a file name's extension.
/// The extension does not verify the file's content or purpose.
public struct FileExtensionUsage: Codable, Equatable, Identifiable, Sendable {
    public let extensionName: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let fileCount: Int

    public var id: String { extensionName }

    public init(extensionName: String, logicalBytes: Int64, allocatedBytes: Int64, fileCount: Int) {
        self.extensionName = extensionName
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
    }
}

public struct FolderObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let displayName: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let fileCount: Int
    public let fileExtensionSummaries: [FileExtensionUsage]
    public let fileExtensionSummariesTruncated: Bool
    public let inaccessibleCount: Int
    public let excludedSymlinkCount: Int
    public let changedDuringScanCount: Int
    public let gitMetadataEntryDetected: Bool
    /// Metrics for a direct, real `.git` directory, retained even when it is
    /// outside the capped largest-subdirectory ranking. A `.git` file is only
    /// a marker and intentionally has no separately attributed footprint.
    public let gitMetadataUsage: DirectoryUsage?
    public let finishedAt: Date
    public let complete: Bool
    public let subdirectorySummaries: [DirectoryUsage]
    public let subdirectorySummariesTruncated: Bool
    /// Identifier read from the Info.plist of an explicitly selected app bundle.
    /// It is metadata evidence, not proof of signing identity or ownership.
    public let applicationBundleIdentifier: String?
    /// Embedded group-entitlement claims from the selected app. The separate
    /// validation fields indicate whether these claims passed local validation.
    public let applicationGroupIdentifiers: [String]
    public let applicationSignatureValidated: Bool
    public let applicationSignedBundleIdentifier: String?

    public init(
        id: UUID = UUID(), path: String, displayName: String,
        logicalBytes: Int64, allocatedBytes: Int64, fileCount: Int,
        fileExtensionSummaries: [FileExtensionUsage] = [],
        fileExtensionSummariesTruncated: Bool = false,
        inaccessibleCount: Int, finishedAt: Date = .now, complete: Bool,
        excludedSymlinkCount: Int = 0,
        changedDuringScanCount: Int = 0,
        gitMetadataEntryDetected: Bool = false,
        gitMetadataUsage: DirectoryUsage? = nil,
        subdirectorySummaries: [DirectoryUsage] = [],
        subdirectorySummariesTruncated: Bool = false,
        applicationBundleIdentifier: String? = nil,
        applicationGroupIdentifiers: [String] = [],
        applicationSignatureValidated: Bool = false,
        applicationSignedBundleIdentifier: String? = nil
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.fileExtensionSummaries = fileExtensionSummaries
        self.fileExtensionSummariesTruncated = fileExtensionSummariesTruncated
        self.inaccessibleCount = inaccessibleCount
        self.excludedSymlinkCount = excludedSymlinkCount
        self.changedDuringScanCount = changedDuringScanCount
        self.gitMetadataEntryDetected = gitMetadataEntryDetected
        self.gitMetadataUsage = gitMetadataUsage
        self.finishedAt = finishedAt
        self.complete = complete
        self.subdirectorySummaries = subdirectorySummaries
        self.subdirectorySummariesTruncated = subdirectorySummariesTruncated
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.applicationGroupIdentifiers = applicationGroupIdentifiers
        self.applicationSignatureValidated = applicationSignatureValidated
        self.applicationSignedBundleIdentifier = applicationSignedBundleIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, displayName, logicalBytes, allocatedBytes, fileCount
        case fileExtensionSummaries, fileExtensionSummariesTruncated
        case inaccessibleCount, excludedSymlinkCount, changedDuringScanCount, gitMetadataEntryDetected
        case finishedAt, complete
        case subdirectorySummaries, subdirectorySummariesTruncated, gitMetadataUsage
        case applicationBundleIdentifier
        case applicationGroupIdentifiers
        case applicationSignatureValidated, applicationSignedBundleIdentifier
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        path = try values.decode(String.self, forKey: .path)
        displayName = try values.decode(String.self, forKey: .displayName)
        logicalBytes = try values.decode(Int64.self, forKey: .logicalBytes)
        allocatedBytes = try values.decode(Int64.self, forKey: .allocatedBytes)
        fileCount = try values.decode(Int.self, forKey: .fileCount)
        fileExtensionSummaries = try values.decodeIfPresent([FileExtensionUsage].self, forKey: .fileExtensionSummaries) ?? []
        fileExtensionSummariesTruncated = try values.decodeIfPresent(Bool.self, forKey: .fileExtensionSummariesTruncated) ?? false
        inaccessibleCount = try values.decode(Int.self, forKey: .inaccessibleCount)
        excludedSymlinkCount = try values.decodeIfPresent(Int.self, forKey: .excludedSymlinkCount) ?? 0
        changedDuringScanCount = try values.decodeIfPresent(Int.self, forKey: .changedDuringScanCount) ?? 0
        gitMetadataEntryDetected = try values.decodeIfPresent(Bool.self, forKey: .gitMetadataEntryDetected) ?? false
        gitMetadataUsage = try values.decodeIfPresent(DirectoryUsage.self, forKey: .gitMetadataUsage)
        finishedAt = try values.decode(Date.self, forKey: .finishedAt)
        complete = try values.decode(Bool.self, forKey: .complete)
        subdirectorySummaries = try values.decodeIfPresent([DirectoryUsage].self, forKey: .subdirectorySummaries) ?? []
        subdirectorySummariesTruncated = try values.decodeIfPresent(Bool.self, forKey: .subdirectorySummariesTruncated) ?? false
        applicationBundleIdentifier = try values.decodeIfPresent(String.self, forKey: .applicationBundleIdentifier)
        applicationGroupIdentifiers = try values.decodeIfPresent([String].self, forKey: .applicationGroupIdentifiers) ?? []
        applicationSignatureValidated = try values.decodeIfPresent(Bool.self, forKey: .applicationSignatureValidated) ?? false
        applicationSignedBundleIdentifier = try values.decodeIfPresent(String.self, forKey: .applicationSignedBundleIdentifier)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(path, forKey: .path)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(logicalBytes, forKey: .logicalBytes)
        try values.encode(allocatedBytes, forKey: .allocatedBytes)
        try values.encode(fileCount, forKey: .fileCount)
        try values.encode(fileExtensionSummaries, forKey: .fileExtensionSummaries)
        try values.encode(fileExtensionSummariesTruncated, forKey: .fileExtensionSummariesTruncated)
        try values.encode(inaccessibleCount, forKey: .inaccessibleCount)
        try values.encode(excludedSymlinkCount, forKey: .excludedSymlinkCount)
        try values.encode(changedDuringScanCount, forKey: .changedDuringScanCount)
        try values.encode(gitMetadataEntryDetected, forKey: .gitMetadataEntryDetected)
        try values.encodeIfPresent(gitMetadataUsage, forKey: .gitMetadataUsage)
        try values.encode(finishedAt, forKey: .finishedAt)
        try values.encode(complete, forKey: .complete)
        try values.encode(subdirectorySummaries, forKey: .subdirectorySummaries)
        try values.encode(subdirectorySummariesTruncated, forKey: .subdirectorySummariesTruncated)
        try values.encodeIfPresent(applicationBundleIdentifier, forKey: .applicationBundleIdentifier)
        try values.encode(applicationGroupIdentifiers, forKey: .applicationGroupIdentifiers)
        try values.encode(applicationSignatureValidated, forKey: .applicationSignatureValidated)
        try values.encodeIfPresent(applicationSignedBundleIdentifier, forKey: .applicationSignedBundleIdentifier)
    }

    public func includingApplicationBundleIdentity(_ identity: ApplicationBundleIdentity) -> FolderObservation {
        FolderObservation(
            id: id, path: path, displayName: displayName,
            logicalBytes: logicalBytes, allocatedBytes: allocatedBytes,
            fileCount: fileCount, fileExtensionSummaries: fileExtensionSummaries,
            fileExtensionSummariesTruncated: fileExtensionSummariesTruncated,
            inaccessibleCount: inaccessibleCount,
            finishedAt: finishedAt, complete: complete,
            excludedSymlinkCount: excludedSymlinkCount,
            changedDuringScanCount: changedDuringScanCount,
            gitMetadataEntryDetected: gitMetadataEntryDetected,
            gitMetadataUsage: gitMetadataUsage,
            subdirectorySummaries: subdirectorySummaries,
            subdirectorySummariesTruncated: subdirectorySummariesTruncated,
            applicationBundleIdentifier: identity.bundleIdentifier,
            applicationGroupIdentifiers: identity.claimedGroupIdentifiers,
            applicationSignatureValidated: identity.signatureValidated,
            applicationSignedBundleIdentifier: identity.signedBundleIdentifier
        )
    }
}

/// A metadata-only aggregate for a directory below a selected scan root.
/// Hard-linked file objects are assigned to the lexicographically first relative
/// file path, so each object contributes to exactly one sibling subtree.
public struct DirectoryUsage: Codable, Equatable, Sendable {
    public let rootRelativePath: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let fileCount: Int
    public let incompleteCount: Int
    public let excludedSymlinkCount: Int
    public let changedDuringScanCount: Int
    public let gitMetadataEntryDetected: Bool
    public let complete: Bool

    public init(
        rootRelativePath: String, logicalBytes: Int64, allocatedBytes: Int64,
        fileCount: Int, incompleteCount: Int, excludedSymlinkCount: Int,
        changedDuringScanCount: Int = 0,
        gitMetadataEntryDetected: Bool = false,
        complete: Bool
    ) {
        self.rootRelativePath = rootRelativePath
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.incompleteCount = incompleteCount
        self.excludedSymlinkCount = excludedSymlinkCount
        self.changedDuringScanCount = changedDuringScanCount
        self.gitMetadataEntryDetected = gitMetadataEntryDetected
        self.complete = complete
    }

    private enum CodingKeys: String, CodingKey {
        case rootRelativePath, logicalBytes, allocatedBytes, fileCount
        case incompleteCount, excludedSymlinkCount, changedDuringScanCount, complete
        case gitMetadataEntryDetected
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rootRelativePath = try values.decode(String.self, forKey: .rootRelativePath)
        logicalBytes = try values.decode(Int64.self, forKey: .logicalBytes)
        allocatedBytes = try values.decode(Int64.self, forKey: .allocatedBytes)
        fileCount = try values.decode(Int.self, forKey: .fileCount)
        incompleteCount = try values.decode(Int.self, forKey: .incompleteCount)
        excludedSymlinkCount = try values.decode(Int.self, forKey: .excludedSymlinkCount)
        changedDuringScanCount = try values.decodeIfPresent(Int.self, forKey: .changedDuringScanCount) ?? 0
        gitMetadataEntryDetected = try values.decodeIfPresent(Bool.self, forKey: .gitMetadataEntryDetected) ?? false
        complete = try values.decode(Bool.self, forKey: .complete)
    }
}

public struct ScanObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let folders: [FolderObservation]
    public let cancelled: Bool

    public init(
        id: UUID = UUID(), startedAt: Date, finishedAt: Date = .now,
        folders: [FolderObservation], cancelled: Bool
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.folders = folders
        self.cancelled = cancelled
    }

    public func includingApplicationBundleIdentities(
        _ identitiesByPath: [String: ApplicationBundleIdentity]
    ) -> ScanObservation {
        guard !identitiesByPath.isEmpty else { return self }
        let identifiedFolders = folders.map { folder in
            guard let identity = identitiesByPath[folder.path] else { return folder }
            return folder.includingApplicationBundleIdentity(identity)
        }
        return ScanObservation(
            id: id, startedAt: startedAt, finishedAt: finishedAt,
            folders: identifiedFolders, cancelled: cancelled
        )
    }
}

public enum StorageReadError: Error, LocalizedError {
    case capacityUnavailable
    case historyLocationUnavailable

    public var errorDescription: String? {
        switch self {
        case .capacityUnavailable:
            return "macOS did not provide capacity values for this volume."
        case .historyLocationUnavailable:
            return "The local Application Support directory is unavailable."
        }
    }
}
