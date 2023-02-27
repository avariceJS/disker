import Foundation

public enum SelectedRootScope {
    /// Returns true when two selected roots are identical or one is a lexical
    /// path ancestor of the other. This does not resolve symlinks or aliases.
    public static func hasOverlappingPaths(_ paths: [String]) -> Bool {
        let normalized = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for firstIndex in normalized.indices {
            for secondIndex in normalized.indices where secondIndex > firstIndex {
                let first = normalized[firstIndex]
                let second = normalized[secondIndex]
                if first == second || containsPath(first, descendant: second)
                    || containsPath(second, descendant: first) {
                    return true
                }
            }
        }
        return false
    }

    private static func containsPath(_ parent: String, descendant: String) -> Bool {
        let prefix = parent == "/" ? "/" : parent + "/"
        return descendant.hasPrefix(prefix)
    }
}
