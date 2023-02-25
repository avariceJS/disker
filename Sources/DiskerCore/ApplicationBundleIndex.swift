import Foundation

public enum ApplicationBundleIndex {
    /// Latest measurements for paths the user explicitly selected through
    /// the app-bundle picker. Later scans of the same path remain current even
    /// when they came from a saved folder bookmark. Bundle identity and
    /// signature details come only from the measurement that recorded them.
    /// This does not discover or attribute support data outside the bundle.
    public static func latestMeasurements(in history: LocalHistory) -> [FolderObservation] {
        let explicitlySelectedPaths = Set(history.observations.lazy
            .flatMap(\.folders)
            .filter(\.selectedAsApplicationBundle)
            .map(\.path))
        var latestByPath: [String: FolderObservation] = [:]
        for observation in history.observations.reversed() {
            for folder in observation.folders
            where explicitlySelectedPaths.contains(folder.path) {
                if latestByPath[folder.path] == nil { latestByPath[folder.path] = folder }
            }
        }
        return latestByPath.values.sorted {
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
        }
    }
}
