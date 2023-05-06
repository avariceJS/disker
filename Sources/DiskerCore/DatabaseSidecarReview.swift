import Foundation

/// Read-only exact-name relationships between SQLite database files and their
/// conventional sidecars inside one already measured selected root.
/// This is filename evidence only; it does not open or parse database contents.
public struct DatabaseSidecarReview: Equatable, Sendable {
    public let rootPath: String
    public let folderObservationID: UUID
    public let observedAt: Date
    public let inventoryComplete: Bool
    public let excludedSymlinkCount: Int
    public let groups: [Group]
    public let unpairedSidecars: [FileInventoryEntry]
    public let omittedGroupCount: Int
    public let omittedUnpairedSidecarCount: Int
    /// Changes from a same-root, same-volume report matching this exact complete observation.
    public let fileChangesByPath: [String: FileInventoryChange]
    public let previousFileInventoryObservationAt: Date?
    /// Nil when no comparable baseline report is available.
    public let omittedFileChangeCount: Int?

    public struct Group: Equatable, Identifiable, Sendable {
        public let database: FileInventoryEntry
        public let sidecars: [FileInventoryEntry]
        public var id: String { database.relativePath }
    }

    public static let maximumGroups = 200
    public static let maximumUnpairedSidecars = 200

    public static func make(
        from snapshot: FileInventorySnapshot,
        fileChangeReport: FileInventoryChangeSet? = nil
    ) -> Self {
        let entriesByPath = Dictionary(
            snapshot.entries.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let databaseEntries = snapshot.entries
            .filter { databaseBasePath(for: $0.relativePath) != nil }
            .sorted { $0.relativePath < $1.relativePath }

        var groups: [Group] = []
        var pairedSidecarPaths = Set<String>()
        for database in databaseEntries {
            let sidecars = sidecarSuffixes.compactMap { suffix -> FileInventoryEntry? in
                let path = database.relativePath + suffix
                guard let entry = entriesByPath[path] else { return nil }
                pairedSidecarPaths.insert(path)
                return entry
            }
            guard !sidecars.isEmpty else { continue }
            groups.append(Group(database: database, sidecars: sidecars))
        }

        let unpairedSidecars = snapshot.entries
            .filter { isSidecarPath($0.relativePath) && !pairedSidecarPaths.contains($0.relativePath) }
            .sorted { $0.relativePath < $1.relativePath }

        let comparableReport = fileChangeReport.flatMap { report -> FileInventoryChangeSet? in
            guard snapshot.complete,
                  let currentVolumeID = snapshot.volumeDeviceID,
                  report.rootPath == snapshot.rootPath,
                  report.folderObservationID == snapshot.folderObservationID,
                  report.volumeDeviceID == currentVolumeID,
                  report.observedAt == snapshot.observedAt,
                  report.hasBaseline,
                  let previousObservedAt = report.previousObservedAt,
                  previousObservedAt < report.observedAt,
                  report.changedPathCount >= report.changes.count,
                  report.omittedChangeCount == report.changedPathCount - report.changes.count,
                  Set(report.changes.map(\.relativePath)).count == report.changes.count else { return nil }
            return report
        }
        let fileChangesByPath = Dictionary(
            (comparableReport?.changes ?? []).filter { entriesByPath[$0.relativePath] != nil }
                .map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return Self(
            rootPath: snapshot.rootPath,
            folderObservationID: snapshot.folderObservationID,
            observedAt: snapshot.observedAt,
            inventoryComplete: snapshot.complete,
            excludedSymlinkCount: snapshot.excludedSymlinkCount,
            groups: Array(groups.prefix(maximumGroups)),
            unpairedSidecars: Array(unpairedSidecars.prefix(maximumUnpairedSidecars)),
            omittedGroupCount: max(0, groups.count - maximumGroups),
            omittedUnpairedSidecarCount: max(0, unpairedSidecars.count - maximumUnpairedSidecars),
            fileChangesByPath: fileChangesByPath,
            previousFileInventoryObservationAt: comparableReport?.previousObservedAt,
            omittedFileChangeCount: comparableReport?.omittedChangeCount
        )
    }

    private static let sidecarSuffixes = ["-wal", "-shm", "-journal"]

    private static func databaseBasePath(for relativePath: String) -> String? {
        guard isSafeRelativePath(relativePath) else { return nil }
        let name = (relativePath as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        guard ["db", "sqlite", "sqlite3"].contains(ext) else { return nil }
        return relativePath
    }

    private static func isSidecarPath(_ relativePath: String) -> Bool {
        guard isSafeRelativePath(relativePath) else { return false }
        return sidecarSuffixes.contains { suffix in
            guard relativePath.hasSuffix(suffix) else { return false }
            let basePath = String(relativePath.dropLast(suffix.count))
            return databaseBasePath(for: basePath) != nil
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
