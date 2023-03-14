import Foundation
import Security

/// A user-selected location that Disker scans without modifying its contents.
/// Sandboxed builds retain access with a security-scoped bookmark; the standard
/// unsandboxed build stores an ordinary path bookmark. Neither is uploaded.
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
    case bookmarkPathChanged(expected: String, resolved: String)

    public var errorDescription: String? {
        switch self {
        case .tooManyBookmarks:
            return "Disker can remember up to 20 selected folders. Remove a saved folder before adding another."
        case .bookmarkUnavailable(let reason):
            return "Disker could not restore access to this selected folder. Choose it again to grant access. \(reason)"
        case .bookmarkPathChanged(let expected, let resolved):
            return "This saved folder now resolves to a different location (\(resolved)) than the selected path (\(expected)). Choose the intended folder again to update it."
        }
    }
}

/// Stores a bounded set of explicitly selected locations for Disker's read-only
/// scans. It does not schedule scans or perform work when the app launches.
public enum SelectedScopeBookmarkStore {
    public static let maximumBookmarkCount = 20
    private static let fileName = "selected-scopes.json"
    private static let maximumBookmarkFileSize = 8 * 1024 * 1024

    /// A recovery picker may replace access only for the exact path the user
    /// originally selected. Standardization removes lexical `.`/`..` parts;
    /// it does not resolve symlinks or retarget a saved history entry.
    public static func isSameSelectedPath(_ selectedURL: URL, as expectedPath: String) -> Bool {
        selectedURL.standardizedFileURL.path
            == URL(fileURLWithPath: expectedPath, isDirectory: true).standardizedFileURL.path
    }

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
                    options: try creationOptionsForCurrentProcess(),
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
        try resolve(
            bookmark,
            at: fileURL,
            resolvingBookmarkData: { data in
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: try resolutionOptionsForCurrentProcess(),
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                return (url: url, isStale: stale)
            },
            creatingBookmarkData: { url in
                try url.bookmarkData(
                    options: try creationOptionsForCurrentProcess(),
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
        )
    }

    /// Injectable URL operations allow deterministic tests of stale-bookmark
    /// refresh and path-mismatch handling without modifying real folder state.
    @_spi(DiskerTesting)
    public static func resolve(
        _ bookmark: SelectedScopeBookmark,
        at fileURL: URL? = nil,
        resolvingBookmarkData: (Data) throws -> (url: URL, isStale: Bool),
        creatingBookmarkData: (URL) throws -> Data
    ) throws -> URL {
        do {
            let resolution = try resolvingBookmarkData(bookmark.bookmarkData)
            let url = resolution.url
            let resolvedPath = url.standardizedFileURL.path
            let expectedPath = URL(fileURLWithPath: bookmark.path, isDirectory: true)
                .standardizedFileURL.path
            guard resolvedPath == expectedPath else {
                throw SelectedScopeBookmarkError.bookmarkPathChanged(
                    expected: bookmark.path, resolved: resolvedPath
                )
            }
            guard resolution.isStale else { return url }

            var bookmarks = try load(from: fileURL)
            let existingIndex = bookmarks.firstIndex(where: { $0.path == bookmark.path })
            if existingIndex == nil && bookmarks.count >= maximumBookmarkCount {
                throw SelectedScopeBookmarkError.tooManyBookmarks
            }
            let refreshed = try creatingBookmarkData(url)
            let refreshedBookmark = SelectedScopeBookmark(
                path: resolvedPath, bookmarkData: refreshed
            )
            if let index = existingIndex {
                bookmarks[index] = refreshedBookmark
            } else {
                bookmarks.append(refreshedBookmark)
            }
            try save(bookmarks, at: fileURL)
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
        try LocalStoreFile.remove(at: url)
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

    /// Ordinary, unsandboxed apps cannot use `.withSecurityScope`; their
    /// selected folder remains available through normal process file access.
    /// Sandboxed builds need scoped bookmark capabilities to retain picker
    /// grants across launches.
    private static func creationOptionsForCurrentProcess() throws -> URL.BookmarkCreationOptions {
        creationOptions(isSandboxed: try isCurrentProcessSandboxed())
    }

    public static func requiresSecurityScopedAccess() throws -> Bool {
        try isCurrentProcessSandboxed()
    }

    static func resolutionOptionsForCurrentProcess() throws -> URL.BookmarkResolutionOptions {
        resolutionOptions(isSandboxed: try isCurrentProcessSandboxed())
    }

    static func isCurrentProcessSandboxed() throws -> Bool {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else {
            throw SelectedScopeBookmarkError.bookmarkUnavailable(
                "Disker could not determine whether this build uses App Sandbox."
            )
        }
        var queryError: Unmanaged<CFError>?
        guard let entitlement = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.app-sandbox" as CFString,
            &queryError
        ) else {
            if let queryError {
                throw SelectedScopeBookmarkError.bookmarkUnavailable(
                    "Disker could not inspect its App Sandbox entitlement: \(queryError.takeRetainedValue().localizedDescription)"
                )
            }
            // An absent entitlement is the normal result for the standard
            // unsandboxed build. A query failure above remains fail-closed.
            return false
        }
        guard CFGetTypeID(entitlement) == CFBooleanGetTypeID() else {
            throw SelectedScopeBookmarkError.bookmarkUnavailable(
                "Disker received an invalid App Sandbox entitlement value."
            )
        }
        return CFBooleanGetValue(unsafeBitCast(entitlement, to: CFBoolean.self))
    }

    @_spi(DiskerTesting)
    public static func creationOptions(isSandboxed: Bool) -> URL.BookmarkCreationOptions {
        isSandboxed ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : []
    }

    @_spi(DiskerTesting)
    public static func resolutionOptions(isSandboxed: Bool) -> URL.BookmarkResolutionOptions {
        isSandboxed ? [.withSecurityScope] : []
    }
}
