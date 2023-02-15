import Foundation

/// A filename-only clue for a selected file extension. This does not inspect
/// file contents, establish ownership, or imply that an item is disposable.
public enum FileArtifactHint: String, CaseIterable, Sendable {
    case database
    case log
    case archiveOrInstaller
    case modelOrCheckpoint
    case structuredData

    public var title: String {
        switch self {
        case .database: "Database or SQLite sidecar · filename match"
        case .log: "Log file · filename match"
        case .archiveOrInstaller: "Archive or installer · filename match"
        case .modelOrCheckpoint: "Model or checkpoint · filename match"
        case .structuredData: "Structured data · filename match"
        }
    }

    public static func matching(extensionName: String) -> FileArtifactHint? {
        switch extensionName.lowercased() {
        case "db", "sqlite", "sqlite3", "sqlite-wal", "sqlite-shm": .database
        case "log": .log
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "dmg", "pkg": .archiveOrInstaller
        case "gguf", "safetensors", "onnx", "pt", "pth", "ckpt", "model": .modelOrCheckpoint
        case "parquet", "arrow", "csv", "jsonl", "ndjson": .structuredData
        default: nil
        }
    }
}
