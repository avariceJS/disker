import Darwin
import Foundation

/// Checks one already selected directory path without opening or traversing it.
/// If a bookmark is supplied, it must still resolve to the exact recorded path.
public enum SelectedScopePathProbe {
    public static func isAvailable(
        at path: String,
        using bookmark: SelectedScopeBookmark? = nil
    ) -> Bool {
        let requestedURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let url: URL
        if let bookmark {
            var bookmarkIsStale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: bookmark.bookmarkData,
                options: try SelectedScopeBookmarkStore.resolutionOptionsForCurrentProcess(),
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            ),
                  resolved.standardizedFileURL.path == requestedURL.path else { return false }
            url = resolved
        } else {
            url = requestedURL
        }

        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { url.stopAccessingSecurityScopedResource() }
        }

        var metadata = stat()
        guard url.path.withCString({ lstat($0, &metadata) }) == 0 else { return false }
        return metadata.st_mode & S_IFMT == S_IFDIR
    }
}
