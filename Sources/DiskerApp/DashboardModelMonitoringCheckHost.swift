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
                    try await Self.runChecks()
                    try writeResult("PASS DashboardModel persists isolated opt-in, keeps the opted-in watcher active while the app is inactive and its window is open, stops it on close, honors opt-out, restores after opt-in, and blocks overlapping scans")
                } catch {
                    try? writeResult("FAIL \(error.localizedDescription)")
                }
                NSApplication.shared.terminate(nil)
            }
    }

    @MainActor
    private static func runChecks() async throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Disker-Dashboard-Monitoring-\(UUID().uuidString)", isDirectory: true)
        let root = stateDirectory.appendingPathComponent("SelectedRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let bookmarkURL = stateDirectory.appendingPathComponent("selected-scopes.json")
        let preferencesURL = stateDirectory.appendingPathComponent("storage-monitoring.json")
        let bookmarks = try SelectedScopeBookmarkStore.remember([root], at: bookmarkURL)
        let rootPath = root.standardizedFileURL.path

        // Fixture mode skips Disker's real local stores; no scan is started by this check.
        let model = DashboardModel(
            includeSnapshotProjectCandidate: true,
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
