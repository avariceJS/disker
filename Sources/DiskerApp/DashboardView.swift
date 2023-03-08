import AppKit
import Charts
import DiskerCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class DashboardModel {
    var capacity: CapacityObservation?
    var ram: RAMObservation?
    var history = LocalHistory()
    var isScanning = false
    var isSamplingRAM = false
    var isAppActive = false
    var duplicateResult: DuplicateVerificationResult?
    var isVerifyingDuplicates = false
    var duplicateProgressPhase: DuplicateVerificationPhase = .readingMetadata
    var duplicateCurrentPath = ""
    var duplicateEntriesVisited = 0
    var duplicateBytesHashed: UInt64 = 0
    var duplicateCandidateFileCount = 0
    var duplicateCandidateBytes: UInt64 = 0
    var preservedDuplicatePaths: [String: String] = [:]
    var rememberedScopes: [SelectedScopeBookmark] = []
    var monitoredScopePaths = Set<String>()
    var pausedMonitoringReasons: [String: String] = [:]
    var storageMonitoringInterval: TimeInterval = StorageMonitoringPolicy.defaultInterval
    var storageMonitoringLastAttempt: [String: Date] = [:]
    var ownFootprint: ScanObservation?
    var ownFootprintPaths: [String] = []
    var isMeasuringOwnFootprint = false
    var applicationBundlePathAvailability: [String: Bool] = [:]
    var checkingApplicationBundlePaths = Set<String>()
    private var applicationBundlePathCheckIDs: [String: UUID] = [:]
    var errorMessage: String?
    var currentPath = ""
    var countedFileObjects = 0
    private var scanTask: Task<ScanObservation, Never>?
    enum ScanOrigin { case manual, scheduled }
    private var scanOrigin: ScanOrigin?
    private var scanRootPaths = Set<String>()
    var scheduledScanPath: String?
    private var storageMonitoringEnabledAtByPath: [String: Date] = [:]
    private var storageMonitoringCooldownByPath: [String: Date] = [:]
    private var storageMonitoringTask: Task<Void, Never>?
    private var historyGeneration = HistoryGeneration()
    private var ownFootprintTask: Task<ScanObservation, Never>?
    private var ownFootprintRequestID: UUID?
    private var ramSampleTask: Task<Void, Never>?
    private var duplicateTask: Task<DuplicateVerificationResult, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init() {
        do {
            history = try ObservationStore.load()
            ram = history.ramObservations.last
        } catch {
            errorMessage = error.localizedDescription
        }
        do {
            rememberedScopes = try SelectedScopeBookmarkStore.load()
        } catch {
            errorMessage = "Saved scan locations could not be loaded: \(error.localizedDescription)"
        }
    }

    var latestScan: ScanObservation? { history.observations.last }

    var localSupportDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Disker", isDirectory: true)
    }

    var measuredApplicationBundles: [FolderObservation] {
        ApplicationBundleIndex.latestMeasurements(in: history)
    }

    func scanWasCancelled(for folder: FolderObservation) -> Bool {
        history.observations.last(where: { observation in
            observation.folders.contains(where: { $0.id == folder.id })
        })?.cancelled ?? false
    }

    func relatedFolders(for bundlePath: String) -> [String] {
        history.applicationAssociations.first(where: { $0.bundlePath == bundlePath })?.relatedFolderPaths ?? []
    }

    func applicationFootprintReview(for bundle: FolderObservation) -> ApplicationFootprintReview {
        ApplicationFootprintReview.make(
            for: bundle, in: history, homeDirectoryPath: NSHomeDirectory()
        )
    }

    func checkApplicationBundlePath(_ path: String) {
        guard checkingApplicationBundlePaths.insert(path).inserted else { return }
        let requestID = UUID()
        applicationBundlePathCheckIDs[path] = requestID
        applicationBundlePathAvailability.removeValue(forKey: path)
        let generation = historyGeneration.token()
        let expectedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let bookmark = rememberedScopes.first(where: { $0.path == expectedPath })
        let task = Task.detached(priority: .utility) {
            SelectedScopePathProbe.isAvailable(at: path, using: bookmark)
        }
        Task {
            let isAvailable = await task.value
            guard applicationBundlePathCheckIDs[path] == requestID,
                  historyGeneration.accepts(generation) else { return }
            applicationBundlePathCheckIDs.removeValue(forKey: path)
            checkingApplicationBundlePaths.remove(path)
            applicationBundlePathAvailability[path] = isAvailable
        }
    }

    func applicationBundleIdentifier(for bundlePath: String) -> String? {
        history.observations.reversed().lazy
            .flatMap(\.folders)
            .first(where: { $0.path == bundlePath })?
            .applicationBundleIdentifier
    }

    func latestFolderObservation(at path: String) -> FolderObservation? {
        history.observations.reversed().lazy
            .flatMap(\.folders)
            .first(where: { $0.path == path })
    }

    func refreshCapacity() {
        do {
            let sample = try CapacityObservation.current()
            capacity = sample
            do {
                history = try ObservationStore.append(sample)
            } catch {
                errorMessage = "Capacity is current, but local history could not be saved: \(error.localizedDescription)"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func measureOwnFootprint() {
        guard !isMeasuringOwnFootprint, !isScanning, !isVerifyingDuplicates else { return }
        let bundleURL = Bundle.main.bundleURL
        let supportDirectory = localSupportDirectory

        let requestID = UUID()
        ownFootprintRequestID = requestID
        isMeasuringOwnFootprint = true
        let task = Task.detached(priority: .utility) {
            DiskerFootprintScanner.scan(
                bundleURL: bundleURL,
                supportDirectory: supportDirectory
            )
        }
        ownFootprintTask = task
        Task {
            let result = await task.value
            guard ownFootprintRequestID == requestID else { return }
            ownFootprint = result
            ownFootprintPaths = result.folders.map(\.path)
            isMeasuringOwnFootprint = false
            ownFootprintTask = nil
        }
    }

    func refreshRAM() {
        guard !isSamplingRAM else { return }
        isSamplingRAM = true
        ramSampleTask = Task {
            defer {
                isSamplingRAM = false
                ramSampleTask = nil
            }
            do {
                let sample = try await Task.detached(priority: .utility) {
                    try RAMObservation.current()
                }.value
                guard !Task.isCancelled else { return }
                ram = sample
                do {
                    history = try ObservationStore.append(sample)
                } catch {
                    errorMessage = "RAM sample completed, but local history could not be saved: \(error.localizedDescription)"
                }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    func updateMemoryPressureMonitoring(enabled: Bool, appIsActive: Bool) {
        guard RAMMonitoringPolicy.shouldObservePressure(
            enabled: enabled, appIsActive: appIsActive
        ) else {
            memoryPressureSource?.setEventHandler {}
            memoryPressureSource?.cancel()
            memoryPressureSource = nil
            return
        }
        guard memoryPressureSource == nil else { return }

        let generation = historyGeneration.token()
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let source,
                  let level = MemoryPressureLevel.from(events: source.data) else { return }
            self?.recordMemoryPressureTransition(level, generation: generation)
        }
        memoryPressureSource = source
        source.resume()
    }

    private func recordMemoryPressureTransition(
        _ level: MemoryPressureLevel, generation: HistoryGeneration.Token
    ) {
        guard historyGeneration.accepts(generation) else { return }
        let observation = MemoryPressureObservation(observedAt: .now, level: level)
        do {
            history = try ObservationStore.append(observation)
        } catch {
            errorMessage = "A system pressure transition was observed, but local history could not be saved: \(error.localizedDescription)"
        }
    }

    func chooseFolders(startingAt directory: URL? = nil) {
        guard !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose folders to measure"
        panel.prompt = "Scan Folders"
        panel.message = "Choose up to 50 folders. Disker reads file metadata in the folders you select; file contents are not opened."
        panel.directoryURL = directory
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }
        guard panel.urls.count <= ApplicationFolderAssociation.maximumRelatedFolderCount else {
            errorMessage = "A scan can include at most 50 selected folders. Reduce the selection and try again."
            return
        }
        rememberFolders(panel.urls)
        scan(panel.urls)
    }

    func chooseApplicationBundle(startingAt directory: URL? = nil) {
        guard !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an application bundle to measure"
        panel.prompt = "Measure Bundle"
        panel.message = "Disker measures only the selected .app bundle. Signature validation reads its signed executable and resources locally, in addition to the declared bundle ID and App Groups claim. It does not verify notarization or current use; group data is shared. No file contents are uploaded."
        panel.directoryURL = directory
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let bundleURL = panel.urls.first else { return }
        applicationBundlePathCheckIDs.removeValue(forKey: bundleURL.path)
        checkingApplicationBundlePaths.remove(bundleURL.path)
        applicationBundlePathAvailability[bundleURL.path] = true
        rememberFolders([bundleURL])
        scan([bundleURL], inspectSelectedAppBundles: true)
    }

    func chooseRelatedFolders(for bundlePath: String, startingAt directory: URL? = nil) {
        guard !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose folders associated with this app"
        panel.prompt = "Associate and Scan"
        panel.message = "Choose up to 50 folders to associate. Exact container paths may match the selected app's bundle ID or App Groups claim. Disker checks the app's local code signature but does not verify notarization, current use, or exclusive ownership; group data is shared and measurements stay separate."
        panel.directoryURL = directory
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            history = try ObservationStore.associateApplicationFolders(
                panel.urls.map(\.path), with: bundlePath,
                bundleIdentifier: applicationBundleIdentifier(for: bundlePath)
            )
            rememberFolders(panel.urls)
            scan(panel.urls)
        } catch {
            errorMessage = "Folders were selected, but their association could not be saved: \(error.localizedDescription)"
        }
    }

    func removeRelatedFolder(_ path: String, from bundlePath: String) {
        do {
            history = try ObservationStore.removeApplicationFolderAssociation(path, from: bundlePath)
        } catch {
            errorMessage = "The saved folder association could not be removed: \(error.localizedDescription)"
        }
    }

    private func rememberFolders(_ urls: [URL]) {
        do {
            rememberedScopes = try SelectedScopeBookmarkStore.remember(urls)
        } catch {
            errorMessage = "The scan can continue, but Disker could not save a reusable read-only location: \(error.localizedDescription)"
        }
    }

    func rescanRememberedFolder(_ path: String) {
        rescanRememberedFolder(path, origin: .manual)
    }

    private func rescanRememberedFolder(_ path: String, origin: ScanOrigin) {
        guard !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        guard let bookmark = rememberedScopes.first(where: { $0.path == path }) else {
            if origin == .scheduled {
                pauseStorageMonitoring(path, reason: "Saved access is missing. Select this folder again before resuming.")
            }
            return
        }
        do {
            let url = try SelectedScopeBookmarkStore.resolve(bookmark)
            do {
                rememberedScopes = try SelectedScopeBookmarkStore.load()
            } catch {
                errorMessage = "The folder is available for this scan, but saved locations could not be refreshed: \(error.localizedDescription)"
            }
            scan([url], origin: origin)
        } catch {
            if origin == .scheduled {
                pauseStorageMonitoring(path, reason: "Saved access needs attention. Choose this folder again, then resume monitoring.")
            }
            errorMessage = error.localizedDescription
        }
    }

    func rescanAssociatedFolder(_ path: String) {
        guard !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        if rememberedScopes.contains(where: { $0.path == path }) {
            rescanRememberedFolder(path)
            return
        }

        let selectedURL = URL(fileURLWithPath: path, isDirectory: true)
        let panel = NSOpenPanel()
        panel.title = "Re-select Associated Folder"
        panel.prompt = "Rescan Folder"
        panel.message = "Select this exact folder to measure it again and save read-only access for later scans."
        panel.directoryURL = selectedURL.deletingLastPathComponent()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let chosenURL = panel.urls.first else { return }
        guard chosenURL.standardizedFileURL.path == selectedURL.standardizedFileURL.path else {
            errorMessage = "Choose the same associated folder to keep its history comparable. No scan was started."
            return
        }
        rememberFolders([chosenURL])
        scan([chosenURL])
    }

    func forgetRememberedFolder(_ path: String) {
        do {
            rememberedScopes = try SelectedScopeBookmarkStore.remove(path: path)
            removeStorageMonitoringState(for: path)
        } catch {
            errorMessage = "The saved folder could not be forgotten: \(error.localizedDescription)"
        }
    }

    func scan(
        _ urls: [URL], applicationBundleIdentities: [String: ApplicationBundleIdentity] = [:],
        inspectSelectedAppBundles: Bool = false, origin: ScanOrigin = .manual
    ) {
        guard !urls.isEmpty, !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        guard urls.count <= ApplicationFolderAssociation.maximumRelatedFolderCount else {
            errorMessage = "A scan can include at most 50 selected folders. Reduce the selection and try again."
            return
        }
        isScanning = true
        scanOrigin = origin
        scanRootPaths = Set(urls.map { $0.standardizedFileURL.path })
        if origin == .scheduled, let onlyPath = scanRootPaths.first {
            scheduledScanPath = onlyPath
        } else {
            scheduledScanPath = nil
        }
        let generation = historyGeneration.token()
        currentPath = ""
        countedFileObjects = 0
        let scanTask = Task.detached(priority: .utility) {
            var identities = applicationBundleIdentities
            let selectedApplicationBundlePaths = inspectSelectedAppBundles
                ? Set(urls.filter { $0.pathExtension.lowercased() == "app" }.map(\.path))
                : []
            if inspectSelectedAppBundles {
                for url in urls where url.pathExtension.lowercased() == "app" {
                    let accessGranted = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessGranted { url.stopAccessingSecurityScopedResource() }
                    }
                    if let identity = ApplicationBundleMetadata.identity(fromSelectedBundleAt: url) {
                        identities[url.path] = identity
                    }
                }
            }
            let observation = FolderScanner.scan(roots: urls, progress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.historyGeneration.accepts(generation) else { return }
                    self.currentPath = progress.currentPath
                    self.countedFileObjects = progress.countedFileObjects
                }
            })
            return observation.includingApplicationBundleIdentities(
                identities, selectedApplicationBundlePaths: selectedApplicationBundlePaths
            )
        }
        self.scanTask = scanTask
        Task {
            let result = await scanTask.value
            if historyGeneration.accepts(generation) {
                do {
                    history = try ObservationStore.append(result)
                } catch {
                    errorMessage = "Scan finished, but local history could not be saved: \(error.localizedDescription)"
                }
            }
            let completedOrigin = scanOrigin
            let completedRootPaths = scanRootPaths
            let completedScheduledPath = scheduledScanPath
            if let completedScheduledPath {
                if !monitoredScopePaths.contains(completedScheduledPath) {
                    storageMonitoringCooldownByPath.removeValue(forKey: completedScheduledPath)
                    storageMonitoringLastAttempt.removeValue(forKey: completedScheduledPath)
                } else if result.cancelled && isAppActive {
                    pauseStorageMonitoring(completedScheduledPath, reason: "Scheduled scan cancelled. Resume monitoring when ready.")
                } else {
                    storageMonitoringCooldownByPath[completedScheduledPath] = .now
                }
            } else if completedOrigin == .manual {
                for path in completedRootPaths.intersection(monitoredScopePaths) {
                    if result.cancelled {
                        pauseStorageMonitoring(path, reason: "Scan cancelled. Resume monitoring when ready.")
                    } else {
                        storageMonitoringCooldownByPath[path] = .now
                    }
                }
            }
            isScanning = false
            currentPath = ""
            countedFileObjects = 0
            self.scanTask = nil
            scanOrigin = nil
            scanRootPaths = []
            scheduledScanPath = nil
            if historyGeneration.accepts(generation) { refreshCapacity() }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    func toggleStorageMonitoring(_ path: String, enabled: Bool) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard rememberedScopes.contains(where: { $0.path == normalizedPath }) else { return }
        if enabled {
            monitoredScopePaths.insert(normalizedPath)
            pausedMonitoringReasons.removeValue(forKey: normalizedPath)
            storageMonitoringEnabledAtByPath[normalizedPath] = .now
            storageMonitoringCooldownByPath[normalizedPath] = .now
            startStorageMonitoringScheduler()
        } else {
            monitoredScopePaths.remove(normalizedPath)
            pausedMonitoringReasons.removeValue(forKey: normalizedPath)
            storageMonitoringEnabledAtByPath.removeValue(forKey: normalizedPath)
            storageMonitoringCooldownByPath.removeValue(forKey: normalizedPath)
            if scheduledScanPath == normalizedPath { cancelScan() }
            if monitoredScopePaths.isEmpty { stopStorageMonitoringScheduler() }
        }
    }

    func resumeStorageMonitoring(_ path: String) {
        guard rememberedScopes.contains(where: { $0.path == path }) else { return }
        pausedMonitoringReasons.removeValue(forKey: path)
        monitoredScopePaths.insert(path)
        storageMonitoringEnabledAtByPath[path] = .now
        storageMonitoringCooldownByPath[path] = .now
        startStorageMonitoringScheduler()
    }

    func setStorageMonitoringInterval(_ interval: TimeInterval) {
        let clamped = max(StorageMonitoringPolicy.minimumInterval, interval)
        guard clamped != storageMonitoringInterval else { return }
        storageMonitoringInterval = clamped
        let now = Date.now
        for path in monitoredScopePaths where pausedMonitoringReasons[path] == nil {
            storageMonitoringCooldownByPath[path] = now
        }
    }

    func storageMonitoringNextEligibleDate(for path: String) -> Date? {
        guard monitoredScopePaths.contains(path), pausedMonitoringReasons[path] == nil else { return nil }
        let anchor = storageMonitoringCooldownByPath[path] ?? storageMonitoringEnabledAtByPath[path]
        return anchor?.addingTimeInterval(storageMonitoringInterval)
    }

    func startStorageMonitoringScheduler() {
        guard monitoredScopePaths.contains(where: { pausedMonitoringReasons[$0] == nil }),
              isAppActive, storageMonitoringTask == nil else { return }
        storageMonitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.evaluateStorageMonitoring()
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    func stopStorageMonitoringScheduler() {
        storageMonitoringTask?.cancel()
        storageMonitoringTask = nil
    }

    func setStorageMonitoringAppActive(_ active: Bool) {
        let wasActive = isAppActive
        isAppActive = active
        if active {
            if !wasActive {
                for path in monitoredScopePaths where pausedMonitoringReasons[path] == nil {
                    storageMonitoringCooldownByPath[path] = .now
                }
            }
            startStorageMonitoringScheduler()
        } else {
            stopStorageMonitoringScheduler()
            if let path = scheduledScanPath {
                cancelScan()
                storageMonitoringCooldownByPath[path] = .now
            }
        }
    }

    private func evaluateStorageMonitoring(at now: Date = .now) {
        let decision = StorageMonitoringPolicy.evaluate(
            StorageMonitoringPolicy.Input(
                enabled: !monitoredScopePaths.isEmpty,
                interval: storageMonitoringInterval,
                enabledAt: monitoredScopePaths.compactMap { storageMonitoringEnabledAtByPath[$0] }.min() ?? .distantFuture,
                appIsActive: isAppActive,
                globalScanInProgress: isScanning || isMeasuringOwnFootprint || isVerifyingDuplicates,
                savedRootIdentifiers: Set(rememberedScopes.map(\.path)),
                selectedRootIdentifiers: monitoredScopePaths,
                pausedRootIdentifiers: Set(pausedMonitoringReasons.keys),
                scheduledScanRootIdentifiers: scheduledScanPath.map { Set([$0]) } ?? [],
                lastScheduledStartByRoot: storageMonitoringCooldownByPath
            ),
            at: now
        )
        for path in decision.cancelScheduledRootIdentifiers where scheduledScanPath == path {
            cancelScan()
        }
        guard let path = decision.nextScheduledRootIdentifier else { return }
        storageMonitoringCooldownByPath[path] = now
        storageMonitoringLastAttempt[path] = now
        rescanRememberedFolder(path, origin: .scheduled)
    }

    private func pauseStorageMonitoring(_ path: String, reason: String) {
        monitoredScopePaths.insert(path)
        pausedMonitoringReasons[path] = reason
        if scheduledScanPath == path { cancelScan() }
        if !monitoredScopePaths.contains(where: { pausedMonitoringReasons[$0] == nil }) {
            stopStorageMonitoringScheduler()
        }
    }

    private func removeStorageMonitoringState(for path: String) {
        monitoredScopePaths.remove(path)
        pausedMonitoringReasons.removeValue(forKey: path)
        storageMonitoringEnabledAtByPath.removeValue(forKey: path)
        storageMonitoringCooldownByPath.removeValue(forKey: path)
        storageMonitoringLastAttempt.removeValue(forKey: path)
        if scheduledScanPath == path { cancelScan() }
        if monitoredScopePaths.isEmpty { stopStorageMonitoringScheduler() }
    }

    func verifyDuplicates(in roots: [URL]) {
        guard !roots.isEmpty, !isVerifyingDuplicates, !isScanning, !isMeasuringOwnFootprint else { return }
        guard roots.count <= DuplicateVerifier.maximumSelectedRootCount else {
            errorMessage = "Choose no more than \(DuplicateVerifier.maximumSelectedRootCount) locations for duplicate verification. No file contents were read."
            return
        }
        duplicateResult = nil
        preservedDuplicatePaths = [:]
        duplicateProgressPhase = .readingMetadata
        duplicateCurrentPath = ""
        duplicateEntriesVisited = 0
        duplicateBytesHashed = 0
        duplicateCandidateFileCount = 0
        duplicateCandidateBytes = 0
        isVerifyingDuplicates = true
        let task = Task.detached(priority: .utility) { [weak self] in
            DuplicateVerifier.verify(roots: roots, progress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.duplicateProgressPhase = progress.phase
                    self?.duplicateCurrentPath = progress.currentPath
                    self?.duplicateEntriesVisited = progress.entriesVisited
                    self?.duplicateBytesHashed = progress.bytesHashed
                    self?.duplicateCandidateFileCount = progress.candidateFileCount
                    self?.duplicateCandidateBytes = progress.candidateBytes
                }
            }, authorizeContentRead: { [weak self] estimate in
                guard let self else { return false }
                return DispatchQueue.main.sync {
                    self.confirmDuplicateContentRead(estimate, in: roots)
                }
            })
        }
        duplicateTask = task
        Task {
            duplicateResult = await task.value
            isVerifyingDuplicates = false
            duplicateCurrentPath = ""
            duplicateTask = nil
        }
    }

    private func confirmDuplicateContentRead(
        _ estimate: DuplicateVerificationReadEstimate, in roots: [URL]
    ) -> Bool {
        duplicateProgressPhase = .awaitingContentAuthorization
        duplicateEntriesVisited = estimate.entriesVisited
        duplicateBytesHashed = 0
        duplicateCandidateFileCount = estimate.candidateFileCount
        duplicateCandidateBytes = estimate.candidateBytes

        let formattedBytes = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: estimate.candidateBytes), countStyle: .file
        )
        let sizeDescription = estimate.byteAccountingOverflowed
            ? "more than \(formattedBytes)"
            : "about \(formattedBytes)"
        let fileLabel = estimate.candidateFileCount == 1 ? "candidate file" : "candidate files"
        let alert = NSAlert()
        alert.messageText = "Read \(estimate.candidateFileCount) \(fileLabel) to verify duplicates?"
        var details = "Metadata found \(estimate.candidateFileCount) regular files sharing logical sizes, with an estimated \(sizeDescription) of file contents to read. Files may change before they are checked."
        if !estimate.metadataCoverageComplete {
            details += " Metadata coverage is incomplete, so this estimate may miss other candidates."
        }
        details += "\n\nApprove to start reading. You can cancel during hashing; cancelled results remain incomplete. Disker will not modify files.\n\nSelected locations:\n"
        alert.informativeText = details + roots.map(\.path).joined(separator: "\n")
        alert.addButton(withTitle: "Read and Verify")
        alert.addButton(withTitle: "Cancel Without Reading")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func cancelDuplicateVerification() {
        duplicateTask?.cancel()
    }

    func preserveDuplicateCopy(hash: String, path: String) {
        preservedDuplicatePaths[hash] = path
    }

    func clearDuplicateKeeperChoices() {
        preservedDuplicatePaths = [:]
    }

    var cleanupPlan: CleanupPlan? {
        guard let duplicateResult, !preservedDuplicatePaths.isEmpty else { return nil }
        return try? CleanupPlanner.makePlan(
            from: duplicateResult, preserving: preservedDuplicatePaths
        )
    }

    func clearHistory() {
        historyGeneration.advance()
        monitoredScopePaths = []
        pausedMonitoringReasons = [:]
        storageMonitoringEnabledAtByPath = [:]
        storageMonitoringCooldownByPath = [:]
        storageMonitoringLastAttempt = [:]
        scheduledScanPath = nil
        stopStorageMonitoringScheduler()
        applicationBundlePathAvailability = [:]
        checkingApplicationBundlePaths = []
        applicationBundlePathCheckIDs = [:]
        scanTask?.cancel()
        ownFootprintRequestID = UUID()
        ownFootprintTask?.cancel()
        ownFootprintTask = nil
        isMeasuringOwnFootprint = false
        ownFootprint = nil
        ownFootprintPaths = []
        ramSampleTask?.cancel()
        ramSampleTask = nil
        isSamplingRAM = false
        updateMemoryPressureMonitoring(enabled: false, appIsActive: false)
        do {
            try ObservationStore.clear()
            try SelectedScopeBookmarkStore.clear()
            history = LocalHistory()
            rememberedScopes = []
            ram = nil
            errorMessage = nil
        } catch {
            errorMessage = "Local history could not be cleared: \(error.localizedDescription)"
        }
    }

    func previousCompleteObservation(for folder: FolderObservation) -> FolderObservation? {
        ObservationComparison.previousCompleteFolder(for: folder, in: history)
    }

    func directoryHistoryLabel(for folder: FolderObservation) -> String {
        if previousCompleteObservation(for: folder) != nil {
            return "No comparable prior retained path"
        }
        guard let currentIndex = history.observations.firstIndex(where: { observation in
            observation.folders.contains(where: { $0.id == folder.id })
        }) else { return "First complete observation" }
        let earlierComplete = history.observations[..<currentIndex].reversed().lazy
            .compactMap { observation in
                observation.folders.first(where: { $0.path == folder.path && $0.complete })
            }
            .first
        guard let earlierComplete else { return "First complete observation" }
        if let previousDeviceID = earlierComplete.volumeDeviceID,
           let currentDeviceID = folder.volumeDeviceID,
           previousDeviceID != currentDeviceID {
            return "Volume identity changed; comparison unavailable"
        }
        if earlierComplete.volumeDeviceID == nil, folder.volumeDeviceID != nil {
            return "Earlier volume identity unavailable; comparison omitted"
        }
        if earlierComplete.volumeDeviceID != nil, folder.volumeDeviceID == nil {
            return "Current volume identity unavailable; comparison omitted"
        }
        return "No comparable prior retained path"
    }

    func previousCompleteDirectory(
        for directory: DirectoryUsage, in folder: FolderObservation
    ) -> DirectoryUsage? {
        ObservationComparison.previousCompleteDirectory(
            for: directory, in: folder, history: history
        )
    }
}

struct DashboardView: View {
    @State private var model = DashboardModel()
    @State private var selectedSection: String? = "Overview"
    @State private var historyChartRange: ObservationTimeRange = .week
    @State private var isConfirmingHistoryClear = false
    @State private var isAutomaticRAMSamplingEnabled = false
    @State private var applicationReviewBundle: FolderObservation?
    @State private var developerArtifactReviewFolder: FolderObservation?
    @Environment(\.scenePhase) private var scenePhase

    private let sections = ["Overview", "Applications", "Folders", "Duplicates", "History", "RAM", "About"]

    private var hasApplicationHistoryChart: Bool {
        model.measuredApplicationBundles.contains {
            ObservationComparison.completeFolderSeries(for: $0, in: model.history).count > 1
        }
    }

    private var hasSelectedFolderHistoryChart: Bool {
        (model.latestScan?.folders ?? []).contains {
            ObservationComparison.completeFolderSeries(for: $0, in: model.history).count > 1
        }
    }

    var body: some View {
        NavigationSplitView {
            List(sections, id: \.self, selection: $selectedSection) { section in
                Label(section, systemImage: icon(for: section))
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("Disker")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LOCAL ONLY")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.2)
                    Text("Your observations stay on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        } detail: {
            Group {
                switch selectedSection ?? "Overview" {
                case "Applications": applicationsPage
                case "Folders": foldersPage
                case "Duplicates": duplicatesPage
                case "History": historyPage
                case "RAM": ramPage
                case "About": aboutPage
                default: overviewPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(item: $applicationReviewBundle) { bundle in
            ApplicationFootprintReviewSheet(
                bundleName: bundle.displayName,
                review: model.applicationFootprintReview(for: bundle)
            )
            .frame(minWidth: 580, minHeight: 520)
        }
        .sheet(item: $developerArtifactReviewFolder) { folder in
            DeveloperArtifactReviewSheet(folder: folder) { url in
                model.chooseFolders(startingAt: url)
            }
            .frame(minWidth: 620, minHeight: 560)
        }
        .onAppear {
            model.setStorageMonitoringAppActive(scenePhase == .active)
            model.startStorageMonitoringScheduler()
            model.refreshCapacity()
            model.updateMemoryPressureMonitoring(
                enabled: isAutomaticRAMSamplingEnabled, appIsActive: model.isAppActive
            )
        }
        .onChange(of: scenePhase) { _, phase in
            model.setStorageMonitoringAppActive(phase == .active)
            model.updateMemoryPressureMonitoring(
                enabled: isAutomaticRAMSamplingEnabled, appIsActive: model.isAppActive
            )
        }
        .onDisappear {
            model.stopStorageMonitoringScheduler()
        }
        .onChange(of: isAutomaticRAMSamplingEnabled) { _, enabled in
            if enabled && scenePhase == .active {
                model.refreshRAM()
            }
            model.updateMemoryPressureMonitoring(
                enabled: enabled, appIsActive: model.isAppActive
            )
        }
        .task(id: isAutomaticRAMSamplingEnabled) {
            guard isAutomaticRAMSamplingEnabled else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(RAMMonitoringPolicy.interval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let maySample = RAMMonitoringPolicy.shouldSample(
                    enabled: isAutomaticRAMSamplingEnabled,
                    appIsActive: model.isAppActive,
                    sampleInProgress: model.isSamplingRAM
                )
                if maySample { model.refreshRAM() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chooseFoldersToScan)) { _ in
            model.chooseFolders()
        }
        .onReceive(NotificationCenter.default.publisher(for: .chooseApplicationBundleToScan)) { _ in
            model.chooseApplicationBundle()
        }
        .alert("Disker", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "Clear Disker’s local history?",
            isPresented: $isConfirmingHistoryClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                isAutomaticRAMSamplingEnabled = false
                model.clearHistory()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes saved capacity, folder, RAM and system-pressure observations, app-folder associations, and remembered scan locations from this Mac. Active storage and RAM monitoring will stop. Your files and folders will not be changed.")
        }
    }

    private var overviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header("Storage overview", subtitle: "A measured view of your Mac's storage, with clear limits.")
                capacityCard
                if model.latestScan == nil && !model.isScanning {
                    emptyHistoryCard
                } else {
                    scanCard
                    selectedRootOverlapNotice
                    folderGrowthCard
                    directoryGrowthCard
                    developerArtifactReviewCard
                    if let latest = model.latestScan, !latest.folders.isEmpty {
                        let largestFolders = Array(latest.folders.sorted {
                            $0.allocatedBytes > $1.allocatedBytes
                        }.prefix(3))
                        folderList(
                            largestFolders, title: "Largest selected folders",
                            scanCancelled: latest.cancelled, includeDetails: false
                        )
                        Button("Open Folders for the full breakdown") {
                            selectedSection = "Folders"
                        }
                        .buttonStyle(.link)
                    }
                }
                methodologyNote
            }
            .padding(30)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if model.isScanning { model.cancelScan() }
                    else { model.chooseFolders() }
                } label: {
                    Label(model.isScanning ? "Cancel Scan" : "Scan Folders", systemImage: model.isScanning ? "stop.circle" : "folder")
                }
            }
        }
    }

    private var capacityCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("System-reported volume capacity", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
                Text(model.capacity.map { $0.observedAt.formatted(date: .abbreviated, time: .shortened) } ?? "Unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    model.refreshCapacity()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Record a new system-reported capacity observation")
                .accessibilityLabel("Refresh storage capacity")
            }
            if let capacity = model.capacity {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(ByteCountFormatter.string(fromByteCount: capacity.availableBytes, countStyle: .file))
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                    Text("available")
                        .foregroundStyle(.secondary)
                }
                Text("\(capacity.volumeName ?? "System volume") · \(capacity.volumeIsLocal.map { $0 ? "local volume" : "network volume" } ?? "volume location unknown")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(capacity.availableBytes), total: Double(max(1, capacity.totalBytes)))
                    .tint(.blue)
                    .accessibilityLabel("Available capacity")
                    .accessibilityValue("\(format(capacity.availableBytes)) of \(format(capacity.totalBytes))")
                if capacity.isLowOnAvailableCapacity {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Low available capacity")
                                .font(.subheadline.weight(.semibold))
                            Text("macOS reports less than the warning threshold of \(format(capacity.lowAvailableCapacityThreshold)). This does not identify which folders use space or how much any action could reclaim.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Review selected folders") {
                                selectedSection = "Folders"
                            }
                            .buttonStyle(.link)
                            .controlSize(.small)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }
                let fullCapacitySeries = ObservationComparison.comparableCapacitySeries(in: model.history)
                let latestCapacityDate = fullCapacitySeries.map(\.observedAt).max() ?? .now
                let capacitySeries = fullCapacitySeries.filter {
                    historyChartRange.includes($0.observedAt, relativeTo: latestCapacityDate)
                }.sorted { $0.observedAt < $1.observedAt }
                if capacitySeries.count > 1 {
                    let values = capacitySeries.map { Double($0.availableBytes) / 1_073_741_824 }
                    let minimum = values.min() ?? 0
                    let maximum = values.max() ?? minimum
                    let padding = max((maximum - minimum) * 0.15, max(Double(capacity.totalBytes) / 1_073_741_824 * 0.005, 0.25))
                    VStack(alignment: .leading, spacing: 8) {
                        historyRangePicker
                        Chart(capacitySeries, id: \.observedAt) { sample in
                            LineMark(
                                x: .value("Observed", sample.observedAt),
                                y: .value("Available GiB", Double(sample.availableBytes) / 1_073_741_824)
                            )
                            .foregroundStyle(.blue)
                            PointMark(
                                x: .value("Observed", sample.observedAt),
                                y: .value("Available GiB", Double(sample.availableBytes) / 1_073_741_824)
                            )
                            .foregroundStyle(.blue)
                        }
                        .chartYScale(domain: max(0, minimum - padding)...(maximum + padding))
                        .chartYAxisLabel("Available (GiB)")
                        .frame(height: 120)
                        .accessibilityLabel("Available-space history for \(historyChartRange.title), \(capacitySeries.count) comparable observations")
                        Text("\(capacitySeries.count) comparable observations · \(historyRangeCaption(endingAt: latestCapacityDate)) · focused vertical scale · not attributed to folders")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if !fullCapacitySeries.isEmpty {
                    historyRangePicker
                    Text("Fewer than two comparable capacity observations in \(historyRangeCaption(endingAt: latestCapacityDate)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let previous = ObservationComparison.previousComparableCapacity(for: capacity, in: model.history),
                   let delta = ObservationComparison.availableCapacityDelta(current: capacity, previous: previous) {
                    Label {
                        Text("Available space \(delta >= 0 ? "increased" : "decreased") by \(format(delta.magnitude)) since \(previous.observedAt.formatted(date: .abbreviated, time: .shortened)).")
                    } icon: {
                        Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    }
                    .font(.caption)
                    .foregroundStyle(delta >= 0 ? .green : .orange)
                    .accessibilityElement(children: .combine)
                } else {
                        Text("No earlier comparable measurement for this volume and availability method is available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 3) {
                    HStack(alignment: .top, spacing: 24) {
                        Text("Capacity minus available")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Volume capacity")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    HStack(alignment: .firstTextBaseline, spacing: 24) {
                        Text(format(capacity.notAvailableBytes))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(format(capacity.totalBytes))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.system(.title3, design: .rounded).weight(.medium))
                }
                    Text(capacity.availabilityBasis == .importantUsage
                     ? "Available space uses macOS’s estimate for important usage. Capacity minus available is a difference between system-reported values, not a measurement of physical file usage."
                     : "macOS’s standard available-capacity value is shown because its important-usage estimate was zero or unavailable. Capacity minus available is not a measurement of physical file usage.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("Capacity unavailable", systemImage: "internaldrive", description: Text("macOS did not provide capacity information for this volume."))
                    .frame(height: 140)
            }
        }
        .padding(22)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
    }

    private var scanCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("See what's taking space")
                    .font(.headline)
                Text("Choose folders to measure their files. Access is limited to the locations you select.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(model.isScanning ? "Cancel Scan" : "Choose Folders…") {
                if model.isScanning { model.cancelScan() }
                else { model.chooseFolders() }
            }
            if model.isScanning {
                VStack(alignment: .trailing, spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.currentPath.isEmpty
                         ? "Starting scan…"
                         : "\(model.countedFileObjects.formatted()) unique file objects counted · \(model.currentPath)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.currentPath.isEmpty
                                    ? "Scanning folders"
                                    : "Scanning folders, \(model.countedFileObjects) unique file objects counted, current path \(model.currentPath)")
            }
        }
        .padding(18)
        .background(Color.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.blue.opacity(0.12)))
    }

    private var emptyHistoryCard: some View {
        ContentUnavailableView {
            Label("No folder observations yet", systemImage: "chart.bar.xaxis")
        } description: {
            Text("Choose folders to get a measured breakdown. Disker will compare later scans of the same folders; it won't invent a history before then.")
        } actions: {
            Button(model.isScanning ? "Cancel Scan" : "Choose Folders…") {
                if model.isScanning { model.cancelScan() }
                else { model.chooseFolders() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var selectedRootOverlapNotice: some View {
        Group {
            if let latest = model.latestScan,
               SelectedRootScope.hasOverlappingPaths(latest.folders.map(\.path)) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Selected folder paths overlap")
                            .font(.subheadline.weight(.semibold))
                        Text("A parent scan can include a nested selected folder. Review each root separately; some files may appear in both totals, so do not add them together.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.orange)
                }
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var developerArtifactReviewCard: some View {
        Group {
            if let latest = model.latestScan {
                let candidateFolders = latest.folders.filter {
                    !DeveloperArtifactReview.make(from: $0).entries.isEmpty
                }
                if !candidateFolders.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Development data to review", systemImage: "shippingbox")
                            .font(.headline)
                        Text("Name and Git-marker clues identify places worth inspecting. They do not show that data is unused or safe to remove.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if candidateFolders.count > 3 {
                            Text("Showing 3 of \(candidateFolders.count) selected roots with candidates. Open Folders to review the rest.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(candidateFolders.prefix(3), id: \.path) { folder in
                            let review = DeveloperArtifactReview.make(from: folder)
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(folder.displayName)
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(review.entries.count) measured candidates · \(folder.complete ? "complete scan" : "partial scan")")
                                        .font(.caption)
                                        .foregroundStyle(folder.complete ? Color.secondary : Color.orange)
                                    if let largest = review.entries.max(by: { $0.allocatedBytesEstimate < $1.allocatedBytesEstimate }) {
                                        Text("Largest: \(largest.relativePath) · ~\(format(largest.allocatedBytesEstimate)) allocated")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 8)
                                Button("Review") { developerArtifactReviewFolder = folder }
                                    .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                            if folder.path != candidateFolders.prefix(3).last?.path { Divider() }
                        }
                        if candidateFolders.contains(where: { !$0.complete }) {
                            Label("Partial scans can omit data; measured sizes are not reclaimable-space estimates.", systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
                }
            }
        }
    }

    private var folderGrowthCard: some View {
        let signals = ObservationComparison.growingFolders(in: model.history)
        return Group {
            if !signals.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Growing selected folders", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.headline)
                    Text("Largest positive allocated-byte changes between complete scans of the same selected path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(signals) { signal in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(signal.folder.path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Text("Complete scans: \(signal.previous.finishedAt.formatted(date: .abbreviated, time: .shortened)) → \(signal.folder.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(formattedDelta(signal.growthBytes))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.orange)
                                Text("At latest scan ~\(format(signal.folder.allocatedBytes)) allocated")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let bytesPerDay = signal.observedBytesPerDay {
                                    Text("Observed pace \(formattedByteRate(bytesPerDay))/day")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    URL(fileURLWithPath: signal.folder.path)
                                ])
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .buttonStyle(.borderless)
                            .help("Reveal selected folder in Finder")
                            .accessibilityLabel("Reveal \(signal.folder.displayName) in Finder")
                        }
                        if signal.id != signals.last?.id { Divider() }
                    }
                }
                .padding(18)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
            }
        }
    }

    private var directoryGrowthCard: some View {
        let signals = ObservationComparison.growingDirectories(in: model.history)
        return Group {
            if !signals.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Growing subfolders", systemImage: "folder.badge.plus")
                        .font(.headline)
                    Text("Largest positive allocated-estimate changes for the same subfolder within the same selected root. Paths missing from a retained summary are not treated as zero.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(signals) { signal in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(signal.directory.rootRelativePath)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Text("In \(signal.folder.path)")
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Text("Complete scans: \(signal.previousFolder.finishedAt.formatted(date: .abbreviated, time: .shortened)) → \(signal.folder.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(formattedDelta(signal.growthBytes))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.orange)
                                Text("At latest scan ~\(format(signal.directory.allocatedBytes)) allocated")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let bytesPerDay = signal.observedBytesPerDay {
                                    Text("Observed pace \(formattedByteRate(bytesPerDay))/day")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Button {
                                let directoryURL = URL(fileURLWithPath: signal.folder.path)
                                    .appendingPathComponent(signal.directory.rootRelativePath)
                                NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .buttonStyle(.borderless)
                            .help("Reveal subfolder in Finder")
                            .accessibilityLabel("Reveal \(signal.directory.rootRelativePath) in Finder")
                        }
                        if signal.id != signals.last?.id { Divider() }
                    }
                }
                .padding(18)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
            }
        }
    }

    private var methodologyNote: some View {
        Label {
            Text("The capacity figure comes from macOS. Folder totals are a separate file-tree estimate: snapshots, clones and system-managed storage can make them differ. Unmeasured items are reported as incomplete, never as zero.")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var applicationsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header("Application bundles", subtitle: "Measure the selected .app bundle; associated data is outside this measurement.")
                if hasApplicationHistoryChart { historyRangePicker }
                Label {
                    Text("Disker does not infer support folders, caches, containers, or shared files. Those locations are not included unless you measure them separately, and a bundle total alone is not an uninstall plan.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button(model.isScanning ? "Cancel Scan" : "Choose an Application Bundle…") {
                    if model.isScanning { model.cancelScan() }
                    else { model.chooseApplicationBundle() }
                }
                if model.isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.currentPath.isEmpty ? "Starting bundle scan…" : "Scanning \(model.currentPath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .accessibilityElement(children: .combine)
                }

                let bundles = model.measuredApplicationBundles
                if bundles.isEmpty {
                    ContentUnavailableView {
                        Label("No application bundles measured", systemImage: "app.dashed")
                    } description: {
                        Text("Choose one .app bundle to measure its file tree. Disker will not scan neighboring support data.")
                    } actions: {
                        Button(model.isScanning ? "Cancel Scan" : "Choose an Application Bundle…") {
                            if model.isScanning { model.cancelScan() }
                            else { model.chooseApplicationBundle() }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 190)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    ForEach(bundles) { bundle in
                        let relatedPaths = model.relatedFolders(for: bundle.path)
                        let pathAvailability = model.applicationBundlePathAvailability[bundle.path]
                        let isCheckingPath = model.checkingApplicationBundlePaths.contains(bundle.path)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top) {
                                Label(bundle.displayName, systemImage: "app.fill")
                                    .font(.headline)
                                Spacer()
                                Button("Rescan…") {
                                    model.chooseApplicationBundle(
                                        startingAt: URL(fileURLWithPath: bundle.path).deletingLastPathComponent()
                                    )
                                }
                                .disabled(model.isScanning)
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundle.path)])
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .buttonStyle(.borderless)
                                .help("Reveal application bundle in Finder")
                                .accessibilityLabel("Reveal \(bundle.displayName) in Finder")
                            }
                            Text(bundle.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            applicationIdentityRow(for: bundle)
                            applicationDataLocationSuggestions(for: bundle)
                            HStack(spacing: 8) {
                                if isCheckingPath {
                                    ProgressView().controlSize(.small)
                                    Text("Checking selected app path…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if let pathAvailability {
                                    Label(
                                        pathAvailability ? "Bundle path available at last check" : "Bundle path unavailable at last check",
                                        systemImage: pathAvailability ? "checkmark.circle" : "questionmark.circle"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(pathAvailability ? Color.secondary : Color.orange)
                                }
                                Button(pathAvailability == nil ? "Check bundle path" : "Check again") {
                                    model.checkApplicationBundlePath(bundle.path)
                                }
                                .controlSize(.small)
                                .disabled(isCheckingPath || model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
                                .help("Check only the exact app bundle path last measured; no folders are scanned")
                            }
                            if pathAvailability == false && !relatedPaths.isEmpty {
                                Label {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Possible leftover data · needs review")
                                            .font(.subheadline.weight(.semibold))
                                        Text("The last measured app path is currently unavailable. The app may have moved, its volume may be disconnected, or access may be restricted. Disker's saved folder associations were selected manually; their current presence, ownership, and safety are unknown.")
                                            .font(.caption)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                } icon: {
                                    Image(systemName: "questionmark.folder.fill")
                                        .foregroundStyle(.orange)
                                }
                                .foregroundStyle(.secondary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityElement(children: .combine)
                            }
                            HStack(spacing: 12) {
                                Text("Logical \(format(bundle.logicalBytes))")
                                Text("Allocated estimate \(format(bundle.allocatedBytes))")
                                Text("\(bundle.fileCount) files")
                                if let previous = model.previousCompleteObservation(for: bundle),
                                   let delta = ObservationComparison.allocatedByteDelta(current: bundle, previous: previous) {
                                    Text(changeDescription(delta))
                                        .foregroundStyle(delta >= 0 ? .orange : .green)
                                } else if bundle.complete {
                                    Text("First complete measurement")
                                        .foregroundStyle(.secondary)
                                }
                                if bundle.complete {
                                    Label("Complete", systemImage: "checkmark.circle")
                                        .foregroundStyle(.green)
                                } else {
                                    Text(coverageSummary(
                                        inaccessible: bundle.inaccessibleCount,
                                        excludedSymlinks: bundle.excludedSymlinkCount,
                                        excludedSpecialFiles: bundle.excludedSpecialFileCount,
                                        excludedVolumeBoundaries: bundle.excludedVolumeBoundaryCount,
                                        changed: bundle.changedDuringScanCount,
                                        wasCancelled: model.scanWasCancelled(for: bundle),
                                        accountingOverflowed: bundle.byteAccountingOverflowed
                                    ))
                                    .foregroundStyle(.orange)
                                }
                                Spacer(minLength: 0)
                                Text(bundle.finishedAt.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption2)
                            Button("Review app removal footprint…") {
                                applicationReviewBundle = bundle
                            }
                            .disabled(model.isScanning || model.isVerifyingDuplicates || model.isMeasuringOwnFootprint)
                            Button("Associate Folders…") {
                                model.chooseRelatedFolders(for: bundle.path)
                            }
                            .disabled(model.isScanning)

                            if !relatedPaths.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Folders you associated", systemImage: "link")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Disker never sums these folders into an app total or claims exclusive ownership. Container hints use the selected app's declared bundle ID and App Groups claim; a matching bundle ID and claim covered by a locally valid code signature receive stronger labels. Notarization, current use, and exclusive ownership are not established; App Group data is shared.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    ForEach(relatedPaths, id: \.self) { path in
                                        applicationAssociationRow(path: path, bundle: bundle)
                                    }
                                }
                                .padding(12)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                            }
                            folderHistoryChart(for: bundle)
                        }
                        .padding(16)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 960, alignment: .leading)
        }
    }

    private var foldersPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header("Selected folders", subtitle: "Measure only locations you choose. Saved read-only access lets you rescan them on demand.")
                selectedRootOverlapNotice
                if hasSelectedFolderHistoryChart { historyRangePicker }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Text("Saved locations are scanned only on request or with per-path opt-in. Monitoring reads metadata only while Disker is active and resets off when Disker quits or relaunches; an in-flight scheduled scan may be cancelled when the app becomes inactive.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Menu("Every \(Int(model.storageMonitoringInterval / 60)) min") {
                                ForEach([5, 15, 30, 60], id: \.self) { minutes in
                                    Button("Every \(minutes) minutes") {
                                        model.setStorageMonitoringInterval(TimeInterval(minutes * 60))
                                    }
                                }
                            }
                            .disabled(model.monitoredScopePaths.isEmpty)
                            .help("Choose the interval for opted-in saved locations")
                        }
                        if model.rememberedScopes.isEmpty {
                            Label("No saved scan locations", systemImage: "folder.badge.questionmark")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.rememberedScopes) { scope in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(URL(fileURLWithPath: scope.path).lastPathComponent)
                                            .font(.subheadline.weight(.medium))
                                        Text(scope.path)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Toggle("Monitor while Disker is active", isOn: Binding(
                                            get: { model.monitoredScopePaths.contains(scope.path) },
                                            set: { model.toggleStorageMonitoring(scope.path, enabled: $0) }
                                        ))
                                        .toggleStyle(.checkbox)
                                        .font(.caption)
                                        if let pauseReason = model.pausedMonitoringReasons[scope.path] {
                                            HStack(spacing: 8) {
                                                Label(pauseReason, systemImage: "pause.circle")
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                                Button("Resume") { model.resumeStorageMonitoring(scope.path) }
                                                    .font(.caption2)
                                            }
                                        } else if model.monitoredScopePaths.contains(scope.path) {
                                            if model.isScanning && model.scheduledScanPath == scope.path {
                                                Text("Scheduled metadata scan in progress")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if let attemptedAt = model.storageMonitoringLastAttempt[scope.path] {
                                                Text("Last attempt \(attemptedAt.formatted(date: .abbreviated, time: .shortened))")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if let nextDate = model.storageMonitoringNextEligibleDate(for: scope.path) {
                                                Text("Next eligible scan \(nextDate.formatted(date: .abbreviated, time: .shortened))")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        if let observation = model.latestFolderObservation(at: scope.path) {
                                            Text("Measured \(observation.finishedAt.formatted(date: .abbreviated, time: .shortened)) · Logical \(format(observation.logicalBytes)) · Allocated ~\(format(observation.allocatedBytes))")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                            if observation.complete {
                                                if let previous = model.previousCompleteObservation(for: observation),
                                                   let delta = ObservationComparison.allocatedByteDelta(
                                                    current: observation, previous: previous
                                                   ) {
                                                    directoryChangeLabel(delta, previous: previous, current: observation)
                                                } else {
                                                    Text(model.directoryHistoryLabel(for: observation))
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                            } else {
                                                Text(coverageSummary(
                                                    inaccessible: observation.inaccessibleCount,
                                                    excludedSymlinks: observation.excludedSymlinkCount,
                                                    excludedSpecialFiles: observation.excludedSpecialFileCount,
                                                    excludedVolumeBoundaries: observation.excludedVolumeBoundaryCount,
                                                    changed: observation.changedDuringScanCount,
                                                    wasCancelled: model.scanWasCancelled(for: observation),
                                                    accountingOverflowed: observation.byteAccountingOverflowed
                                                ))
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                            }
                                        } else {
                                            Text("No measurement saved for this path yet")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Button("Scan") { model.rescanRememberedFolder(scope.path) }
                                        .disabled(model.isScanning)
                                    Button {
                                        model.forgetRememberedFolder(scope.path)
                                    } label: {
                                        Image(systemName: "xmark.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(model.isScanning)
                                    .help("Forget this saved scan location")
                                    .accessibilityLabel("Forget saved location \(URL(fileURLWithPath: scope.path).lastPathComponent)")
                                }
                                Divider()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Saved scan roots (\(model.rememberedScopes.count)/\(SelectedScopeBookmarkStore.maximumBookmarkCount))", systemImage: "bookmark")
                }
                if let folders = model.latestScan?.folders, !folders.isEmpty {
                    folderList(folders, title: "Latest scan", scanCancelled: model.latestScan?.cancelled ?? false)
                } else {
                    emptyHistoryCard
                }
            }
            .padding(30)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(model.isScanning ? "Cancel Scan" : "Scan Folders…") {
                    if model.isScanning { model.cancelScan() }
                    else { model.chooseFolders() }
                }
            }
        }
    }

    private var historyPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header("History", subtitle: "Local observations from folders you've explicitly selected.")
                if model.history.observations.isEmpty {
                    emptyHistoryCard
                } else {
                    ForEach(model.history.observations.reversed()) { observation in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(observation.finishedAt.formatted(date: .complete, time: .shortened)).font(.headline)
                                Spacer()
                                if observation.cancelled { Text("Cancelled").foregroundStyle(.orange) }
                            }
                            ForEach(observation.folders) { folder in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(folder.displayName)
                                        Text(folder.path).font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                        if folder.gitMetadataEntryDetected {
                                            Label("Git metadata marker detected", systemImage: "chevron.left.forwardslash.chevron.right")
                                                .font(.caption2)
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    Spacer(minLength: 12)
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(ByteCountFormatter.string(fromByteCount: folder.allocatedBytes, countStyle: .file))
                                        if let previous = ObservationComparison.previousCompleteFolder(for: folder, in: model.history),
                                           let delta = ObservationComparison.allocatedByteDelta(current: folder, previous: previous) {
                                            Text(changeDescription(delta))
                                                .font(.caption2)
                                                .foregroundStyle(delta >= 0 ? .orange : .green)
                                        } else if folder.complete {
                                            Text("No earlier complete match")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    if !folder.complete {
                                        Text(coverageSummary(
                                            inaccessible: folder.inaccessibleCount,
                                            excludedSymlinks: folder.excludedSymlinkCount,
                                            excludedSpecialFiles: folder.excludedSpecialFileCount,
                                            excludedVolumeBoundaries: folder.excludedVolumeBoundaryCount,
                                            changed: folder.changedDuringScanCount,
                                            wasCancelled: observation.cancelled,
                                            accountingOverflowed: folder.byteAccountingOverflowed
                                        ))
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                .font(.subheadline)
                            }
                        }
                        .padding(18)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 960, alignment: .leading)
        }
    }

    private var aboutPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header("About Disker", subtitle: "Understand storage without guessing what is safe to remove.")
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Folder-size scans read metadata only. Explicit app signature checks read signed executable and resource contents locally; duplicate verification reads selected candidates after confirmation. Nothing is uploaded.", systemImage: "hand.raised")
                        Label("For a selected app bundle, Disker reads its declared bundle ID and embedded App Groups claim, then reads signed executable and resource contents to check local signature integrity. It does not verify notarization or publisher trust, current use, or exclusive ownership; App Group data is shared.", systemImage: "app.badge.checkmark")
                        Label("Scan locations are chosen by you. Disker does not change their contents; optional monitoring scans selected paths only while the app is active.", systemImage: "folder.badge.plus")
                        Label("Disker does not offer cleanup or deletion of user files.", systemImage: "lock.shield")
                        Label("History stays in this Mac's Application Support folder.", systemImage: "internaldrive")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                } label: {
                    Text("Privacy and safety")
                }
                ownFootprintCard
                GroupBox {
                    Text("This build reports volume capacity from macOS and estimates selected-folder usage from file metadata. APFS snapshots, copy-on-write clones, shared blocks, system-managed data and inaccessible paths prevent a path scan from reconciling exactly with the system's capacity figures.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text("Measurement limits")
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Remove saved capacity measurements, folder paths and sizes, RAM samples, app-folder associations, and remembered scan locations from this Mac. Scanned files are not changed.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Clear Local History…", role: .destructive) {
                            isConfirmingHistoryClear = true
                        }
                    }
                } label: {
                    Text("Local history")
                }
            }
            .padding(30)
            .frame(maxWidth: 800, alignment: .leading)
        }
    }

    private var ownFootprintCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Measure only Disker’s installed app bundle and its own Application Support folder. This metadata-only check does not include the folders you selected for storage scans and is not saved in history.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button(model.isMeasuringOwnFootprint ? "Measuring…" : "Measure Disker’s Files") {
                    model.measureOwnFootprint()
                }
                .disabled(model.isMeasuringOwnFootprint || model.isScanning || model.isVerifyingDuplicates)

                if model.isMeasuringOwnFootprint {
                    ProgressView("Measuring Disker’s own files…")
                } else if let observation = model.ownFootprint {
                    ForEach(observation.folders) { folder in
                        let isBundle = folder.path == Bundle.main.bundleURL.standardizedFileURL.path
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(isBundle ? "Disker application bundle" : "Disker local support data")
                                    .font(.subheadline.weight(.semibold))
                                Text(folder.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Text("Logical \(format(folder.logicalBytes)) · allocated estimate \(format(folder.allocatedBytes)) · \(folder.fileCount) files")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !folder.complete {
                                    Text(coverageSummary(
                                        inaccessible: folder.inaccessibleCount,
                                        excludedSymlinks: folder.excludedSymlinkCount,
                                        excludedSpecialFiles: folder.excludedSpecialFileCount,
                                        excludedVolumeBoundaries: folder.excludedVolumeBoundaryCount,
                                        changed: folder.changedDuringScanCount,
                                        wasCancelled: observation.cancelled,
                                        accountingOverflowed: folder.byteAccountingOverflowed
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 4)
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    URL(fileURLWithPath: folder.path)
                                ])
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .buttonStyle(.borderless)
                            .help("Reveal Disker files in Finder")
                            .accessibilityLabel("Reveal \(isBundle ? "Disker application bundle" : "Disker local support data") in Finder")
                        }
                        .padding(.vertical, 7)
                        Divider()
                    }
                    if let support = model.localSupportDirectory,
                       !model.ownFootprintPaths.contains(support.standardizedFileURL.path) {
                        Text("No Disker Application Support folder existed when this measurement ran.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("This one-time measurement is kept only in the current view. Clear Local History removes Disker’s saved observation and bookmark files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No measurement yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } label: {
            Text("Disker’s own files")
        }
    }

    private var duplicateProgressTitle: String {
        switch model.duplicateProgressPhase {
        case .readingMetadata: "Reviewing selected-folder metadata…"
        case .awaitingContentAuthorization: "Waiting for content-read confirmation…"
        case .readingContents: "Verifying same-size file candidates…"
        }
    }

    private var duplicateProgressDetail: String {
        switch model.duplicateProgressPhase {
        case .readingMetadata:
            "\(model.duplicateEntriesVisited) entries inspected · no file contents read"
        case .awaitingContentAuthorization:
            "\(model.duplicateCandidateFileCount) candidates · about \(format(model.duplicateCandidateBytes)) to read · no content read yet"
        case .readingContents where model.duplicateCandidateBytes > 0:
            "Read \(format(model.duplicateBytesHashed)) of \(format(model.duplicateCandidateBytes)) across \(model.duplicateCandidateFileCount) files"
        case .readingContents:
            "\(model.duplicateCandidateFileCount) candidate files · 0 content bytes"
        }
    }

    private var duplicatesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(
                    "Duplicate review",
                    subtitle: "Confirm byte-identical files inside folders you choose. Disker will not change them."
                )
                if model.isVerifyingDuplicates {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(duplicateProgressTitle)
                            .font(.headline)
                        if model.duplicateProgressPhase == .readingContents && model.duplicateCandidateBytes > 0 {
                            ProgressView(
                                value: Double(model.duplicateBytesHashed),
                                total: Double(model.duplicateCandidateBytes)
                            )
                        } else {
                            ProgressView()
                        }
                        Text(model.duplicateCurrentPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        HStack {
                            Text(duplicateProgressDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel Check", action: model.cancelDuplicateVerification)
                        }
                    }
                    .padding(18)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                } else if let result = model.duplicateResult {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(result.cancelled ? "Verification cancelled" : result.complete ? "Verification complete" : "Verification partial")
                                .font(.title3.weight(.semibold))
                            Text("\(result.checkedFileCount) same-size candidates hashed across \(result.selectedRootPaths.count) selected folders.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Group {
                                if let verifiedAt = result.verifiedAt {
                                    Text("Checked \(verifiedAt.formatted(date: .abbreviated, time: .shortened)). Files may have changed since this check.")
                                } else {
                                    Text("Verification time unavailable. Run a new check before acting on any path.")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if !result.complete {
                                Text(duplicateCoverageSummary(result))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button("Verify Folders…", action: chooseDuplicateFolders)
                    }

                    if result.groups.isEmpty {
                        ContentUnavailableView {
                            Label(
                                result.complete ? "No confirmed duplicates" : "No confirmed groups yet",
                                systemImage: "doc.on.doc"
                            )
                        } description: {
                            Text(result.complete
                                 ? "No byte-identical files were found among the same-size candidates in these folders."
                                 : "Coverage was incomplete, so this check cannot rule out additional matches.")
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        Text("Confirmed byte-identical groups")
                            .font(.title3.weight(.semibold))
                        ForEach(result.groups) { group in
                            VStack(alignment: .leading, spacing: 11) {
                                HStack {
                                    Text("\(group.files.count) matching files")
                                        .font(.headline)
                                    Spacer()
                                    Text(format(group.files[0].logicalBytes))
                                        .font(.system(.body, design: .rounded).weight(.semibold))
                                    Text("each")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("SHA-256  \(group.sha256)")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                                ForEach(group.files, id: \.path) { file in
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc")
                                            .foregroundStyle(.secondary)
                                        Text(file.path)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 4)
                                        Text("Allocated ~\(format(file.allocatedBytes))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Button {
                                            NSWorkspace.shared.activateFileViewerSelecting([
                                                URL(fileURLWithPath: file.path)
                                            ])
                                        } label: {
                                            Image(systemName: "arrow.up.right.square")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Reveal in Finder")
                                        .accessibilityLabel("Reveal \(file.path) in Finder")
                                    }
                                    HStack {
                                        Spacer()
                                        Button(model.preservedDuplicatePaths[group.sha256] == file.path
                                               ? "Chosen to keep"
                                               : "Keep this copy") {
                                            model.preserveDuplicateCopy(hash: group.sha256, path: file.path)
                                        }
                                        .controlSize(.small)
                                        .disabled(model.preservedDuplicatePaths[group.sha256] == file.path)
                                        .accessibilityLabel("Keep this copy at \(file.path)")
                                    }
                                }
                                Divider()
                                Text("Potential space to reclaim: unknown. Identical contents do not prove a file is safe to remove; APFS clones and shared blocks can change physical savings.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(16)
                            .background(.background, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }

                    if let plan = model.cleanupPlan, !plan.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Dry-run cleanup plan")
                                    .font(.title3.weight(.semibold))
                                Spacer()
                                Button("Clear choices", action: model.clearDuplicateKeeperChoices)
                                    .controlSize(.small)
                            }
                            Text("Based on your choice of which copy to keep. These exact paths are proposed for manual review only; Disker will not move or remove them.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Ownership, shared use, and whether either copy can be restored or reproduced are unknown. Identical contents do not establish that either path is safe to remove.")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Group {
                                if let verifiedAt = plan.verifiedAt {
                                    Text("Evidence checked \(verifiedAt.formatted(date: .abbreviated, time: .shortened)). Run Verify Folders again before acting on these paths.")
                                } else {
                                    Text("Verification time unavailable. Run Verify Folders again before acting on these paths.")
                                }
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            if !plan.sourceCoverageComplete {
                                Text("The verification scope was partial. This plan covers only groups that were confirmed; other matches may remain unmeasured.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            DisclosureGroup("Verified scope · \(plan.selectedRootPaths.count) selected locations") {
                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(Array(plan.selectedRootPaths.enumerated()), id: \.offset) { item in
                                        Text(item.element)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.top, 5)
                            }
                            .font(.caption.weight(.medium))
                            ForEach(plan.entries) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Proposed candidate · risk unknown")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.orange)
                                    Text(entry.targetPath)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                    HStack(spacing: 10) {
                                        Button("Reveal candidate in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([
                                                URL(fileURLWithPath: entry.targetPath)
                                            ])
                                        }
                                        .controlSize(.small)
                                        .accessibilityLabel("Reveal proposed candidate in Finder")
                                        Button("Reveal kept copy") {
                                            NSWorkspace.shared.activateFileViewerSelecting([
                                                URL(fileURLWithPath: entry.preservedPath)
                                            ])
                                        }
                                        .controlSize(.small)
                                        .accessibilityLabel("Reveal preserved duplicate in Finder")
                                    }
                                    Text("Keep: \(entry.preservedPath)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                    Text("Logical \(format(entry.logicalBytes)) · allocated ~\(format(entry.allocatedBytesEstimate)) · expected reclaimable space unknown")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("Verified SHA-256 · \(entry.verifiedSHA256)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.vertical, 7)
                                Divider()
                            }
                        }
                        .padding(18)
                        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    }
                } else {
                    ContentUnavailableView {
                        Label("No duplicate check yet", systemImage: "doc.on.doc")
                    } description: {
                        Text("Choose folders for a one-time content check. Disker first groups regular files by size, then reads only those candidates to verify their SHA-256 digest.")
                    } actions: {
                        Button("Verify Folders…", action: chooseDuplicateFolders)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                }

                Label {
                Text("Checks are read-only. Symlinks are not followed, hard links count as one file, and no move or deletion action is available.")
                } icon: {
                    Image(systemName: "lock.shield")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(30)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Verify Folders…", action: chooseDuplicateFolders)
                    .disabled(model.isVerifyingDuplicates)
            }
        }
    }

    private func applicationIdentityRow(for bundle: FolderObservation) -> some View {
        let identifierMatches = bundle.applicationSignatureValidated
            && bundle.applicationBundleIdentifier != nil
            && bundle.applicationSignedBundleIdentifier == bundle.applicationBundleIdentifier
        return VStack(alignment: .leading, spacing: 4) {
            if let identifier = bundle.applicationBundleIdentifier {
                Text("Declared bundle ID · \(identifier)")
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
            Label(
                identifierMatches ? "Static signature valid · ID matches" : "Signed ID not verified",
                systemImage: identifierMatches ? "checkmark.seal" : "questionmark.circle"
            )
            .font(.caption2)
            .foregroundStyle(identifierMatches ? Color.green : Color.secondary)
            .help("Local static signature integrity only; this does not verify notarization, publisher trust, or current use.")
            if let signedIdentifier = bundle.applicationSignedBundleIdentifier,
               signedIdentifier != bundle.applicationBundleIdentifier {
                Text("Signed ID differs · \(signedIdentifier)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func applicationDataLocationSuggestions(for bundle: FolderObservation) -> some View {
        let suggestions = ApplicationDataLocationCandidates.suggestions(
            bundleIdentifier: bundle.applicationBundleIdentifier,
            homeDirectoryPath: NSHomeDirectory(),
            claimedGroupIdentifiers: bundle.applicationGroupIdentifiers,
            signatureValidated: bundle.applicationSignatureValidated,
            signedBundleIdentifier: bundle.applicationSignedBundleIdentifier
        )
        return Group {
            if !suggestions.isEmpty {
                DisclosureGroup("Possible data locations · not measured") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("These conventional paths come from the selected app's bundle ID and embedded group claims. Disker has not checked whether they exist or who uses them. Choose a path to open the folder picker; only folders you select will be measured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(suggestions) { suggestion in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.title)
                                        .font(.caption.weight(.medium))
                                    Text(suggestion.path)
                                        .font(.caption2.monospaced())
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(suggestion.explanation)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 4)
                                Button("Select…") {
                                    model.chooseRelatedFolders(
                                        for: bundle.path,
                                        startingAt: URL(fileURLWithPath: suggestion.path).deletingLastPathComponent()
                                    )
                                }
                                .controlSize(.small)
                                .disabled(model.isScanning)
                            }
                            if suggestion.id != suggestions.last?.id { Divider() }
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption.weight(.medium))
            }
        }
    }

    private func applicationAssociationRow(path: String, bundle: FolderObservation) -> some View {
        let folderName = URL(fileURLWithPath: path).lastPathComponent
        let hasSavedAccess = model.rememberedScopes.contains(where: { $0.path == path })
        let attribution = ApplicationPathAttribution.classify(
            bundleIdentifier: bundle.applicationBundleIdentifier,
            associatedFolderPath: path,
            homeDirectoryPath: NSHomeDirectory(),
            claimedGroupIdentifiers: bundle.applicationGroupIdentifiers,
            signatureValidated: bundle.applicationSignatureValidated,
            signedBundleIdentifier: bundle.applicationSignedBundleIdentifier
        )
        let attributionSymbol: String
        switch attribution.evidence {
        case .signatureCoveredSharedGroupClaim:
            attributionSymbol = "person.2.badge.gearshape.fill"
        case .declaredSharedGroupContainerClaim:
            attributionSymbol = "person.2.badge.gearshape"
        case .validatedBundleIdentifierPathMatch:
            attributionSymbol = "folder.badge.questionmark"
        case .probableContainerPathMatch:
            attributionSymbol = "folder.badge.questionmark"
        case .probableNamedSupportPathMatch:
            attributionSymbol = "folder.badge.questionmark"
        case .userSelectedOnly:
            attributionSymbol = "person.crop.circle.badge.questionmark"
        }

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(path)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label(attribution.title, systemImage: attributionSymbol)
                    .font(.caption2)
                    .foregroundStyle(attribution.evidence == .userSelectedOnly ? Color.secondary : Color.blue)
                Text(attribution.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let observation = model.latestFolderObservation(at: path) {
                    HStack(spacing: 8) {
                        Text("Logical \(format(observation.logicalBytes))")
                        Text("Allocated estimate \(format(observation.allocatedBytes))")
                        Text("Measured \(observation.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                        if observation.complete {
                            Text("Complete")
                                .foregroundStyle(.green)
                            if let previous = model.previousCompleteObservation(for: observation),
                               let delta = ObservationComparison.allocatedByteDelta(
                                current: observation, previous: previous
                               ) {
                                Text("\(changeDescription(delta)) since \(previous.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .foregroundStyle(delta >= 0 ? .orange : .green)
                            } else {
                                Text("First complete measurement")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(coverageSummary(
                                inaccessible: observation.inaccessibleCount,
                                excludedSymlinks: observation.excludedSymlinkCount,
                                excludedSpecialFiles: observation.excludedSpecialFileCount,
                                excludedVolumeBoundaries: observation.excludedVolumeBoundaryCount,
                                changed: observation.changedDuringScanCount,
                                wasCancelled: model.scanWasCancelled(for: observation),
                                accountingOverflowed: observation.byteAccountingOverflowed
                            ))
                            .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Selected for association; no measurement saved yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button(hasSavedAccess ? "Rescan" : "Select to rescan…") {
                model.rescanAssociatedFolder(path)
            }
            .controlSize(.small)
            .disabled(model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
            .help(hasSavedAccess ? "Measure this selected app-associated folder again" : "Re-select this exact folder to measure it again")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Reveal associated folder in Finder")
            .accessibilityLabel("Reveal \(folderName) in Finder")
            Button {
                model.removeRelatedFolder(path, from: bundle.path)
            } label: {
                Image(systemName: "link.badge.minus")
            }
            .buttonStyle(.borderless)
            .help("Remove Disker's association; files and scan history remain")
            .accessibilityLabel("Remove association for \(folderName)")
        }
        .padding(.vertical, 4)
        .background(alignment: .bottom) { Divider() }
    }

    private func chooseDuplicateFolders() {
        let panel = NSOpenPanel()
        panel.title = "Choose folders for duplicate verification"
        panel.prompt = "Choose Folders"
        panel.message = "Disker will inspect file metadata to find same-size candidates. It will not read file contents until you confirm the next step."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        guard panel.urls.count <= DuplicateVerifier.maximumSelectedRootCount else {
            model.errorMessage = "Choose no more than \(DuplicateVerifier.maximumSelectedRootCount) locations for duplicate verification. No file contents were read."
            return
        }

        model.verifyDuplicates(in: panel.urls)
    }

    private func duplicateCoverageSummary(_ result: DuplicateVerificationResult) -> String {
        var reasons: [String] = []
        if result.selectedRootLimitExceeded {
            return "Not run · choose no more than \(DuplicateVerifier.maximumSelectedRootCount) locations; no file contents were read"
        }
        if result.byteAccountingOverflowed { reasons.append("allocated-byte estimate exceeded the supported range and was capped") }
        if result.inaccessibleCount > 0 { reasons.append("\(result.inaccessibleCount) inaccessible") }
        if result.excludedSymlinkCount > 0 { reasons.append("\(result.excludedSymlinkCount) symlinks skipped") }
        if result.excludedSpecialFileCount > 0 { reasons.append("\(result.excludedSpecialFileCount) special files skipped") }
        if result.excludedVolumeBoundaryCount > 0 { reasons.append("\(result.excludedVolumeBoundaryCount) nested volume boundaries skipped") }
        if result.changedDuringCheckCount > 0 { reasons.append("\(result.changedDuringCheckCount) items changed") }
        if result.cancelled { reasons.append("cancelled") }
        return "Partial coverage · " + reasons.joined(separator: " · ")
    }

    private var ramPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header("RAM", subtitle: "Physical memory, process resident sizes, swap, and reported pressure transitions.")
                Toggle(isOn: $isAutomaticRAMSamplingEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sample RAM and watch pressure changes")
                            .font(.subheadline.weight(.medium))
                        Text("RAM samples arrive every five minutes; system pressure is recorded only when macOS reports a transition. This pauses while Disker is inactive and runs no background service.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityHint("When enabled, Disker saves a RAM sample every five minutes and records system pressure transitions while this app is active. It pauses when the app is inactive and is off again next time Disker opens.")
                if let ram = model.ram {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("Physical RAM", systemImage: "memorychip")
                                .font(.headline)
                            Spacer()
                            if model.isSamplingRAM {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Sampling RAM")
                            }
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(ram.observedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                Text(ram.observedAt, style: .relative)
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(format(ram.physicalBytes))
                                .font(.system(size: 38, weight: .semibold, design: .rounded))
                            Text("installed")
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 118), alignment: .leading)],
                            alignment: .leading, spacing: 14
                        ) {
                            ramMetric("Free pages", bytes: ram.freeBytes)
                            ramMetric("Active", bytes: ram.activeBytes)
                            ramMetric("Wired", bytes: ram.wiredBytes)
                            ramMetric("Compressed", bytes: ram.compressedBytes)
                            if let swap = ram.swapUsage {
                                if swap.totalBytes == 0 {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Swap")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("No allocation")
                                            .font(.system(.body, design: .rounded).weight(.medium))
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Swap used / total")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("\(format(swap.usedBytes)) / \(format(swap.totalBytes))")
                                            .font(.system(.body, design: .rounded).weight(.medium))
                                    }
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Swap")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Unavailable")
                                        .font(.system(.body, design: .rounded).weight(.medium))
                                }
                            }
                        }
                        Text("Kernel page counts are a point-in-time view. Inactive pages may be reclaimable cache; these values are not a single additive ‘used’ total and are not macOS memory pressure.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("RAM history")
                            .font(.title3.weight(.semibold))
                        let allRAMSamples = model.history.ramObservations
                        let latestRAMDate = allRAMSamples.last?.observedAt ?? .now
                        let ramSamples = allRAMSamples.filter {
                            historyChartRange.includes($0.observedAt, relativeTo: latestRAMDate)
                        }.sorted { $0.observedAt < $1.observedAt }
                        if !allRAMSamples.isEmpty { historyRangePicker }
                        Text("Free and compressed pages, plus reported swap use, across \(ramSamples.count) samples in the \(historyRangeCaption(endingAt: latestRAMDate)). Dots are observed snapshots; nothing is interpolated between them, and gaps mean no observation. This is not a pressure or leak diagnosis.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if ramSamples.count > 1 {
                            Chart(ramSamples, id: \.observedAt) { sample in
                                PointMark(
                                    x: .value("Sample time", sample.observedAt),
                                    y: .value("MiB", Double(sample.freeBytes) / 1_048_576)
                                )
                                .foregroundStyle(by: .value("Metric", "Free pages"))
                                PointMark(
                                    x: .value("Sample time", sample.observedAt),
                                    y: .value("MiB", Double(sample.compressedBytes) / 1_048_576)
                                )
                                .foregroundStyle(by: .value("Metric", "Compressed pages"))
                                if let swap = sample.swapUsage {
                                    PointMark(
                                        x: .value("Sample time", sample.observedAt),
                                        y: .value("MiB", Double(swap.usedBytes) / 1_048_576)
                                    )
                                    .foregroundStyle(by: .value("Metric", "Swap used"))
                                }
                            }
                            .chartLegend(position: .bottom, alignment: .leading)
                            .chartYAxisLabel("MiB")
                            .frame(height: 180)
                            .accessibilityLabel("RAM snapshot points for \(historyChartRange.title), \(ramSamples.count) observations of free and compressed pages and reported swap use")
                        } else {
                            Text(ramSamples.isEmpty
                                 ? "No RAM sample is available. Take a sample to begin RAM history."
                                 : "One sample falls within \(historyRangeCaption(endingAt: latestRAMDate)); another is needed to draw a history chart.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("A possible process-growth signal needs a continuous series of available samples for the same PID, name, and kernel start time, at least three samples spanning 15 minutes or more, and a resident-size increase of 100 MiB or more.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))

                    let growthSignals = ObservationComparison.possibleProcessGrowth(in: model.history)
                    if !growthSignals.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Possible sustained resident-size growth")
                                .font(.title3.weight(.semibold))
                            ForEach(growthSignals) { signal in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(signal.processName).font(.headline)
                                        Text("PID \(signal.processID)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("+\(format(signal.growthBytes))")
                                            .foregroundStyle(.orange)
                                    }
                                    Text("\(signal.firstObservedAt.formatted(date: .abbreviated, time: .shortened)) to \(signal.lastObservedAt.formatted(date: .abbreviated, time: .shortened)) · resident size")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                                Divider()
                            }
                            Text("This is an investigation signal only. Workload changes and caches can explain resident-size growth; it is not proof of a memory leak.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(20)
                        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Processes by resident size").font(.title3.weight(.semibold))
                        ForEach(ram.largestProcesses) { process in
                            HStack {
                                Image(systemName: "app.dashed").foregroundStyle(.secondary)
                                Text(process.name).lineLimit(1)
                                Text("PID \(process.processID)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(format(process.residentBytes))
                                    .font(.system(.body, design: .rounded).weight(.medium))
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                        Text(ram.processListAvailable
                             ? "Resident size is not the same as physical footprint. \(ram.sampledProcessCount) processes sampled; \(ram.unavailableProcessCount) exited during sampling or were inaccessible."
                             : "Resident size is not the same as physical footprint. macOS did not allow this process list to be read; system RAM counts above are still available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    ContentUnavailableView {
                        Label("No RAM sample yet", systemImage: "memorychip")
                    } description: {
                        Text("Take a point-in-time sample of system RAM and process resident sizes.")
                    } actions: {
                        Button {
                            model.refreshRAM()
                        } label: {
                            if model.isSamplingRAM {
                                Label("Sampling RAM…", systemImage: "hourglass")
                            } else {
                                Text("Sample RAM")
                            }
                        }
                        .disabled(model.isSamplingRAM)
                    }
                }
                memoryPressureCard
            }
            .padding(30)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(model.isSamplingRAM ? "Sampling RAM…" : "Refresh RAM", action: model.refreshRAM)
                    .disabled(model.isSamplingRAM)
            }
        }
    }

    private var memoryPressureCard: some View {
        let recentEvents = Array(model.history.memoryPressureObservations.suffix(12).reversed())
        return VStack(alignment: .leading, spacing: 10) {
            Label("System memory-pressure transitions", systemImage: "waveform.path.ecg")
                .font(.title3.weight(.semibold))
            Text("These are system-wide transitions macOS reported while Disker was active and monitoring was enabled. Gaps and periods before the first event are unknown; no event does not mean normal pressure.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if recentEvents.isEmpty {
                Text(isAutomaticRAMSamplingEnabled
                     ? "Waiting for a pressure transition. Current system pressure is unknown."
                     : "Enable RAM monitoring to observe pressure transitions while Disker is active.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                if model.history.memoryPressureObservations.count > recentEvents.count {
                    Text("Showing the latest \(recentEvents.count) of \(model.history.memoryPressureObservations.count) retained transitions.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(recentEvents) { event in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(event.level == .critical ? .red : event.level == .warning ? .orange : .green)
                            .frame(width: 8, height: 8)
                        Text(event.level.rawValue.capitalized)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(event.observedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Divider()
                }
            }
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
    }

    private func folderList(
        _ folders: [FolderObservation], title: String, scanCancelled: Bool,
        includeDetails: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            ForEach(folders.sorted { $0.allocatedBytes > $1.allocatedBytes }) { folder in
                let projectPaths = Set(folder.projectDirectorySummaries.map(\.rootRelativePath))
                let rankedSubdirectories = folder.subdirectorySummaries.filter {
                    !projectPaths.contains($0.rootRelativePath)
                }
                HStack(spacing: 14) {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(folder.displayName).font(.headline)
                        Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if folder.gitMetadataEntryDetected {
                            Label("Git metadata marker detected", systemImage: "chevron.left.forwardslash.chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        HStack(spacing: 8) {
                            Text("Logical \(format(folder.logicalBytes))")
                            Text("Allocated estimate \(format(folder.allocatedBytes))")
                            if !folder.complete {
                                Text(coverageSummary(
                                    inaccessible: folder.inaccessibleCount,
                                    excludedSymlinks: folder.excludedSymlinkCount,
                                    excludedSpecialFiles: folder.excludedSpecialFileCount,
                                    excludedVolumeBoundaries: folder.excludedVolumeBoundaryCount,
                                    changed: folder.changedDuringScanCount,
                                    wasCancelled: scanCancelled,
                                    accountingOverflowed: folder.byteAccountingOverflowed
                                ))
                                .foregroundStyle(.orange)
                            }
                            if let previous = model.previousCompleteObservation(for: folder) {
                                if let delta = ObservationComparison.allocatedByteDelta(current: folder, previous: previous) {
                                    Text(changeDescription(delta))
                                        .foregroundStyle(delta >= 0 ? .orange : .green)
                                } else {
                                    Text("Comparison unavailable")
                                        .foregroundStyle(.secondary)
                                }
                            } else if folder.complete {
                                Text(model.directoryHistoryLabel(for: folder))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        if includeDetails && !folder.fileExtensionSummaries.isEmpty {
                            fileExtensionSummary(for: folder)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(format(folder.allocatedBytes))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(folder.displayName) in Finder")
                }
                .padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))

                if includeDetails {
                    folderHistoryChart(for: folder)
                }

                if includeDetails, let gitUsage = folder.gitMetadataUsage {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Git metadata in this selected folder", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.subheadline.weight(.semibold))
                        Text("Measured at \(gitUsage.rootRelativePath). The marker identifies Git metadata here; Disker does not read repository configuration or infer ownership of other files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 9) {
                            Text("Logical \(format(gitUsage.logicalBytes))")
                            Text("Allocated ~\(format(gitUsage.allocatedBytes))")
                                .help("Allocated-byte estimate from filesystem metadata")
                            Text("\(gitUsage.fileCount) files")
                            if !gitUsage.complete {
                                Text(coverageSummary(
                                    inaccessible: gitUsage.incompleteCount,
                                    excludedSymlinks: gitUsage.excludedSymlinkCount,
                                    excludedSpecialFiles: gitUsage.excludedSpecialFileCount,
                                    excludedVolumeBoundaries: gitUsage.excludedVolumeBoundaryCount,
                                    changed: gitUsage.changedDuringScanCount,
                                    wasCancelled: scanCancelled,
                                    accountingOverflowed: folder.byteAccountingOverflowed
                                ))
                                .foregroundStyle(.orange)
                            } else if let previous = model.previousCompleteDirectory(for: gitUsage, in: folder),
                                      let delta = ObservationComparison.allocatedByteDelta(current: gitUsage, previous: previous),
                                      let previousFolder = model.previousCompleteObservation(for: folder) {
                                directoryChangeLabel(delta, previous: previousFolder, current: folder)
                            } else if gitUsage.complete {
                                Text(model.directoryHistoryLabel(for: folder))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }

                if includeDetails && (!folder.projectDirectorySummaries.isEmpty
                                      || folder.projectDirectorySummariesTruncated) {
                    projectDirectorySection(for: folder, scanCancelled: scanCancelled)
                }

                if includeDetails && !rankedSubdirectories.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Largest subfolders")
                            .font(.subheadline.weight(.semibold))
                        Text("Ranked by allocated-byte estimate. Nested folders overlap, so these rows are not additive. Hard-linked files are counted once and assigned to one path.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Some exact directory names get a descriptive development-data hint. A name match does not confirm ownership or mean the contents are safe to remove.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(rankedSubdirectories, id: \.rootRelativePath) { directory in
                            let directoryURL = URL(fileURLWithPath: folder.path)
                                .appendingPathComponent(directory.rootRelativePath, isDirectory: true)
                            HStack(spacing: 10) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(directory.rootRelativePath)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let hint = StorageAreaHint.matching(relativePath: directory.rootRelativePath) {
                                        Label("\(hint.title) · name match", systemImage: hint.symbolName)
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                    }
                                    HStack(spacing: 8) {
                                        Text("Logical \(format(directory.logicalBytes))")
                                Text("Allocated ~\(format(directory.allocatedBytes))")
                                    .help("Allocated-byte estimate from filesystem metadata")
                                        Text("\(directory.fileCount) files")
                                        if directory.gitMetadataEntryDetected {
                                            Text("Git metadata marker detected")
                                                .foregroundStyle(.blue)
                                        }
                                        if !directory.complete {
                                            Text(coverageSummary(
                                                inaccessible: directory.incompleteCount,
                                                excludedSymlinks: directory.excludedSymlinkCount,
                                                excludedSpecialFiles: directory.excludedSpecialFileCount,
                                                excludedVolumeBoundaries: directory.excludedVolumeBoundaryCount,
                                                changed: directory.changedDuringScanCount,
                                                wasCancelled: scanCancelled,
                                                accountingOverflowed: folder.byteAccountingOverflowed
                                            ))
                                            .foregroundStyle(.orange)
                                        } else if let previous = model.previousCompleteDirectory(
                                            for: directory, in: folder
                                        ), let delta = ObservationComparison.allocatedByteDelta(
                                            current: directory, previous: previous
                                        ), let previousFolder = model.previousCompleteObservation(for: folder) {
                                            directoryChangeLabel(delta, previous: previousFolder, current: folder)
                                        } else if directory.complete {
                                            Text(model.directoryHistoryLabel(for: folder))
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Text(format(directory.allocatedBytes))
                                    .font(.system(.caption, design: .rounded).weight(.semibold))
                                Button("Scan this folder…") {
                                    model.chooseFolders(startingAt: directoryURL)
                                }
                                .controlSize(.small)
                                .help("Choose this subfolder as a new scan root")
                                .accessibilityLabel("Choose \(directory.rootRelativePath) for a new scan")
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .buttonStyle(.borderless)
                                .help("Reveal subfolder in Finder")
                                .accessibilityLabel("Reveal \(directory.rootRelativePath) in Finder")
                            }
                            .padding(.vertical, 7)
                            Divider()
                        }
                        if folder.subdirectorySummariesTruncated {
                            Text("Showing the 100 largest subfolders. The root total includes the full scan.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                if includeDetails && !folder.largestFiles.isEmpty {
                    largestFileSection(for: folder)
                }
            }
            if let latest = model.latestScan {
                Text("Scan finished \(latest.finishedAt.formatted(date: .abbreviated, time: .shortened)) · \(latest.folders.count) selected locations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func projectDirectorySection(
        for folder: FolderObservation, scanCancelled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Project and development-data candidates", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.subheadline.weight(.semibold))
            Text("Entries have a direct `.git` marker or an exact development-data directory name. These are candidates, not verified project ownership or safe cleanup targets. Name matches do not inspect contents; nested folder totals overlap.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if folder.projectDirectorySummariesTruncated {
                Text("Showing the 20 largest candidates; additional matching paths were omitted.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            ForEach(folder.projectDirectorySummaries, id: \.rootRelativePath) { directory in
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(directory.rootRelativePath)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if directory.gitMetadataEntryDetected {
                            Label("Direct `.git` marker · candidate", systemImage: "folder.badge.questionmark")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        if let hint = StorageAreaHint.matchingDirectory(relativePath: directory.rootRelativePath) {
                            Label("\(hint.title) · exact directory-name match", systemImage: "tag")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        HStack(spacing: 8) {
                            Text("Logical \(format(directory.logicalBytes))")
                            Text("Allocated ~\(format(directory.allocatedBytes))")
                                .help("Allocated-byte estimate from filesystem metadata")
                            Text("\(directory.fileCount) files")
                            if !directory.complete {
                                Text(coverageSummary(
                                    inaccessible: directory.incompleteCount,
                                    excludedSymlinks: directory.excludedSymlinkCount,
                                    excludedSpecialFiles: directory.excludedSpecialFileCount,
                                    excludedVolumeBoundaries: directory.excludedVolumeBoundaryCount,
                                    changed: directory.changedDuringScanCount,
                                    wasCancelled: scanCancelled,
                                    accountingOverflowed: folder.byteAccountingOverflowed
                                ))
                                .foregroundStyle(.orange)
                            } else if let previous = model.previousCompleteDirectory(
                                for: directory, in: folder
                            ), let delta = ObservationComparison.allocatedByteDelta(
                                current: directory, previous: previous
                            ), let previousFolder = model.previousCompleteObservation(for: folder) {
                                directoryChangeLabel(delta, previous: previousFolder, current: folder)
                            } else if directory.complete {
                                Text(model.directoryHistoryLabel(for: folder))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 5)
                    Button("Review") { developerArtifactReviewFolder = folder }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Review development data in \(folder.displayName)")
                    Button {
                        let url = URL(fileURLWithPath: folder.path)
                            .appendingPathComponent(directory.rootRelativePath, isDirectory: true)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal repository-marker folder in Finder")
                    .accessibilityLabel("Reveal \(directory.rootRelativePath) in Finder")
                }
                .padding(.vertical, 7)
                Divider()
            }
        }
        .padding(14)
        .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func largestFileSection(for folder: FolderObservation) -> some View {
        var growthByPath: [String: ObservationComparison.FileGrowthSignal] = [:]
        for signal in ObservationComparison.growingFiles(for: folder, in: model.history) {
            growthByPath[signal.file.rootRelativePath] = signal
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Largest files")
                .font(.subheadline.weight(.semibold))
            Text("Ranked by allocated-byte estimate from metadata. Logical size is separate. Growth is shown only for paths present in both complete scans; omitted paths are unknown, and file size does not imply cleanup safety.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(folder.largestFiles) { file in
                let fileURL = file.rootRelativePath.isEmpty
                    ? URL(fileURLWithPath: folder.path)
                    : URL(fileURLWithPath: folder.path).appendingPathComponent(file.rootRelativePath)
                HStack(spacing: 10) {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.rootRelativePath.isEmpty ? folder.displayName : file.rootRelativePath)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 8) {
                            Text("Logical \(format(file.logicalBytes))")
                            Text("Allocated ~\(format(file.allocatedBytes))")
                                .help("Allocated-byte estimate from filesystem metadata")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        if let growth = growthByPath[file.rootRelativePath] {
                            Text("Allocated estimate increased \(format(growth.growthBytes)) since \(growth.previousFolder.finishedAt.formatted(date: .abbreviated, time: .shortened)).")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(format(file.allocatedBytes))
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(file.rootRelativePath.isEmpty ? folder.displayName : file.rootRelativePath)")
                }
                .padding(.vertical, 7)
                Divider()
            }
            if folder.largestFilesTruncated {
                Text("Additional files were omitted from this bounded summary.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func fileExtensionSummary(for folder: FolderObservation) -> some View {
        let summaries = Array(folder.fileExtensionSummaries.prefix(5))
        let growth = ObservationComparison.growingFileExtensions(for: folder, in: model.history)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Largest filename extensions · allocated estimate")
                .font(.caption2.weight(.semibold))
            ForEach(summaries) { item in
                HStack(spacing: 8) {
                    Text(item.extensionName == "no extension" ? "No extension" : ".\(item.extensionName)")
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                    if let hint = FileArtifactHint.matching(extensionName: item.extensionName) {
                        Label(hint.title, systemImage: "tag")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                            .help("Filename-based clue only. Disker does not inspect this category's contents or determine whether it is safe to remove.")
                    }
                    Text("\(item.fileCount) files")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(format(item.allocatedBytes))
                        .font(.caption2.monospacedDigit())
                }
            }
            if folder.fileExtensionSummariesTruncated || folder.fileExtensionSummaries.count > summaries.count {
                Text(folder.fileExtensionSummariesTruncated
                     ? "Showing the five largest of the 30 retained filename categories."
                     : "Showing the five largest filename categories.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let other = folder.otherFileExtensionUsage,
               folder.otherFileExtensionCategoryCount > 0 {
                HStack(spacing: 8) {
                    Text("Other \(folder.otherFileExtensionCategoryCount) extensions")
                        .font(.caption2)
                    Text("\(other.fileCount) files")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(format(other.allocatedBytes))
                        .font(.caption2.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
                .help("Combined allocated-byte estimate for filename categories beyond the 30-category retention limit.")
            }
            if let growth, !growth.isEmpty,
               let previous = model.previousCompleteObservation(for: folder) {
                Text("Growing categories · allocated estimate · \(previous.finishedAt.formatted(date: .abbreviated, time: .shortened)) → \(folder.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2.weight(.semibold))
                    .padding(.top, 2)
                ForEach(growth) { item in
                    HStack(spacing: 8) {
                        Text(item.extensionName == "no extension" ? "No extension" : ".\(item.extensionName)")
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(formattedDelta(item.growthBytes))
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundStyle(.orange)
                            Text("At latest scan ~\(format(item.currentAllocatedBytes)) allocated")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

            }
            Text("Grouped by filename only; content and purpose are not verified. Estimates share this scan's coverage.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func header(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func metric(
        _ title: String, value: Int64, alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(format(value)).font(.system(.title3, design: .rounded).weight(.medium))
        }
    }

    private func ramMetric(_ title: String, bytes: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(format(bytes)).font(.system(.body, design: .rounded).weight(.medium))
        }
    }

    @ViewBuilder
    private func folderHistoryChart(for folder: FolderObservation) -> some View {
        let fullSeries = ObservationComparison.completeFolderSeries(for: folder, in: model.history)
        let latestDate = fullSeries.map(\.finishedAt).max() ?? .now
        let samples = fullSeries.filter {
            historyChartRange.includes($0.finishedAt, relativeTo: latestDate)
        }.sorted { $0.finishedAt < $1.finishedAt }
        if samples.count > 1 {
            let visibleSamples = samples
            let values = visibleSamples.map { Double($0.allocatedBytes) / 1_073_741_824 }
            let minimum = values.min() ?? 0
            let maximum = values.max() ?? minimum
            let padding = max((maximum - minimum) * 0.15, 0.25)
            Chart(visibleSamples, id: \.id) { sample in
                LineMark(
                    x: .value("Observed", sample.finishedAt),
                    y: .value("Allocated GiB", Double(sample.allocatedBytes) / 1_073_741_824)
                )
                .foregroundStyle(.indigo)
                PointMark(
                    x: .value("Observed", sample.finishedAt),
                    y: .value("Allocated GiB", Double(sample.allocatedBytes) / 1_073_741_824)
                )
                .foregroundStyle(.indigo)
            }
            .chartYScale(domain: max(0, minimum - padding)...(maximum + padding))
            .chartYAxisLabel("Allocated (GiB)")
            .frame(height: 112)
            .accessibilityLabel("Allocated-size history from \(visibleSamples.count) complete scans of \(folder.path)")
            Text("\(visibleSamples.count) complete scans of this selected path · \(historyRangeCaption(endingAt: latestDate)) · focused vertical scale")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if !fullSeries.isEmpty {
            Text("Fewer than two complete observations of this path in \(historyRangeCaption(endingAt: latestDate)).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var historyRangePicker: some View {
        Picker("History range", selection: $historyChartRange) {
            ForEach(ObservationTimeRange.allCases) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("History chart range")
    }

    private func historyRangeCaption(endingAt date: Date) -> String {
        "\(historyChartRange.title) ending \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .memory)
    }

    private func formattedByteRate(_ bytesPerDay: Double) -> String {
        let maximum = Double(Int64.max) * 0.999
        let bounded = min(max(bytesPerDay, 0), maximum)
        return format(Int64(bounded.rounded()))
    }

    private func formattedDelta(_ bytes: Int64) -> String {
        let magnitude = bytes == Int64.min ? Int64.max : abs(bytes)
        return "\(bytes >= 0 ? "+" : "−")\(format(magnitude))"
    }

    private func changeDescription(_ bytes: Int64) -> String {
        bytes == 0 ? "No allocated-size change" : "Since previous \(formattedDelta(bytes))"
    }

    private func directoryChangeLabel(
        _ bytes: Int64, previous: FolderObservation, current: FolderObservation
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(changeDescription(bytes))
                .foregroundStyle(bytes >= 0 ? .orange : .green)
            Text("Complete scans: \(previous.finishedAt.formatted(date: .abbreviated, time: .shortened)) → \(current.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func coverageSummary(
        inaccessible: Int, excludedSymlinks: Int, excludedSpecialFiles: Int = 0,
        excludedVolumeBoundaries: Int = 0,
        changed: Int, wasCancelled: Bool, accountingOverflowed: Bool = false
    ) -> String {
        var details: [String] = []
        if accountingOverflowed { details.append("byte total exceeded the supported range and was capped") }
        if inaccessible > 0 { details.append("\(inaccessible) unmeasured") }
        if excludedSymlinks > 0 { details.append("\(excludedSymlinks) symlinks not followed") }
        if excludedSpecialFiles > 0 { details.append("\(excludedSpecialFiles) special files excluded") }
        if excludedVolumeBoundaries > 0 { details.append("\(excludedVolumeBoundaries) nested volume boundaries skipped") }
        if changed > 0 { details.append("\(changed) changed during scan") }
        if wasCancelled && details.isEmpty { details.append("scan cancelled") }
        return details.isEmpty ? "Coverage incomplete" : "Partial · " + details.joined(separator: " · ")
    }

    private func icon(for section: String) -> String {
        switch section {
        case "Applications": "app.dashed"
        case "Folders": "folder"
        case "Duplicates": "doc.on.doc"
        case "History": "clock.arrow.circlepath"
        case "RAM": "memorychip"
        case "About": "info.circle"
        default: "chart.pie"
        }
    }
}

private struct DeveloperArtifactReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let folder: FolderObservation
    let onRescan: (URL) -> Void

    private var review: DeveloperArtifactReview {
        DeveloperArtifactReview.make(from: folder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Development data review")
                        .font(.title2.weight(.semibold))
                    Text(folder.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
                } label: {
                    Label("Reveal root", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 14) {
                Label(folder.complete ? "Complete observation" : "Partial observation", systemImage: folder.complete ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(folder.complete ? Color.secondary : Color.orange)
                Text("Measured \(folder.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Text("These measured paths are review leads based on directory names or a direct Git marker. Disker did not read their contents or determine current use, ownership, or safe removal. Logical size and allocated-byte estimate are separate; reclaimable bytes are unknown.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if review.candidatesTruncated {
                Label("Only the 20 largest retained candidates are shown. Omitted matching paths are unknown.", systemImage: "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }

            if review.entries.isEmpty {
                ContentUnavailableView("No measured candidates", systemImage: "shippingbox", description: Text("This scan did not retain any directories with a recognized name or direct Git marker."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(review.entries) { entry in
                            developerArtifactEntry(entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func developerArtifactEntry(_ entry: DeveloperArtifactReview.Entry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(for: entry.category))
                    .foregroundStyle(.blue)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.relativePath)
                        .font(.subheadline.weight(.semibold).monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(entry.category.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text(entry.risk)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 210, alignment: .trailing)
            }

            HStack(spacing: 12) {
                Text("Logical \(format(entry.logicalBytes))")
                Text("Allocated ~\(format(entry.allocatedBytesEstimate))")
                    .help("Filesystem allocation estimate; not reclaimable bytes")
                Text("\(entry.fileCount.formatted()) files")
                Text(entry.subtreeComplete ? "Subtree complete" : "Subtree partial")
                    .foregroundStyle(entry.subtreeComplete ? Color.secondary : Color.orange)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(entry.evidence)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.possibleConsequence)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.caution)
                .font(.caption)
                .foregroundStyle(entry.subtreeComplete && entry.selectedRootComplete ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            if !entry.overlappingCandidatePaths.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Overlapping candidate measurements · do not add")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                    ForEach(entry.overlappingCandidatePaths, id: \.self) { path in
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            HStack {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                } label: {
                    Label("Reveal in Finder", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Choose this folder to rescan…") {
                    onRescan(URL(fileURLWithPath: entry.path, isDirectory: true))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Opens the native folder picker. Disker will scan only after you select a folder.")
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func symbol(for category: DeveloperArtifactReview.Category) -> String {
        switch category {
        case .sourceControl: "chevron.left.forwardslash.chevron.right"
        case .buildProducts: "hammer"
        case .dependencies, .packageManagerData: "shippingbox"
        case .runtimeAndSimulatorData, .archiveOrSymbols: "externaldrive"
        case .userData: "externaldrive.badge.exclamationmark"
        case .logs: "doc.text"
        case .testOutput: "checkmark.rectangle.stack"
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct ApplicationFootprintReviewSheet: View {
    let bundleName: String
    let review: ApplicationFootprintReview

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("App removal footprint", systemImage: "app.badge.checkmark")
                        .font(.title2.weight(.semibold))
                    Text(bundleName)
                        .font(.headline)
                    Text("Read-only review of the bundle and folders you associated with it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Label {
                    Text("Disker does not remove files or add these independent measurements together. Overlapping or shared paths can be counted more than once. Reclaimable physical space is unknown.")
                } icon: {
                    Image(systemName: "info.circle.fill")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

                ForEach(review.entries) { entry in
                    entryCard(entry)
                }

            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    @ViewBuilder
    private func entryCard(_ entry: ApplicationFootprintReview.Entry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(
                    entry.kind == .applicationBundle ? "Selected application bundle" : "Associated location",
                    systemImage: entry.kind == .applicationBundle ? "app.fill" : "folder"
                )
                .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                } label: {
                    Label("Reveal", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Reveal this exact path in Finder")
            }
            Text(entry.path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let observation = entry.observation {
                Text("Last measured \(observation.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption.weight(.medium))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Logical size: \(format(observation.logicalBytes))")
                    Text("Allocated estimate: ~\(format(observation.allocatedBytes))")
                    Text("\(observation.fileCount) files")
                }
                .font(.caption.monospacedDigit())
                if observation.complete {
                    Label("Complete coverage at that scan", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("Partial coverage at that scan · \(unmeasuredSummary(observation, wasCancelled: entry.scanWasCancelled))", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("No saved measurement for this path", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let attribution = entry.attribution {
                Label(attribution.title, systemImage: entry.isShared ? "person.2" : "questionmark.folder")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(entry.isShared ? Color.orange : Color.secondary)
                Text(attribution.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !entry.otherAssociatedBundlePaths.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Also associated with other applications · current use unknown", systemImage: "person.2")
                        .font(.caption.weight(.medium))
                    ForEach(entry.otherAssociatedBundlePaths, id: \.self) { path in
                        Text(path)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(.orange)
            }

            Text(consequence(for: entry))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            if !entry.overlappingPaths.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Overlaps another reviewed path", systemImage: "square.stack.3d.up")
                        .font(.caption.weight(.medium))
                    ForEach(entry.overlappingPaths, id: \.self) { path in
                        Text(path)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func consequence(for entry: ApplicationFootprintReview.Entry) -> String {
        guard entry.kind == .associatedFolder else {
            return "Removing the bundle may leave related data behind. Reinstallation might restore the app, but availability of a trusted installer has not been checked."
        }
        if entry.isShared {
            if entry.attribution?.evidence == .declaredSharedGroupContainerClaim
                || entry.attribution?.evidence == .signatureCoveredSharedGroupClaim {
                return "This path has a shared App Group claim; current use by other apps is unverified. It is excluded from any app-exclusive cleanup estimate."
            }
            return "Other app records also link this exact path; current use is unverified. It is excluded from any app-exclusive cleanup estimate."
        }
        if entry.attribution?.evidence == .probableNamedSupportPathMatch,
           URL(fileURLWithPath: entry.path).pathComponents.contains("Caches") {
            return "This path is under a conventional cache location. Its name does not prove that its contents are safe to remove or regenerate."
        }
        return "This location may contain unique documents, settings, databases, licenses, or app state. Ownership and recovery options are unverified."
    }

    private func unmeasuredSummary(_ observation: FolderObservation, wasCancelled: Bool) -> String {
        var reasons: [String] = []
        if observation.inaccessibleCount > 0 { reasons.append("\(observation.inaccessibleCount) inaccessible") }
        if observation.excludedSymlinkCount > 0 { reasons.append("\(observation.excludedSymlinkCount) symlinks skipped") }
        if observation.excludedSpecialFileCount > 0 { reasons.append("\(observation.excludedSpecialFileCount) special files skipped") }
        if observation.excludedVolumeBoundaryCount > 0 { reasons.append("\(observation.excludedVolumeBoundaryCount) volume boundaries skipped") }
        if observation.changedDuringScanCount > 0 { reasons.append("\(observation.changedDuringScanCount) changed during scan") }
        if observation.byteAccountingOverflowed { reasons.append("byte totals capped") }
        if wasCancelled { reasons.append("scan cancelled") }
        return reasons.isEmpty ? "some data may be unmeasured" : reasons.joined(separator: " · ")
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
