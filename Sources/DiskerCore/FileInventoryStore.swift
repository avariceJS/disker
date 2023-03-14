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

        var changes: [FileInventoryChange] = []
        var changedPathCount = 0
        var logicalDelta: Int64 = 0
        var allocatedDelta: Int64 = 0
        var logicalOverflow = false
        var allocatedOverflow = false
        func precedes(_ lhs: FileInventoryChange, _ rhs: FileInventoryChange) -> Bool {
            let left = max(lhs.allocatedDelta, 0)
            let right = max(rhs.allocatedDelta, 0)
            if left != right { return left > right }
            if lhs.logicalDelta != rhs.logicalDelta { return lhs.logicalDelta > rhs.logicalDelta }
            return lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
        }
        func retain(_ change: FileInventoryChange) {
            changedPathCount += 1
            add(change.logicalDelta, to: &logicalDelta, overflowed: &logicalOverflow)
            add(change.allocatedDelta, to: &allocatedDelta, overflowed: &allocatedOverflow)
            var low = 0
            var high = changes.count
            while low < high {
                let middle = (low + high) / 2
                if precedes(changes[middle], change) { low = middle + 1 }
                else { high = middle }
            }
            if low < maximumChangesInReport || changes.count < maximumChangesInReport {
                changes.insert(change, at: low)
                if changes.count > maximumChangesInReport { changes.removeLast() }
            }
        }

        // Both manifests are stored in UTF-8 path order, so a merge walk finds
        // every difference without two additional 300k-entry dictionaries.
        var currentIndex = 0
        var previousIndex = 0
        while currentIndex < current.entries.count || previousIndex < previous.entries.count {
            if currentIndex >= current.entries.count {
                let old = previous.entries[previousIndex]
                retain(FileInventoryChange(
                    relativePath: old.relativePath, kind: .noLongerPresent,
                    logicalDelta: -old.logicalBytes, allocatedDelta: -old.allocatedBytes,
                    logicalBytes: 0, allocatedBytes: 0
                ))
                previousIndex += 1
                continue
            }
            if previousIndex >= previous.entries.count {
                let new = current.entries[currentIndex]
                retain(FileInventoryChange(
                    relativePath: new.relativePath, kind: .added,
                    logicalDelta: new.logicalBytes, allocatedDelta: new.allocatedBytes,
                    logicalBytes: new.logicalBytes, allocatedBytes: new.allocatedBytes
                ))
                currentIndex += 1
                continue
            }

            let new = current.entries[currentIndex]
            let old = previous.entries[previousIndex]
            if new.relativePath.utf8.lexicographicallyPrecedes(old.relativePath.utf8) {
                retain(FileInventoryChange(
                    relativePath: new.relativePath, kind: .added,
                    logicalDelta: new.logicalBytes, allocatedDelta: new.allocatedBytes,
                    logicalBytes: new.logicalBytes, allocatedBytes: new.allocatedBytes
                ))
                currentIndex += 1
            } else if old.relativePath.utf8.lexicographicallyPrecedes(new.relativePath.utf8) {
                retain(FileInventoryChange(
                    relativePath: old.relativePath, kind: .noLongerPresent,
                    logicalDelta: -old.logicalBytes, allocatedDelta: -old.allocatedBytes,
                    logicalBytes: 0, allocatedBytes: 0
                ))
                previousIndex += 1
            } else {
                let logicalChange = difference(new.logicalBytes, old.logicalBytes)
                let allocatedChange = difference(new.allocatedBytes, old.allocatedBytes)
                if logicalChange != 0 || allocatedChange != 0 {
                    retain(FileInventoryChange(
                        relativePath: new.relativePath, kind: .resized,
                        logicalDelta: logicalChange, allocatedDelta: allocatedChange,
                        logicalBytes: new.logicalBytes, allocatedBytes: new.allocatedBytes
                    ))
                }
                currentIndex += 1
                previousIndex += 1
            }
        }

        return FileInventoryChangeSet(
            rootPath: current.rootPath, folderObservationID: current.folderObservationID,
            previousObservedAt: previous.observedAt,
            observedAt: current.observedAt, volumeDeviceID: current.volumeDeviceID,
            changes: changes,
            changedPathCount: changedPathCount,
            omittedChangeCount: max(0, changedPathCount - maximumChangesInReport),
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
