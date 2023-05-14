#if DEBUG
import AppKit
import DiskerCore
import SwiftUI

struct DashboardModelMonitoringCheckHost: View {
    let resultURL: URL
    @State private var hasStarted = false

    static func resultURL(from arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--dashboard-model-monitoring-check"),
              arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .task {
                guard !hasStarted else { return }
                hasStarted = true
                do {
                    let runDirectory = resultURL.deletingLastPathComponent()
                    try await Self.runChecks(
                        stateDirectory: runDirectory.appendingPathComponent("lifecycle", isDirectory: true)
                    )
                    try await Self.runEventTriggeredScanCheck(
                        stateDirectory: runDirectory.appendingPathComponent("event-scan", isDirectory: true)
                    )
                    try writeResult("PASS DashboardModel monitor lifecycle, event-triggered growth scan, persisted same-path report, opt-out, re-opt-in baseline, and periodic scheduled scan")
                } catch {
                    try? writeResult("FAIL \(error.localizedDescription)")
                }
                NSApplication.shared.terminate(nil)
            }
    }

    @MainActor
    private static func runChecks(stateDirectory: URL) async throws {
        let root = stateDirectory.appendingPathComponent("SelectedRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let observationsURL = stateDirectory.appendingPathComponent("observations.json")
        let inventoriesURL = stateDirectory.appendingPathComponent("file-inventory.plist")
        let bookmarkURL = stateDirectory.appendingPathComponent("selected-scopes.json")
        let preferencesURL = stateDirectory.appendingPathComponent("storage-monitoring.json")
        let bookmarks = try SelectedScopeBookmarkStore.remember([root], at: bookmarkURL)
        let rootPath = root.standardizedFileURL.path

        // Fixture mode skips Disker's real local stores; no scan is started by this check.
        let model = DashboardModel(
            includeSnapshotProjectCandidate: true,
            observationStoreURL: observationsURL,
            fileInventoryStoreURL: inventoriesURL,
            selectedScopeBookmarkStoreURL: bookmarkURL,
            storageMonitoringPreferencesURL: preferencesURL
        )
        defer {
            model.setStorageMonitoringSessionOpen(false)
            model.isScanning = false
        }
        model.rememberedScopes = bookmarks
        model.storageMonitoringInterval = StorageMonitoringPolicy.minimumInterval
        model.isScanning = true
        model.toggleStorageMonitoring(rootPath, enabled: true)
        guard try StorageMonitoringPreferences.load(from: preferencesURL) == [rootPath],
              model.monitoredScopePaths == [rootPath],
              model.activeStorageEventWatcherPathsForTesting.isEmpty else {
            throw failure("Opt-in was not persisted to the isolated preferences file before the window opened.")
        }

        model.setStorageMonitoringSessionOpen(true)
        guard model.storageMonitoringSessionOpen,
              model.activeStorageEventWatcherPathsForTesting == [rootPath],
              model.storageEventWatcherErrors[rootPath] == nil else {
            throw failure("Opening the model session did not start the selected synthetic-root watcher.")
        }

        model.setStorageMonitoringAppActive(false)
        try recordEvent(in: root, named: "while-open.bin")
        try await waitUntil(timeout: 9) { model.pendingStorageEventPathsForTesting.contains(rootPath) }
        guard model.scheduledScanPath == nil, model.eventTriggeredScanPath == nil else {
            throw failure("A synthetic event started a scan while a user scan was already in progress.")
        }

        model.setStorageMonitoringSessionOpen(false)
        guard !model.storageMonitoringSessionOpen,
              model.activeStorageEventWatcherPathsForTesting.isEmpty,
              model.pendingStorageEventPathsForTesting.isEmpty,
              model.scheduledScanPath == nil,
              model.eventTriggeredScanPath == nil else {
            throw failure("Closing the model session did not stop and clear event-triggered work.")
        }

        try recordEvent(in: root, named: "while-closed.bin")
        try await Task.sleep(for: .seconds(1.5))
        guard model.pendingStorageEventPathsForTesting.isEmpty else {
            throw failure("A filesystem change after session close reached the model's pending scan queue.")
        }

        model.toggleStorageMonitoring(rootPath, enabled: false)
        guard try StorageMonitoringPreferences.load(from: preferencesURL).isEmpty,
              model.monitoredScopePaths.isEmpty else {
            throw failure("Opt-out was not persisted to the isolated preferences file.")
        }
        model.setStorageMonitoringSessionOpen(true)
        guard model.activeStorageEventWatcherPathsForTesting.isEmpty else {
            throw failure("Reopening the window restored a watcher after the user opted out.")
        }
        try recordEvent(in: root, named: "while-opted-out.bin")
        try await Task.sleep(for: .seconds(1.5))
        guard model.pendingStorageEventPathsForTesting.isEmpty else {
            throw failure("An opted-out selected root queued work after a filesystem change.")
        }

        model.setStorageMonitoringSessionOpen(false)
        model.toggleStorageMonitoring(rootPath, enabled: true)

        model.setStorageMonitoringSessionOpen(true)
        guard model.activeStorageEventWatcherPathsForTesting == [rootPath],
              model.storageEventWatcherErrors[rootPath] == nil else {
            throw failure("Reopening the model session did not restore the selected synthetic-root watcher.")
        }
        try recordEvent(in: root, named: "after-reopen.bin")
        try await waitUntil(timeout: 9) { model.pendingStorageEventPathsForTesting.contains(rootPath) }
        guard model.storageMonitoringSessionOpen,
              model.scheduledScanPath == nil,
              model.eventTriggeredScanPath == nil else {
            throw failure("The reopened watcher did not queue an event without bypassing the active-scan gate.")
        }

        model.setStorageMonitoringSessionOpen(false)
        model.isScanning = false
    }

    @MainActor
    private static func runEventTriggeredScanCheck(stateDirectory: URL) async throws {
        let root = stateDirectory.appendingPathComponent("SelectedRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let baselinePath = root.appendingPathComponent("baseline.bin")
        try Data(repeating: 0x42, count: 16).write(to: baselinePath)

        let observationsURL = stateDirectory.appendingPathComponent("observations.json")
        let inventoriesURL = stateDirectory.appendingPathComponent("file-inventory.plist")
        let bookmarksURL = stateDirectory.appendingPathComponent("selected-scopes.json")
        let preferencesURL = stateDirectory.appendingPathComponent("storage-monitoring.json")
        let rootPath = root.standardizedFileURL.path

        let baselineScan = FolderScanner.scanWithFileInventories(roots: [root])
        let baselineFolder = baselineScan.observation.folders.first
        let baselineSnapshot = baselineScan.fileInventories.first
        let baselineRecord = try baselineSnapshot.flatMap {
            try FileInventoryStore.recordWithTrendPoints($0, at: inventoriesURL)
        }
        let baselineHasBaseline = baselineRecord?.report.hasBaseline.description ?? "unknown"
        guard baselineFolder?.complete == true, baselineSnapshot?.complete == true,
              baselineRecord?.report.hasBaseline == false else {
            throw failure(
                "The selected synthetic root did not create a complete initial file-inventory baseline "
                    + "(folderComplete: \(baselineFolder?.complete ?? false), "
                    + "inventoryComplete: \(baselineSnapshot?.complete ?? false), "
                    + "recorded: \(baselineRecord != nil), "
                    + "hasBaseline: \(baselineHasBaseline))."
            )
        }
        _ = try ObservationStore.append(baselineScan.observation, to: observationsURL)
        _ = try SelectedScopeBookmarkStore.remember([root], at: bookmarksURL)

        // Every on-disk dependency uses this test-owned directory.
        let model = DashboardModel(
            observationStoreURL: observationsURL,
            fileInventoryStoreURL: inventoriesURL,
            selectedScopeBookmarkStoreURL: bookmarksURL,
            storageMonitoringPreferencesURL: preferencesURL
        )
        defer {
            model.setStorageMonitoringSessionOpen(false)
            model.isScanning = false
        }
        guard model.history.observations.contains(where: {
                  $0.folders.contains(where: { $0.path == rootPath && $0.logicalBytes == 16 })
              }),
              model.fileInventoryReports[rootPath]?.hasBaseline == false,
              model.rememberedScopes.contains(where: { $0.path == rootPath }) else {
            throw failure("DashboardModel did not restore the complete synthetic baseline and exact selected-root bookmark from its injected stores.")
        }
        model.storageMonitoringInterval = StorageMonitoringPolicy.minimumInterval
        model.toggleStorageMonitoring(rootPath, enabled: true)
        model.setStorageMonitoringSessionOpen(true)
        model.setStorageMonitoringAppActive(false)
        guard model.activeStorageEventWatcherPathsForTesting == [rootPath] else {
            throw failure("The opted-in synthetic root did not start an event watcher.")
        }

        model.setStorageMonitoringCooldownForTesting(
            rootPath, lastScanAt: Date.now.addingTimeInterval(-StorageMonitoringPolicy.minimumEventScanInterval - 1)
        )
        let addedPath = "event-growth.bin"
        try Data(repeating: 0x44, count: 8_192).write(to: root.appendingPathComponent(addedPath))
        try await waitUntil(timeout: 18) {
            !model.isScanning && model.fileInventoryReports[rootPath]?.changes.contains(where: {
                $0.relativePath == addedPath && $0.kind == .added
            }) == true
        }

        guard let eventReport = model.fileInventoryReports[rootPath],
              eventReport.hasBaseline,
              eventReport.netLogicalDelta == 8_192,
              eventReport.grossAllocatedGrowth ?? 0 > 0,
              let latestObservation = model.history.observations.last,
              let latestFolder = latestObservation.folders.first(where: { $0.path == rootPath }),
              latestFolder.complete,
              latestFolder.logicalBytes == 8_208,
              try FileInventoryStore.loadReports(at: inventoriesURL)[rootPath] == eventReport,
              try ObservationStore.load(from: observationsURL).observations.contains(where: {
                  $0.folders.contains(where: { $0.path == rootPath && $0.logicalBytes == 8_208 })
              }) else {
            throw failure("DashboardModel did not persist the exact complete event-triggered growth observation and report.")
        }

        model.setStorageMonitoringSessionOpen(false)
        let closedHistoryCount = try ObservationStore.load(from: observationsURL).observations.count
        try Data(repeating: 0x51, count: 64).write(to: root.appendingPathComponent("while-closed.bin"))
        try await Task.sleep(for: .seconds(1.5))
        guard model.activeStorageEventWatcherPathsForTesting.isEmpty,
              model.pendingStorageEventPathsForTesting.isEmpty,
              try ObservationStore.load(from: observationsURL).observations.count == closedHistoryCount else {
            throw failure("Closing the monitoring session did not leave the event history unchanged.")
        }

        model.toggleStorageMonitoring(rootPath, enabled: false)
        model.setStorageMonitoringSessionOpen(true)
        try Data(repeating: 0x52, count: 64).write(to: root.appendingPathComponent("while-opted-out.bin"))
        try await Task.sleep(for: .seconds(1.5))
        guard model.activeStorageEventWatcherPathsForTesting.isEmpty,
              model.pendingStorageEventPathsForTesting.isEmpty,
              try ObservationStore.load(from: observationsURL).observations.count == closedHistoryCount else {
            throw failure("Opt-out restored a watcher or recorded a scan of the synthetic root.")
        }

        model.toggleStorageMonitoring(rootPath, enabled: true)
        try await waitUntil(timeout: 18) {
            !model.isScanning && model.fileInventoryReports[rootPath]?.changes.contains(where: {
                $0.relativePath == "while-closed.bin" && $0.kind == .added
            }) == true && model.fileInventoryReports[rootPath]?.changes.contains(where: {
                $0.relativePath == "while-opted-out.bin" && $0.kind == .added
            }) == true
        }
        guard model.activeStorageEventWatcherPathsForTesting == [rootPath] else {
            throw failure("Re-opt-in did not restore the watcher after recording a fresh manual baseline.")
        }

        let scansBeforeScheduledRun = try ObservationStore.load(from: observationsURL).observations.count
        model.setStorageMonitoringCooldownForTesting(
            rootPath, lastScanAt: Date.now.addingTimeInterval(-model.storageMonitoringInterval - 1)
        )
        model.evaluateStorageMonitoringForTesting(at: .now)
        guard model.scheduledScanPath == rootPath else {
            throw failure("The due periodic monitoring decision did not start a DashboardModel scheduled scan.")
        }
        try await waitUntil(timeout: 18) {
            !model.isScanning && model.scheduledScanPath == nil
                && ((try? ObservationStore.load(from: observationsURL).observations.count) ?? 0)
                    > scansBeforeScheduledRun
        }
        guard let scheduledObservation = try ObservationStore.load(from: observationsURL).observations.last,
              scheduledObservation.folders.first(where: { $0.path == rootPath })?.complete == true,
              model.storageMonitoringLastAttempt[rootPath] != nil else {
            throw failure("The scheduled selected-root scan did not finish and persist a complete observation.")
        }

        model.setStorageMonitoringSessionOpen(false)
        model.isScanning = false
    }

    @MainActor
    private static func recordEvent(in root: URL, named name: String) throws {
        try Data([0x44, 0x69, 0x73, 0x6b, 0x65, 0x72]).write(to: root.appendingPathComponent(name))
    }

    @MainActor
    private static func waitUntil(timeout: TimeInterval, condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard condition() else {
            throw failure("The DashboardModel did not receive the expected synthetic filesystem event within \(timeout) seconds.")
        }
    }

    private func writeResult(_ value: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try (value + "\n").write(to: resultURL, atomically: true, encoding: .utf8)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Disker.DashboardModelMonitoringChecks", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}
#endif
