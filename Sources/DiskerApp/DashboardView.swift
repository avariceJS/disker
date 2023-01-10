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
    var duplicateResult: DuplicateVerificationResult?
    var isVerifyingDuplicates = false
    var duplicateCurrentPath = ""
    var duplicateBytesHashed: UInt64 = 0
    var duplicateCandidateBytes: UInt64 = 0
    var preservedDuplicatePaths: [String: String] = [:]
    var errorMessage: String?
    var currentPath = ""
    var visitedFiles = 0
    private var scanTask: Task<ScanObservation, Never>?
    private var duplicateTask: Task<DuplicateVerificationResult, Never>?

    init() {
        do {
            history = try ObservationStore.load()
            ram = history.ramObservations.last
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var latestScan: ScanObservation? { history.observations.last }

    var measuredApplicationBundles: [FolderObservation] {
        ApplicationBundleIndex.latestMeasurements(in: history)
    }

    func scanWasCancelled(for folder: FolderObservation) -> Bool {
        history.observations.last(where: { observation in
            observation.folders.contains(where: { $0.id == folder.id })
        })?.cancelled ?? false
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

    func refreshRAM() {
        Task {
            do {
                let sample = try await Task.detached(priority: .utility) {
                    try RAMObservation.current()
                }.value
                ram = sample
                do {
                    history = try ObservationStore.append(sample)
                } catch {
                    errorMessage = "RAM sample completed, but local history could not be saved: \(error.localizedDescription)"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func chooseFolders(startingAt directory: URL? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Choose folders to measure"
        panel.prompt = "Scan Folders"
        panel.message = "Disker reads file metadata in the folders you select. File contents are not opened."
        panel.directoryURL = directory
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }
        scan(panel.urls)
    }

    func chooseApplicationBundle(startingAt directory: URL? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Choose an application bundle to measure"
        panel.prompt = "Measure Bundle"
        panel.message = "Disker measures only the selected .app bundle. Support data, caches, and shared files are not included."
        panel.directoryURL = directory
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK else { return }
        scan(panel.urls)
    }

    func scan(_ urls: [URL]) {
        guard !urls.isEmpty, !isScanning else { return }
        isScanning = true
        currentPath = ""
        visitedFiles = 0
        let scanTask = Task.detached(priority: .utility) {
            FolderScanner.scan(roots: urls, progress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.currentPath = progress.currentPath
                    self?.visitedFiles = progress.visitedFiles
                }
            })
        }
        self.scanTask = scanTask
        Task {
            let result = await scanTask.value
            do {
                history = try ObservationStore.append(result)
            } catch {
                errorMessage = "Scan finished, but local history could not be saved: \(error.localizedDescription)"
            }
            isScanning = false
            currentPath = ""
            visitedFiles = 0
            self.scanTask = nil
            refreshCapacity()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    func verifyDuplicates(in roots: [URL]) {
        guard !roots.isEmpty, !isVerifyingDuplicates else { return }
        duplicateResult = nil
        preservedDuplicatePaths = [:]
        duplicateCurrentPath = ""
        duplicateBytesHashed = 0
        duplicateCandidateBytes = 0
        isVerifyingDuplicates = true
        let task = Task.detached(priority: .utility) {
            DuplicateVerifier.verify(roots: roots, progress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.duplicateCurrentPath = progress.currentPath
                    self?.duplicateBytesHashed = progress.bytesHashed
                    self?.duplicateCandidateBytes = progress.candidateBytes
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
        do {
            try ObservationStore.clear()
            history = LocalHistory()
            ram = nil
            errorMessage = nil
        } catch {
            errorMessage = "Local history could not be cleared: \(error.localizedDescription)"
        }
    }

    func previousCompleteObservation(for folder: FolderObservation) -> FolderObservation? {
        ObservationComparison.previousCompleteFolder(for: folder, in: history)
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
    @State private var isConfirmingHistoryClear = false

    private let sections = ["Overview", "Applications", "Folders", "Duplicates", "History", "RAM", "About"]

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
        .onAppear { model.refreshCapacity() }
        .onReceive(NotificationCenter.default.publisher(for: .chooseFoldersToScan)) { _ in
            model.chooseFolders()
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
            Button("Clear History", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes Disker’s saved capacity, folder, and RAM observations from this Mac. Your files and folders will not be changed.")
        }
    }

    private var overviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header("Storage overview", subtitle: "A measured view of your Mac's storage, with clear limits.")
                capacityCard
                scanCard
                if let latest = model.latestScan, !latest.folders.isEmpty {
                    folderList(latest.folders, title: "Largest selected folders", scanCancelled: latest.cancelled)
                } else {
                    emptyHistoryCard
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
                ProgressView(value: Double(capacity.availableBytes), total: Double(max(1, capacity.totalBytes)))
                    .tint(.blue)
                    .accessibilityLabel("Available capacity")
                    .accessibilityValue("\(format(capacity.availableBytes)) of \(format(capacity.totalBytes))")
                let capacitySeries = Array(ObservationComparison.comparableCapacitySeries(in: model.history).suffix(24))
                if capacitySeries.count > 1 {
                    let values = capacitySeries.map { Double($0.availableBytes) / 1_073_741_824 }
                    let minimum = values.min() ?? 0
                    let maximum = values.max() ?? minimum
                    let padding = max((maximum - minimum) * 0.15, max(Double(capacity.totalBytes) / 1_073_741_824 * 0.005, 0.25))
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
                    .accessibilityLabel("Available-space history for the latest \(capacitySeries.count) comparable observations")
                    Text("Latest comparable observations · focused vertical scale · not attributed to folders")
                        .font(.caption2)
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
                    Text("No earlier capacity measurement with this volume size and availability method is available for comparison.")
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
                         : "\(model.visitedFiles.formatted()) files visited · \(model.currentPath)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.currentPath.isEmpty
                                    ? "Scanning folders"
                                    : "Scanning folders, \(model.visitedFiles) files visited, current path \(model.currentPath)")
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
                        Text(model.currentPath.isEmpty ? "Starting bundle scan…" : "Scanning (model.currentPath)")
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
                            HStack(spacing: 12) {
                                Text("Logical \(format(bundle.logicalBytes))")
                                Text("Allocated estimate \(format(bundle.allocatedBytes))")
                                Text("\(bundle.fileCount) files")
                                if bundle.complete {
                                    Label("Complete", systemImage: "checkmark.circle")
                                        .foregroundStyle(.green)
                                } else {
                                    Text(coverageSummary(
                                        inaccessible: bundle.inaccessibleCount,
                                        excludedSymlinks: bundle.excludedSymlinkCount,
                                        changed: bundle.changedDuringScanCount,
                                        wasCancelled: model.scanWasCancelled(for: bundle)
                                    ))
                                    .foregroundStyle(.orange)
                                }
                                Spacer(minLength: 0)
                                Text(bundle.finishedAt.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption2)
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
                header("Selected folders", subtitle: "File sizes are measured only inside the locations you choose.")
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
                                            changed: folder.changedDuringScanCount,
                                            wasCancelled: observation.cancelled
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
                        Label("No file contents are read during folder scans.", systemImage: "hand.raised")
                        Label("Scan scope is chosen by you each time.", systemImage: "folder.badge.plus")
                        Label("No cleanup or deletion actions are available.", systemImage: "lock.shield")
                        Label("History stays in this Mac's Application Support folder.", systemImage: "internaldrive")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                } label: {
                    Text("Privacy and safety")
                }
                GroupBox {
                    Text("This build reports volume capacity from macOS and estimates selected-folder usage from file metadata. APFS snapshots, copy-on-write clones, shared blocks, system-managed data and inaccessible paths prevent a path scan from reconciling exactly with the system's capacity figures.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text("Measurement limits")
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Remove saved capacity measurements, folder paths and sizes, and RAM samples from this Mac. Scanned files are not changed.")
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

    private var duplicatesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(
                    "Duplicate review",
                    subtitle: "Confirm byte-identical files inside folders you choose. Disker will not change them."
                )
                if model.isVerifyingDuplicates {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Verifying same-size file candidates…")
                            .font(.headline)
                        if model.duplicateCandidateBytes > 0 {
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
                            Text("Read \(format(model.duplicateBytesHashed)) of \(format(model.duplicateCandidateBytes)) candidate bytes")
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
                            if !plan.sourceCoverageComplete {
                                Text("The verification scope was partial. This plan covers only groups that were confirmed; other matches may remain unmeasured.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(plan.entries) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Proposed candidate · risk unknown")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.orange)
                                    Text(entry.targetPath)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                    Text("Keep: \(entry.preservedPath)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                    Text("Logical \(format(entry.logicalBytes)) · allocated ~\(format(entry.allocatedBytesEstimate)) · expected reclaimable space unknown")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
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

    private func chooseDuplicateFolders() {
        let panel = NSOpenPanel()
        panel.title = "Choose folders for duplicate verification"
        panel.prompt = "Choose Folders"
        panel.message = "Disker will hash regular files with matching sizes in these folders. Contents of other files are not read."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let confirmation = NSAlert()
        confirmation.messageText = "Read selected files to verify duplicates?"
        confirmation.informativeText = "Disker will read contents only for regular files that share a logical size inside the selected folders. It will not modify files.\n\n" + panel.urls.map(\.path).joined(separator: "\n")
        confirmation.addButton(withTitle: "Read and Verify")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        model.verifyDuplicates(in: panel.urls)
    }

    private func duplicateCoverageSummary(_ result: DuplicateVerificationResult) -> String {
        var reasons: [String] = []
        if result.inaccessibleCount > 0 { reasons.append("\(result.inaccessibleCount) inaccessible") }
        if result.excludedSymlinkCount > 0 { reasons.append("\(result.excludedSymlinkCount) symlinks skipped") }
        if result.excludedSpecialFileCount > 0 { reasons.append("\(result.excludedSpecialFileCount) special files skipped") }
        if result.changedDuringCheckCount > 0 { reasons.append("\(result.changedDuringCheckCount) items changed") }
        if result.cancelled { reasons.append("cancelled") }
        return "Partial coverage · " + reasons.joined(separator: " · ")
    }

    private var ramPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header("RAM", subtitle: "A separate snapshot of physical memory and process resident sizes.")
                if let ram = model.ram {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("Physical RAM", systemImage: "memorychip")
                                .font(.headline)
                            Spacer()
                            Text(ram.observedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(format(ram.physicalBytes))
                                .font(.system(size: 38, weight: .semibold, design: .rounded))
                            Text("installed")
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 18) {
                            ramMetric("Free pages", bytes: ram.freeBytes)
                            ramMetric("Active", bytes: ram.activeBytes)
                            ramMetric("Wired", bytes: ram.wiredBytes)
                            ramMetric("Compressed", bytes: ram.compressedBytes)
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
                        Text("Manual RAM history")
                            .font(.title3.weight(.semibold))
                        Text("Free and compressed pages across your last 24 on-demand samples. These snapshots are not a memory-pressure or leak diagnosis.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Chart(Array(model.history.ramObservations.suffix(24)), id: \.observedAt) { sample in
                            LineMark(
                                x: .value("Sample time", sample.observedAt),
                                y: .value("MiB", Double(sample.freeBytes) / 1_048_576),
                                series: .value("Metric", "Free pages")
                            )
                            .foregroundStyle(by: .value("Metric", "Free pages"))
                            LineMark(
                                x: .value("Sample time", sample.observedAt),
                                y: .value("MiB", Double(sample.compressedBytes) / 1_048_576),
                                series: .value("Metric", "Compressed pages")
                            )
                            .foregroundStyle(by: .value("Metric", "Compressed pages"))
                        }
                        .chartLegend(position: .bottom, alignment: .leading)
                        .chartYAxisLabel("MiB")
                        .frame(height: 180)
                        .accessibilityLabel("Manual history of free and compressed RAM pages")
                        if model.history.ramObservations.count < 2 {
                            Text("Take another manual sample later to begin comparing observations.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("A possible process-growth signal requires the same PID and kernel start time in three consecutive samples spanning at least 15 minutes, with a resident-size increase of 100 MiB or more.")
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
                        Button("Sample RAM", action: model.refreshRAM)
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh RAM", action: model.refreshRAM)
            }
        }
    }

    private func folderList(
        _ folders: [FolderObservation], title: String, scanCancelled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            ForEach(folders.sorted { $0.allocatedBytes > $1.allocatedBytes }) { folder in
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
                                    changed: folder.changedDuringScanCount,
                                    wasCancelled: scanCancelled
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
                                Text("First complete observation")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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

                if let gitUsage = folder.gitMetadataUsage {
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
                                    changed: gitUsage.changedDuringScanCount,
                                    wasCancelled: scanCancelled
                                ))
                                .foregroundStyle(.orange)
                            } else if let previous = model.previousCompleteDirectory(for: gitUsage, in: folder),
                                      let delta = ObservationComparison.allocatedByteDelta(current: gitUsage, previous: previous) {
                                Text(changeDescription(delta))
                                    .foregroundStyle(delta >= 0 ? .orange : .green)
                            } else if gitUsage.complete {
                                Text("First complete observation")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }

                if !folder.subdirectorySummaries.isEmpty {
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

                        ForEach(folder.subdirectorySummaries, id: \.rootRelativePath) { directory in
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
                                                changed: directory.changedDuringScanCount,
                                                wasCancelled: scanCancelled
                                            ))
                                            .foregroundStyle(.orange)
                                        } else if let previous = model.previousCompleteDirectory(
                                            for: directory, in: folder
                                        ), let delta = ObservationComparison.allocatedByteDelta(
                                            current: directory, previous: previous
                                        ) {
                                            Text(changeDescription(delta))
                                                .foregroundStyle(delta >= 0 ? .orange : .green)
                                        } else if directory.complete {
                                            Text("First complete observation")
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
            }
            if let latest = model.latestScan {
                Text("Scan finished \(latest.finishedAt.formatted(date: .abbreviated, time: .shortened)) · \(latest.folders.count) selected locations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .memory)
    }

    private func formattedDelta(_ bytes: Int64) -> String {
        let magnitude = bytes == Int64.min ? Int64.max : abs(bytes)
        return "\(bytes >= 0 ? "+" : "−")\(format(magnitude))"
    }

    private func changeDescription(_ bytes: Int64) -> String {
        bytes == 0 ? "No allocated-size change" : "Since previous \(formattedDelta(bytes))"
    }

    private func coverageSummary(
        inaccessible: Int, excludedSymlinks: Int, changed: Int, wasCancelled: Bool
    ) -> String {
        var details: [String] = []
        if inaccessible > 0 { details.append("\(inaccessible) unmeasured") }
        if excludedSymlinks > 0 { details.append("\(excludedSymlinks) symlinks not followed") }
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
