#if DEBUG
import AppKit
import CryptoKit
import Darwin
@_spi(DiskerTesting) import DiskerCore
import SwiftUI

struct DashboardModelMonitoringCheckHost: View {
    let resultURL: URL
    @State private var hasStarted = false

    static func resultURL(from arguments: [String]) -> URL? {
        if let index = arguments.firstIndex(of: "--sandboxed-duplicate-verification-check"),
           arguments.indices.contains(index + 1),
           let runID = UUID(uuidString: arguments[index + 1]),
           let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return cachesDirectory
                .appendingPathComponent("DiskerDuplicateVerificationQA", isDirectory: true)
                .appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("result.txt")
        }
        if let index = arguments.firstIndex(of: "--sandboxed-app-footprint-check"),
           arguments.indices.contains(index + 1),
           let runID = UUID(uuidString: arguments[index + 1]),
           let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return cachesDirectory
                .appendingPathComponent("DiskerAppFootprintQA", isDirectory: true)
                .appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("result.txt")
        }
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
                    if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--sandboxed-duplicate-verification-check"),
                       ProcessInfo.processInfo.arguments.indices.contains(index + 1),
                       let runID = UUID(uuidString: ProcessInfo.processInfo.arguments[index + 1]) {
                        try await Self.runSandboxedDuplicateVerificationCheck(runID: runID)
                        try writeResult("PASS sandboxed duplicate verification, explicit content-read gate, and no-follow boundary")
                    } else if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--sandboxed-app-footprint-check"),
                       ProcessInfo.processInfo.arguments.indices.contains(index + 1),
                       let runID = UUID(uuidString: ProcessInfo.processInfo.arguments[index + 1]) {
                        try await Self.runSandboxedAppFootprintCheck(runID: runID)
                        try writeResult("PASS sandboxed app-owned footprint, no-follow scan, and path probes")
                    } else {
                        let runDirectory = resultURL.deletingLastPathComponent()
                        try await Self.runChecks(
                            stateDirectory: runDirectory.appendingPathComponent("lifecycle", isDirectory: true)
                        )
                        try await Self.runEventTriggeredScanCheck(
                            stateDirectory: runDirectory.appendingPathComponent("event-scan", isDirectory: true)
                        )
                        try await Self.runApplicationBundleMonitoringCheck(
                            stateDirectory: runDirectory.appendingPathComponent("application-bundle", isDirectory: true)
                        )
                        try writeResult("PASS DashboardModel monitor lifecycle, event-triggered growth scan, opt-out, re-opt-in baseline, scheduled scan, incomplete-root pause/resume, and app-profile retention with signature claims withheld during monitoring rescans")
                    }
                } catch {
                    try? writeResult("FAIL \(error.localizedDescription)")
                }
                NSApplication.shared.terminate(nil)
            }
    }

    @MainActor
    private static func runSandboxedAppFootprintCheck(runID: UUID) async throws {
        guard let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw failure("The sandbox did not provide an Application Support location.")
        }
        let supportDirectory = supportRoot
            .appendingPathComponent("DiskerAppFootprintQA", isDirectory: true)
            .appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
        let symlinkTarget = supportDirectory.deletingLastPathComponent()
            .appendingPathComponent("outside-support", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory.deletingLastPathComponent()) }
        try Data(repeating: 0x44, count: 128).write(to: supportDirectory.appendingPathComponent("fixture.bin"))
        try FileManager.default.createDirectory(at: symlinkTarget, withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: 4096).write(to: symlinkTarget.appendingPathComponent("must-not-count.bin"))
        try FileManager.default.createSymbolicLink(
            at: supportDirectory.appendingPathComponent("linked-outside"),
            withDestinationURL: symlinkTarget
        )

        let bundleURL = Bundle.main.bundleURL
        let observation = await Task.detached(priority: .utility) {
            DiskerFootprintScanner.scan(bundleURL: bundleURL, supportDirectory: supportDirectory)
        }.value
        guard let bundle = observation.folders.first(where: {
                  $0.path == bundleURL.standardizedFileURL.path
              }), bundle.complete else {
            let result = observation.folders.first(where: { $0.path == bundleURL.standardizedFileURL.path })
            let sandboxed = (try? SelectedScopeBookmarkStore.requiresSecurityScopedAccess()) ?? false
            throw failure(
                "The sandboxed QA app bundle was not measured completely "
                    + "(inaccessible: \(result?.inaccessibleCount ?? -1), "
                    + "symlinks: \(result?.excludedSymlinkCount ?? -1), "
                    + "sandbox entitlement: \(sandboxed), path: \(bundleURL.path), "
                    + "direct: \(Self.directPathDiagnostics(bundleURL.path)))."
            )
        }
        guard let support = observation.folders.first(where: {
                  $0.path == supportDirectory.standardizedFileURL.path
              }), !support.complete, support.inaccessibleCount == 0,
              support.excludedSymlinkCount == 1, support.fileCount == 1,
              support.logicalBytes == 128 else {
            let result = observation.folders.first(where: { $0.path == supportDirectory.standardizedFileURL.path })
            throw failure(
                "The sandboxed synthetic support root did not preserve the no-follow boundary "
                    + "(complete: \(result?.complete ?? false), "
                    + "inaccessible: \(result?.inaccessibleCount ?? -1), "
                    + "symlinks: \(result?.excludedSymlinkCount ?? -1), "
                    + "files: \(result?.fileCount ?? -1), logical: \(result?.logicalBytes ?? -1))."
            )
        }
        let unselectedPath = SelectedScopePathProbe.probe(at: supportDirectory.path)
        let presentPath = SelectedScopePathProbe.probe(selectedURL: supportDirectory)
        let missingPath = SelectedScopePathProbe.probe(
            selectedURL: supportDirectory.appendingPathComponent("not-present", isDirectory: true)
        )
        let symlinkPath = SelectedScopePathProbe.probe(
            selectedURL: supportDirectory.appendingPathComponent("linked-outside", isDirectory: true)
        )
        guard unselectedPath == .permissionOrAccessUnknown,
              presentPath.isAvailableDirectory,
              missingPath == .missingOrUnreachable,
              symlinkPath == .symbolicLink else {
            throw failure(
                "Sandboxed app-data path probes returned unexpected presence-only statuses "
                    + "(unselected: \(unselectedPath), present: \(presentPath), "
                    + "missing: \(missingPath), symlink: \(symlinkPath))."
            )
        }
    }

    @MainActor
    private static func runSandboxedDuplicateVerificationCheck(runID: UUID) async throws {
        guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw failure("The sandbox did not provide a Caches location for synthetic duplicate fixtures.")
        }
        let fixtureDirectory = cachesDirectory
            .appendingPathComponent("DiskerDuplicateVerificationFixtures", isDirectory: true)
            .appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
        let selectedRoot = fixtureDirectory.appendingPathComponent("SelectedRoot", isDirectory: true)
        let outsideRoot = fixtureDirectory.appendingPathComponent("OutsideRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let duplicateContents = Data("Disker synthetic sandbox duplicate fixture".utf8)
        let uniqueContents = Data("unique".utf8)
        let firstPath = selectedRoot.appendingPathComponent("first.bin").path
        let secondPath = selectedRoot.appendingPathComponent("second.bin").path
        try duplicateContents.write(to: URL(fileURLWithPath: firstPath))
        try duplicateContents.write(to: URL(fileURLWithPath: secondPath))
        try uniqueContents.write(to: selectedRoot.appendingPathComponent("unique.bin"))
        try duplicateContents.write(to: outsideRoot.appendingPathComponent("outside-copy.bin"))
        try FileManager.default.createSymbolicLink(
            at: selectedRoot.appendingPathComponent("outside-link.bin"),
            withDestinationURL: outsideRoot.appendingPathComponent("outside-copy.bin")
        )

        let originalContents = try Data(contentsOf: URL(fileURLWithPath: firstPath))
        var declinedEstimate: DuplicateVerificationReadEstimate?
        var declinedReadStarted = false
        let declined = DuplicateVerifier.verify(
            roots: [selectedRoot],
            simulatedDeviceIDsByPath: [:],
            scopedAccessGrantedByPath: [selectedRoot.standardizedFileURL.path],
            progress: { progress in
                if progress.phase == .readingContents { declinedReadStarted = true }
            },
            authorizeContentRead: { estimate in
                declinedEstimate = estimate
                return false
            }
        )
        guard declined.cancelled, declined.groups.isEmpty, declined.checkedFileCount == 0,
              !declinedReadStarted,
              let declinedEstimate,
              declinedEstimate.selectedRootPaths == [selectedRoot.standardizedFileURL.path],
              declinedEstimate.candidateFileCount == 2,
              declinedEstimate.candidateBytes == UInt64(duplicateContents.count * 2),
              declinedEstimate.excludedSymlinkCount == 1,
              !declinedEstimate.metadataCoverageComplete else {
            throw failure(
                "Declining synthetic content-read consent did not stop before hashing with honest coverage "
                    + "(cancelled: \(declined.cancelled), groups: \(declined.groups.count), "
                    + "checked: \(declined.checkedFileCount), readStarted: \(declinedReadStarted), "
                    + "roots: \(declinedEstimate?.selectedRootPaths ?? []), "
                    + "candidates: \(declinedEstimate?.candidateFileCount ?? -1), "
                    + "bytes: \(declinedEstimate?.candidateBytes ?? 0), "
                    + "symlinks: \(declinedEstimate?.excludedSymlinkCount ?? -1), "
                    + "coverage: \(declinedEstimate?.metadataCoverageComplete ?? true), "
                    + "entries: \(declinedEstimate?.entriesVisited ?? declined.checkedFileCount), "
                    + "inaccessible: \(declined.inaccessibleCount), symlinksFound: \(declined.excludedSymlinkCount), "
                    + "special: \(declined.excludedSpecialFileCount), volumes: \(declined.excludedVolumeBoundaryCount), "
                    + "rootExists: \(FileManager.default.fileExists(atPath: selectedRoot.path)), root: \(selectedRoot.path))."
            )
        }

        var authorizedEstimate: DuplicateVerificationReadEstimate?
        var contentReadStarted = false
        let verified = DuplicateVerifier.verify(
            roots: [selectedRoot],
            simulatedDeviceIDsByPath: [:],
            scopedAccessGrantedByPath: [selectedRoot.standardizedFileURL.path],
            progress: { progress in
                if progress.phase == .readingContents && progress.bytesHashed > 0 {
                    contentReadStarted = true
                }
            },
            authorizeContentRead: { estimate in
                authorizedEstimate = estimate
                return estimate.selectedRootPaths == [selectedRoot.standardizedFileURL.path]
                    && estimate.candidateFileCount == 2
                    && estimate.candidateBytes == UInt64(duplicateContents.count * 2)
                    && estimate.excludedSymlinkCount == 1
            }
        )
        let expectedHash = SHA256.hash(data: duplicateContents)
            .map { String(format: "%02x", $0) }
            .joined()
        guard contentReadStarted,
              authorizedEstimate?.candidateFileCount == 2,
              verified.cancelled == false, verified.complete == false,
              verified.checkedFileCount == 2,
              verified.inaccessibleCount == 0, verified.excludedSymlinkCount == 1,
              verified.excludedSpecialFileCount == 0,
              verified.excludedVolumeBoundaryCount == 0, verified.changedDuringCheckCount == 0,
              verified.groups.count == 1,
              verified.groups[0].sha256 == expectedHash,
              Set(verified.groups[0].files.map(\.path)) == Set([firstPath, secondPath]),
              verified.groups[0].files.allSatisfy({ $0.logicalBytes == Int64(duplicateContents.count) }),
              try Data(contentsOf: URL(fileURLWithPath: firstPath)) == originalContents,
              try Data(contentsOf: URL(fileURLWithPath: secondPath)) == originalContents,
              try Data(contentsOf: outsideRoot.appendingPathComponent("outside-copy.bin")) == originalContents else {
            throw failure("Sandboxed duplicate hashing failed, escaped the selected root, altered a fixture, or overstated coverage.")
        }
    }

    private static func directPathDiagnostics(_ path: String) -> String {
        var components = ""
        var ancestors: [String] = []
        for component in path.split(separator: "/") {
            components += "/" + component
            var metadata = stat()
            let status = components.withCString { lstat($0, &metadata) }
            ancestors.append("\(components)=\(status == 0 ? "ok" : String(errno))")
        }
        let descriptor = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        let opened = descriptor >= 0 ? "ok" : String(errno)
        if descriptor >= 0 { close(descriptor) }
        return "lstat[\(ancestors.joined(separator: ","))],open=\(opened)"
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
            storeURLs: DashboardModelStoreURLs(
                observations: observationsURL,
                fileInventory: inventoriesURL,
                selectedScopeBookmarks: bookmarkURL,
                storageMonitoringPreferences: preferencesURL
            )
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
        let pausedRoot = stateDirectory.appendingPathComponent("PausedRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pausedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let baselinePath = root.appendingPathComponent("baseline.bin")
        try Data(repeating: 0x42, count: 16).write(to: baselinePath)
        let unmeasuredTarget = stateDirectory.appendingPathComponent("outside-scope.bin")
        try Data(repeating: 0x4A, count: 256).write(to: unmeasuredTarget)
        let rejectedLink = pausedRoot.appendingPathComponent("excluded-link")
        try FileManager.default.createSymbolicLink(at: rejectedLink, withDestinationURL: unmeasuredTarget)

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
        _ = try SelectedScopeBookmarkStore.remember([root, pausedRoot], at: bookmarksURL)

        // Every on-disk dependency uses this test-owned directory.
        let model = DashboardModel(
            storeURLs: DashboardModelStoreURLs(
                observations: observationsURL,
                fileInventory: inventoriesURL,
                selectedScopeBookmarks: bookmarksURL,
                storageMonitoringPreferences: preferencesURL
            )
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

        let pausedRootPath = pausedRoot.standardizedFileURL.path
        model.toggleStorageMonitoring(pausedRootPath, enabled: true)
        try await waitUntil(timeout: 18) {
            !model.isScanning
                && model.fileInventoryReports[pausedRootPath] != nil
                && model.history.observations.contains(where: {
                    $0.folders.contains(where: {
                        $0.path == pausedRootPath && !$0.complete && $0.fileCount == 0
                            && $0.logicalBytes == 0 && $0.excludedSymlinkCount == 1
                    })
                })
        }
        guard model.fileInventoryReports[pausedRootPath]?.hasBaseline == false,
              model.activeStorageEventWatcherPathsForTesting.contains(pausedRootPath) else {
            throw failure("The incomplete synthetic root did not save its isolated baseline and start opted-in monitoring.")
        }

        model.setStorageMonitoringCooldownForTesting(rootPath, lastScanAt: .now)
        model.setStorageMonitoringCooldownForTesting(pausedRootPath, lastScanAt: .distantPast)
        model.evaluateStorageMonitoringForTesting(at: .now)
        guard model.scheduledScanPath == pausedRootPath else {
            throw failure("The due incomplete synthetic root was not selected for its scheduled scan.")
        }
        try await waitUntil(timeout: 18) {
            !model.isScanning && model.scheduledScanPath == nil
                && model.pausedMonitoringReasons[pausedRootPath] != nil
        }
        guard !model.activeStorageEventWatcherPathsForTesting.contains(pausedRootPath) else {
            throw failure("A scheduled scan with no measured files left an incomplete root watched instead of pausing it.")
        }

        try FileManager.default.removeItem(at: rejectedLink)
        let resumedPath = "measured-after-resume.bin"
        try Data(repeating: 0x53, count: 128).write(to: pausedRoot.appendingPathComponent(resumedPath))
        model.resumeStorageMonitoring(pausedRootPath)
        try await waitUntil(timeout: 18) {
            !model.isScanning
                && model.pausedMonitoringReasons[pausedRootPath] == nil
                && model.activeStorageEventWatcherPathsForTesting.contains(pausedRootPath)
                && model.fileInventoryReports[pausedRootPath]?.changes.contains(where: {
                    $0.relativePath == resumedPath && $0.kind == .added
                }) == true
        }
        guard let resumedReport = model.fileInventoryReports[pausedRootPath],
              resumedReport.hasBaseline,
              resumedReport.netLogicalDelta == 128,
              resumedReport.symlinkExcludedCount == 0,
              resumedReport.changes.contains(where: {
                  $0.relativePath == resumedPath && $0.kind == .added
              }),
              model.history.observations.contains(where: {
                  $0.folders.contains(where: {
                      $0.path == pausedRootPath && $0.complete && $0.logicalBytes == 128
                  })
              }) else {
            throw failure("Resume did not restore the exact same-root file comparison after the excluded symlink was removed.")
        }

        model.setStorageMonitoringSessionOpen(false)
        model.isScanning = false
    }

    @MainActor
    private static func runApplicationBundleMonitoringCheck(stateDirectory: URL) async throws {
        let bundleURL = stateDirectory.appendingPathComponent("Workflow Demo.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleIdentifier": "com.example.DiskerMonitoringWorkflow",
            "CFBundleName": "Workflow Demo",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        let initialResource = resourcesURL.appendingPathComponent("baseline.dat")
        try Data(repeating: 0x41, count: 256).write(to: initialResource)
        guard let identity = ApplicationBundleMetadata.identity(fromSelectedBundleAt: bundleURL) else {
            throw failure("The synthetic application bundle did not expose its local Bundle ID.")
        }

        let observationsURL = stateDirectory.appendingPathComponent("observations.json")
        let inventoriesURL = stateDirectory.appendingPathComponent("file-inventory.plist")
        let bookmarksURL = stateDirectory.appendingPathComponent("selected-scopes.json")
        let preferencesURL = stateDirectory.appendingPathComponent("storage-monitoring.json")
        let rootPath = bundleURL.standardizedFileURL.path
        let initialScan = FolderScanner.scanWithFileInventories(roots: [bundleURL])
        guard let initialFolder = initialScan.observation.folders.first,
              initialFolder.complete,
              let initialInventory = initialScan.fileInventories.first else {
            throw failure("The synthetic application bundle did not create a complete baseline.")
        }
        let selectedBundleBaseline = initialScan.observation.includingApplicationBundleIdentities(
            [rootPath: ApplicationBundleIdentity(
                bundleIdentifier: identity.bundleIdentifier,
                claimedGroupIdentifiers: ["TEAM.synthetic.shared"],
                signatureValidated: true,
                signedBundleIdentifier: identity.bundleIdentifier
            )], selectedApplicationBundlePaths: [rootPath]
        )
        _ = try ObservationStore.append(selectedBundleBaseline, to: observationsURL)
        _ = try FileInventoryStore.recordWithTrendPoints(initialInventory, at: inventoriesURL)
        let bookmarks = try SelectedScopeBookmarkStore.remember([bundleURL], at: bookmarksURL)
        let model = DashboardModel(
            storeURLs: DashboardModelStoreURLs(
                observations: observationsURL,
                fileInventory: inventoriesURL,
                selectedScopeBookmarks: bookmarksURL,
                storageMonitoringPreferences: preferencesURL
            )
        )
        defer {
            model.setStorageMonitoringSessionOpen(false)
            model.isScanning = false
        }
        model.rememberedScopes = bookmarks
        model.storageMonitoringInterval = StorageMonitoringPolicy.minimumInterval
        model.setStorageMonitoringSessionOpen(true)
        model.toggleStorageMonitoring(rootPath, enabled: true)
        try await waitUntil(timeout: 18) { !model.isScanning }
        guard let manualBaseline = model.latestFolderObservation(at: rootPath) else {
            throw failure("The monitoring baseline for the synthetic application path was not saved.")
        }
        let identityState = [
            "selected=\(manualBaseline.selectedAsApplicationBundle)",
            "bundleID=\(String(describing: manualBaseline.applicationBundleIdentifier))",
            "groups=\(manualBaseline.applicationGroupIdentifiers.count)",
            "signature=\(manualBaseline.applicationSignatureValidated)",
            "signedID=\(String(describing: manualBaseline.applicationSignedBundleIdentifier))",
        ].joined(separator: ", ")
        guard manualBaseline.selectedAsApplicationBundle,
              manualBaseline.applicationBundleIdentifier == nil,
              manualBaseline.applicationGroupIdentifiers.isEmpty,
              !manualBaseline.applicationSignatureValidated,
              manualBaseline.applicationSignedBundleIdentifier == nil else {
            throw failure("The metadata-only monitoring baseline lost the selected path marker or retained stale signature and group claims (\(identityState)).")
        }

        model.setStorageMonitoringAppActive(false)
        guard model.activeStorageEventWatcherPathsForTesting == [rootPath] else {
            throw failure("The opted-in selected application path did not start its authorized event watcher.")
        }
        model.setStorageMonitoringCooldownForTesting(
            rootPath, lastScanAt: .now.addingTimeInterval(-StorageMonitoringPolicy.minimumEventScanInterval - 1)
        )
        let addedPath = "Contents/Resources/after-baseline.dat"
        try Data(repeating: 0x42, count: 8_192).write(
            to: bundleURL.appendingPathComponent(addedPath)
        )
        try await waitUntil(timeout: 18) {
            !model.isScanning && model.fileInventoryReports[rootPath]?.changes.contains(where: {
                $0.relativePath == addedPath && $0.kind == .added
            }) == true
        }

        guard let report = model.fileInventoryReports[rootPath],
              report.hasBaseline,
              report.netLogicalDelta == 8_192,
              let latestBundle = model.latestFolderObservation(at: rootPath),
              latestBundle.complete,
              latestBundle.selectedAsApplicationBundle,
              latestBundle.applicationBundleIdentifier == nil,
              latestBundle.applicationGroupIdentifiers.isEmpty,
              !latestBundle.applicationSignatureValidated,
              latestBundle.applicationSignedBundleIdentifier == nil,
              ApplicationBundleIndex.latestMeasurements(in: model.history).first(where: { $0.path == rootPath }) == latestBundle,
              ApplicationFootprintReview.make(
                  forBundlePath: rootPath, in: model.history, homeDirectoryPath: stateDirectory.path
              ).entries.first?.observation == latestBundle else {
            throw failure("An event-triggered app-bundle growth scan lost its selected identity or profile measurement.")
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
