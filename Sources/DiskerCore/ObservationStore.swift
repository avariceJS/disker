import Foundation

public struct LocalHistory: Codable, Sendable {
    public var observations: [ScanObservation]

    public init(observations: [ScanObservation] = []) {
        self.observations = observations
    }
}

public enum ObservationStore {
    private static let fileName = "observations.json"

    public static func load(from fileURL: URL? = nil) throws -> LocalHistory {
        guard let url = fileURL ?? historyURL() else { throw StorageReadError.historyLocationUnavailable }
        guard FileManager.default.fileExists(atPath: url.path) else { return LocalHistory() }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(LocalHistory.self, from: data)
        } catch {
            throw HistoryDecodeError.invalidHistory(error.localizedDescription)
        }
    }

    @discardableResult
    public static func append(_ observation: ScanObservation, to fileURL: URL? = nil) throws -> LocalHistory {
        var history = try load(from: fileURL)
        history.observations.append(observation)
        history.observations = Array(history.observations.suffix(180))
        guard let url = fileURL ?? historyURL() else { throw StorageReadError.historyLocationUnavailable }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(history)
        try data.write(to: url, options: .atomic)
        return history
    }

    public static func clear(at fileURL: URL? = nil) throws {
        guard let url = fileURL ?? historyURL() else { throw StorageReadError.historyLocationUnavailable }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
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
