import Foundation

/// Persists only explicit per-root monitoring consent. It stores no bookmark
/// data and never resolves selected paths; callers still require a saved scope
/// and an open Disker window before starting scans.
public enum StorageMonitoringPreferences {
    public static let maximumRootCount = 20
    private static let fileName = "storage-monitoring.json"
    private static let maximumFileSize = 16 * 1024

    public static func load(from fileURL: URL? = nil) throws -> Set<String> {
        guard let url = fileURL ?? storageURL() else { return [] }
        guard let data = try LocalStoreFile.read(at: url, maximumBytes: maximumFileSize) else { return [] }
        let paths = try JSONDecoder().decode([String].self, from: data)
        let normalized = try normalize(paths)
        return Set(normalized)
    }

    public static func save(_ paths: Set<String>, at fileURL: URL? = nil) throws {
        guard let url = fileURL ?? storageURL() else { return }
        let normalized = try normalize(Array(paths))
        try LocalStoreFile.ensurePrivateDirectory(at: url.deletingLastPathComponent())
        let data = try JSONEncoder().encode(normalized)
        guard data.count <= maximumFileSize else { throw LocalStoreFileError.exceedsSizeLimit }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func clear(at fileURL: URL? = nil) throws {
        guard let url = fileURL ?? storageURL() else { return }
        try LocalStoreFile.remove(at: url)
    }

    private static func normalize(_ paths: [String]) throws -> [String] {
        guard paths.count <= maximumRootCount else { throw PreferenceError.tooManyRoots }
        var unique = Set<String>()
        for path in paths {
            guard path.hasPrefix("/"),
                  URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path == path,
                  unique.insert(path).inserted
            else { throw PreferenceError.invalidRoot }
        }
        return unique.sorted()
    }

    private static func storageURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Disker", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private enum PreferenceError: Error, LocalizedError {
        case tooManyRoots
        case invalidRoot

        var errorDescription: String? {
            switch self {
            case .tooManyRoots:
                return "Disker can remember monitoring for at most 20 selected folders."
            case .invalidRoot:
                return "A saved monitoring location is invalid or duplicated. No preference was changed."
            }
        }
    }
}
