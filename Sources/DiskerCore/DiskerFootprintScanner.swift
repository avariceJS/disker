import Darwin
import Foundation

/// Measures Disker's own bundle and dedicated support directory without
/// persisting a history observation or widening the scan to neighboring data.
public enum DiskerFootprintScanner {
    public static func selectedRoots(
        bundleURL: URL, supportDirectory: URL?
    ) -> [URL] {
        var roots = [bundleURL]
        guard let supportDirectory,
              supportDirectory.standardizedFileURL.path != bundleURL.standardizedFileURL.path else {
            return roots
        }

        var metadata = stat()
        let result = supportDirectory.path.withCString { lstat($0, &metadata) }
        // Preserve non-ENOENT lookup failures as a scan root so the scanner can
        // report them as inaccessible. lstat ensures a symlink is never opened.
        if result == 0 || errno != ENOENT {
            roots.append(supportDirectory)
        }
        return roots
    }

    public static func scan(
        bundleURL: URL,
        supportDirectory: URL?,
        shouldCancel: () -> Bool = { Task.isCancelled },
        progress: (ScanProgress) -> Void = { _ in }
    ) -> ScanObservation {
        FolderScanner.scanAppOwnedRoots(
            roots: selectedRoots(bundleURL: bundleURL, supportDirectory: supportDirectory),
            shouldCancel: shouldCancel,
            progress: progress
        )
    }
}
