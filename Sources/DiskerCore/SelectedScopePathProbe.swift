import Darwin
import Foundation

/// Checks one already selected directory path without opening or traversing it.
/// If a bookmark is supplied, it must still resolve to the exact recorded path.
public enum SelectedScopePathProbe {
    public enum Status: Equatable, Sendable {
        case availableDirectory
        case missingOrUnreachable
        case permissionOrAccessUnknown
        case notDirectory
        case symbolicLink
        case invalidBookmark
        case staleBookmark
        case mismatchedBookmark(expectedPath: String, actualPath: String)
    }

    /// Reports metadata availability for one exact user-selected path. It does
    /// not enumerate descendants, read file contents, or refresh bookmarks.
    /// `lstat` ensures the selected final path is not followed when it is a symlink.
    public static func probe(
        at path: String,
        using bookmark: SelectedScopeBookmark? = nil
    ) -> Status {
        let requestedURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let url: URL
        if let bookmark {
            let recordedPath = URL(fileURLWithPath: bookmark.path, isDirectory: true)
                .standardizedFileURL.path
            guard recordedPath == requestedURL.path else {
                return .mismatchedBookmark(expectedPath: recordedPath, actualPath: requestedURL.path)
            }

            let resolutionOptions: URL.BookmarkResolutionOptions
            do {
                resolutionOptions = try SelectedScopeBookmarkStore.resolutionOptionsForCurrentProcess()
            } catch {
                return .permissionOrAccessUnknown
            }

            var bookmarkIsStale = false
            let resolved: URL
            do {
                resolved = try URL(
                    resolvingBookmarkData: bookmark.bookmarkData,
                    options: resolutionOptions,
                    relativeTo: nil,
                    bookmarkDataIsStale: &bookmarkIsStale
                )
            } catch {
                return .invalidBookmark
            }
            let resolvedPath = resolved.standardizedFileURL.path
            guard resolvedPath == requestedURL.path else {
                return .mismatchedBookmark(expectedPath: requestedURL.path, actualPath: resolvedPath)
            }
            guard !bookmarkIsStale else { return .staleBookmark }
            url = resolved
        } else {
            url = requestedURL
        }

        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { url.stopAccessingSecurityScopedResource() }
        }

        var metadata = stat()
        let result = url.path.withCString { lstat($0, &metadata) }
        guard result == 0 else {
            switch errno {
            case ENOENT, ENOTDIR:
                return .missingOrUnreachable
            case EACCES, EPERM:
                return .permissionOrAccessUnknown
            case ELOOP:
                return .symbolicLink
            default:
                return .permissionOrAccessUnknown
            }
        }
        switch metadata.st_mode & S_IFMT {
        case S_IFLNK: return .symbolicLink
        case S_IFDIR: return .availableDirectory
        default: return .notDirectory
        }
    }

    public static func isAvailable(
        at path: String,
        using bookmark: SelectedScopeBookmark? = nil
    ) -> Bool {
        probe(at: path, using: bookmark) == .availableDirectory
    }
}
