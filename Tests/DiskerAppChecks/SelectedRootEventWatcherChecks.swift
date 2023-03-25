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
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let mode = arguments.first {
            switch mode {
            case "--relaunch-resume":
                do {
                    try runRelaunchResumeProcess(Array(arguments.dropFirst()))
                } catch {
                    fputs("RELAUNCH RESUME FAILED: \(error.localizedDescription)\n", stderr)
                    exit(EXIT_FAILURE)
                }
                return
            case "--relaunch-opt-out":
                do {
                    try runRelaunchOptOutProcess(Array(arguments.dropFirst()))
                } catch {
                    fputs("RELAUNCH OPT-OUT FAILED: \(error.localizedDescription)\n", stderr)
                    exit(EXIT_FAILURE)
                }
                return
            default:
                throw checkFailure("Unknown child-process check mode: \(mode).")
            }
        }

        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("EventFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let stateDirectory = fixtureRoot.deletingLastPathComponent()
            .appendingPathComponent("EventLifecycleState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let inventoryURL = stateDirectory.appendingPathComponent("file-inventory.plist")
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

        try verifyMonitoringRelaunch(
            root: fixtureRoot,
            inventoryURL: inventoryURL,
            stateDirectory: stateDirectory,
            expectedGrowthPath: "relaunch-growth.bin"
        )

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
            lastScanAtByRoot: [:],
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
        let lastScanAt = [rootPath: throttledAt]
        let tooSoon = StorageMonitoringPolicy.nextEventTriggeredRoot(
            monitoringSessionOpen: true,
            scanInProgress: false,
            pendingRootIdentifiers: [rootPath],
            savedRootIdentifiers: [rootPath],
            selectedRootIdentifiers: [rootPath],
            pausedRootIdentifiers: [],
            lastScanAtByRoot: lastScanAt,
            at: throttledAt.addingTimeInterval(3)
        )
        let remainingThrottle = StorageMonitoringPolicy.nextEventThrottleDelay(
            monitoringSessionOpen: true,
            scanInProgress: false,
            pendingRootIdentifiers: [rootPath],
            savedRootIdentifiers: [rootPath],
            selectedRootIdentifiers: [rootPath],
            pausedRootIdentifiers: [],
            lastScanAtByRoot: lastScanAt,
            at: throttledAt.addingTimeInterval(3)
        )
        guard tooSoon == nil, let remainingThrottle,
              abs(remainingThrottle - 297) < 0.01 else {
            throw checkFailure("A second event must remain pending for the final 297 seconds of its five-minute per-root throttle.")
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
        print("PASS  saved opt-in and bookmark resume in a new process; FSEvents records exact growth; symlinks stay excluded, partial FIFO scans preserve the baseline, throttle holds, and stop is clean")
    }

    private static func verifyMonitoringRelaunch(
        root: URL,
        inventoryURL: URL,
        stateDirectory: URL,
        expectedGrowthPath: String
    ) throws {
        let rootPath = root.standardizedFileURL.path
        let bookmarkURL = stateDirectory.appendingPathComponent("selected-scopes.json")
        let preferencesURL = stateDirectory.appendingPathComponent("storage-monitoring.json")
        let readyURL = stateDirectory.appendingPathComponent("watcher-ready")
        let resultURL = stateDirectory.appendingPathComponent("relaunch-result")
        _ = try SelectedScopeBookmarkStore.remember([root], at: bookmarkURL)
        try StorageMonitoringPreferences.save([rootPath], at: preferencesURL)

        let resume = Process()
        resume.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        resume.arguments = [
            "--relaunch-resume", rootPath, bookmarkURL.path, preferencesURL.path,
            inventoryURL.path, readyURL.path, resultURL.path, expectedGrowthPath
        ]
        try resume.run()
        do {
            try waitForFile(readyURL, process: resume, timeout: 10)
            try Data(repeating: 0x65, count: 8192).write(
                to: root.appendingPathComponent(expectedGrowthPath)
            )
            resume.waitUntilExit()
            guard resume.terminationStatus == 0,
                  try String(contentsOf: resultURL, encoding: .utf8)
                    == "\(rootPath)\n\(expectedGrowthPath)\n8192" else {
                throw checkFailure("The relaunched opted-in process did not record the exact synthetic file change.")
            }
        } catch {
            if resume.isRunning { resume.terminate(); resume.waitUntilExit() }
            throw error
        }

        try StorageMonitoringPreferences.save([], at: preferencesURL)
        let optOut = Process()
        optOut.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        optOut.arguments = ["--relaunch-opt-out", rootPath, bookmarkURL.path, preferencesURL.path]
        try optOut.run()
        optOut.waitUntilExit()
        guard optOut.terminationStatus == 0 else {
            throw checkFailure("A persisted opt-out remained eligible after restarting the process.")
        }
    }

    private static func runRelaunchResumeProcess(_ arguments: [String]) throws {
        guard arguments.count == 7 else {
            throw checkFailure("The relaunch-resume child received an invalid argument list.")
        }
        let rootPath = arguments[0]
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let bookmarkURL = URL(fileURLWithPath: arguments[1])
        let preferencesURL = URL(fileURLWithPath: arguments[2])
        let inventoryURL = URL(fileURLWithPath: arguments[3])
        let readyURL = URL(fileURLWithPath: arguments[4])
        let resultURL = URL(fileURLWithPath: arguments[5])
        let expectedGrowthPath = arguments[6]

        let bookmarks = try SelectedScopeBookmarkStore.load(from: bookmarkURL)
        guard let bookmark = bookmarks.first(where: { $0.path == rootPath }),
              try StorageMonitoringPreferences.load(from: preferencesURL).contains(rootPath),
              try SelectedScopeBookmarkStore.resolve(bookmark, at: bookmarkURL)
                .standardizedFileURL.path == rootPath else {
            throw checkFailure("The new process failed to restore the exact consented synthetic bookmark.")
        }

        let signal = EventSignal()
        let watcher = try SelectedRootEventWatcher(rootURL: root, ownsSecurityScope: false) {
            signal.record()
        }
        defer { watcher.stop() }
        try Data([0x52]).write(to: readyURL)
        try waitForEvent(signal, after: 0, timeout: 12)
        RunLoop.current.run(
            until: Date.now.addingTimeInterval(StorageMonitoringPolicy.eventDebounceInterval)
        )

        let consentedPaths = try StorageMonitoringPreferences.load(from: preferencesURL)
        let scanRoot = StorageMonitoringPolicy.nextEventTriggeredRoot(
            monitoringSessionOpen: true,
            scanInProgress: false,
            pendingRootIdentifiers: [rootPath],
            savedRootIdentifiers: Set(bookmarks.map(\.path)),
            selectedRootIdentifiers: consentedPaths,
            pausedRootIdentifiers: [],
            lastScanAtByRoot: [:],
            at: .now
        )
        guard scanRoot == rootPath else {
            throw checkFailure("The relaunched process did not schedule an opted-in event scan for its saved root.")
        }

        let scan = FolderScanner.scanWithFileInventories(roots: [root])
        guard scan.observation.folders.first?.complete == true,
              let snapshot = scan.fileInventories.first,
              let recorded = try FileInventoryStore.recordWithTrendPoints(snapshot, at: inventoryURL),
              let netLogicalDelta = recorded.report.netLogicalDelta,
              recorded.report.changes.contains(where: {
                  $0.relativePath == expectedGrowthPath && $0.kind == .added
              }), netLogicalDelta == 8192 else {
            throw checkFailure("The relaunched event scan failed to save the exact complete inventory comparison.")
        }
        try "\(rootPath)\n\(expectedGrowthPath)\n\(netLogicalDelta)".write(
            to: resultURL, atomically: true, encoding: .utf8
        )
    }

    private static func runRelaunchOptOutProcess(_ arguments: [String]) throws {
        guard arguments.count == 3 else {
            throw checkFailure("The relaunch-opt-out child received an invalid argument list.")
        }
        let rootPath = arguments[0]
        let bookmarks = try SelectedScopeBookmarkStore.load(from: URL(fileURLWithPath: arguments[1]))
        let consentedPaths = try StorageMonitoringPreferences.load(from: URL(fileURLWithPath: arguments[2]))
        let eligibleRoot = StorageMonitoringPolicy.nextEventTriggeredRoot(
            monitoringSessionOpen: true,
            scanInProgress: false,
            pendingRootIdentifiers: [rootPath],
            savedRootIdentifiers: Set(bookmarks.map(\.path)),
            selectedRootIdentifiers: consentedPaths,
            pausedRootIdentifiers: [],
            lastScanAtByRoot: [:],
            at: .now
        )
        guard bookmarks.contains(where: { $0.path == rootPath }),
              !consentedPaths.contains(rootPath), eligibleRoot == nil else {
            throw checkFailure("A saved bookmark without monitoring consent must not become scan-eligible.")
        }
    }

    private static func waitForFile(_ url: URL, process: Process, timeout: TimeInterval) throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline, process.isRunning,
              !FileManager.default.fileExists(atPath: url.path) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw checkFailure("The relaunched watcher did not become ready before the timeout.")
        }
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
