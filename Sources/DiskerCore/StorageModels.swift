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

    /// Conservative dashboard signal threshold: the larger of 10 GiB or 5%
    /// of the system-reported volume capacity. This does not attribute use.
    public var lowAvailableCapacityThreshold: Int64 {
        max(10 * 1_073_741_824, totalBytes / 20)
    }

    public var isLowOnAvailableCapacity: Bool {
        availableBytes < lowAvailableCapacityThreshold
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
    /// Device identifier from lstat on the selected root. It never follows a
    /// symlink and prevents history from crossing a different mounted volume
    /// at the same path while this identifier remains stable.
    public let volumeDeviceID: UInt64?
    public let displayName: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let fileCount: Int
    public let fileExtensionSummaries: [FileExtensionUsage]
    public let fileExtensionSummariesTruncated: Bool
    /// Combined bytes for filename categories beyond the retained cap. The
    /// aggregate is intentionally separate so history never compares it as if
    /// it were one stable extension category.
    public let otherFileExtensionUsage: FileExtensionUsage?
    public let otherFileExtensionCategoryCount: Int
    public let inaccessibleCount: Int
    public let excludedSymlinkCount: Int
    public let excludedSpecialFileCount: Int
    public let changedDuringScanCount: Int
    /// At least one logical or allocated-byte total exceeded Int64's range and was capped.
    public let byteAccountingOverflowed: Bool
    public let gitMetadataEntryDetected: Bool
    /// Metrics for a direct, real `.git` directory, retained even when it is
    /// outside the capped largest-subdirectory ranking. A `.git` file is only
    /// a marker and intentionally has no separately attributed footprint.
    public let gitMetadataUsage: DirectoryUsage?
    public let finishedAt: Date
    public let complete: Bool
    public let subdirectorySummaries: [DirectoryUsage]
    public let subdirectorySummariesTruncated: Bool
    /// Bounded summaries for nested directories with a direct non-symlink
    /// `.git` entry or an exact recognized development-data directory name,
    /// independent of the largest-folder cap.
    public let projectDirectorySummaries: [DirectoryUsage]
    public let projectDirectorySummariesTruncated: Bool
    /// Identifier read from the Info.plist of an explicitly selected app bundle.
    /// It is metadata evidence, not proof of signing identity or ownership.
    public let applicationBundleIdentifier: String?
    /// Embedded group-entitlement claims from the selected app. The separate
    /// validation fields indicate whether these claims passed local validation.
    public let applicationGroupIdentifiers: [String]
    public let applicationSignatureValidated: Bool
    public let applicationSignedBundleIdentifier: String?
    /// True only for a scan initiated through the application-bundle picker.
    public let selectedAsApplicationBundle: Bool

    public init(
        id: UUID = UUID(), path: String, volumeDeviceID: UInt64? = nil, displayName: String,
        logicalBytes: Int64, allocatedBytes: Int64, fileCount: Int,
        fileExtensionSummaries: [FileExtensionUsage] = [],
        fileExtensionSummariesTruncated: Bool = false,
        otherFileExtensionUsage: FileExtensionUsage? = nil,
        otherFileExtensionCategoryCount: Int = 0,
        inaccessibleCount: Int, finishedAt: Date = .now, complete: Bool,
        excludedSymlinkCount: Int = 0,
        excludedSpecialFileCount: Int = 0,
        changedDuringScanCount: Int = 0,
        byteAccountingOverflowed: Bool = false,
        gitMetadataEntryDetected: Bool = false,
        gitMetadataUsage: DirectoryUsage? = nil,
        subdirectorySummaries: [DirectoryUsage] = [],
        subdirectorySummariesTruncated: Bool = false,
        projectDirectorySummaries: [DirectoryUsage] = [],
        projectDirectorySummariesTruncated: Bool = false,
        applicationBundleIdentifier: String? = nil,
        applicationGroupIdentifiers: [String] = [],
        applicationSignatureValidated: Bool = false,
        applicationSignedBundleIdentifier: String? = nil,
        selectedAsApplicationBundle: Bool = false
    ) {
        self.id = id
        self.path = path
        self.volumeDeviceID = volumeDeviceID
        self.displayName = displayName
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.fileExtensionSummaries = fileExtensionSummaries
        self.fileExtensionSummariesTruncated = fileExtensionSummariesTruncated
        self.otherFileExtensionUsage = otherFileExtensionUsage
        self.otherFileExtensionCategoryCount = otherFileExtensionCategoryCount
        self.inaccessibleCount = inaccessibleCount
        self.excludedSymlinkCount = excludedSymlinkCount
        self.excludedSpecialFileCount = excludedSpecialFileCount
        self.changedDuringScanCount = changedDuringScanCount
        self.byteAccountingOverflowed = byteAccountingOverflowed
        self.gitMetadataEntryDetected = gitMetadataEntryDetected
        self.gitMetadataUsage = gitMetadataUsage
        self.finishedAt = finishedAt
        self.complete = complete
        self.subdirectorySummaries = subdirectorySummaries
        self.subdirectorySummariesTruncated = subdirectorySummariesTruncated
        self.projectDirectorySummaries = projectDirectorySummaries
        self.projectDirectorySummariesTruncated = projectDirectorySummariesTruncated
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.applicationGroupIdentifiers = applicationGroupIdentifiers
        self.applicationSignatureValidated = applicationSignatureValidated
        self.applicationSignedBundleIdentifier = applicationSignedBundleIdentifier
        self.selectedAsApplicationBundle = selectedAsApplicationBundle
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, volumeDeviceID, displayName, logicalBytes, allocatedBytes, fileCount
        case fileExtensionSummaries, fileExtensionSummariesTruncated
        case otherFileExtensionUsage, otherFileExtensionCategoryCount
        case inaccessibleCount, excludedSymlinkCount, excludedSpecialFileCount
        case changedDuringScanCount, byteAccountingOverflowed, gitMetadataEntryDetected
        case finishedAt, complete
        case subdirectorySummaries, subdirectorySummariesTruncated, gitMetadataUsage
        case projectDirectorySummaries, projectDirectorySummariesTruncated
        case applicationBundleIdentifier
        case applicationGroupIdentifiers
        case applicationSignatureValidated, applicationSignedBundleIdentifier
        case selectedAsApplicationBundle
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        path = try values.decode(String.self, forKey: .path)
        volumeDeviceID = try values.decodeIfPresent(UInt64.self, forKey: .volumeDeviceID)
        displayName = try values.decode(String.self, forKey: .displayName)
        logicalBytes = try values.decode(Int64.self, forKey: .logicalBytes)
        allocatedBytes = try values.decode(Int64.self, forKey: .allocatedBytes)
        fileCount = try values.decode(Int.self, forKey: .fileCount)
        fileExtensionSummaries = try values.decodeIfPresent([FileExtensionUsage].self, forKey: .fileExtensionSummaries) ?? []
        fileExtensionSummariesTruncated = try values.decodeIfPresent(Bool.self, forKey: .fileExtensionSummariesTruncated) ?? false
        otherFileExtensionUsage = try values.decodeIfPresent(FileExtensionUsage.self, forKey: .otherFileExtensionUsage)
        otherFileExtensionCategoryCount = try values.decodeIfPresent(Int.self, forKey: .otherFileExtensionCategoryCount) ?? 0
        inaccessibleCount = try values.decode(Int.self, forKey: .inaccessibleCount)
        excludedSymlinkCount = try values.decodeIfPresent(Int.self, forKey: .excludedSymlinkCount) ?? 0
        excludedSpecialFileCount = try values.decodeIfPresent(Int.self, forKey: .excludedSpecialFileCount) ?? 0
        changedDuringScanCount = try values.decodeIfPresent(Int.self, forKey: .changedDuringScanCount) ?? 0
        byteAccountingOverflowed = try values.decodeIfPresent(Bool.self, forKey: .byteAccountingOverflowed) ?? false
        gitMetadataEntryDetected = try values.decodeIfPresent(Bool.self, forKey: .gitMetadataEntryDetected) ?? false
        gitMetadataUsage = try values.decodeIfPresent(DirectoryUsage.self, forKey: .gitMetadataUsage)
        finishedAt = try values.decode(Date.self, forKey: .finishedAt)
        complete = try values.decode(Bool.self, forKey: .complete)
        subdirectorySummaries = try values.decodeIfPresent([DirectoryUsage].self, forKey: .subdirectorySummaries) ?? []
        subdirectorySummariesTruncated = try values.decodeIfPresent(Bool.self, forKey: .subdirectorySummariesTruncated) ?? false
        projectDirectorySummaries = try values.decodeIfPresent([DirectoryUsage].self, forKey: .projectDirectorySummaries) ?? []
        projectDirectorySummariesTruncated = try values.decodeIfPresent(Bool.self, forKey: .projectDirectorySummariesTruncated) ?? false
        applicationBundleIdentifier = try values.decodeIfPresent(String.self, forKey: .applicationBundleIdentifier)
        applicationGroupIdentifiers = try values.decodeIfPresent([String].self, forKey: .applicationGroupIdentifiers) ?? []
        applicationSignatureValidated = try values.decodeIfPresent(Bool.self, forKey: .applicationSignatureValidated) ?? false
        applicationSignedBundleIdentifier = try values.decodeIfPresent(String.self, forKey: .applicationSignedBundleIdentifier)
        selectedAsApplicationBundle = try values.decodeIfPresent(Bool.self, forKey: .selectedAsApplicationBundle)
            ?? (applicationBundleIdentifier != nil && URL(fileURLWithPath: path).pathExtension.lowercased() == "app")
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(path, forKey: .path)
        try values.encodeIfPresent(volumeDeviceID, forKey: .volumeDeviceID)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(logicalBytes, forKey: .logicalBytes)
        try values.encode(allocatedBytes, forKey: .allocatedBytes)
        try values.encode(fileCount, forKey: .fileCount)
        try values.encode(fileExtensionSummaries, forKey: .fileExtensionSummaries)
        try values.encode(fileExtensionSummariesTruncated, forKey: .fileExtensionSummariesTruncated)
        try values.encodeIfPresent(otherFileExtensionUsage, forKey: .otherFileExtensionUsage)
        try values.encode(otherFileExtensionCategoryCount, forKey: .otherFileExtensionCategoryCount)
        try values.encode(inaccessibleCount, forKey: .inaccessibleCount)
        try values.encode(excludedSymlinkCount, forKey: .excludedSymlinkCount)
        try values.encode(excludedSpecialFileCount, forKey: .excludedSpecialFileCount)
        try values.encode(changedDuringScanCount, forKey: .changedDuringScanCount)
        try values.encode(byteAccountingOverflowed, forKey: .byteAccountingOverflowed)
        try values.encode(gitMetadataEntryDetected, forKey: .gitMetadataEntryDetected)
        try values.encodeIfPresent(gitMetadataUsage, forKey: .gitMetadataUsage)
        try values.encode(finishedAt, forKey: .finishedAt)
        try values.encode(complete, forKey: .complete)
        try values.encode(subdirectorySummaries, forKey: .subdirectorySummaries)
        try values.encode(subdirectorySummariesTruncated, forKey: .subdirectorySummariesTruncated)
        try values.encode(projectDirectorySummaries, forKey: .projectDirectorySummaries)
        try values.encode(projectDirectorySummariesTruncated, forKey: .projectDirectorySummariesTruncated)
        try values.encodeIfPresent(applicationBundleIdentifier, forKey: .applicationBundleIdentifier)
        try values.encode(applicationGroupIdentifiers, forKey: .applicationGroupIdentifiers)
        try values.encode(applicationSignatureValidated, forKey: .applicationSignatureValidated)
        try values.encodeIfPresent(applicationSignedBundleIdentifier, forKey: .applicationSignedBundleIdentifier)
        try values.encode(selectedAsApplicationBundle, forKey: .selectedAsApplicationBundle)
    }

    public func includingApplicationBundleIdentity(
        _ identity: ApplicationBundleIdentity?, selectedAsApplicationBundle: Bool
    ) -> FolderObservation {
        FolderObservation(
            id: id, path: path, volumeDeviceID: volumeDeviceID, displayName: displayName,
            logicalBytes: logicalBytes, allocatedBytes: allocatedBytes,
            fileCount: fileCount, fileExtensionSummaries: fileExtensionSummaries,
            fileExtensionSummariesTruncated: fileExtensionSummariesTruncated,
            otherFileExtensionUsage: otherFileExtensionUsage,
            otherFileExtensionCategoryCount: otherFileExtensionCategoryCount,
            inaccessibleCount: inaccessibleCount,
            finishedAt: finishedAt, complete: complete,
            excludedSymlinkCount: excludedSymlinkCount,
            excludedSpecialFileCount: excludedSpecialFileCount,
            changedDuringScanCount: changedDuringScanCount,
            gitMetadataEntryDetected: gitMetadataEntryDetected,
            gitMetadataUsage: gitMetadataUsage,
            subdirectorySummaries: subdirectorySummaries,
            subdirectorySummariesTruncated: subdirectorySummariesTruncated,
            projectDirectorySummaries: projectDirectorySummaries,
            projectDirectorySummariesTruncated: projectDirectorySummariesTruncated,
            applicationBundleIdentifier: identity?.bundleIdentifier,
            applicationGroupIdentifiers: identity?.claimedGroupIdentifiers ?? [],
            applicationSignatureValidated: identity?.signatureValidated ?? false,
            applicationSignedBundleIdentifier: identity?.signedBundleIdentifier,
            selectedAsApplicationBundle: selectedAsApplicationBundle
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
    public let excludedSpecialFileCount: Int
    public let changedDuringScanCount: Int
    public let gitMetadataEntryDetected: Bool
    public let complete: Bool

    public init(
        rootRelativePath: String, logicalBytes: Int64, allocatedBytes: Int64,
        fileCount: Int, incompleteCount: Int, excludedSymlinkCount: Int,
        excludedSpecialFileCount: Int = 0,
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
        self.excludedSpecialFileCount = excludedSpecialFileCount
        self.changedDuringScanCount = changedDuringScanCount
        self.gitMetadataEntryDetected = gitMetadataEntryDetected
        self.complete = complete
    }

    private enum CodingKeys: String, CodingKey {
        case rootRelativePath, logicalBytes, allocatedBytes, fileCount
        case incompleteCount, excludedSymlinkCount, excludedSpecialFileCount
        case changedDuringScanCount, complete
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
        excludedSpecialFileCount = try values.decodeIfPresent(Int.self, forKey: .excludedSpecialFileCount) ?? 0
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
        _ identitiesByPath: [String: ApplicationBundleIdentity],
        selectedApplicationBundlePaths: Set<String> = []
    ) -> ScanObservation {
        guard !identitiesByPath.isEmpty || !selectedApplicationBundlePaths.isEmpty else { return self }
        let identifiedFolders = folders.map { folder in
            let selected = selectedApplicationBundlePaths.contains(folder.path)
                || identitiesByPath[folder.path] != nil
            guard selected else { return folder }
            return folder.includingApplicationBundleIdentity(
                identitiesByPath[folder.path], selectedAsApplicationBundle: true
            )
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
