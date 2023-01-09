import Foundation

public enum ApplicationBundleIndex {
    /// Latest measured root for each explicitly selected `.app` path.
    /// This indexes bundle scans only; it does not discover or attribute
    /// support data outside the bundle.
    public static func latestMeasurements(in history: LocalHistory) -> [FolderObservation] {
        var latestByPath: [String: FolderObservation] = [:]
        for observation in history.observations.reversed() {
            for folder in observation.folders
            where URL(fileURLWithPath: folder.path).pathExtension.lowercased() == "app" {
                if latestByPath[folder.path] == nil { latestByPath[folder.path] = folder }
            }
        }
        return latestByPath.values.sorted {
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
        }
    }
}
