import Foundation

/// A user-approved, read-only location that can be scanned again on demand.
/// The bookmark is a capability; it is stored locally and never uploaded.
public struct SelectedScopeBookmark: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let bookmarkData: Data
    public let savedAt: Date

    public var id: String { path }

    public init(path: String, bookmarkData: Data, savedAt: Date = .now) {
        self.path = path
        self.bookmarkData = bookmarkData
        self.savedAt = savedAt
    }
}

public enum SelectedScopeBookmarkError: Error, LocalizedError {
    case tooManyBookmarks
    case bookmarkUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .tooManyBookmarks:
            return "Disker can remember up to 20 selected folders. Remove a saved folder before adding another."
        case .bookmarkUnavailable(let reason):
            return "Disker could not restore access to this selected folder. Choose it again to grant access. \(reason)"
        }
    }
}

/// Stores a bounded set of explicit, read-only scopes for user-triggered scans.
/// It does not schedule scans or perform work when the app launches.
public enum SelectedScopeBookmarkStore {
    public static let maximumBookmarkCount = 20
    private static let fileName = "selected-scopes.json"
    private static let maximumBookmarkFileSize = 8 * 1024 * 1024

    public static func load(from fileURL: URL? = nil) throws -> [SelectedScopeBookmark] {
        guard let url = fileURL ?? storageURL() else { return [] }
        guard let data = try LocalStoreFile.read(at: url, maximumBytes: maximumBookmarkFileSize) else { return [] }
        let bookmarks = try JSONDecoder().decode([SelectedScopeBookmark].self, from: data)
        let bounded = Array(bookmarks.sorted {
            if $0.savedAt == $1.savedAt { return $0.path < $1.path }
            return $0.savedAt < $1.savedAt
        }.suffix(maximumBookmarkCount))
        return bounded.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    @discardableResult
    public static func remember(_ urls: [URL], at fileURL: URL? = nil) throws -> [SelectedScopeBookmark] {
        var bookmarks = try load(from: fileURL)
        var updates: [String: SelectedScopeBookmark] = [:]
        for url in urls {
            let data: Data
            do {
                data = try url.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                throw SelectedScopeBookmarkError.bookmarkUnavailable(error.localizedDescription)
            }
            updates[url.standardizedFileURL.path] = SelectedScopeBookmark(
                path: url.standardizedFileURL.path,
                bookmarkData: data
            )
        }

        for bookmark in updates.values {
            if let index = bookmarks.firstIndex(where: { $0.path == bookmark.path }) {
                bookmarks[index] = bookmark
            } else {
                guard bookmarks.count < maximumBookmarkCount else {
                    throw SelectedScopeBookmarkError.tooManyBookmarks
                }
                bookmarks.append(bookmark)
            }
        }
        try save(bookmarks, at: fileURL)
        return bookmarks.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Resolves a previously approved location. A refreshed stale bookmark is
    /// persisted before the URL is returned for the caller's explicit action.
    public static func resolve(_ bookmark: SelectedScopeBookmark, at fileURL: URL? = nil) throws -> URL {
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard !stale else {
                var bookmarks = try load(from: fileURL).filter { $0.path != bookmark.path }
                let refreshed = try url.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                bookmarks.append(SelectedScopeBookmark(
                    path: url.standardizedFileURL.path,
                    bookmarkData: refreshed
                ))
                try save(bookmarks, at: fileURL)
                return url
            }
            return url
        } catch let error as SelectedScopeBookmarkError {
            throw error
        } catch {
            throw SelectedScopeBookmarkError.bookmarkUnavailable(error.localizedDescription)
        }
    }

    @discardableResult
    public static func remove(path: String, at fileURL: URL? = nil) throws -> [SelectedScopeBookmark] {
        let remaining = try load(from: fileURL).filter { $0.path != path }
        try save(remaining, at: fileURL)
        return remaining
    }

    public static func clear(at fileURL: URL? = nil) throws {
        guard let url = fileURL ?? storageURL() else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func save(_ bookmarks: [SelectedScopeBookmark], at fileURL: URL?) throws {
        guard let url = fileURL ?? storageURL() else { return }
        try LocalStoreFile.ensurePrivateDirectory(at: url.deletingLastPathComponent())
        let data = try JSONEncoder().encode(bookmarks)
        guard data.count <= maximumBookmarkFileSize else {
            throw LocalStoreFileError.exceedsSizeLimit
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func storageURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Disker", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
