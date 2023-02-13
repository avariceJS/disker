import Foundation

public struct LocalHistory: Codable, Sendable {
    public var observations: [ScanObservation]
    public var ramObservations: [RAMObservation]
    public var memoryPressureObservations: [MemoryPressureObservation]
    public var capacityObservations: [CapacityObservation]
    public var applicationAssociations: [ApplicationFolderAssociation]

    public init(
        observations: [ScanObservation] = [], ramObservations: [RAMObservation] = [],
        memoryPressureObservations: [MemoryPressureObservation] = [],
        capacityObservations: [CapacityObservation] = [],
        applicationAssociations: [ApplicationFolderAssociation] = []
    ) {
        self.observations = observations
        self.ramObservations = ramObservations
        self.memoryPressureObservations = memoryPressureObservations
        self.capacityObservations = capacityObservations
        self.applicationAssociations = applicationAssociations
    }

    private enum CodingKeys: String, CodingKey {
        case observations, ramObservations, memoryPressureObservations
        case capacityObservations, applicationAssociations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        observations = try values.decodeIfPresent([ScanObservation].self, forKey: .observations) ?? []
        ramObservations = try values.decodeIfPresent([RAMObservation].self, forKey: .ramObservations) ?? []
        memoryPressureObservations = try values.decodeIfPresent(
            [MemoryPressureObservation].self, forKey: .memoryPressureObservations
        ) ?? []
        capacityObservations = try values.decodeIfPresent([CapacityObservation].self, forKey: .capacityObservations) ?? []
        applicationAssociations = try values.decodeIfPresent([ApplicationFolderAssociation].self, forKey: .applicationAssociations) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(observations, forKey: .observations)
        try values.encode(ramObservations, forKey: .ramObservations)
        try values.encode(memoryPressureObservations, forKey: .memoryPressureObservations)
        try values.encode(capacityObservations, forKey: .capacityObservations)
        try values.encode(applicationAssociations, forKey: .applicationAssociations)
    }
}

public enum ObservationStore {
    private static let fileName = "observations.json"
    private static let maximumObservationCount = 180
    private static let maximumHistoryFileSize = 256 * 1024 * 1024

    public static func load(from fileURL: URL? = nil) throws -> LocalHistory {
        guard let url = fileURL ?? historyURL() else { throw StorageReadError.historyLocationUnavailable }
        guard let data = try LocalStoreFile.read(at: url, maximumBytes: maximumHistoryFileSize) else {
            return LocalHistory()
        }
        do {
            var history = try JSONDecoder().decode(LocalHistory.self, from: data)
            history.observations = Array(history.observations.suffix(maximumObservationCount))
            history.ramObservations = Array(history.ramObservations.suffix(maximumObservationCount))
            history.memoryPressureObservations = Array(
                history.memoryPressureObservations.suffix(maximumObservationCount)
            )
            history.capacityObservations = Array(history.capacityObservations.suffix(maximumObservationCount))
            history.applicationAssociations = Array(
                history.applicationAssociations.suffix(maximumObservationCount)
            )
            return history
        } catch {
            throw HistoryDecodeError.invalidHistory(error.localizedDescription)
        }
    }

    @discardableResult
    public static func append(_ observation: ScanObservation, to fileURL: URL? = nil) throws -> LocalHistory {
        var history = try load(from: fileURL)
        history.observations.append(observation)
        history.observations = Array(history.observations.suffix(maximumObservationCount))
        try save(history, fileURL: fileURL)
        return history
    }

    @discardableResult
    public static func append(_ observation: RAMObservation, to fileURL: URL? = nil) throws -> LocalHistory {
        var history = try load(from: fileURL)
        history.ramObservations.append(observation)
        history.ramObservations = Array(history.ramObservations.suffix(maximumObservationCount))
        try save(history, fileURL: fileURL)
        return history
    }

    @discardableResult
    public static func append(_ observation: MemoryPressureObservation, to fileURL: URL? = nil) throws -> LocalHistory {
        var history = try load(from: fileURL)
        history.memoryPressureObservations.append(observation)
        history.memoryPressureObservations = Array(
            history.memoryPressureObservations.suffix(maximumObservationCount)
        )
        try save(history, fileURL: fileURL)
        return history
    }

    @discardableResult
    public static func append(_ observation: CapacityObservation, to fileURL: URL? = nil) throws -> LocalHistory {
        var history = try load(from: fileURL)
        history.capacityObservations.append(observation)
        history.capacityObservations = Array(history.capacityObservations.suffix(maximumObservationCount))
        try save(history, fileURL: fileURL)
        return history
    }

    @discardableResult
    public static func associateApplicationFolders(
        _ paths: [String], with bundlePath: String,
        bundleIdentifier: String? = nil, to fileURL: URL? = nil
    ) throws -> LocalHistory {
        var history = try load(from: fileURL)
        guard !paths.isEmpty else { return history }
        if let index = history.applicationAssociations.firstIndex(where: { $0.bundlePath == bundlePath }) {
            let current = history.applicationAssociations[index]
            guard let updated = current.adding(paths) else {
                throw ApplicationFolderAssociationError.tooManyRelatedFolders
            }
            history.applicationAssociations[index] = ApplicationFolderAssociation(
                bundlePath: updated.bundlePath,
                bundleIdentifier: bundleIdentifier ?? current.bundleIdentifier,
                relatedFolderPaths: updated.relatedFolderPaths,
                updatedAt: updated.updatedAt
            )
        } else {
            guard Set(paths.filter { !$0.isEmpty }).count <= ApplicationFolderAssociation.maximumRelatedFolderCount else {
                throw ApplicationFolderAssociationError.tooManyRelatedFolders
            }
            history.applicationAssociations.append(ApplicationFolderAssociation(
                bundlePath: bundlePath,
                bundleIdentifier: bundleIdentifier,
                relatedFolderPaths: paths
            ))
        }
        history.applicationAssociations = Array(history.applicationAssociations.suffix(maximumObservationCount))
        try save(history, fileURL: fileURL)
        return history
    }

    @discardableResult
    public static func removeApplicationFolderAssociation(
        _ path: String, from bundlePath: String, at fileURL: URL? = nil
    ) throws -> LocalHistory {
        var history = try load(from: fileURL)
        guard let index = history.applicationAssociations.firstIndex(where: { $0.bundlePath == bundlePath }) else {
            return history
        }
        if let remaining = history.applicationAssociations[index].removing(path) {
            history.applicationAssociations[index] = remaining
        } else {
            history.applicationAssociations.remove(at: index)
        }
        try save(history, fileURL: fileURL)
        return history
    }

    private static func save(_ history: LocalHistory, fileURL: URL?) throws {
        guard let url = fileURL ?? historyURL() else { throw StorageReadError.historyLocationUnavailable }
        let directoryURL = url.deletingLastPathComponent()
        try LocalStoreFile.ensurePrivateDirectory(at: directoryURL)
        let data = try JSONEncoder().encode(history)
        guard data.count <= maximumHistoryFileSize else {
            throw LocalStoreFileError.exceedsSizeLimit
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func clear(at fileURL: URL? = nil) throws {
        guard let url = fileURL ?? historyURL() else { throw StorageReadError.historyLocationUnavailable }
        try LocalStoreFile.remove(at: url)
    }

    private static func historyURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Disker", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

public enum HistoryDecodeError: Error, LocalizedError {
    case invalidHistory(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHistory(let reason):
            return "Saved Disker history could not be read and was left untouched. \(reason)"
        }
    }
}
