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

    public var notAvailableBytes: Int64 {
        max(0, totalBytes - availableBytes)
    }

    public init(
        observedAt: Date = .now, totalBytes: Int64, availableBytes: Int64,
        availabilityBasis: CapacityAvailabilityBasis = .importantUsage
    ) {
        self.observedAt = observedAt
        self.totalBytes = max(0, totalBytes)
        self.availableBytes = min(max(0, availableBytes), max(0, totalBytes))
        self.availabilityBasis = availabilityBasis
    }

    public static func current(at url: URL = URL(fileURLWithPath: "/")) throws -> CapacityObservation {
        let values = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
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
            availabilityBasis: availability.basis
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

public struct FolderObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let displayName: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let fileCount: Int
    public let inaccessibleCount: Int
    public let finishedAt: Date
    public let complete: Bool

    public init(
        id: UUID = UUID(), path: String, displayName: String,
        logicalBytes: Int64, allocatedBytes: Int64, fileCount: Int,
        inaccessibleCount: Int, finishedAt: Date = .now, complete: Bool
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.inaccessibleCount = inaccessibleCount
        self.finishedAt = finishedAt
        self.complete = complete
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
