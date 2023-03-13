import Foundation

public enum FileInventoryStoreError: Error, LocalizedError {
    case unavailable
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "The private file-change history folder is unavailable."
        case .tooLarge: return "The bounded file inventory exceeds its storage limit and was not replaced."
        }
    }
}

/// A private, bounded store for one full metadata inventory per selected root
/// and the latest net file-level change report for that root.
public enum FileInventoryStore {
    private struct State: Codable {
        var snapshots: [String: FileInventorySnapshot] = [:]
        var reports: [String: FileInventoryChangeSet] = [:]
    }

    private static let fileName = "file-inventory.plist"
    private static let maximumFileSize = 128 * 1_048_576
    private static let maximumRootCount = 50
    private static let maximumTotalEntryCount = 750_000
    private static let maximumChangesInReport = 100
    private static let lock = NSRecursiveLock()

    public static func loadReports(at fileURL: URL? = nil) throws -> [String: FileInventoryChangeSet] {
        lock.lock()
        defer { lock.unlock() }
        return try load(at: fileURL).reports
    }

    public static func clear(at fileURL: URL? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        try LocalStoreFile.remove(at: resolvedURL(fileURL))
    }

    /// Partial or capped inventories never replace a prior complete baseline.
    @discardableResult
    public static func record(
        _ snapshot: FileInventorySnapshot, at fileURL: URL? = nil
    ) throws -> FileInventoryChangeSet? {
        lock.lock()
        defer { lock.unlock() }
        guard !Task.isCancelled else { return nil }
        guard snapshot.complete else { return nil }
        let url = try resolvedURL(fileURL)
        var state = try load(at: url)
        let previous = state.snapshots[snapshot.rootPath]
        let comparablePrevious = previous.flatMap { value in
            value.complete && value.volumeDeviceID == snapshot.volumeDeviceID ? value : nil
        }
        let report = compare(snapshot, with: comparablePrevious)
        state.snapshots[snapshot.rootPath] = snapshot
        state.reports[snapshot.rootPath] = report
        trim(&state, preserving: snapshot.rootPath)
        guard !Task.isCancelled else { return nil }
        try save(state, at: url)
        return report
    }

    private static func compare(
        _ current: FileInventorySnapshot, with previous: FileInventorySnapshot?
    ) -> FileInventoryChangeSet {
        guard let previous else {
            return FileInventoryChangeSet(
                rootPath: current.rootPath, folderObservationID: current.folderObservationID,
                previousObservedAt: nil,
                observedAt: current.observedAt, volumeDeviceID: current.volumeDeviceID,
                changes: [], changedPathCount: 0, omittedChangeCount: 0,
                netLogicalDelta: nil, netAllocatedDelta: nil,
                symlinkExcludedCount: current.excludedSymlinkCount, hasBaseline: false
            )
        }

        let priorByPath = Dictionary(uniqueKeysWithValues: previous.entries.map { ($0.relativePath, $0) })
        let currentByPath = Dictionary(uniqueKeysWithValues: current.entries.map { ($0.relativePath, $0) })
        var changes: [FileInventoryChange] = []
        var logicalDelta: Int64 = 0
        var allocatedDelta: Int64 = 0
        var logicalOverflow = false
        var allocatedOverflow = false

        for entry in current.entries {
            let prior = priorByPath[entry.relativePath]
            let logicalChange = difference(entry.logicalBytes, prior?.logicalBytes ?? 0)
            let allocatedChange = difference(entry.allocatedBytes, prior?.allocatedBytes ?? 0)
            guard prior == nil || logicalChange != 0 || allocatedChange != 0 else { continue }
            let kind: FileInventoryChange.Kind = prior == nil ? .added : .resized
            changes.append(FileInventoryChange(
                relativePath: entry.relativePath, kind: kind,
                logicalDelta: logicalChange, allocatedDelta: allocatedChange,
                logicalBytes: entry.logicalBytes, allocatedBytes: entry.allocatedBytes
            ))
            add(logicalChange, to: &logicalDelta, overflowed: &logicalOverflow)
            add(allocatedChange, to: &allocatedDelta, overflowed: &allocatedOverflow)
        }
        for entry in previous.entries where currentByPath[entry.relativePath] == nil {
            changes.append(FileInventoryChange(
                relativePath: entry.relativePath, kind: .noLongerPresent,
                logicalDelta: -entry.logicalBytes, allocatedDelta: -entry.allocatedBytes,
                logicalBytes: 0, allocatedBytes: 0
            ))
            add(-entry.logicalBytes, to: &logicalDelta, overflowed: &logicalOverflow)
            add(-entry.allocatedBytes, to: &allocatedDelta, overflowed: &allocatedOverflow)
        }

        let ordered = changes.sorted {
            let left = max($0.allocatedDelta, 0)
            let right = max($1.allocatedDelta, 0)
            if left != right { return left > right }
            if $0.logicalDelta != $1.logicalDelta { return $0.logicalDelta > $1.logicalDelta }
            return $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
        }
        return FileInventoryChangeSet(
            rootPath: current.rootPath, folderObservationID: current.folderObservationID,
            previousObservedAt: previous.observedAt,
            observedAt: current.observedAt, volumeDeviceID: current.volumeDeviceID,
            changes: Array(ordered.prefix(maximumChangesInReport)),
            changedPathCount: ordered.count,
            omittedChangeCount: max(0, ordered.count - maximumChangesInReport),
            netLogicalDelta: logicalOverflow ? nil : logicalDelta,
            netAllocatedDelta: allocatedOverflow ? nil : allocatedDelta,
            symlinkExcludedCount: current.excludedSymlinkCount, hasBaseline: true
        )
    }

    private static func difference(_ current: Int64, _ previous: Int64) -> Int64 {
        let (value, overflow) = current.subtractingReportingOverflow(previous)
        if overflow { return current >= previous ? Int64.max : Int64.min }
        return value
    }

    private static func add(_ value: Int64, to total: inout Int64, overflowed: inout Bool) {
        let (result, overflow) = total.addingReportingOverflow(value)
        if overflow { overflowed = true } else { total = result }
    }

    private static func trim(_ state: inout State, preserving path: String) {
        while state.snapshots.count > maximumRootCount
            || state.snapshots.values.reduce(0, { $0 + $1.entries.count }) > maximumTotalEntryCount {
            guard let oldest = state.snapshots.values
                .filter({ $0.rootPath != path })
                .min(by: { $0.observedAt < $1.observedAt }) else { break }
            state.snapshots.removeValue(forKey: oldest.rootPath)
            state.reports.removeValue(forKey: oldest.rootPath)
        }
    }

    private static func load(at fileURL: URL?) throws -> State {
        let url = try resolvedURL(fileURL)
        guard let data = try LocalStoreFile.read(at: url, maximumBytes: maximumFileSize) else {
            return State()
        }
        do { return try PropertyListDecoder().decode(State.self, from: data) }
        catch { throw HistoryDecodeError.invalidHistory(error.localizedDescription) }
    }

    private static func save(_ state: State, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try LocalStoreFile.ensurePrivateDirectory(at: directory)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(state)
        guard data.count <= maximumFileSize else { throw FileInventoryStoreError.tooLarge }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func resolvedURL(_ fileURL: URL?) throws -> URL {
        if let fileURL { return fileURL }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw FileInventoryStoreError.unavailable
        }
        return support.appendingPathComponent("Disker", isDirectory: true).appendingPathComponent(fileName)
    }
}
