import Darwin
import Foundation

private final class EventSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var eventCount = 0

    func record() {
        lock.lock()
        eventCount += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return eventCount
    }
}

@main
private enum SelectedRootEventWatcherChecks {
    static func main() throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("EventFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let inventoryURL = fixtureRoot.deletingLastPathComponent()
            .appendingPathComponent("EventInventory-\(UUID().uuidString).plist")
        defer { try? FileInventoryStore.clear(at: inventoryURL) }

        let baselineFile = fixtureRoot.appendingPathComponent("baseline.bin")
        try Data(repeating: 0x42, count: 16).write(to: baselineFile)
        let baselineScan = FolderScanner.scanWithFileInventories(roots: [fixtureRoot])
        guard baselineScan.observation.folders.first?.complete == true,
              let baselineSnapshot = baselineScan.fileInventories.first,
              let baselineResult = try FileInventoryStore.recordWithTrendPoints(
                baselineSnapshot, at: inventoryURL
              ), !baselineResult.report.hasBaseline else {
            throw checkFailure("The synthetic complete scan should establish a forward-only baseline.")
        }

        let signal = EventSignal()
        let watcher = try SelectedRootEventWatcher(rootURL: fixtureRoot, ownsSecurityScope: false) {
            signal.record()
        }
        defer { watcher.stop() }
        let growthPath = "nested/synthetic-growth.bin"
        let growthFile = fixtureRoot.appendingPathComponent(growthPath)
        try FileManager.default.createDirectory(at: growthFile.deletingLastPathComponent(), withIntermediateDirectories: false)
        try Data(repeating: 0x44, count: 8192).write(to: growthFile)

        try waitForEvent(signal, after: 0, timeout: 8)
        RunLoop.current.run(until: Date.now.addingTimeInterval(StorageMonitoringPolicy.eventDebounceInterval))
        let rootPath = fixtureRoot.standardizedFileURL.path
        let eventAt = Date.now
        let eventScanRoot = StorageMonitoringPolicy.nextEventTriggeredRoot(
            monitoringSessionOpen: true,
            scanInProgress: false,
            pendingRootIdentifiers: [rootPath],
            savedRootIdentifiers: [rootPath],
            selectedRootIdentifiers: [rootPath],
            pausedRootIdentifiers: [],
            lastEventScanAtByRoot: [:],
            at: eventAt
        )
        guard eventScanRoot == rootPath else {
            throw checkFailure("A debounced event for the saved opted-in synthetic root should be eligible for a scan.")
        }

        let growthScan = FolderScanner.scanWithFileInventories(roots: [fixtureRoot])
        guard growthScan.observation.folders.first?.complete == true,
              let growthSnapshot = growthScan.fileInventories.first,
              let growthResult = try FileInventoryStore.recordWithTrendPoints(
                growthSnapshot, at: inventoryURL
              ), growthResult.report.hasBaseline,
              growthResult.report.changes.contains(where: {
                  $0.relativePath == growthPath && $0.kind == .added
              }), growthResult.report.grossAllocatedGrowth ?? 0 > 0,
              growthResult.report.netLogicalDelta == 8192 else {
            throw checkFailure("The complete event-triggered re-scan should report the exact added path and measured growth.")
        }

        let afterGrowth = signal.count
        let outsideFile = fixtureRoot.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outsideFile) }
        try Data(repeating: 0x58, count: 4096).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: fixtureRoot.appendingPathComponent("external-link"),
            withDestinationURL: outsideFile
        )
        let partialScan = FolderScanner.scanWithFileInventories(roots: [fixtureRoot])
        let partialSnapshot = partialScan.fileInventories.first
        let symlinkResult = try partialSnapshot.flatMap {
            try FileInventoryStore.recordWithTrendPoints($0, at: inventoryURL)
        }
        guard let partialFolder = partialScan.observation.folders.first,
              !partialFolder.complete, partialFolder.excludedSymlinkCount == 1,
              partialSnapshot?.complete == true,
              partialSnapshot?.excludedSymlinkCount == 1,
              partialSnapshot?.entries.contains(where: { $0.relativePath == "external-link" }) == false,
              symlinkResult?.report.hasBaseline == true,
              symlinkResult?.report.symlinkExcludedCount == 1,
              symlinkResult?.report.changes.isEmpty == true else {
            throw checkFailure(
                "No-follow scope check failed (folderComplete=\(String(describing: partialScan.observation.folders.first?.complete)), excludedSymlinks=\(partialScan.observation.folders.first?.excludedSymlinkCount ?? -1), inventoryComplete=\(String(describing: partialSnapshot?.complete)), symlinkCount=\(partialSnapshot?.excludedSymlinkCount ?? -1), symlinkListed=\(partialSnapshot?.entries.contains(where: { $0.relativePath == "external-link" }) ?? true), reportExcludesLink=\(symlinkResult?.report.symlinkExcludedCount == 1))."
            )
        }

        let fifoURL = fixtureRoot.appendingPathComponent("unmeasured-stream.fifo")
        let fifoCreated = fifoURL.path.withCString {
            mkfifo($0, mode_t(S_IRUSR | S_IWUSR))
        }
        guard fifoCreated == 0 else {
            throw checkFailure("The synthetic FIFO used to verify incomplete inventory coverage could not be created.")
        }
        let fifoScan = FolderScanner.scanWithFileInventories(roots: [fixtureRoot])
        let fifoSnapshot = fifoScan.fileInventories.first
        let fifoRecord = try fifoSnapshot.flatMap {
            try FileInventoryStore.recordWithTrendPoints($0, at: inventoryURL)
        }
        let reportAfterFIFO = try FileInventoryStore.loadReports(at: inventoryURL)[rootPath]
        guard fifoScan.observation.folders.first?.complete == false,
              fifoScan.observation.folders.first?.excludedSpecialFileCount == 1,
              fifoSnapshot?.complete == false, fifoRecord == nil,
              reportAfterFIFO?.observedAt == symlinkResult?.report.observedAt else {
            throw checkFailure("A truly incomplete FIFO scan must not replace the complete no-follow inventory baseline.")
        }

        let throttledAt = Date.now
        let lastEventScanAt = [rootPath: throttledAt]
        let tooSoon = StorageMonitoringPolicy.nextEventTriggeredRoot(
            monitoringSessionOpen: true,
            scanInProgress: false,
            pendingRootIdentifiers: [rootPath],
            savedRootIdentifiers: [rootPath],
            selectedRootIdentifiers: [rootPath],
            pausedRootIdentifiers: [],
            lastEventScanAtByRoot: lastEventScanAt,
            at: throttledAt.addingTimeInterval(3)
        )
        let remainingThrottle = StorageMonitoringPolicy.nextEventThrottleDelay(
            monitoringSessionOpen: true,
            scanInProgress: false,
            pendingRootIdentifiers: [rootPath],
            savedRootIdentifiers: [rootPath],
            selectedRootIdentifiers: [rootPath],
            pausedRootIdentifiers: [],
            lastEventScanAtByRoot: lastEventScanAt,
            at: throttledAt.addingTimeInterval(3)
        )
        guard tooSoon == nil, let remainingThrottle,
              abs(remainingThrottle - 57) < 0.01 else {
            throw checkFailure("A second event must remain pending for the final 57 seconds of its per-root throttle.")
        }

        // Drain any callbacks for the first write before establishing the
        // post-stop count. A stopped stream must not deliver later changes.
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.25))
        let countAfterFirstChange = signal.count
        watcher.stop()
        try Data([0x73, 0x74, 0x6f, 0x70]).write(
            to: fixtureRoot.appendingPathComponent("after-stop.bin")
        )
        let stopDeadline = Date.now.addingTimeInterval(1.5)
        while Date.now < stopDeadline {
            RunLoop.current.run(until: min(stopDeadline, Date.now.addingTimeInterval(0.05)))
        }
        guard signal.count == countAfterFirstChange else {
            throw NSError(domain: "Disker.SelectedRootEventWatcherChecks", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "A stopped FSEvents watcher delivered a later synthetic filesystem change."
            ])
        }
        guard countAfterFirstChange >= afterGrowth else {
            throw checkFailure("The watcher should retain the callback count through the completed synthetic workflow.")
        }
        print("PASS  FSEvents drives exact inventory growth; symlinks stay excluded, partial FIFO scans preserve the baseline, throttle holds, and stop is clean")
    }

    private static func waitForEvent(_ signal: EventSignal, after count: Int, timeout: TimeInterval) throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline && signal.count <= count {
            RunLoop.current.run(until: min(deadline, Date.now.addingTimeInterval(0.05)))
        }
        guard signal.count > count else {
            throw checkFailure("FSEvents did not notify Disker about a synthetic selected-root change within \(timeout) seconds.")
        }
    }

    private static func checkFailure(_ message: String) -> NSError {
        NSError(domain: "Disker.SelectedRootEventWatcherChecks", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }

}
