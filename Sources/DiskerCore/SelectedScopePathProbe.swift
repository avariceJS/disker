import Darwin
import Foundation

/// Checks one already selected directory path without enumerating descendants
/// or reading file contents.
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
    /// Every path component is opened relative to a directory descriptor with
    /// `O_NOFOLLOW`, so ancestor symlinks are rejected as well as final links.
    public static func probe(
        at path: String,
        using bookmark: SelectedScopeBookmark? = nil
    ) -> Status {
        let rawComponents = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !rawComponents.contains("."), !rawComponents.contains("..") else {
            return .permissionOrAccessUnknown
        }
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

        guard url.path.hasPrefix("/") else { return .permissionOrAccessUnknown }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return status(forErrno: errno) }
        defer { close(descriptor) }

        let components = Array(url.standardizedFileURL.pathComponents.dropFirst())
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                return .permissionOrAccessUnknown
            }
            var enumerated = stat()
            let lookup = component.withCString {
                fstatat(descriptor, $0, &enumerated, AT_SYMLINK_NOFOLLOW)
            }
            guard lookup == 0 else { return status(forErrno: errno) }

            switch enumerated.st_mode & S_IFMT {
            case S_IFLNK:
                return .symbolicLink
            case S_IFDIR:
                break
            default:
                return .notDirectory
            }

            let nextDescriptor = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard nextDescriptor >= 0 else { return status(forErrno: errno) }
            var opened = stat()
            guard fstat(nextDescriptor, &opened) == 0 else {
                let failure = status(forErrno: errno)
                close(nextDescriptor)
                return failure
            }
            guard opened.st_mode & S_IFMT == S_IFDIR,
                  opened.st_dev == enumerated.st_dev,
                  opened.st_ino == enumerated.st_ino else {
                close(nextDescriptor)
                return .permissionOrAccessUnknown
            }

            close(descriptor)
            descriptor = nextDescriptor
        }
        return .availableDirectory
    }

    public static func isAvailable(
        at path: String,
        using bookmark: SelectedScopeBookmark? = nil
    ) -> Bool {
        probe(at: path, using: bookmark) == .availableDirectory
    }

    private static func status(forErrno code: Int32) -> Status {
        switch code {
        case ENOENT: .missingOrUnreachable
        case ENOTDIR: .notDirectory
        case EACCES, EPERM: .permissionOrAccessUnknown
        case ELOOP: .symbolicLink
        default: .permissionOrAccessUnknown
        }
    }
}
