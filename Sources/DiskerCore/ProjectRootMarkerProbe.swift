import Darwin
import Foundation

/// Checks only the selected directory and its direct `.git` child. Every path
/// component is opened as a directory with `O_NOFOLLOW`; no repository or file
/// contents are read.
public enum ProjectRootMarkerProbe {
    public static func hasDirectGitMarker(at directoryURL: URL) -> Bool {
        let path = directoryURL.standardizedFileURL.path
        guard path.hasPrefix("/") else { return false }
        var directoryFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else { return false }
        for component in path.split(separator: "/") {
            let nextFD = component.withCString {
                openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard nextFD >= 0 else {
                close(directoryFD)
                return false
            }
            close(directoryFD)
            directoryFD = nextFD
        }
        defer { close(directoryFD) }

        var rootMetadata = stat()
        guard fstat(directoryFD, &rootMetadata) == 0,
              (rootMetadata.st_mode & S_IFMT) == S_IFDIR else { return false }

        var markerMetadata = stat()
        let markerResult = ".git".withCString {
            fstatat(directoryFD, $0, &markerMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard markerResult == 0 else { return false }
            let type = markerMetadata.st_mode & S_IFMT
        return type == S_IFDIR || type == S_IFREG
    }
}
