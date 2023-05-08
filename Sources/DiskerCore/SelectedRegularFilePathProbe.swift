import Darwin
import Foundation

/// Verifies that an explicitly selected path is a regular file without
/// following symlink components or reading file contents.
public enum SelectedRegularFilePathProbe {
    public enum Status: Equatable, Sendable {
        case availableRegularFile
        case missingOrUnreachable
        case permissionOrAccessUnknown
        case notRegularFile
        case symbolicLink
    }

    public static func probe(selectedURL: URL) -> Status {
        let path = selectedURL.path
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"), !components.isEmpty,
              !components.contains("."), !components.contains("..") else {
            return .permissionOrAccessUnknown
        }

        let accessGranted = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { selectedURL.stopAccessingSecurityScopedResource() }
        }

        var currentPath = ""
        for (index, component) in components.enumerated() {
            currentPath += "/" + component
            var metadata = stat()
            let result = currentPath.withCString { lstat($0, &metadata) }
            guard result == 0 else { return status(forErrno: errno) }

            let type = metadata.st_mode & S_IFMT
            if type == S_IFLNK { return .symbolicLink }
            if index < components.count - 1 {
                guard type == S_IFDIR else { return .notRegularFile }
            } else {
                return type == S_IFREG ? .availableRegularFile : .notRegularFile
            }
        }
        return .permissionOrAccessUnknown
    }

    private static func status(forErrno code: Int32) -> Status {
        switch code {
        case ENOENT: .missingOrUnreachable
        case ENOTDIR: .notRegularFile
        case EACCES, EPERM: .permissionOrAccessUnknown
        case ELOOP: .symbolicLink
        default: .permissionOrAccessUnknown
        }
    }
}
