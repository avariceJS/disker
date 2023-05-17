import AppKit
import Darwin
import Charts
import DiskerCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// ShipSwift's KPI-card pattern, adapted to native macOS control colors and
/// Disker's calm, system-first visual language.
private struct SWKPICard<Trailing: View>: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String
    let tint: Color
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: LocalizedStringKey,
        value: String,
        icon: String,
        tint: Color,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.value = value
        self.icon = icon
        self.tint = tint
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            trailing()
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.035), radius: 8, x: 0, y: 3)
        .accessibilityElement(children: .combine)
    }
}

private extension SWKPICard where Trailing == EmptyView {
    init(title: LocalizedStringKey, value: String, icon: String, tint: Color) {
        self.init(title: title, value: value, icon: icon, tint: tint) { EmptyView() }
    }
}

/// A compact semantic state chip adapted from ShipSwift's status-badge pattern.
/// It uses native system colors and adds no package or platform dependency.
private struct DiscoveryStatusBadge: View {
    enum Style {
        case measured, partial, unmeasured

        var tint: Color {
            switch self {
            case .measured: .green
            case .partial: .orange
            case .unmeasured: .secondary
            }
        }
    }

    let title: String
    let style: Style

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(style.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(style.tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(style.tint.opacity(0.28), lineWidth: 0.5))
            .accessibilityAddTraits(.isStaticText)
    }
}

/// ShipSwift's interactive donut pattern, adapted to selected-root byte
/// evidence and Disker's native compact detail layout.
private struct SWFileExtensionBreakdownChart: View {
    private enum SizeBasis: String, CaseIterable, Identifiable {
        case allocated
        case logical

        var id: String { rawValue }

        var title: String {
            switch self {
            case .allocated: NSLocalizedString("Allocated estimate", comment: "Filename chart size basis")
            case .logical: NSLocalizedString("Logical", comment: "Filename chart size basis")
            }
        }

        func bytes(in category: FileExtensionUsage) -> Int64 {
            switch self {
            case .allocated: category.allocatedBytes
            case .logical: category.logicalBytes
            }
        }
    }

    let categories: [FileExtensionUsage]
    let coverageComplete: Bool

    @State private var selectedCategoryID: String?
    @State private var selectedAngle: Int?
    @State private var ignoresNextAngleReset = false
    @State private var sizeBasis: SizeBasis = .allocated

    private let palette: [Color] = [.blue, .purple, .teal, .orange, .indigo, .pink]

    private var chartCategories: [FileExtensionUsage] {
        categories.filter { sizeBasis.bytes(in: $0) > 0 }
    }

    private var selectedCategory: FileExtensionUsage? {
        categories.first { $0.extensionName == selectedCategoryID }
    }

    private var coverageDescription: LocalizedStringKey {
        guard coverageComplete else {
            return "Partial scan: categories describe measured entries only; the selected folder total remains unknown."
        }
        return sizeBasis == .allocated
            ? "Allocated-byte estimates describe this selected scan; they do not measure reclaimable space."
            : "Logical byte totals describe this selected scan; they do not measure reclaimable space."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Size basis")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("Filename chart size basis", selection: $sizeBasis) {
                    ForEach(SizeBasis.allCases) { basis in
                        Text(basis.title).tag(basis)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(maxWidth: 220)
                .accessibilityLabel("Filename chart size basis")
                Spacer(minLength: 0)
            }
            .onChange(of: sizeBasis) { _, _ in
                selectedCategoryID = nil
                selectedAngle = nil
            }
            HStack(alignment: .center, spacing: 18) {
                if chartCategories.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "chart.pie")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No positive size estimates are available for a chart.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 176, height: 150)
                } else {
                    Chart(chartCategories) { category in
                        let isSelected = selectedCategoryID == category.extensionName
                        SectorMark(
                            angle: .value(sizeBasis.title, Int(sizeBasis.bytes(in: category))),
                            innerRadius: .ratio(0.64),
                            outerRadius: .ratio(isSelected ? 0.98 : 0.88),
                            angularInset: isSelected ? 2 : 1
                        )
                        .cornerRadius(4)
                        .foregroundStyle(by: .value("Filename category", categoryTitle(category)))
                        .opacity(selectedCategoryID == nil || isSelected ? 1 : 0.34)
                    }
                    .chartLegend(.hidden)
                    .chartForegroundStyleScale(
                        domain: chartCategories.map(categoryTitle),
                        range: chartCategories.map { category in
                            let index = categories.firstIndex(where: { $0.extensionName == category.extensionName }) ?? 0
                            return palette[index % palette.count]
                        }
                    )
                    .chartAngleSelection(value: $selectedAngle)
                    .chartBackground { proxy in
                        GeometryReader { geometry in
                            if let plotFrame = proxy.plotFrame {
                                let frame = geometry[plotFrame]
                                VStack(spacing: 2) {
                                    Text(selectedCategory.map { formatValue(sizeBasis.bytes(in: $0)) }
                                         ?? sizeBasis.title)
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.72)
                                    Text(selectedCategory.map(categoryTitle)
                                         ?? NSLocalizedString("Select a category", comment: "Hint inside the file-extension chart"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(width: 96)
                                .position(x: frame.midX, y: frame.midY)
                            }
                        }
                    }
                    .frame(width: 176, height: 150)
                    .accessibilityLabel("Interactive filename-size breakdown chart")
                    .onChange(of: selectedAngle) { _, angle in
                        if angle == nil, ignoresNextAngleReset {
                            ignoresNextAngleReset = false
                            return
                        }
                        selectedCategoryID = angle.flatMap(categoryID(forCumulativeAngle:))
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(categories.enumerated()), id: \.element.extensionName) { index, category in
                        Button {
                            let nextID = selectedCategoryID == category.extensionName
                                ? nil : category.extensionName
                            if selectedAngle != nil {
                                ignoresNextAngleReset = true
                                selectedAngle = nil
                            }
                            selectedCategoryID = nextID
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(palette[index % palette.count])
                                    .frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 5) {
                                        Text(categoryTitle(category))
                                            .font(.caption2.monospaced())
                                            .lineLimit(1)
                                        if category.extensionName != FileExtensionBreakdown.otherCategoryName,
                                           FileArtifactHint.matching(extensionName: category.extensionName) != nil {
                                            Image(systemName: "tag")
                                                .font(.caption2)
                                                .foregroundStyle(.blue)
                                                .help("Filename-based clue only; file contents and purpose are not verified.")
                                        }
                                        Spacer(minLength: 3)
                                        VStack(alignment: .trailing, spacing: 1) {
                                            Text(String.localizedStringWithFormat(
                                                NSLocalizedString("Logical %@", comment: "Exact logical bytes for a filename category"),
                                                formatLogical(category.logicalBytes)
                                            ))
                                            Text(String.localizedStringWithFormat(
                                                NSLocalizedString("Allocated estimate ~%@", comment: "Allocated-byte estimate for a filename category"),
                                                formatLogical(category.allocatedBytes)
                                            ))
                                        }
                                        .font(.caption2.monospacedDigit())
                                    }
                                    Text("\(category.fileCount) files")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(
                                selectedCategoryID == category.extensionName
                                    ? Color.accentColor.opacity(0.10) : .clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(categoryAccessibilityLabel(for: category))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grouped by filename only; file contents and purpose are not verified.")
                Text(coverageDescription)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func categoryID(forCumulativeAngle angle: Int) -> String? {
        var cumulative: Int64 = 0
        for category in chartCategories {
            let (next, overflow) = cumulative.addingReportingOverflow(sizeBasis.bytes(in: category))
            guard !overflow else { return nil }
            cumulative = next
            if Int64(angle) <= cumulative { return category.extensionName }
        }
        return nil
    }

    private func categoryTitle(_ category: FileExtensionUsage) -> String {
        switch category.extensionName {
        case "no extension": NSLocalizedString("No extension", comment: "Files without a filename extension")
        case FileExtensionBreakdown.otherCategoryName:
            NSLocalizedString("Other filename extensions", comment: "Combined categories beyond the chart's leading extensions")
        default: ".\(category.extensionName)"
        }
    }

    private func categoryAccessibilityLabel(for category: FileExtensionUsage) -> String {
        let format = NSLocalizedString(
            "%@, %d files, logical %@, allocated estimate %@",
            comment: "Accessible label for a filename category in the storage chart"
        )
        return String.localizedStringWithFormat(
            format, categoryTitle(category), category.fileCount,
            formatLogical(category.logicalBytes), formatAllocated(category.allocatedBytes)
        )
    }

    private func formatValue(_ bytes: Int64) -> String {
        sizeBasis == .allocated ? formatAllocated(bytes) : formatLogical(bytes)
    }

    private func formatLogical(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatAllocated(_ bytes: Int64) -> String {
        "~" + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension ApplicationDiscoveryMeasurementFilter {
    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .unmeasured: "Not measured"
        case .partial: "Partial"
        case .complete: "Complete"
        }
    }
}

private extension ApplicationDiscoverySort {
    var title: LocalizedStringKey {
        switch self {
        case .name: "Name"
        case .largestCompleteMeasurement: "Largest complete measurement"
        case .recentlyObserved: "Recently observed in Spotlight"
        }
    }
}

private func measuredBytesSummary(logicalBytes: Int64, allocatedBytes: Int64, complete: Bool) -> String {
    let logical = ByteCountFormatter.string(fromByteCount: logicalBytes, countStyle: .file)
    let allocated = ByteCountFormatter.string(fromByteCount: allocatedBytes, countStyle: .file)
    if !complete && logicalBytes == 0 && allocatedBytes == 0 {
        return NSLocalizedString("No bytes measured · total unknown", comment: "No bytes measured in an incomplete scope")
    }
    if !complete {
        let format = NSLocalizedString(
            "Measured so far · logical %@ · allocated estimate ~%@ · total unknown",
            comment: "Partial logical and allocated-byte estimates for a selected scope"
        )
        return String.localizedStringWithFormat(format, logical, allocated)
    }
    let format = NSLocalizedString(
        "Logical %@ · allocated estimate ~%@",
        comment: "Logical bytes and allocated-byte estimate for a measured scope"
    )
    return String.localizedStringWithFormat(format, logical, allocated)
}

private func folderMeasurementSummary(_ observation: FolderObservation) -> String {
    measuredBytesSummary(
        logicalBytes: observation.logicalBytes,
        allocatedBytes: observation.allocatedBytes,
        complete: observation.complete
    )
}

private func applicationDiscoverySummary(
    catalogCount: Int, searchableCount: Int, completeCount: Int,
    matchCount: Int?, shownCount: Int
) -> String {
    if let matchCount {
        let format = NSLocalizedString(
            "Application discovery results · filtered",
            value: "Matches: %ld · showing: %ld · complete: %ld · Spotlight sample: %ld",
            comment: "Counts for filtered Spotlight results, visible rows, complete bundle measurements, and bounded query results"
        )
        return String.localizedStringWithFormat(format, matchCount, shownCount, completeCount, searchableCount)
    }
    let format = NSLocalizedString(
        "Application discovery results · all",
        value: "Catalog sample: %ld · complete: %ld",
        comment: "Counts for displayed Spotlight results and complete bundle measurements"
    )
    return String.localizedStringWithFormat(format, catalogCount, completeCount)
}

private func directoryMeasurementSummary(_ usage: DirectoryUsage) -> String {
    measuredBytesSummary(
        logicalBytes: usage.logicalBytes,
        allocatedBytes: usage.allocatedBytes,
        complete: usage.complete
    )
}

private func directoryAllocatedValue(_ usage: DirectoryUsage) -> String {
    let allocated = ByteCountFormatter.string(fromByteCount: usage.allocatedBytes, countStyle: .file)
    guard !usage.complete else { return allocated }
    guard usage.allocatedBytes > 0 else { return "Unknown total" }
    return "~\(allocated) measured so far"
}

private func folderAllocatedValue(_ observation: FolderObservation) -> String {
    let allocated = ByteCountFormatter.string(fromByteCount: observation.allocatedBytes, countStyle: .file)
    guard !observation.complete else { return allocated }
    guard observation.allocatedBytes > 0 else { return "Unknown total" }
    return "~\(allocated) measured so far"
}

struct DashboardModelStoreURLs {
    let observations: URL
    let fileInventory: URL
    let selectedScopeBookmarks: URL
    let storageMonitoringPreferences: URL
}

@MainActor
@Observable
final class DashboardModel {
    var capacity: CapacityObservation?
    var ram: RAMObservation?
    var history = LocalHistory()
    var fileInventoryReports: [String: FileInventoryChangeSet] = [:]
    var fileInventoryTrends: [String: [FileInventoryTrendPoint]] = [:]
    var sameSizeFileCandidates: [String: SameSizeFileCandidateSummary] = [:]
    var isScanning = false
    var isSamplingRAM = false
    var isAppActive = false
    var storageMonitoringSessionOpen = false
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
    var storageEventWatcherErrors: [String: String] = [:]
    var ownFootprint: ScanObservation?
    var ownFootprintPaths: [String] = []
    var isMeasuringOwnFootprint = false
    var applicationBundlePathStatuses: [String: SelectedScopePathProbe.Status] = [:]
    var checkingApplicationBundlePaths = Set<String>()
    private var applicationBundlePathCheckIDs: [String: UUID] = [:]
    var applicationDataLocationStatuses: [String: SelectedScopePathProbe.Status] = [:]
    var checkingApplicationDataLocationPaths = Set<String>()
    private var applicationDataLocationCheckIDs: [String: UUID] = [:]
    var applicationAssociatedPathStatuses: [String: SelectedScopePathProbe.Status] = [:]
    var checkingApplicationAssociatedPaths = Set<String>()
    private var applicationAssociatedPathCheckIDs: [String: UUID] = [:]
    var projectResourcePathStatuses: [String: SelectedScopePathProbe.Status] = [:]
    var checkingProjectResourcePaths = Set<String>()
    private var projectResourcePathCheckIDs: [String: UUID] = [:]
    var errorMessage: String?
    var currentPath = ""
    var countedFileObjects = 0
    private var scanTask: Task<DetailedScanObservation, Never>?
    private var fileInventoryTask: Task<[FileInventoryRecordResult], Error>?
    private var scanOrigin: StorageScanOrigin?
    private var scanRootPaths = Set<String>()
    var scheduledScanPath: String?
    var eventTriggeredScanPath: String?
    private var storageMonitoringEnabledAtByPath: [String: Date] = [:]
    private var storageMonitoringCooldownByPath: [String: Date] = [:]
    private var storageMonitoringTask: Task<Void, Never>?
    private var storageEventScanTask: Task<Void, Never>?
    private var storageEventWatchers: [String: SelectedRootEventWatcher] = [:]
    private var pendingStorageEventPaths = Set<String>()
#if DEBUG
    var activeStorageEventWatcherPathsForTesting: Set<String> { Set(storageEventWatchers.keys) }
    var pendingStorageEventPathsForTesting: Set<String> { pendingStorageEventPaths }
    func setStorageMonitoringCooldownForTesting(_ path: String, lastScanAt: Date) {
        storageMonitoringCooldownByPath[path] = lastScanAt
    }
    func evaluateStorageMonitoringForTesting(at date: Date) {
        evaluateStorageMonitoring(at: date)
    }
#endif
    private var historyGeneration = HistoryGeneration()
    private var ownFootprintTask: Task<ScanObservation, Never>?
    private var ownFootprintRequestID: UUID?
    private var ramSampleTask: Task<Void, Never>?
    private var duplicateTask: Task<DuplicateVerificationResult, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let observationStoreURL: URL?
    private let fileInventoryStoreURL: URL?
    private let selectedScopeBookmarkStoreURL: URL?
    private let storageMonitoringPreferencesURL: URL?

    init(
        includeSnapshotProjectCandidate: Bool = false,
        includeSnapshotDiscoveredApplicationCandidate: Bool = false,
        storeURLs: DashboardModelStoreURLs? = nil
    ) {
        self.observationStoreURL = storeURLs?.observations
        self.fileInventoryStoreURL = storeURLs?.fileInventory
        self.selectedScopeBookmarkStoreURL = storeURLs?.selectedScopeBookmarks
        self.storageMonitoringPreferencesURL = storeURLs?.storageMonitoringPreferences
        if includeSnapshotProjectCandidate {
            history = Self.snapshotProjectCandidateHistory()
        } else if includeSnapshotDiscoveredApplicationCandidate {
            history = Self.snapshotDiscoveredApplicationHistory()
        } else {
            do {
                history = try ObservationStore.load(from: observationStoreURL)
                ram = history.ramObservations.last
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if !includeSnapshotProjectCandidate && !includeSnapshotDiscoveredApplicationCandidate {
            do {
                let fileInventoryHistory = try FileInventoryStore.loadDashboardHistory(at: fileInventoryStoreURL)
                fileInventoryReports = fileInventoryHistory.reports
                fileInventoryTrends = fileInventoryHistory.trendPoints
                sameSizeFileCandidates = fileInventoryHistory.sameSizeCandidates
            } catch {
                errorMessage = "File change history could not be loaded: \(error.localizedDescription)"
            }
            do {
                rememberedScopes = try SelectedScopeBookmarkStore.load(from: selectedScopeBookmarkStoreURL)
            } catch {
                errorMessage = "Saved scan locations could not be loaded: \(error.localizedDescription)"
            }
            do {
                let savedMonitoringPaths = try StorageMonitoringPreferences.load(
                    from: storageMonitoringPreferencesURL
                )
                monitoredScopePaths = savedMonitoringPaths.intersection(Set(rememberedScopes.map(\.path)))
                if monitoredScopePaths != savedMonitoringPaths {
                    try StorageMonitoringPreferences.save(
                        monitoredScopePaths, at: storageMonitoringPreferencesURL
                    )
                }
                for path in monitoredScopePaths {
                    let lastCompleteScan = fileInventoryTrends[path]?.last?.observedAt
                        ?? fileInventoryReports[path]?.observedAt
                        ?? .distantPast
                    storageMonitoringEnabledAtByPath[path] = lastCompleteScan
                    storageMonitoringCooldownByPath[path] = lastCompleteScan
                }
            } catch {
                errorMessage = "Saved monitoring choices could not be loaded: \(error.localizedDescription)"
            }
        }
    }

    private static func snapshotDiscoveredApplicationHistory() -> LocalHistory {
        LocalHistory(applicationAssociations: [
            ApplicationFolderAssociation(
                bundlePath: "/synthetic/Applications/DemoApp.app",
                relatedFolderPaths: ["/synthetic/QA/UnmeasuredAppData"]
            )
        ])
    }

    private static func snapshotProjectCandidateHistory() -> LocalHistory {
        let root = "/synthetic/QA/DemoProject"
        let models = root + "/models"
        let now = Date()
        let gitUsage = DirectoryUsage(
            rootRelativePath: ".git", logicalBytes: 8_192, allocatedBytes: 12_288,
            fileCount: 2, incompleteCount: 0, excludedSymlinkCount: 0,
            gitMetadataEntryDetected: true, complete: true
        )
        let modelUsage = DirectoryUsage(
            rootRelativePath: "models", logicalBytes: 268_435_456, allocatedBytes: 281_018_368,
            fileCount: 4, incompleteCount: 0, excludedSymlinkCount: 0, complete: true
        )
        let project = FolderObservation(
            path: root, volumeDeviceID: 42, displayName: "DemoProject",
            logicalBytes: 268_443_648, allocatedBytes: 281_030_656, fileCount: 6,
            inaccessibleCount: 0, finishedAt: now.addingTimeInterval(-600), complete: true,
            gitMetadataEntryDetected: true, gitMetadataUsage: gitUsage,
            projectDirectorySummaries: [gitUsage, modelUsage]
        )
        let candidateBefore = FolderObservation(
            path: models, volumeDeviceID: 42, displayName: "models",
            logicalBytes: 250_609_664, allocatedBytes: 262_144_000, fileCount: 4,
            inaccessibleCount: 0, finishedAt: now.addingTimeInterval(-1_200), complete: true
        )
        let candidateLatest = FolderObservation(
            path: models, volumeDeviceID: 42, displayName: "models",
            logicalBytes: modelUsage.logicalBytes, allocatedBytes: modelUsage.allocatedBytes, fileCount: 4,
            inaccessibleCount: 0, finishedAt: now.addingTimeInterval(-300), complete: true
        )
        let association = try? ProjectResourceAssociation(
            projectRootPath: root, relatedFolderPaths: [models],
            updatedAt: now.addingTimeInterval(-300)
        )
        let observations = [
            ScanObservation(
                startedAt: candidateBefore.finishedAt, finishedAt: candidateBefore.finishedAt,
                folders: [candidateBefore], cancelled: false
            ),
            ScanObservation(
                startedAt: candidateLatest.finishedAt, finishedAt: candidateLatest.finishedAt,
                folders: [candidateLatest], cancelled: false
            ),
            ScanObservation(
                startedAt: project.finishedAt, finishedAt: project.finishedAt,
                folders: [project], cancelled: false
            ),
        ]
        return LocalHistory(
            observations: observations,
            projectResourceAssociations: association.map { [$0] } ?? []
        )
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
            for: bundle, in: history, homeDirectoryPath: CurrentUserHomeDirectory.path ?? ""
        )
    }

    func checkApplicationBundlePath(_ path: String) {
        guard checkingApplicationBundlePaths.insert(path).inserted else { return }
        let requestID = UUID()
        applicationBundlePathCheckIDs[path] = requestID
        applicationBundlePathStatuses.removeValue(forKey: path)
        let generation = historyGeneration.token()
        let expectedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let bookmark = rememberedScopes.first(where: { $0.path == expectedPath })
        let task = Task.detached(priority: .utility) {
            SelectedScopePathProbe.probe(at: path, using: bookmark)
        }
        Task {
            let status = await task.value
            guard applicationBundlePathCheckIDs[path] == requestID,
                  historyGeneration.accepts(generation) else { return }
            applicationBundlePathCheckIDs.removeValue(forKey: path)
            checkingApplicationBundlePaths.remove(path)
            applicationBundlePathStatuses[path] = status
        }
    }

    func checkApplicationDataLocation(_ path: String, for bundle: FolderObservation) {
        let candidates = ApplicationDataLocationCandidates.suggestions(
            bundleIdentifier: bundle.applicationBundleIdentifier,
            homeDirectoryPath: CurrentUserHomeDirectory.path ?? "",
            claimedGroupIdentifiers: bundle.applicationGroupIdentifiers,
            signatureValidated: bundle.applicationSignatureValidated,
            signedBundleIdentifier: bundle.applicationSignedBundleIdentifier
        )
        checkApplicationDataLocation(path, among: candidates)
    }

    func checkDiscoveredApplicationDataLocation(
        _ path: String, for candidate: ApplicationDiscoveryCandidate
    ) {
        let candidates = ApplicationDataLocationCandidates.suggestions(
            bundleIdentifier: candidate.spotlightBundleIdentifier,
            homeDirectoryPath: CurrentUserHomeDirectory.path ?? ""
        )
        checkApplicationDataLocation(path, among: candidates)
    }

    private func checkApplicationDataLocation(
        _ path: String, among candidates: [ApplicationDataLocationCandidate]
    ) {
        let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard candidates.contains(where: {
            URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL.path == normalizedPath
        }), checkingApplicationDataLocationPaths.insert(normalizedPath).inserted else { return }

        let requestID = UUID()
        applicationDataLocationCheckIDs[normalizedPath] = requestID
        applicationDataLocationStatuses.removeValue(forKey: normalizedPath)
        let generation = historyGeneration.token()
        let task = Task.detached(priority: .utility) {
            SelectedScopePathProbe.probe(at: normalizedPath)
        }
        Task {
            let status = await task.value
            guard applicationDataLocationCheckIDs[normalizedPath] == requestID,
                  historyGeneration.accepts(generation) else { return }
            applicationDataLocationCheckIDs.removeValue(forKey: normalizedPath)
            checkingApplicationDataLocationPaths.remove(normalizedPath)
            applicationDataLocationStatuses[normalizedPath] = status
        }
    }

    func chooseDiscoveredApplicationDataLocation(
        _ path: String, for candidate: ApplicationDiscoveryCandidate
    ) {
        guard !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates,
              let spotlightBundleIdentifier = candidate.spotlightBundleIdentifier else { return }
        let expectedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard ApplicationDataLocationCandidates.suggestion(
            matchingExactPath: expectedPath,
            bundleIdentifier: spotlightBundleIdentifier,
            homeDirectoryPath: CurrentUserHomeDirectory.path ?? ""
        ) != nil else { return }

        let panel = NSOpenPanel()
        panel.title = NSLocalizedString(
            "Confirm Suggested App Data Location",
            comment: "Native file or folder picker title for explicitly confirming a suggested app data path"
        )
        panel.prompt = NSLocalizedString(
            "Associate and Measure",
            comment: "Native folder picker action to associate and measure an exact suggested app data folder"
        )
        panel.message = NSLocalizedString(
            "Spotlight's bundle ID is an unverified hint. Choose this exact file or folder to associate it with the discovered app and start a metadata-only scan. Disker will not follow symlinks or read file contents.",
            comment: "Native folder picker explanation for the evidence limits and scope of an app data scan"
        )
        panel.directoryURL = URL(fileURLWithPath: expectedPath).deletingLastPathComponent()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        let selectionValidation = ApplicationDataLocationCandidates.validateSelectedLocation(
            selectedURL, expectedPath: expectedPath,
            bundleIdentifier: spotlightBundleIdentifier,
            homeDirectoryPath: CurrentUserHomeDirectory.path ?? ""
        )
        guard selectionValidation != .cancelled else { return }
        guard selectionValidation != .differentPath,
              selectionValidation != .notSuggested else {
            errorMessage = NSLocalizedString(
                "Choose the same suggested location to measure it. No scan was started.",
                comment: "Error shown when the user chooses a different path than the suggested app data location"
            )
            return
        }
        guard selectionValidation == .accepted else {
            errorMessage = NSLocalizedString(
                "Disker could not confirm this exact location as a regular file or folder without following symbolic links. No association or scan was created.",
                comment: "Rejects a missing, inaccessible, wrong-type, or symlink suggested application data root before saving its association"
            )
            return
        }

        do {
            history = try ObservationStore.associateApplicationFolders(
                [selectedURL.path], with: candidate.path,
                bundleIdentifier: applicationBundleIdentifier(for: candidate.path),
                to: observationStoreURL
            )
            invalidateAssociatedPathProbe(for: candidate.path, clearing: [selectedURL.path])
            rememberFolders([selectedURL])
            scan([selectedURL])
        } catch {
            errorMessage = "The location was selected, but its app association could not be saved: \(error.localizedDescription)"
        }
    }

    func checkAssociatedApplicationPaths(for bundlePath: String) {
        guard checkingApplicationAssociatedPaths.insert(bundlePath).inserted else { return }
        let requestID = UUID()
        applicationAssociatedPathCheckIDs[bundlePath] = requestID
        let generation = historyGeneration.token()
        let paths = relatedFolders(for: bundlePath)
        let bookmarks = Dictionary(
            rememberedScopes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let task = Task.detached(priority: .utility) {
            var result: [String: SelectedScopePathProbe.Status] = [:]
            for path in paths {
                result[path] = SelectedScopePathProbe.probe(at: path, using: bookmarks[path])
            }
            return result
        }
        Task {
            let statuses = await task.value
            guard applicationAssociatedPathCheckIDs[bundlePath] == requestID,
                  historyGeneration.accepts(generation) else { return }
            applicationAssociatedPathCheckIDs.removeValue(forKey: bundlePath)
            checkingApplicationAssociatedPaths.remove(bundlePath)
            applicationAssociatedPathStatuses.merge(statuses) { _, latest in latest }
        }
    }

    private func invalidateAssociatedPathProbe(for bundlePath: String, clearing paths: [String]) {
        applicationAssociatedPathCheckIDs.removeValue(forKey: bundlePath)
        checkingApplicationAssociatedPaths.remove(bundlePath)
        for path in paths {
            applicationAssociatedPathStatuses.removeValue(forKey: path)
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
                history = try ObservationStore.append(sample, to: observationStoreURL)
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
                    history = try ObservationStore.append(sample, to: observationStoreURL)
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
            history = try ObservationStore.append(observation, to: observationStoreURL)
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

    func chooseApplicationBundle(startingAt directory: URL? = nil, expectedPath: String? = nil) {
        guard !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        let panel = NSOpenPanel()
        panel.title = expectedPath == nil ? "Choose an application bundle to measure" : "Confirm the discovered application to measure"
        panel.prompt = "Measure Bundle"
        panel.message = "Disker measures only the selected .app bundle. Signature validation reads its signed executable and resources locally, in addition to the declared bundle ID and App Groups claim. It does not verify notarization or current use; group data is shared. No file contents are uploaded."
        panel.directoryURL = directory
        // NSOpenPanel may expose app bundles as package directories on macOS.
        // Allow both selection forms, then validate application metadata below.
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let bundleURL = panel.urls.first else { return }
        if let expectedPath, bundleURL.standardizedFileURL.path != URL(fileURLWithPath: expectedPath).standardizedFileURL.path {
            errorMessage = "Choose the same application bundle that you selected for measurement."
            return
        }
        guard bundleURL.pathExtension.lowercased() == "app" else {
            errorMessage = "Choose an application bundle (.app). Ordinary folders are not measured as applications."
            return
        }
        var rootStat = stat()
        let selectedPathIsRealDirectory = bundleURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &rootStat) == 0 && (rootStat.st_mode & S_IFMT) == S_IFDIR
        }
        guard selectedPathIsRealDirectory else {
            errorMessage = "The selected application bundle is unavailable or is a symbolic link."
            return
        }
        guard let selectedBundle = Bundle(url: bundleURL),
              selectedBundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              selectedBundle.bundleIdentifier?.isEmpty == false else {
            errorMessage = "The selected .app does not contain a valid application bundle identity."
            return
        }
        applicationBundlePathCheckIDs.removeValue(forKey: bundleURL.path)
        checkingApplicationBundlePaths.remove(bundleURL.path)
        applicationBundlePathStatuses[bundleURL.path] = .availableDirectory
        rememberFolders([bundleURL])
        scan([bundleURL], inspectSelectedAppBundles: true)
    }

    func chooseRelatedFolders(for bundlePath: String, startingAt directory: URL? = nil) {
        guard !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString(
            "Choose locations associated with this app",
            comment: "Native picker title for selecting exact files or folders associated with an app"
        )
        panel.prompt = NSLocalizedString("Associate and Scan", comment: "Native picker action for app-related locations")
        panel.message = NSLocalizedString(
            "Choose up to 50 files or folders to associate. Exact container paths may match the selected app's bundle ID or App Groups claim. Disker checks the app's local code signature but does not verify notarization, current use, or exclusive ownership; group data is shared and measurements stay separate.",
            comment: "Scope and attribution limits for selected app-related files or folders"
        )
        panel.directoryURL = directory
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            history = try ObservationStore.associateApplicationFolders(
                panel.urls.map(\.path), with: bundlePath,
                bundleIdentifier: applicationBundleIdentifier(for: bundlePath),
                to: observationStoreURL
            )
            invalidateAssociatedPathProbe(for: bundlePath, clearing: history.applicationAssociations
                .first(where: { $0.bundlePath == bundlePath })?.relatedFolderPaths ?? [])
            rememberFolders(panel.urls)
            scan(panel.urls)
        } catch {
            errorMessage = "Locations were selected, but their association could not be saved: \(error.localizedDescription)"
        }
    }

    func removeRelatedFolder(_ path: String, from bundlePath: String) {
        do {
            history = try ObservationStore.removeApplicationFolderAssociation(
                path, from: bundlePath, at: observationStoreURL
            )
            invalidateAssociatedPathProbe(for: bundlePath, clearing: [path])
        } catch {
            errorMessage = "The saved folder association could not be removed: \(error.localizedDescription)"
        }
    }

    func projectResourceReview(for projectRootPath: String) -> ProjectResourceReview {
        ProjectResourceReview.make(for: projectRootPath, in: history)
    }

    func projectRootsLinkingResource(_ path: String) -> [String] {
        let standardizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        return history.projectResourceAssociations.compactMap { association in
            guard association.relatedFolderPaths.contains(where: {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path == standardizedPath
            }) else { return nil }
            return URL(fileURLWithPath: association.projectRootPath, isDirectory: true).standardizedFileURL.path
        }.sorted()
    }

    func crossDomainResourceEvidence(for projectRootPath: String) -> CrossDomainResourceEvidence {
        CrossDomainResourceEvidence.make(
            forProjectRootPath: projectRootPath,
            in: history,
            homeDirectoryPath: CurrentUserHomeDirectory.path ?? ""
        )
    }

    func crossDomainResourceEvidence(forApplicationBundlePath bundlePath: String) -> CrossDomainResourceEvidence {
        CrossDomainResourceEvidence.make(
            forApplicationBundlePath: bundlePath,
            in: history,
            homeDirectoryPath: CurrentUserHomeDirectory.path ?? ""
        )
    }

    func chooseProjectResourceFolders(for projectRootPath: String, startingAt directory: URL? = nil) {
        guard !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose folders linked to this project"
        panel.prompt = "Link and Scan"
        panel.message = "Choose up to 50 exact folders. This records your project grouping and starts a metadata-only scan of only these folders. It does not establish ownership; measurements remain separate and may overlap."
        panel.directoryURL = directory
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        guard panel.urls.count <= ProjectResourceAssociation.maximumRelatedFolderCount else {
            errorMessage = "A project root can have at most 50 linked folders. Reduce the selection and try again."
            return
        }
        do {
            history = try ObservationStore.associateProjectFolders(
                panel.urls.map(\.path), with: projectRootPath, to: observationStoreURL
            )
            rememberFolders(panel.urls)
            scan(panel.urls)
        } catch {
            errorMessage = "Folders were selected, but their project links could not be saved: \(error.localizedDescription)"
        }
    }

    func measureSelectedCandidate(at path: String) {
        guard !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        let expectedURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let panel = NSOpenPanel()
        panel.title = "Confirm Candidate Folder"
        panel.prompt = "Measure Folder"
        panel.message = "Choose this exact candidate folder to record a separate metadata-only measurement. Its size remains separate from the selected parent folder."
        panel.directoryURL = expectedURL.deletingLastPathComponent()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let chosenURL = panel.urls.first else { return }
        guard SelectedScopeBookmarkStore.isSameSelectedPath(chosenURL, as: expectedURL.path) else {
            errorMessage = "Choose the same candidate folder to measure its exact path. No scan was started."
            return
        }
        guard SelectedScopePathProbe.probe(selectedURL: chosenURL).isAvailableDirectory else {
            errorMessage = NSLocalizedString(
                "Disker could not confirm this exact path as a directory without following symbolic links. No link or scan was created.",
                comment: "Rejects inaccessible, non-directory, or symlink project data candidates before saving access"
            )
            return
        }
        rememberFolders([chosenURL])
        scan([chosenURL])
    }

    func measureAndLinkProjectCandidate(at path: String, to projectRootPath: String) {
        guard !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        let expectedURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let standardizedRoot = URL(fileURLWithPath: projectRootPath, isDirectory: true).standardizedFileURL.path
        let latestProjectObservation = history.observations.reversed()
            .lazy
            .flatMap(\.folders)
            .first { URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL.path == standardizedRoot }
        guard let latestProjectObservation,
              latestProjectObservation.gitMetadataEntryDetected,
              DeveloperArtifactReview.make(from: latestProjectObservation).entries.contains(where: {
                  $0.path == expectedURL.path && $0.category != .sourceControl
              }) else {
            errorMessage = NSLocalizedString(
                "This path is no longer a recognized candidate in the selected Git project. Refresh the project scan and try again.",
                comment: "The candidate changed or is stale before the user confirms an exact project resource"
            )
            return
        }

        let existingAssociation = history.projectResourceAssociations.first {
            URL(fileURLWithPath: $0.projectRootPath, isDirectory: true).standardizedFileURL.path == standardizedRoot
        }
        if existingAssociation?.relatedFolderPaths.contains(expectedURL.path) != true,
           (existingAssociation?.relatedFolderPaths.count ?? 0) >= ProjectResourceAssociation.maximumRelatedFolderCount {
            errorMessage = NSLocalizedString(
                "This project already has the maximum number of linked locations. Remove an existing link before adding another.",
                comment: "Project resource association bound reached"
            )
            return
        }

        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Confirm Project Data Candidate", comment: "Exact candidate selection title for project resource measurement")
        panel.prompt = NSLocalizedString("Measure and Link", comment: "Confirm exact project candidate and measure it")
        panel.message = NSLocalizedString(
            "Choose this exact candidate directory. Disker will save your project link and read-only access, then measure only this directory as a separate path.",
            comment: "Explains exact selected candidate, separate scope, and explicit project relationship"
        )
        panel.directoryURL = expectedURL.deletingLastPathComponent()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let chosenURL = panel.urls.first else { return }
        guard SelectedScopeBookmarkStore.isSameSelectedPath(chosenURL, as: expectedURL.path) else {
            errorMessage = NSLocalizedString(
                "Choose the same candidate directory to keep its project link and history exact. No link or scan was created.",
                comment: "Rejects a different path selected while confirming a project candidate"
            )
            return
        }
        guard SelectedScopePathProbe.probe(selectedURL: chosenURL).isAvailableDirectory else {
            errorMessage = NSLocalizedString(
                "Disker could not confirm this exact path as a directory without following symbolic links. No link or scan was created.",
                comment: "Rejects inaccessible, non-directory, or symlink project candidate paths"
            )
            return
        }

        do {
            history = try ObservationStore.associateProjectFolders(
                [chosenURL.standardizedFileURL.path], with: standardizedRoot, to: observationStoreURL
            )
        } catch {
            errorMessage = "The project link could not be saved: \(error.localizedDescription)"
            return
        }
        rememberFolders([chosenURL])
        scan([chosenURL])
    }

    func removeProjectResourceFolder(_ path: String, from projectRootPath: String) {
        do {
            history = try ObservationStore.removeProjectFolderAssociation(
                path, from: projectRootPath, at: observationStoreURL
            )
            projectResourcePathCheckIDs.removeValue(forKey: path)
            checkingProjectResourcePaths.remove(path)
            projectResourcePathStatuses.removeValue(forKey: path)
        } catch {
            errorMessage = "The project resource link could not be removed: \(error.localizedDescription)"
        }
    }

    func checkProjectResourcePath(_ path: String) {
        let expectedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard checkingProjectResourcePaths.insert(expectedPath).inserted else { return }
        let requestID = UUID()
        projectResourcePathCheckIDs[expectedPath] = requestID
        projectResourcePathStatuses.removeValue(forKey: expectedPath)
        let generation = historyGeneration.token()
        let bookmark = rememberedScopes.first(where: { $0.path == expectedPath })
        let task = Task.detached(priority: .utility) {
            SelectedScopePathProbe.probe(at: expectedPath, using: bookmark)
        }
        Task {
            let status = await task.value
            guard projectResourcePathCheckIDs[expectedPath] == requestID,
                  historyGeneration.accepts(generation) else { return }
            projectResourcePathCheckIDs.removeValue(forKey: expectedPath)
            checkingProjectResourcePaths.remove(expectedPath)
            projectResourcePathStatuses[expectedPath] = status
        }
    }

    private func rememberFolders(_ urls: [URL]) {
        do {
            rememberedScopes = try SelectedScopeBookmarkStore.remember(urls, at: selectedScopeBookmarkStoreURL)
            let updatedPaths = Set(urls.map { $0.standardizedFileURL.path })
            for path in updatedPaths {
                projectResourcePathCheckIDs.removeValue(forKey: path)
                checkingProjectResourcePaths.remove(path)
                projectResourcePathStatuses.removeValue(forKey: path)
            }
            let affectedBundles = history.applicationAssociations.filter { association in
                association.relatedFolderPaths.contains(where: {
                    updatedPaths.contains(URL(fileURLWithPath: $0).standardizedFileURL.path)
                })
            }
            for association in affectedBundles {
                invalidateAssociatedPathProbe(
                    for: association.bundlePath,
                    clearing: Array(updatedPaths)
                )
            }
        } catch {
            errorMessage = "The scan can continue, but Disker could not save a reusable read-only location: \(error.localizedDescription)"
        }
    }

    func rescanRememberedFolder(_ path: String) {
        rescanRememberedFolder(path, origin: .manual)
    }

    func reselectRememberedFolder(_ path: String) {
        guard !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        let expectedURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let panel = NSOpenPanel()
        panel.title = "Re-select Saved Scan Folder"
        panel.prompt = "Re-select Folder"
        panel.message = "Choose the same folder to restore read-only access. Disker will keep its existing history and scan only this selected path."
        panel.directoryURL = expectedURL.deletingLastPathComponent()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let chosenURL = panel.urls.first else { return }
        guard SelectedScopeBookmarkStore.isSameSelectedPath(chosenURL, as: expectedURL.path) else {
            errorMessage = "Choose the same saved folder to keep its history comparable. No scan was started."
            return
        }
        rememberFolders([chosenURL])
        scan([chosenURL])
    }

    private func rescanRememberedFolder(_ path: String, origin: StorageScanOrigin) {
        guard !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        guard let bookmark = rememberedScopes.first(where: { $0.path == path }) else {
            if origin.isMonitoring {
                pauseStorageMonitoring(path, reason: "Saved access is missing. Select this folder again before resuming.")
            }
            return
        }
        do {
            let url = try SelectedScopeBookmarkStore.resolve(bookmark, at: selectedScopeBookmarkStoreURL)
            do {
                rememberedScopes = try SelectedScopeBookmarkStore.load(from: selectedScopeBookmarkStoreURL)
            } catch {
                errorMessage = "The folder is available for this scan, but saved locations could not be refreshed: \(error.localizedDescription)"
            }
            scan([url], origin: origin)
        } catch {
            if origin.isMonitoring {
                pauseStorageMonitoring(path, reason: "Saved access needs attention. Choose this folder again, then resume monitoring.")
            }
            errorMessage = error.localizedDescription
        }
    }

    func rescanAssociatedFolder(_ path: String) {
        guard !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        if let bookmark = rememberedScopes.first(where: { $0.path == path }) {
            do {
                let resolvedURL = try SelectedScopeBookmarkStore.resolve(bookmark, at: selectedScopeBookmarkStoreURL)
                do {
                    rememberedScopes = try SelectedScopeBookmarkStore.load(from: selectedScopeBookmarkStoreURL)
                } catch {
                    errorMessage = "The location is available for this scan, but saved locations could not be refreshed: \(error.localizedDescription)"
                }
                scan([resolvedURL])
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        let selectedURL = URL(fileURLWithPath: path, isDirectory: true)
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Re-select Associated Location", comment: "Native picker title to restore access to an app-related path")
        panel.prompt = NSLocalizedString("Rescan Location", comment: "Native picker action to rescan an app-related path")
        panel.message = NSLocalizedString(
            "Select this exact file or folder to measure it again and save read-only access for later scans.",
            comment: "Exact-path reminder for restoring access to a previously measured app-related location"
        )
        panel.directoryURL = selectedURL.deletingLastPathComponent()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let chosenURL = panel.urls.first else { return }
        guard SelectedScopeBookmarkStore.isSameSelectedPath(chosenURL, as: selectedURL.path) else {
            errorMessage = NSLocalizedString(
                "Choose the same associated location to keep its history comparable. No scan was started.",
                comment: "Error when a different path is selected while restoring app-related location access"
            )
            return
        }
        errorMessage = nil
        rememberFolders([chosenURL])
        scan([chosenURL])
    }

    func forgetRememberedFolder(_ path: String) {
        do {
            rememberedScopes = try SelectedScopeBookmarkStore.remove(path: path, at: selectedScopeBookmarkStoreURL)
            removeStorageMonitoringState(for: path)
            projectResourcePathCheckIDs.removeValue(forKey: path)
            checkingProjectResourcePaths.remove(path)
            projectResourcePathStatuses.removeValue(forKey: path)
        } catch {
            errorMessage = "The saved folder could not be forgotten: \(error.localizedDescription)"
        }
    }

    func scan(
        _ urls: [URL], applicationBundleIdentities: [String: ApplicationBundleIdentity] = [:],
        inspectSelectedAppBundles: Bool = false, origin: StorageScanOrigin = .manual
    ) {
        guard !urls.isEmpty, !isScanning, !isMeasuringOwnFootprint, !isVerifyingDuplicates else { return }
        guard urls.count <= ApplicationFolderAssociation.maximumRelatedFolderCount else {
            errorMessage = "A scan can include at most 50 selected locations. Reduce the selection and try again."
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
        eventTriggeredScanPath = origin == .eventTriggered ? scanRootPaths.first : nil
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
            let detailed = FolderScanner.scanWithFileInventories(roots: urls, progress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.historyGeneration.accepts(generation) else { return }
                    self.currentPath = progress.currentPath
                    self.countedFileObjects = progress.countedFileObjects
                }
            })
            return DetailedScanObservation(
                observation: detailed.observation.includingApplicationBundleIdentities(
                    identities, selectedApplicationBundlePaths: selectedApplicationBundlePaths
                ),
                fileInventories: detailed.fileInventories
            )
        }
        self.scanTask = scanTask
        Task {
            let result = await scanTask.value
            let observation = result.observation
            if historyGeneration.accepts(generation) {
                do {
                    history = try ObservationStore.append(observation, to: observationStoreURL)
                } catch {
                    errorMessage = "Scan finished, but local history could not be saved: \(error.localizedDescription)"
                }
                if !result.fileInventories.isEmpty {
                    let inventoryStoreURL = fileInventoryStoreURL
                    let inventoryTask = Task.detached(priority: .utility) {
                        try result.fileInventories.compactMap {
                            try FileInventoryStore.recordWithTrendPoints($0, at: inventoryStoreURL)
                        }
                    }
                    fileInventoryTask = inventoryTask
                    do {
                        let inventoryUpdates = try await inventoryTask.value
                        if historyGeneration.accepts(generation) {
                            for update in inventoryUpdates {
                                fileInventoryReports[update.report.rootPath] = update.report
                                sameSizeFileCandidates[update.sameSizeCandidates.rootPath] = update.sameSizeCandidates
                            }
                            if let latest = inventoryUpdates.last {
                                fileInventoryTrends = latest.trendPoints
                            }
                        }
                    } catch {
                        if historyGeneration.accepts(generation) {
                            errorMessage = "The scan was saved, but full file-change history could not be updated: \(error.localizedDescription)"
                        }
                    }
                    fileInventoryTask = nil
                }
            }
            let completedOrigin = scanOrigin
            let completedRootPaths = scanRootPaths
            let completedScheduledPath = scheduledScanPath
            if let completedScheduledPath {
                if !monitoredScopePaths.contains(completedScheduledPath) {
                    storageMonitoringCooldownByPath.removeValue(forKey: completedScheduledPath)
                    storageMonitoringLastAttempt.removeValue(forKey: completedScheduledPath)
                } else if observation.cancelled && isAppActive && storageMonitoringSessionOpen {
                    pauseStorageMonitoring(completedScheduledPath, reason: "Scheduled scan cancelled. Resume monitoring when ready.")
                } else if let folder = observation.folders.first(where: {
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path == completedScheduledPath
                }), StorageMonitoringPolicy.shouldPauseAfterScheduledScan(folder) {
                    pauseStorageMonitoring(
                        completedScheduledPath,
                        reason: "No files could be measured. Check this folder's access, then resume monitoring."
                    )
                } else {
                    storageMonitoringCooldownByPath[completedScheduledPath] = .now
                }
            } else if completedOrigin == .manual {
                for path in completedRootPaths.intersection(monitoredScopePaths) {
                    if observation.cancelled {
                        pauseStorageMonitoring(path, reason: "Scan cancelled. Resume monitoring when ready.")
                    } else {
                        storageMonitoringCooldownByPath[path] = .now
                    }
                }
            } else if completedOrigin == .eventTriggered, let path = completedRootPaths.first {
                if !monitoredScopePaths.contains(path) {
                    storageMonitoringCooldownByPath.removeValue(forKey: path)
                    storageMonitoringLastAttempt.removeValue(forKey: path)
                } else if observation.cancelled && isAppActive && storageMonitoringSessionOpen {
                    pauseStorageMonitoring(path, reason: "Event-triggered scan cancelled. Resume monitoring when ready.")
                } else if let folder = observation.folders.first(where: {
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path == path
                }), StorageMonitoringPolicy.shouldPauseAfterScheduledScan(folder) {
                    pauseStorageMonitoring(
                        path,
                        reason: "No files could be measured. Check this folder's access, then resume monitoring."
                    )
                } else {
                    storageMonitoringCooldownByPath[path] = .now
                }
            }
            isScanning = false
            currentPath = ""
            countedFileObjects = 0
            self.scanTask = nil
            scanOrigin = nil
            scanRootPaths = []
            scheduledScanPath = nil
            eventTriggeredScanPath = nil
            if historyGeneration.accepts(generation) { refreshCapacity() }
            if completedOrigin == .eventTriggered,
               let nextPath = pendingStorageEventPaths.sorted().first {
                noteStorageChangeEvent(for: nextPath)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        fileInventoryTask?.cancel()
        fileInventoryTask = nil
    }

    func toggleStorageMonitoring(_ path: String, enabled: Bool) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard rememberedScopes.contains(where: { $0.path == normalizedPath }) else { return }
        var updatedPaths = monitoredScopePaths
        if enabled { updatedPaths.insert(normalizedPath) }
        else { updatedPaths.remove(normalizedPath) }
        do {
            try StorageMonitoringPreferences.save(updatedPaths, at: storageMonitoringPreferencesURL)
        } catch {
            errorMessage = "The monitoring choice could not be saved: \(error.localizedDescription)"
            return
        }
        if enabled {
            monitoredScopePaths.insert(normalizedPath)
            pausedMonitoringReasons.removeValue(forKey: normalizedPath)
            storageMonitoringEnabledAtByPath[normalizedPath] = .now
            storageMonitoringCooldownByPath[normalizedPath] = .now
            startStorageEventWatchers()
            startStorageMonitoringScheduler()
            requestMonitoringBaseline(for: normalizedPath)
        } else {
            monitoredScopePaths.remove(normalizedPath)
            pausedMonitoringReasons.removeValue(forKey: normalizedPath)
            storageMonitoringEnabledAtByPath.removeValue(forKey: normalizedPath)
            storageMonitoringCooldownByPath.removeValue(forKey: normalizedPath)
            stopStorageEventWatcher(for: normalizedPath)
            if scheduledScanPath == normalizedPath || eventTriggeredScanPath == normalizedPath { cancelScan() }
            if monitoredScopePaths.isEmpty { stopStorageMonitoringScheduler() }
        }
    }

    func resumeStorageMonitoring(_ path: String) {
        guard rememberedScopes.contains(where: { $0.path == path }) else { return }
        pausedMonitoringReasons.removeValue(forKey: path)
        monitoredScopePaths.insert(path)
        storageMonitoringEnabledAtByPath[path] = .now
        storageMonitoringCooldownByPath[path] = .now
        startStorageEventWatchers()
        startStorageMonitoringScheduler()
        requestMonitoringBaseline(for: path)
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
              storageMonitoringSessionOpen, storageMonitoringTask == nil else { return }
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

    func stopStorageEventWatchers() {
        storageEventScanTask?.cancel()
        storageEventScanTask = nil
        pendingStorageEventPaths.removeAll()
        for watcher in storageEventWatchers.values { watcher.stop() }
        storageEventWatchers.removeAll()
        if let eventTriggeredScanPath {
            storageMonitoringCooldownByPath[eventTriggeredScanPath] = .now
            cancelScan()
        }
    }

    func setStorageMonitoringAppActive(_ active: Bool) {
        isAppActive = active
    }

    func setStorageMonitoringSessionOpen(_ open: Bool) {
        storageMonitoringSessionOpen = open
        if open {
            for path in monitoredScopePaths where pausedMonitoringReasons[path] == nil {
                let lastCompleteScan = fileInventoryTrends[path]?.last?.observedAt
                    ?? fileInventoryReports[path]?.observedAt
                if storageMonitoringCooldownByPath[path] == nil {
                    storageMonitoringCooldownByPath[path] = lastCompleteScan ?? .distantPast
                }
                if storageMonitoringEnabledAtByPath[path] == nil {
                    storageMonitoringEnabledAtByPath[path] = storageMonitoringCooldownByPath[path]
                }
            }
            startStorageEventWatchers()
            startStorageMonitoringScheduler()
        } else {
            stopStorageMonitoringScheduler()
            stopStorageEventWatchers()
            if let path = scheduledScanPath {
                cancelScan()
                storageMonitoringCooldownByPath[path] = .now
            }
        }
    }

    private func startStorageEventWatchers() {
        guard storageMonitoringSessionOpen else { return }
        let eligible = monitoredScopePaths.subtracting(pausedMonitoringReasons.keys)
        for path in Array(storageEventWatchers.keys) where !eligible.contains(path) {
            stopStorageEventWatcher(for: path)
        }
        for path in eligible where storageEventWatchers[path] == nil {
            guard let bookmark = rememberedScopes.first(where: { $0.path == path }) else {
                storageEventWatcherErrors[path] = "Saved access is missing; periodic scans remain available."
                continue
            }
            do {
                let url = try SelectedScopeBookmarkStore.resolve(bookmark, at: selectedScopeBookmarkStoreURL)
                let isSandboxed = try SelectedScopeBookmarkStore.requiresSecurityScopedAccess()
                let accessGranted = url.startAccessingSecurityScopedResource()
                guard !isSandboxed || accessGranted else {
                    throw SelectedScopeBookmarkError.bookmarkUnavailable(
                        "macOS did not grant folder access for event monitoring. Periodic scans remain available."
                    )
                }
                let watcher = try SelectedRootEventWatcher(
                    rootURL: url, ownsSecurityScope: accessGranted
                ) { [weak self] in
                    Task { @MainActor in self?.noteStorageChangeEvent(for: path) }
                }
                storageEventWatchers[path] = watcher
                storageEventWatcherErrors.removeValue(forKey: path)
            } catch {
                storageEventWatcherErrors[path] = "Event monitoring unavailable; periodic scans remain available. \(error.localizedDescription)"
            }
        }
    }

    private func stopStorageEventWatcher(for path: String) {
        storageEventWatchers.removeValue(forKey: path)?.stop()
        storageEventWatcherErrors.removeValue(forKey: path)
        pendingStorageEventPaths.remove(path)
    }

    private func requestMonitoringBaseline(for path: String) {
        guard storageMonitoringSessionOpen else { return }
        if isScanning || isMeasuringOwnFootprint || isVerifyingDuplicates {
            noteStorageChangeEvent(for: path)
        } else {
            rescanRememberedFolder(path, origin: .manual)
        }
    }

    private func noteStorageChangeEvent(for path: String) {
        guard storageMonitoringSessionOpen, monitoredScopePaths.contains(path), pausedMonitoringReasons[path] == nil else { return }
        pendingStorageEventPaths.insert(path)
        storageEventScanTask?.cancel()
        storageEventScanTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(
                    StorageMonitoringPolicy.eventDebounceInterval * 1_000_000_000
                ))
            } catch { return }
            guard let self else { return }
            while !Task.isCancelled, self.storageMonitoringSessionOpen, !self.pendingStorageEventPaths.isEmpty {
                let now = Date.now
                let scanInProgress = self.isScanning || self.isMeasuringOwnFootprint || self.isVerifyingDuplicates
                let pendingPaths = self.pendingStorageEventPaths
                let savedPaths = Set(self.rememberedScopes.map(\.path))
                let pausedPaths = Set(self.pausedMonitoringReasons.keys)
                let path = StorageMonitoringPolicy.nextEventTriggeredRoot(
                    monitoringSessionOpen: self.storageMonitoringSessionOpen,
                    scanInProgress: scanInProgress,
                    pendingRootIdentifiers: pendingPaths,
                    savedRootIdentifiers: savedPaths,
                    selectedRootIdentifiers: self.monitoredScopePaths,
                    pausedRootIdentifiers: pausedPaths,
                    lastScanAtByRoot: self.storageMonitoringCooldownByPath,
                    at: now
                )
                if let path {
                    self.pendingStorageEventPaths.remove(path)
                    self.storageMonitoringCooldownByPath[path] = now
                    self.storageMonitoringLastAttempt[path] = now
                    self.storageEventScanTask = nil
                    self.rescanRememberedFolder(path, origin: .eventTriggered)
                    return
                }
                let throttleDelay = StorageMonitoringPolicy.nextEventThrottleDelay(
                    monitoringSessionOpen: self.storageMonitoringSessionOpen,
                    scanInProgress: scanInProgress,
                    pendingRootIdentifiers: pendingPaths,
                    savedRootIdentifiers: savedPaths,
                    selectedRootIdentifiers: self.monitoredScopePaths,
                    pausedRootIdentifiers: pausedPaths,
                    lastScanAtByRoot: self.storageMonitoringCooldownByPath,
                    at: now
                )
                let retryDelay = min(max(throttleDelay ?? 1, 0.05), 60)
                do { try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000)) }
                catch { return }
            }
            self.storageEventScanTask = nil
        }
    }

    private func evaluateStorageMonitoring(at now: Date = .now) {
        let decision = StorageMonitoringPolicy.evaluate(
            StorageMonitoringPolicy.Input(
                enabled: !monitoredScopePaths.isEmpty,
                interval: storageMonitoringInterval,
                enabledAt: monitoredScopePaths.compactMap { storageMonitoringEnabledAtByPath[$0] }.min() ?? .distantFuture,
                monitoringSessionOpen: storageMonitoringSessionOpen,
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
        stopStorageEventWatcher(for: path)
        if scheduledScanPath == path || eventTriggeredScanPath == path { cancelScan() }
        if !monitoredScopePaths.contains(where: { pausedMonitoringReasons[$0] == nil }) {
            stopStorageMonitoringScheduler()
        }
    }

    private func removeStorageMonitoringState(for path: String) {
        monitoredScopePaths.remove(path)
        do {
            try StorageMonitoringPreferences.save(monitoredScopePaths, at: storageMonitoringPreferencesURL)
        } catch {
            errorMessage = "The forgotten folder's monitoring choice could not be removed: \(error.localizedDescription)"
        }
        pausedMonitoringReasons.removeValue(forKey: path)
        storageMonitoringEnabledAtByPath.removeValue(forKey: path)
        storageMonitoringCooldownByPath.removeValue(forKey: path)
        storageMonitoringLastAttempt.removeValue(forKey: path)
        stopStorageEventWatcher(for: path)
        if scheduledScanPath == path || eventTriggeredScanPath == path { cancelScan() }
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
        storageMonitoringSessionOpen = false
        pausedMonitoringReasons = [:]
        storageMonitoringEnabledAtByPath = [:]
        storageMonitoringCooldownByPath = [:]
        storageMonitoringLastAttempt = [:]
        scheduledScanPath = nil
        stopStorageMonitoringScheduler()
        stopStorageEventWatchers()
        applicationBundlePathStatuses = [:]
        checkingApplicationBundlePaths = []
        applicationBundlePathCheckIDs = [:]
        applicationDataLocationStatuses = [:]
        checkingApplicationDataLocationPaths = []
        applicationDataLocationCheckIDs = [:]
        applicationAssociatedPathStatuses = [:]
        checkingApplicationAssociatedPaths = []
        applicationAssociatedPathCheckIDs = [:]
        projectResourcePathStatuses = [:]
        checkingProjectResourcePaths = []
        projectResourcePathCheckIDs = [:]
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
            try ObservationStore.clear(at: observationStoreURL)
            try FileInventoryStore.clear(at: fileInventoryStoreURL)
            try SelectedScopeBookmarkStore.clear(at: selectedScopeBookmarkStoreURL)
            try StorageMonitoringPreferences.clear(at: storageMonitoringPreferencesURL)
            history = LocalHistory()
            fileInventoryReports = [:]
            fileInventoryTrends = [:]
            sameSizeFileCandidates = [:]
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
            return NSLocalizedString("No comparable prior retained path", comment: "History status when no matching complete prior path is retained")
        }
        guard let currentIndex = history.observations.firstIndex(where: { observation in
            observation.folders.contains(where: { $0.id == folder.id })
        }) else { return NSLocalizedString("First complete observation", comment: "History status when this path has no prior complete scan") }
        let earlierComplete = history.observations[..<currentIndex].reversed().lazy
            .compactMap { observation in
                observation.folders.first(where: { $0.path == folder.path && $0.complete })
            }
            .first
        guard let earlierComplete else { return NSLocalizedString("First complete observation", comment: "History status when this path has no prior complete scan") }
        if let previousDeviceID = earlierComplete.volumeDeviceID,
           let currentDeviceID = folder.volumeDeviceID,
           previousDeviceID != currentDeviceID {
            return NSLocalizedString("Volume identity changed; comparison unavailable", comment: "History status when a path now resolves to another volume")
        }
        if earlierComplete.volumeDeviceID == nil, folder.volumeDeviceID != nil {
            return NSLocalizedString("Earlier volume identity unavailable; comparison omitted", comment: "History status when the prior volume identity is missing")
        }
        if earlierComplete.volumeDeviceID != nil, folder.volumeDeviceID == nil {
            return NSLocalizedString("Current volume identity unavailable; comparison omitted", comment: "History status when the current volume identity is missing")
        }
        return NSLocalizedString("No comparable prior retained path", comment: "History status when no matching complete prior path is retained")
    }

    func previousCompleteDirectory(
        for directory: DirectoryUsage, in folder: FolderObservation
    ) -> DirectoryUsage? {
        ObservationComparison.previousCompleteDirectory(
            for: directory, in: folder, history: history
        )
    }
}

private struct OverviewFileChangeRow: Identifiable {
    let folder: FolderObservation
    let change: FileInventoryChange
    var id: String { folder.path + "\u{0}" + change.relativePath }
}

struct DashboardView: View {
    @State private var model: DashboardModel
    @State private var applicationDiscovery: ApplicationDiscoveryModel
    @State private var selectedSection: String? = "Overview"
    @State private var historyChartRange: ObservationTimeRange = .week
    @State private var selectedCapacityDate: Date?
    @State private var selectedRAMDate: Date?
    @State private var selectedFolderHistoryPath: String?
    @State private var selectedFolderHistoryDate: Date?
    @State private var isConfirmingHistoryClear = false
    @State private var isAutomaticRAMSamplingEnabled = false
    @State private var applicationReviewBundle: FolderObservation?
    @State private var applicationDiscoverySearchText = ""
    @State private var savedApplicationInventoryCache = SavedApplicationInventory.empty
    @State private var isSavedApplicationInventoryLoading = false
    @State private var isSavedApplicationHistoryExpanded = false
    @State private var expandedSavedApplicationPaths = Set<String>()
    @State private var expandedApplicationDiscoveryDataPaths = Set<String>()
    @State private var expandedApplicationDiscoveryRelatedLocations = Set<String>()
    @State private var expandedProjectResourceRoots = Set<String>()
    @State private var applicationDiscoveryMeasurementFilter: ApplicationDiscoveryMeasurementFilter = .all
    @State private var applicationDiscoverySort: ApplicationDiscoverySort = .name
    @State private var developerArtifactReviewFolder: FolderObservation?
    @State private var databaseSidecarReviewFolder: FolderObservation?
    @Environment(\.scenePhase) private var scenePhase

    private let suppressSpotlightDiscovery: Bool
    private let expandFirstSavedApplicationForSnapshot: Bool
    private let includeSnapshotProjectCandidate: Bool
    private let includeSnapshotDiscoveredApplicationCandidate: Bool

    init(
        initialSection: String = "Overview",
        expandSavedApplicationHistory: Bool = false,
        suppressSpotlightDiscovery: Bool = false,
        expandFirstSavedApplicationForSnapshot: Bool = false,
        includeSnapshotProjectCandidate: Bool = false,
        includeSnapshotDiscoveredApplicationCandidate: Bool = false
    ) {
        _model = State(initialValue: DashboardModel(
            includeSnapshotProjectCandidate: includeSnapshotProjectCandidate,
            includeSnapshotDiscoveredApplicationCandidate: includeSnapshotDiscoveredApplicationCandidate
        ))
        _applicationDiscovery = State(initialValue: ApplicationDiscoveryModel(
            includeSnapshotCandidate: includeSnapshotDiscoveredApplicationCandidate
        ))
        _selectedSection = State(initialValue: initialSection)
        _isSavedApplicationHistoryExpanded = State(initialValue: expandSavedApplicationHistory)
        _expandedProjectResourceRoots = State(initialValue: includeSnapshotProjectCandidate
            ? ["/synthetic/QA/DemoProject"] : [])
        _expandedApplicationDiscoveryDataPaths = State(initialValue: includeSnapshotDiscoveredApplicationCandidate
            ? ["/synthetic/Applications/DemoApp.app"] : [])
        _expandedApplicationDiscoveryRelatedLocations = State(initialValue: includeSnapshotDiscoveredApplicationCandidate
            ? ["/synthetic/Applications/DemoApp.app"] : [])
        self.suppressSpotlightDiscovery = suppressSpotlightDiscovery
        self.expandFirstSavedApplicationForSnapshot = expandFirstSavedApplicationForSnapshot
        self.includeSnapshotProjectCandidate = includeSnapshotProjectCandidate
        self.includeSnapshotDiscoveredApplicationCandidate = includeSnapshotDiscoveredApplicationCandidate
    }

    private let sections = ["Overview", "Applications", "Folders", "Duplicates", "History", "RAM", "About"]

    /// Keep stable English section identifiers for navigation state while
    /// translating only the labels presented to the user.
    private func sectionTitle(_ section: String) -> String {
        NSLocalizedString(section, comment: "Disker sidebar section")
    }

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
                Label(sectionTitle(section), systemImage: icon(for: section))
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
                review: model.applicationFootprintReview(for: bundle),
                crossDomainEvidence: model.crossDomainResourceEvidence(forApplicationBundlePath: bundle.path)
            )
            .frame(minWidth: 580, minHeight: 520)
        }
        .sheet(item: $developerArtifactReviewFolder) { folder in
            DeveloperArtifactReviewSheet(folder: folder, history: model.history) { url in
                model.measureSelectedCandidate(at: url.path)
            }
            .frame(minWidth: 620, minHeight: 560)
        }
        .sheet(item: $databaseSidecarReviewFolder) { folder in
            DatabaseSidecarReviewSheet(
                folder: folder,
                fileChangeReport: model.fileInventoryReports[folder.path].flatMap {
                    $0.folderObservationID == folder.id ? $0 : nil
                }
            )
                .frame(minWidth: 620, minHeight: 500)
        }
        .onAppear {
            model.setStorageMonitoringAppActive(scenePhase == .active)
            model.setStorageMonitoringSessionOpen(true)
            model.startStorageMonitoringScheduler()
            if !includeSnapshotProjectCandidate && !includeSnapshotDiscoveredApplicationCandidate {
                model.refreshCapacity()
            }
            if !suppressSpotlightDiscovery { applicationDiscovery.start() }
            model.updateMemoryPressureMonitoring(
                enabled: isAutomaticRAMSamplingEnabled, appIsActive: model.isAppActive
            )
        }
        .onChange(of: historyChartRange) { _, _ in
            selectedCapacityDate = nil
            selectedRAMDate = nil
        }
        .onChange(of: scenePhase) { _, phase in
            model.setStorageMonitoringAppActive(phase == .active)
            model.updateMemoryPressureMonitoring(
                enabled: isAutomaticRAMSamplingEnabled, appIsActive: model.isAppActive
            )
        }
        .onDisappear {
            model.setStorageMonitoringSessionOpen(false)
            applicationDiscovery.stop()
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
                applicationDiscovery.resetHistory()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes saved capacity, folder, file-change, RAM and system-pressure history, application discovery dates, saved application discovery folders and app-folder associations, and remembered scan locations from this Mac. Active storage and RAM monitoring will stop. Your files and folders will not be changed.")
        }
    }

    private var overviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header("Storage overview", subtitle: "A measured view of your Mac's storage, with clear limits.")
                capacitySummaryCards
                capacityCard
                if model.latestScan == nil && !model.isScanning {
                    firstRunOverviewCard
                } else {
                    scanCard
                }
                fileChangeOverviewCard
                if model.latestScan != nil || model.isScanning {
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

    @ViewBuilder
    private var capacitySummaryCards: some View {
        if let capacity = model.capacity {
            let roots = model.latestScan?.folders ?? []
            let completeRoots = roots.filter(\.complete).count
            let coverageTint: Color = roots.isEmpty ? .secondary : completeRoots == roots.count ? .green : .orange
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                SWKPICard(
                    title: "Available now",
                    value: format(capacity.availableBytes),
                    icon: "internaldrive.fill",
                    tint: .blue
                ) {
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("%@ · reported by macOS", comment: "Volume name and capacity source"),
                        capacity.volumeName ?? NSLocalizedString("System volume", comment: "Name fallback for the system volume")
                    ))
                }
                SWKPICard(
                    title: "Volume capacity",
                    value: format(capacity.totalBytes),
                    icon: "externaldrive.fill",
                    tint: .indigo
                ) {
                    Text(NSLocalizedString(
                        capacity.volumeIsLocal.map { $0 ? "Local volume" : "Network volume" } ?? "Volume location unknown",
                        comment: "Storage volume location"
                    ))
                }
                SWKPICard(
                    title: "Selected-folder coverage",
                    value: roots.isEmpty ? "—" : "\(completeRoots) / \(roots.count)",
                    icon: "folder.badge.gearshape",
                    tint: coverageTint
                ) {
                    Text(roots.isEmpty ? "No folder scan recorded" : "Complete selected roots · latest scan")
                }
            }
        }
    }

    /// Most recent partial observation for each exact selected path. These
    /// values are useful context beside an unexplained capacity movement,
    /// but never represent the amount added during that movement.
    private var latestPartialFolderMeasurements: [FolderObservation] {
        guard let latest = model.history.observations.last else { return [] }
        return latest.folders
            .filter { !$0.complete }
            .sorted {
                if $0.finishedAt != $1.finishedAt { return $0.finishedAt > $1.finishedAt }
                return $0.path < $1.path
            }
            .prefix(3)
            .map { $0 }
    }

    private func historyDateAxisFormat(for dates: [Date]) -> Date.FormatStyle {
        guard let earliest = dates.min(), let latest = dates.max() else { return .dateTime.month(.abbreviated).day() }
        let span = latest.timeIntervalSince(earliest)
        if span < 24 * 60 * 60 { return .dateTime.hour().minute() }
        if span < 21 * 24 * 60 * 60 { return .dateTime.month(.abbreviated).day().hour() }
        if span < 730 * 24 * 60 * 60 { return .dateTime.month(.abbreviated).day() }
        return .dateTime.month(.abbreviated).year()
    }

    private var fileChangeOverviewCard: some View {
        Group {
            if let latest = model.latestScan, !latest.folders.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Changes inside selected folders", systemImage: "doc.badge.arrow.up")
                        .font(.headline)
                    ForEach(latest.folders) { folder in
                        fileInventoryOverviewRow(folder, latest: latest)
                    }
                    Text("Disker compares regular files only inside the exact selected folders. It cannot name changes elsewhere on the Mac, reconstruct earlier growth, or catch files created and removed between scans. Overlapping roots are not additive; allocated bytes are estimates, not reclaimable space.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if latest.folders.contains(where: { folder in
                        guard let report = model.fileInventoryReports[folder.path] else { return true }
                        return report.folderObservationID != folder.id
                    }) {
                        Button("Choose folders and record a baseline") { model.chooseFolders() }
                            .buttonStyle(.link)
                            .disabled(model.isScanning)
                    } else {
                        Button("Open Folders for file details and monitoring") { selectedSection = "Folders" }
                            .buttonStyle(.link)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.12)))
            }
        }
    }

    @ViewBuilder
    private func fileInventoryOverviewRow(_ folder: FolderObservation, latest: ScanObservation) -> some View {
        if let report = model.fileInventoryReports[folder.path], report.folderObservationID == folder.id {
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.displayName)
                    .font(.subheadline.weight(.semibold))
                monitoringStatusLabel(for: folder.path)
                if !report.hasBaseline {
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString(
                            "Baseline recorded at %@; the next complete scan can show file-level changes.",
                            comment: "Time of the initial selected-folder file inventory baseline"
                        ),
                        report.observedAt.formatted(date: .abbreviated, time: .shortened)
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(fileInventorySummary(report))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(report.changes.filter { $0.allocatedDelta > 0 }.prefix(3))) { change in
                        fileInventoryGrowthRow(change, folderName: folder.displayName)
                    }
                    if report.changedPathCount == 0 {
                        Text("No file-path or size changes measured.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if report.omittedChangeCount > 0 {
                        Text(String.localizedStringWithFormat(
                            NSLocalizedString("%ld additional paths are included in the net totals; open Folders for the bounded details.", comment: "Number of file paths omitted from the bounded visible change list"),
                            Int32(report.omittedChangeCount)
                        ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.displayName)
                    .font(.subheadline.weight(.semibold))
                monitoringStatusLabel(for: folder.path)
                Group {
                    if !folder.complete || latest.cancelled {
                        if model.fileInventoryReports[folder.path] != nil {
                            Text(String.localizedStringWithFormat(
                                NSLocalizedString("%@ No file-level comparison was produced for this scan; the prior report remains stored but is not current.", comment: "Partial selected-root file scan keeps its older report but withholds a current comparison"),
                                fileInventoryIncompleteness(for: folder)
                            ))
                        } else {
                            Text(String.localizedStringWithFormat(
                                NSLocalizedString("%@ No complete file-level baseline is stored for this folder. A later complete scan must establish one; earlier growth cannot be reconstructed.", comment: "Partial selected-root file scan has no baseline and requires a future complete scan"),
                                fileInventoryIncompleteness(for: folder)
                            ))
                        }
                    } else if model.fileInventoryReports[folder.path] != nil {
                        Text("This scan did not produce a comparable full inventory. The prior complete report remains stored; a later complete scan can resume path-level comparisons.")
                    } else {
                        Text("No complete file-level baseline exists for this selected folder. Record a baseline now to show exact path changes after a later complete scan; earlier growth cannot be reconstructed.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func monitoringStatusLabel(for path: String) -> some View {
        let enabled = model.monitoredScopePaths.contains(path)
        let paused = model.pausedMonitoringReasons[path] != nil
        return Label(
            paused ? "Monitoring paused · review access"
                : enabled ? "Monitoring on · only while window open"
                : "Monitoring off · changes appear after a scan",
            systemImage: paused ? "pause.circle" : enabled ? "dot.radiowaves.left.and.right" : "pause.circle"
        )
        .font(.caption2)
        .foregroundStyle(paused ? Color.orange : enabled ? Color.accentColor : Color.secondary)
    }

    private func fileInventoryGrowthRow(_ change: FileInventoryChange, folderName: String) -> some View {
        let path = change.relativePath.isEmpty ? folderName : change.relativePath
        let amount = String.localizedStringWithFormat(
            NSLocalizedString("+%@ allocated estimate", comment: "Allocated-byte estimate increase for one file path"),
            format(change.allocatedDelta)
        )
        return HStack(spacing: 8) {
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(amount)
                .monospacedDigit()
        }
        .font(.caption2)
    }

    private func partialFolderCoverageReason(_ folder: FolderObservation) -> String {
        var reasons: [String] = []
        if folder.excludedSymlinkCount > 0 {
            reasons.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld symlinks not followed", comment: "Count of symbolic links excluded from scan"),
                folder.excludedSymlinkCount
            ))
        }
        if folder.inaccessibleCount > 0 {
            reasons.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld items inaccessible", comment: "Count of inaccessible selected-folder items"),
                folder.inaccessibleCount
            ))
        }
        if folder.changedDuringScanCount > 0 {
            reasons.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld changed during scan", comment: "Count of items that changed during metadata measurement"),
                folder.changedDuringScanCount
            ))
        }
        if folder.excludedVolumeBoundaryCount > 0 {
            reasons.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld nested volume boundaries skipped", comment: "Count of nested volumes outside selected scan boundary"),
                folder.excludedVolumeBoundaryCount
            ))
        }
        if folder.excludedSpecialFileCount > 0 {
            reasons.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld special files excluded", comment: "Count of unsupported special filesystem items"),
                folder.excludedSpecialFileCount
            ))
        }
        if folder.byteAccountingOverflowed {
            reasons.append(NSLocalizedString(
                "byte total exceeded the supported range and was capped",
                comment: "Coverage limitation caused by byte-accounting overflow"
            ))
        }
        return reasons.isEmpty
            ? NSLocalizedString("Coverage incomplete", comment: "Selected-folder coverage is incomplete")
            : reasons.joined(separator: " · ")
    }

    private var capacityCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Available-space history", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                Text(model.capacity.map { $0.observedAt.formatted(date: .abbreviated, time: .shortened) }
                    ?? NSLocalizedString("Unavailable", comment: "No stored capacity observation is available"))
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
                HStack(spacing: 10) {
                    Image(systemName: "internaldrive.fill")
                        .foregroundStyle(.blue)
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("%@ · %@", comment: "Volume name and local or network location"),
                        capacity.volumeName ?? NSLocalizedString("System volume", comment: "Name fallback for the system volume"),
                        NSLocalizedString(
                            capacity.volumeIsLocal.map { $0 ? "local volume" : "network volume" } ?? "volume location unknown",
                            comment: "Storage volume location"
                        )
                    ))
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 4)
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("%ld%% available", comment: "Percent of volume capacity available"),
                        Int((Double(capacity.availableBytes) / Double(max(1, capacity.totalBytes)) * 100).rounded())
                    ))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(capacity.availableBytes), total: Double(max(1, capacity.totalBytes)))
                    .tint(.blue)
                    .controlSize(.small)
                    .accessibilityLabel("Available capacity")
                    .accessibilityValue("\(format(capacity.availableBytes)) of \(format(capacity.totalBytes))")
                if let interval = ObservationComparison.folderGrowthDuringLargestUnrecoveredCapacityLoss(in: model.history),
                   interval.folderGrowth.isEmpty {
                    HStack(alignment: .center, spacing: 10) {
                        Label("Source not identified", systemImage: "questionmark.folder")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text("No complete before-and-after scan of a selected folder matches this drop. Capacity history cannot name the files or measure what was added.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Choose folders") { model.chooseFolders() }
                            .buttonStyle(.link)
                            .disabled(model.isScanning)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityElement(children: .contain)
                    if !latestPartialFolderMeasurements.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Latest selected-folder measurements")
                                .font(.caption.weight(.semibold))
                            ForEach(latestPartialFolderMeasurements) { folder in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(folder.displayName)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Text(folderAllocatedValue(folder))
                                        .monospacedDigit()
                                    Text(partialFolderCoverageReason(folder))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .font(.caption2)
                                .accessibilityElement(children: .combine)
                                if folder.excludedSymlinkCount > 0 {
                                    excludedSymlinkSection(for: folder)
                                }
                            }
                            Text("These are partial current-size estimates, not new bytes. Disker cannot reconstruct a before-scan it did not record; a complete baseline and later scan are needed to show future growth.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, 4)
                    }
                }
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
                    let firstCapacityDate = capacitySeries[0].observedAt
                    let lastCapacityDate = capacitySeries[capacitySeries.count - 1].observedAt
                    let xAxisPadding = max(lastCapacityDate.timeIntervalSince(firstCapacityDate) * 0.04, 1)
                    let minimum = values.min() ?? 0
                    let maximum = values.max() ?? minimum
                    let padding = max((maximum - minimum) * 0.15, max(Double(capacity.totalBytes) / 1_073_741_824 * 0.005, 0.25))
                    let selectedCapacitySample = selectedCapacityDate.flatMap { selectedDate in
                        capacitySeries.min {
                            abs($0.observedAt.timeIntervalSince(selectedDate))
                                < abs($1.observedAt.timeIntervalSince(selectedDate))
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        historyRangePicker
                        Chart {
                            ForEach(capacitySeries, id: \.observedAt) { sample in
                                LineMark(
                                    x: .value("Observed", sample.observedAt),
                                    y: .value("Available GiB", Double(sample.availableBytes) / 1_073_741_824)
                                )
                                .interpolationMethod(.linear)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(Color.accentColor.gradient)

                                if selectedCapacitySample?.observedAt == sample.observedAt {
                                    PointMark(
                                        x: .value("Observed", sample.observedAt),
                                        y: .value("Available GiB", Double(sample.availableBytes) / 1_073_741_824)
                                    )
                                    .symbolSize(90)
                                    .foregroundStyle(Color.accentColor)
                                }
                            }
                            if let selectedCapacitySample {
                                RuleMark(x: .value("Selected observation", selectedCapacitySample.observedAt))
                                    .foregroundStyle(.secondary.opacity(0.55))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            }
                        }
                        .chartXScale(domain:
                            firstCapacityDate.addingTimeInterval(-xAxisPadding)...lastCapacityDate.addingTimeInterval(xAxisPadding)
                        )
                        .chartYScale(domain: max(0, minimum - padding)...(maximum + padding))
                        .chartYAxisLabel("Available (GiB)")
                        .chartYAxis {
                            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { _ in
                                AxisGridLine()
                                AxisValueLabel()
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                                AxisGridLine()
                                    .foregroundStyle(.quaternary)
                                if let tickDate = value.as(Date.self),
                                   tickDate <= lastCapacityDate.addingTimeInterval(-xAxisPadding) {
                                    AxisValueLabel(format: historyDateAxisFormat(for: capacitySeries.map(\.observedAt)))
                                }
                            }
                        }
                        .chartPlotStyle { plot in
                            plot
                                .background(Color.primary.opacity(0.018))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .chartXSelection(value: $selectedCapacityDate)
                        .frame(height: 210)
                        .accessibilityLabel(String.localizedStringWithFormat(
                            NSLocalizedString("Available-space history for %@, %ld comparable observations", comment: "Accessible description of storage history chart"),
                            NSLocalizedString(historyChartRange.title, comment: "Storage history chart time range"),
                            capacitySeries.count
                        ))
                        if let selectedCapacitySample {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(format(selectedCapacitySample.availableBytes))
                                    .font(.title3.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.blue)
                                Text(selectedCapacitySample.observedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear selection") { selectedCapacityDate = nil }
                                    .buttonStyle(.link)
                                    .font(.caption)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Text("\(capacitySeries.count) comparable observations · \(historyRangeCaption(endingAt: latestCapacityDate)) · drag across the chart to inspect a saved sample · focused vertical scale · not attributed to folders")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if !fullCapacitySeries.isEmpty {
                    historyRangePicker
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("Fewer than two comparable capacity observations in %@.", comment: "Insufficient observations in selected storage history range"),
                        historyRangeCaption(endingAt: latestCapacityDate)
                    ))
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
                    if let interval = ObservationComparison.folderGrowthDuringLargestUnrecoveredCapacityLoss(
                        in: model.history
                    ) {
                        capacityIntervalGrowthCard(interval)
                    }
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
                    Text(NSLocalizedString(
                        capacity.availabilityBasis == .importantUsage
                            ? "Available space uses macOS’s estimate for important usage. Capacity minus available is a difference between system-reported values, not a measurement of physical file usage."
                            : "macOS’s standard available-capacity value is shown because its important-usage estimate was zero or unavailable. Capacity minus available is not a measurement of physical file usage.",
                        comment: "Clarifies the system-reported capacity measurement basis"
                    ))
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

    private func capacityIntervalGrowthCard(
        _ interval: ObservationComparison.CapacityIntervalFolderGrowth
    ) -> some View {
        let fileInventoryGrowth = ObservationComparison.fileInventoryGrowthAligned(
            with: interval,
            points: model.fileInventoryTrends.values.flatMap { $0 },
            limit: 3
        )
        return VStack(alignment: .leading, spacing: 10) {
            Label("Selected-folder changes near this capacity interval", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
            Text("Capacity decreased by \(format(interval.availableBytesLost)) from \(interval.previousCapacity.observedAt.formatted(date: .abbreviated, time: .shortened)) to \(interval.currentCapacity.observedAt.formatted(date: .abbreviated, time: .shortened)).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("This is the largest drop of at least \(format(ObservationComparison.minimumReportedCapacityLossBytes)) in retained history that later readings have not fully recovered.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if interval.folderGrowth.isEmpty && fileInventoryGrowth.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No selected folder has complete before-and-after measurements aligned with this capacity drop. The graph alone cannot identify which files changed or how large they were.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Choose exact project folders to measure them now. A later complete scan can show growth; Disker cannot reconstruct a baseline from before the first scan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.chooseFolders()
                    } label: {
                        Label("Choose folders to measure", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.link)
                    .disabled(model.isScanning)
                }
            } else {
                if interval.folderGrowth.isEmpty {
                    Text("Folder-size totals were incomplete for this interval, but complete no-follow file inventories recorded these selected-root changes:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(interval.folderGrowth.prefix(3)) { signal in
                        HStack(alignment: .top, spacing: 10) {
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
                            Spacer(minLength: 6)
                            Text("+\(format(signal.growthBytes)) allocated")
                                .font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(.orange)
                        }
                    }
                    if interval.folderGrowth.count > 3 {
                        Text("Showing 3 of \(interval.folderGrowth.count) aligned selected paths. Open Folders to review others.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !fileInventoryGrowth.isEmpty {
                    Label("Regular-file changes observed in the overlapping period", systemImage: "doc.badge.arrow.up")
                        .font(.caption.weight(.semibold))
                    ForEach(fileInventoryGrowth) { point in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(URL(fileURLWithPath: point.rootPath).lastPathComponent)
                                    .font(.caption.weight(.medium))
                                Spacer(minLength: 4)
                                Text("Gross growth ~\(point.grossAllocatedGrowth.map { format($0) } ?? "unknown")")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.orange)
                            }
                            Text("\(point.rootPath) · reduced ~\(point.grossAllocatedReduction.map { format($0) } ?? "unknown") · net \(point.netAllocatedDelta.map(formattedDelta) ?? "unknown") · \(point.changedPathCount) paths")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("Scans: \(point.previousObservedAt.formatted(date: .abbreviated, time: .shortened)) → \(point.observedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let excludedSymlinkCount = point.excludedSymlinkCount, excludedSymlinkCount > 0 {
                                Text("\(excludedSymlinkCount) symlink entries and their targets were excluded.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else if point.excludedSymlinkCount == nil {
                                Text("Symlink exclusion details are unavailable for this older interval.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Text("These observations are selected-scope time correlations, not proof that the paths caused this capacity change or reside on the same physical volume. They may include overlapping paths, so do not add the values. Unselected, inaccessible, symlink-target, and system-managed storage remains unassigned.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var scanCard: some View {
        let latest = model.latestScan
        let completeRootCount = latest?.folders.filter(\.complete).count ?? 0
        let selectedRootCount = latest?.folders.count ?? 0
        return HStack(spacing: 16) {
            Image(systemName: model.isScanning ? "folder.badge.questionmark" : "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(model.isScanning ? Color.blue : Color.accentColor)
                .frame(width: 44, height: 44)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isScanning ? "Scanning selected folders" : "Selected-folder coverage")
                    .font(.headline)
                if model.isScanning {
                    Text("Access is limited to the locations you select.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let latest, !latest.folders.isEmpty {
                    HStack(spacing: 5) {
                        Text("Complete selected roots")
                        Text("\(completeRootCount) / \(selectedRootCount)")
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Text("Last scan")
                        Text(latest.finishedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if completeRootCount < selectedRootCount {
                        Text("Some selected roots are incomplete; their totals remain unknown.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if latest.cancelled {
                        Text("The latest scan was cancelled.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("No folder results were recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    private var firstRunOverviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Start with one folder", systemImage: "folder.badge.plus")
                .font(.headline)
            Text("Disker can report your drive's available space, but it does not yet know how that space is distributed across folders. Unselected and system-managed storage remains unknown.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Choose a project, Downloads, or Documents. A complete scan records a baseline; a later complete scan can show changes from that point forward. Earlier growth cannot be reconstructed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose folders to measure…") { model.chooseFolders() }
                .disabled(model.isScanning)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.12)))
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
                            Text(String.localizedStringWithFormat(
                                NSLocalizedString("Showing 3 of %ld selected roots with candidates. Open Folders to review the rest.", comment: "Bounded number of selected roots with development-data candidates on Overview"),
                                Int32(candidateFolders.count)
                            ))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(candidateFolders.prefix(3), id: \.path) { folder in
                            let review = DeveloperArtifactReview.make(from: folder)
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(folder.displayName)
                                        .font(.subheadline.weight(.semibold))
                                    Text(String.localizedStringWithFormat(
                                        NSLocalizedString("%ld measured candidates · %@", comment: "Count of measured development-data candidates and selected-folder scan coverage"),
                                        Int32(review.entries.count),
                                        NSLocalizedString(
                                            folder.complete ? "complete scan" : "partial scan",
                                            comment: "Coverage state of the selected-folder scan"
                                        )
                                    ))
                                        .font(.caption)
                                        .foregroundStyle(folder.complete ? Color.secondary : Color.orange)
                                    if let largest = review.entries.max(by: { $0.allocatedBytesEstimate < $1.allocatedBytesEstimate }) {
                                        Text(String.localizedStringWithFormat(
                                            NSLocalizedString("Largest candidate: %@ · allocated estimate ~%@", comment: "Largest measured development-data candidate and its allocated-byte estimate"),
                                            largest.relativePath,
                                            format(largest.allocatedBytesEstimate)
                                        ))
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
                                Text(String.localizedStringWithFormat(
                                    NSLocalizedString("At latest scan · allocated estimate ~%@", comment: "Allocated-byte estimate for the latest complete selected-folder scan"),
                                    format(signal.folder.allocatedBytes)
                                ))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let bytesPerDay = signal.observedBytesPerDay {
                                    Text(String.localizedStringWithFormat(
                                        NSLocalizedString("Observed pace %@/day", comment: "Observed allocated-byte change rate per day"),
                                        formattedByteRate(bytesPerDay)
                                    ))
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
                                Text(String.localizedStringWithFormat(
                                    NSLocalizedString("At latest scan · allocated estimate ~%@", comment: "Allocated-byte estimate for the latest complete selected-folder scan"),
                                    format(signal.directory.allocatedBytes)
                                ))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let bytesPerDay = signal.observedBytesPerDay {
                                    Text(String.localizedStringWithFormat(
                                        NSLocalizedString("Observed pace %@/day", comment: "Observed allocated-byte change rate per day"),
                                        formattedByteRate(bytesPerDay)
                                    ))
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
        DisclosureGroup {
            Text("The capacity figure comes from macOS. Folder totals are a separate file-tree estimate: snapshots, clones and system-managed storage can make them differ. Unmeasured items are reported as incomplete, never as zero.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Label("About these measurements", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var applicationsPage: some View {
        ScrollViewReader { scrollProxy in
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

                if model.isScanning {
                    Button("Cancel Scan") { model.cancelScan() }
                } else {
                    Button("Choose an Application Bundle…") { model.chooseApplicationBundle() }
                }
                applicationDiscoverySection { path in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        scrollProxy.scrollTo(path, anchor: .top)
                    }
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
                if bundles.isEmpty && applicationDiscovery.candidates.isEmpty {
                    ContentUnavailableView {
                        Label("No application bundles measured", systemImage: "app.dashed")
                    } description: {
                        Text("Choose one .app bundle to measure its file tree. Disker will not scan neighboring support data.")
                    } actions: {
                        if model.isScanning {
                            Button("Cancel Scan") { model.cancelScan() }
                        } else {
                            Button("Choose an Application Bundle…") { model.chooseApplicationBundle() }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 190)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    ForEach(bundles) { bundle in
                        let relatedPaths = model.relatedFolders(for: bundle.path)
                        let pathStatus = model.applicationBundlePathStatuses[bundle.path]
                        let isCheckingPath = model.checkingApplicationBundlePaths.contains(bundle.path)
                        let isCheckingRelatedPaths = model.checkingApplicationAssociatedPaths.contains(bundle.path)
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
                                } else if let pathStatus {
                                    Label(
                                        applicationBundlePathStatusText(pathStatus),
                                        systemImage: associatedPathStatusSymbol(pathStatus)
                                    )
                                    .font(.caption)
                                    .foregroundStyle(associatedPathStatusColor(pathStatus))
                                }
                                Button(pathStatus == nil ? "Check bundle path" : "Check again") {
                                    model.checkApplicationBundlePath(bundle.path)
                                }
                                .controlSize(.small)
                                .disabled(isCheckingPath || model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
                                .help("Check only the exact app bundle path last measured; no folders are scanned")
                            }
                            if let pathStatus, !pathStatus.isAvailableDirectory, !relatedPaths.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Label {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Related locations · review suggested")
                                                .font(.subheadline.weight(.semibold))
                                            Text("The last exact-path check did not confirm the app bundle location. It may have moved, its volume may be disconnected, access may be restricted, or the path may have changed type. This does not establish that the app was removed. Saved location associations were selected manually; their presence, ownership, and safety are unknown.")
                                                .font(.caption)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    } icon: {
                                        Image(systemName: "questionmark.folder.fill")
                                            .foregroundStyle(.orange)
                                    }
                                    .foregroundStyle(.secondary)

                                    Text("Check only the exact associated paths. Disker does not scan file contents in this check, follow symlinks, or decide whether anything can be removed.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)

                                    Button {
                                        model.checkAssociatedApplicationPaths(for: bundle.path)
                                    } label: {
                                        if isCheckingRelatedPaths {
                                            ProgressView("Checking selected paths…")
                                                .controlSize(.small)
                                        } else {
                                            Label("Check associated locations…", systemImage: "folder.badge.questionmark")
                                        }
                                    }
                                    .controlSize(.small)
                                    .disabled(isCheckingRelatedPaths || model.isScanning || model.isVerifyingDuplicates || model.isMeasuringOwnFootprint)

                                    let checkedPaths = relatedPaths.filter {
                                        model.applicationAssociatedPathStatuses[$0] != nil
                                    }
                                    if !checkedPaths.isEmpty {
                                        DisclosureGroup("Exact paths checked (\(checkedPaths.count))") {
                                            VStack(alignment: .leading, spacing: 10) {
                                                ForEach(checkedPaths, id: \.self) { path in
                                                    let status = model.applicationAssociatedPathStatuses[path]!
                                                    VStack(alignment: .leading, spacing: 5) {
                                                        Text(path)
                                                            .font(.caption2.monospaced())
                                                            .textSelection(.enabled)
                                                            .fixedSize(horizontal: false, vertical: true)
                                                        Label(associatedPathStatusText(status), systemImage: associatedPathStatusSymbol(status))
                                                            .font(.caption)
                                                            .foregroundStyle(associatedPathStatusColor(status))
                                                        HStack(spacing: 12) {
                                                            if status.isAvailableDirectory {
                                                                Button("Reveal in Finder") {
                                                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                                                }
                                                                .buttonStyle(.borderless)
                                                                .font(.caption)
                                                            }
                                                            if associatedPathNeedsReselection(status) {
                                                                Button("Re-select saved folder…") {
                                                                    model.reselectRememberedFolder(path)
                                                                }
                                                                .buttonStyle(.borderless)
                                                                .font(.caption)
                                                            }
                                                        }
                                                    }
                                                    if path != checkedPaths.last { Divider() }
                                                }
                                            }
                                            .padding(.top, 6)
                                        }
                                        .font(.caption.weight(.medium))
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                            }
                            HStack(spacing: 12) {
                                Text(folderMeasurementSummary(bundle))
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
                            if !bundle.fileExtensionSummaries.isEmpty {
                                DisclosureGroup {
                                    fileExtensionSummary(for: bundle)
                                        .padding(.top, 6)
                                } label: {
                                    Label("Measured bundle filename mix", systemImage: "chart.pie")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .padding(12)
                                .background(.blue.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                            }
                            DisclosureGroup {
                                fileInventoryChangeSection(for: bundle, showHeading: false)
                                    .padding(.top, 6)
                            } label: {
                                Label("File-level changes inside this bundle", systemImage: "doc.badge.arrow.up")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .padding(12)
                            .background(.orange.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                            folderHistoryChart(for: bundle)
                        }
                        .padding(16)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                        .id(bundle.path)
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 960, alignment: .leading)
            }
        }
    }

    private func applicationDiscoverySection(scrollToMeasurement: @escaping (String) -> Void) -> some View {
        let measurementsByPath = Dictionary(
            model.measuredApplicationBundles.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let discoveryRecordsByPath = Dictionary(
            applicationDiscovery.history.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let searchesExtendedSample = !applicationDiscoverySearchText.isEmpty
            || applicationDiscoveryMeasurementFilter != .all
        let sourceCandidates = searchesExtendedSample
            ? applicationDiscovery.searchableCandidates
            : applicationDiscovery.candidates
        let matchingCandidates = sourceCandidates.filter { candidate in
            let matchesSearch = applicationDiscoverySearchText.isEmpty
                || candidate.displayName.localizedStandardContains(applicationDiscoverySearchText)
                || candidate.path.localizedStandardContains(applicationDiscoverySearchText)
            return matchesSearch
                && applicationDiscoveryMeasurementFilter.includes(measurementsByPath[candidate.path])
        }
        let sortedCandidates = ApplicationBundleIndex.sortedCandidates(
            matchingCandidates, by: applicationDiscoverySort,
            measurementsByPath: measurementsByPath, discoveryRecordsByPath: discoveryRecordsByPath
        )
        let candidates = Array(sortedCandidates.prefix(ApplicationBundleIndex.maximumDiscoveryRecords))
        let completeCount = matchingCandidates.reduce(into: 0) { count, candidate in
            if measurementsByPath[candidate.path]?.complete == true { count += 1 }
        }
        let displayedCandidatePaths = Set(candidates.map(\.path))
        let matchingSavedEntries = savedApplicationInventoryCache.entries.filter {
            !displayedCandidatePaths.contains($0.bundlePath)
        }
        let savedOnlyEntries = Array(matchingSavedEntries.prefix(120))
        let savedInventoryHasMore = savedApplicationInventoryCache.hasMore
            || matchingSavedEntries.count > savedOnlyEntries.count

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Discovered applications", systemImage: "sparkle.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button("Add Discovery Folder…") { applicationDiscovery.addUserSelectedScope() }
                    .controlSize(.small)
                    .disabled(
                        applicationDiscovery.userSelectedScopePaths.count
                            >= ApplicationDiscoveryModel.maximumUserSelectedScopeCount
                    )
            }
            Text("While Disker is open, Spotlight searches only /Applications, /System/Applications, ~/Applications, and folders you add here. Discovery reads indexed metadata only; it does not measure bundles or their data. Press Measure and confirm the exact bundle in the picker before Disker scans it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("When Spotlight provides it, Disker shows the last date Launch Services opened a bundle. Missing dates mean unknown; launches outside Launch Services may not appear.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !applicationDiscovery.userSelectedScopePaths.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Additional Spotlight folders")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(applicationDiscovery.userSelectedScopePaths, id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(.caption.weight(.medium))
                                Text(path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Button("Remove") {
                                applicationDiscovery.removeUserSelectedScope(path: path)
                            }
                            .controlSize(.small)
                            .accessibilityLabel("Remove application search folder at \(path)")
                        }
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
            if let message = applicationDiscovery.statusMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if applicationDiscovery.isGathering {
                Label("Collecting indexed Spotlight results…", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !applicationDiscovery.candidates.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter by app name or path", text: $applicationDiscoverySearchText)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Filter discovered applications")
                    if !applicationDiscoverySearchText.isEmpty {
                        Button {
                            applicationDiscoverySearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear application filter")
                    }
                }
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                Picker("Filter applications by measurement", selection: $applicationDiscoveryMeasurementFilter) {
                    ForEach(ApplicationDiscoveryMeasurementFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .accessibilityLabel("Filter applications by measurement")
                HStack(spacing: 8) {
                    Picker("Sort discovered applications", selection: $applicationDiscoverySort) {
                        ForEach(ApplicationDiscoverySort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel("Sort discovered applications")
                    Spacer(minLength: 0)
                }
                if applicationDiscoverySort == .largestCompleteMeasurement {
                    Text("Complete measurements sort by allocated-byte estimate. Partial, overflowed, and unmeasured bundles remain alphabetized with unknown size.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(applicationDiscoverySummary(
                    catalogCount: applicationDiscovery.candidates.count,
                    searchableCount: applicationDiscovery.searchableCandidates.count,
                    completeCount: completeCount,
                    matchCount: searchesExtendedSample ? matchingCandidates.count : nil,
                    shownCount: candidates.count
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if applicationDiscovery.candidates.isEmpty,
               applicationDiscovery.isRunning,
               !applicationDiscovery.isGathering {
                Text("Spotlight returned no application bundles in the current sample.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if candidates.isEmpty {
                if !applicationDiscoverySearchText.isEmpty {
                    ContentUnavailableView.search(text: applicationDiscoverySearchText)
                        .frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    Group {
                        switch applicationDiscoveryMeasurementFilter {
                        case .all:
                            ContentUnavailableView(
                                "No discovered applications",
                                systemImage: "app.dashed",
                                description: Text("Spotlight has not returned an application bundle in this sample. Index coverage may be incomplete.")
                            )
                        case .unmeasured:
                            ContentUnavailableView(
                                "No applications without a measurement",
                                systemImage: "checkmark.circle",
                                description: Text("Every application in this catalog sample has a saved result; some scans may be partial.")
                            )
                        case .partial:
                            ContentUnavailableView(
                                "No partial measurements",
                                systemImage: "checkmark.circle",
                                description: Text("No application in this catalog sample currently has a partial scan.")
                            )
                        case .complete:
                            ContentUnavailableView(
                                "No complete measurements yet",
                                systemImage: "app.badge.checkmark",
                                description: Text("Measure a discovered application bundle to add a complete result to this list.")
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                }
            } else {
                LazyVStack(spacing: 0) {
                ForEach(candidates) { candidate in
                    let measurement = measurementsByPath[candidate.path]
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "app")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.displayName)
                                .font(.subheadline.weight(.medium))
                            Text(candidate.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let record = discoveryRecordsByPath[candidate.path] {
                                Text("First seen by Disker · \(record.firstSeenAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("Last observed in Spotlight index · \(record.lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let lastOpened = record.launchServicesLastOpenedAt {
                                    Text("Launch Services last-open date · \(lastOpened.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if candidate.spotlightBundleIdentifier != nil {
                                applicationDiscoveryDataLocationSuggestions(for: candidate)
                            }
                            if let measurement {
                                HStack(spacing: 6) {
                                    DiscoveryStatusBadge(
                                        title: NSLocalizedString(
                                            measurement.complete ? "Measured" : "Partial measurement",
                                            comment: "Measured application bundle coverage state"
                                        ),
                                        style: measurement.complete ? .measured : .partial
                                    )
                                    Text(folderMeasurementSummary(measurement))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text("Last measured · \(measurement.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                DiscoveryStatusBadge(
                                    title: NSLocalizedString("Not measured", comment: "Application bundle has not been measured"),
                                    style: .unmeasured
                                )
                            }
                            applicationDiscoveryRelatedLocations(for: candidate)
                        }
                        Spacer(minLength: 8)
                        if measurement != nil {
                            Button("View measurement") {
                                scrollToMeasurement(candidate.path)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderless)
                        }
                        if measurement == nil {
                            Button("Measure…") {
                                model.chooseApplicationBundle(
                                    startingAt: URL(fileURLWithPath: candidate.path).deletingLastPathComponent(),
                                    expectedPath: candidate.path
                                )
                            }
                            .controlSize(.small)
                            .disabled(model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
                        } else {
                            Button("Measure again…") {
                                model.chooseApplicationBundle(
                                    startingAt: URL(fileURLWithPath: candidate.path).deletingLastPathComponent(),
                                    expectedPath: candidate.path
                                )
                            }
                            .controlSize(.small)
                            .disabled(model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
                        }
                    }
                    .padding(.vertical, 5)
                    if candidate.id != candidates.last?.id { Divider() }
                }
                }
            }
            if !savedOnlyEntries.isEmpty {
                savedApplicationHistorySection(entries: savedOnlyEntries, hasMore: savedInventoryHasMore)
            }
            if isSavedApplicationInventoryLoading {
                Label("Updating saved application history…", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: savedApplicationInventoryRefreshKey) {
            let refreshKey = savedApplicationInventoryRefreshKey
            let searchText = applicationDiscoverySearchText
            isSavedApplicationInventoryLoading = true
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, refreshKey == savedApplicationInventoryRefreshKey else { return }
            var history = model.history
            history.discoveredApplications = applicationDiscovery.history
            let visiblePaths = Set(applicationDiscovery.candidates.map(\.path))
            let extendedPaths = Set(applicationDiscovery.searchableCandidates.map(\.path))
            let queryCompleted = applicationDiscovery.hasCompletedQuery
            let projection = await Task.detached(priority: .userInitiated) {
                SavedApplicationInventory.make(
                    from: history,
                    visibleSpotlightPaths: visiblePaths,
                    extendedSpotlightPaths: extendedPaths,
                    spotlightQueryCompleted: queryCompleted,
                    searchText: searchText
                )
            }.value
            guard !Task.isCancelled, refreshKey == savedApplicationInventoryRefreshKey else { return }
            savedApplicationInventoryCache = projection
            if expandFirstSavedApplicationForSnapshot, let firstPath = projection.entries.first?.bundlePath {
                expandedSavedApplicationPaths.insert(firstPath)
            }
            isSavedApplicationInventoryLoading = false
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    private var savedApplicationInventoryRefreshKey: String {
        let history = model.history
        let latestObservationID = history.observations.last?.id.uuidString ?? "none"
        let latestAssociation = history.applicationAssociations.map(\.updatedAt).max()?.timeIntervalSinceReferenceDate.bitPattern ?? 0
        return "\(history.observations.count):\(latestObservationID):\(history.applicationAssociations.count):\(latestAssociation):\(applicationDiscovery.resultRevision):\(applicationDiscovery.hasCompletedQuery):\(applicationDiscoverySearchText)"
    }

    private var foldersPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header("Selected folders", subtitle: "Measure only locations you choose. Saved read-only access lets you rescan them on demand.")
                selectedRootOverlapNotice
                if hasSelectedFolderHistoryChart { historyRangePicker }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Opt-in monitoring", systemImage: "dot.radiowaves.left.and.right")
                                    .font(.subheadline.weight(.semibold))
                                Text("Off until enabled per folder. Scans selected locations only while this window is open.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Menu {
                                ForEach([5, 15, 30, 60], id: \.self) { minutes in
                                    Button(String.localizedStringWithFormat(
                                        NSLocalizedString("Every %ld minutes", comment: "Storage monitoring interval option"),
                                        minutes
                                    )) {
                                        model.setStorageMonitoringInterval(TimeInterval(minutes * 60))
                                    }
                                }
                            } label: {
                                Text(String.localizedStringWithFormat(
                                    NSLocalizedString("Every %ld min", comment: "Selected storage monitoring interval"),
                                    Int(model.storageMonitoringInterval / 60)
                                ))
                            }
                            .disabled(model.monitoredScopePaths.isEmpty)
                            .help("Choose the interval for opted-in saved locations")
                        }
                        DisclosureGroup("How monitoring works") {
                            Text("Enabling monitoring remembers your choice and requests a fresh baseline scan. During a running Disker session, event-triggered scans of an opted-in folder share a five-minute cooldown with manual and scheduled full scans. Periodic scans reconcile changes at your chosen interval. Monitoring resumes when Disker opens and continues only while this window remains open, even when you switch to another app. Closing the window or quitting stops scans until the next launch. macOS sleep may defer scans; events can be missed or coalesced, and files created and removed between scans cannot be reconstructed. No background helper or unselected path is monitored.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 6)
                        }
                        .font(.caption.weight(.medium))
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
                                        Toggle("Remember monitoring for this folder", isOn: Binding(
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
                                            if let watcherError = model.storageEventWatcherErrors[scope.path] {
                                                Text(watcherError)
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                            } else {
                                                Text("Selected-root events prompt metadata scans; periodic reconciliation runs while this window stays open. This choice resumes next time Disker opens.")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if model.isScanning && model.scheduledScanPath == scope.path {
                                                Text("Scheduled metadata scan in progress")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if model.isScanning && model.eventTriggeredScanPath == scope.path {
                                                Text("Checking selected folder for path and size changes")
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
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
                                            Text("\(folderMeasurementSummary(observation)) · measured \(observation.finishedAt.formatted(date: .abbreviated, time: .shortened))")
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
                                    Button("Re-select…") { model.reselectRememberedFolder(scope.path) }
                                        .disabled(model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
                                        .help("Restore read-only access to this exact saved folder")
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
                    Label(String.localizedStringWithFormat(
                        NSLocalizedString("Saved scan roots (%ld/%ld)", comment: "Saved selected scan roots and maximum count"),
                        model.rememberedScopes.count,
                        SelectedScopeBookmarkStore.maximumBookmarkCount
                    ), systemImage: "bookmark")
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
                                        Text(folderAllocatedValue(folder))
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
                        Label("Scan locations are chosen by you. Disker does not change their contents; optional monitoring scans selected paths while its window remains open, even when you switch to another app.", systemImage: "folder.badge.plus")
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
                                Text("\(folderMeasurementSummary(folder)) · \(folder.fileCount) files")
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
                sameSizeFileCandidateSection
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
                                    Text("Candidate path context · \(entry.targetPathContext.caution)")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("Kept-copy path context · \(entry.preservedPathContext.caution)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
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
            homeDirectoryPath: CurrentUserHomeDirectory.path ?? "",
            claimedGroupIdentifiers: bundle.applicationGroupIdentifiers,
            signatureValidated: bundle.applicationSignatureValidated,
            signedBundleIdentifier: bundle.applicationSignedBundleIdentifier
        )
        return Group {
            if !suggestions.isEmpty {
                DisclosureGroup("Possible data locations · not measured") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("These conventional paths come from the selected app's bundle ID and embedded group claims. Disker checks only the exact path when asked; this does not scan its contents or establish ownership. Choose a path to open the picker, and only the exact files or folders you select will be measured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(suggestions) { suggestion in
                            let candidatePath = URL(fileURLWithPath: suggestion.path, isDirectory: true)
                                .standardizedFileURL.path
                            let candidateStatus = model.applicationDataLocationStatuses[candidatePath]
                            ApplicationDataLocationSuggestionRow(
                                suggestion: suggestion,
                                statusText: candidateStatus.map(applicationDataLocationStatusText),
                                statusSymbol: candidateStatus.map(associatedPathStatusSymbol),
                                statusColor: candidateStatus.map(associatedPathStatusColor),
                                isChecking: model.checkingApplicationDataLocationPaths.contains(candidatePath),
                                canCheck: suggestion.evidence != .probablePreferencesFile,
                                isMeasurementDisabled: model.isScanning,
                                measurementTitle: "Choose location to measure…",
                                onCheck: {
                                    model.checkApplicationDataLocation(suggestion.path, for: bundle)
                                },
                                onMeasure: {
                                    let startingPath = candidateStatus?.isAvailableDirectory == true
                                        ? suggestion.path
                                        : URL(fileURLWithPath: suggestion.path).deletingLastPathComponent().path
                                    model.chooseRelatedFolders(
                                        for: bundle.path,
                                        startingAt: URL(fileURLWithPath: startingPath, isDirectory: true)
                                    )
                                }
                            )
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption.weight(.medium))
            }
        }
    }

    private func applicationDiscoveryDataLocationSuggestions(
        for candidate: ApplicationDiscoveryCandidate
    ) -> some View {
        let suggestions = ApplicationDataLocationCandidates.suggestions(
            bundleIdentifier: candidate.spotlightBundleIdentifier,
            homeDirectoryPath: CurrentUserHomeDirectory.path ?? ""
        )
        return Group {
            if let identifier = candidate.spotlightBundleIdentifier, !suggestions.isEmpty {
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedApplicationDiscoveryDataPaths.contains(candidate.path) },
                    set: { isExpanded in
                        if isExpanded { expandedApplicationDiscoveryDataPaths.insert(candidate.path) }
                        else { expandedApplicationDiscoveryDataPaths.remove(candidate.path) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Spotlight returned bundle ID · \(identifier) · unverified")
                            .font(.caption.weight(.medium))
                            .textSelection(.enabled)
                        Text("These conventional paths are hints only. Spotlight's bundle ID is not verified against the app signature or data ownership. Check inspects only the exact suggested path and does not list descendants or read file contents. A metadata-only measurement starts only after you choose the exact file or folder in the picker.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(suggestions) { suggestion in
                            let candidatePath = URL(fileURLWithPath: suggestion.path, isDirectory: true)
                                .standardizedFileURL.path
                            let candidateStatus = model.applicationDataLocationStatuses[candidatePath]
                            ApplicationDataLocationSuggestionRow(
                                suggestion: suggestion,
                                statusText: candidateStatus.map(applicationDataLocationStatusText),
                                statusSymbol: candidateStatus.map(associatedPathStatusSymbol),
                                statusColor: candidateStatus.map(associatedPathStatusColor),
                                isChecking: model.checkingApplicationDataLocationPaths.contains(candidatePath),
                                canCheck: suggestion.evidence != .probablePreferencesFile,
                                isMeasurementDisabled: model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates,
                                measurementTitle: "Choose exact location to measure…",
                                onCheck: {
                                    model.checkDiscoveredApplicationDataLocation(
                                        suggestion.path, for: candidate
                                    )
                                },
                                onMeasure: {
                                    model.chooseDiscoveredApplicationDataLocation(suggestion.path, for: candidate)
                                }
                            )
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Possible related data locations")
                }
                .font(.caption.weight(.medium))
            }
        }
    }

    private func applicationDiscoveryRelatedLocations(
        for candidate: ApplicationDiscoveryCandidate
    ) -> some View {
        let paths = model.relatedFolders(for: candidate.path)
        let titleFormat = NSLocalizedString(
            "Associated locations · %ld",
            comment: "Count of user-associated paths for a discovered application, which may not all be measured yet"
        )
        let title = String.localizedStringWithFormat(titleFormat, paths.count)
        return Group {
            if !paths.isEmpty {
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedApplicationDiscoveryRelatedLocations.contains(candidate.path) },
                    set: { isExpanded in
                        if isExpanded { expandedApplicationDiscoveryRelatedLocations.insert(candidate.path) }
                        else { expandedApplicationDiscoveryRelatedLocations.remove(candidate.path) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Each measured location keeps its own observation. A link may have no measurement yet. Paths may overlap, so Disker does not add these values or infer exclusive ownership.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(paths, id: \.self) { path in
                            let hasSavedAccess = model.rememberedScopes.contains { $0.path == path }
                            if let observation = model.latestFolderObservation(at: path) {
                                let cancelled = model.scanWasCancelled(for: observation)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 7) {
                                        DiscoveryStatusBadge(
                                            title: NSLocalizedString(
                                                cancelled ? "Cancelled scan" : observation.complete ? "Complete measurement" : "Partial measurement",
                                                comment: "Coverage state of a user-selected app-related folder"
                                            ),
                                            style: cancelled || !observation.complete ? .partial : .measured
                                        )
                                        Text(folderMeasurementSummary(observation))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(path)
                                        .font(.caption2.monospaced())
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if observation.isFileRoot {
                                        Label("Selected file root", systemImage: "doc.text")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("Last measured · \(observation.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if !cancelled, observation.complete,
                                       let previous = model.previousCompleteObservation(for: observation),
                                       let allocatedDelta = ObservationComparison.allocatedByteDelta(
                                        current: observation, previous: previous
                                       ) {
                                        let (logicalDelta, overflow) = observation.logicalBytes
                                            .subtractingReportingOverflow(previous.logicalBytes)
                                        if !overflow {
                                            Text(String.localizedStringWithFormat(
                                                NSLocalizedString(
                                                    "Change since %@ · logical %@ · allocated estimate %@",
                                                    comment: "Separate logical and allocated changes for one app-associated folder, with its prior complete observation time"
                                                ),
                                                previous.finishedAt.formatted(date: .abbreviated, time: .shortened),
                                                formattedDelta(logicalDelta),
                                                formattedDelta(allocatedDelta)
                                            ))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(
                                                allocatedDelta > 0 ? .orange
                                                    : allocatedDelta < 0 ? .green : .secondary
                                            )
                                        }
                                    }
                                    linkedPathFileChangesDisclosure(for: observation)
                                    if !observation.isFileRoot && !observation.fileExtensionSummaries.isEmpty {
                                        DisclosureGroup {
                                            fileExtensionSummary(for: observation)
                                                .padding(.top, 4)
                                        } label: {
                                            Label("Measured location filename mix", systemImage: "chart.pie")
                                                .font(.caption2.weight(.medium))
                                        }
                                    }
                                    if cancelled {
                                        Text("The last scan was cancelled; this location remains incomplete.")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                    Button {
                                        model.rescanAssociatedFolder(path)
                                    } label: {
                                        Text(hasSavedAccess
                                             ? NSLocalizedString("Rescan…", comment: "Repeat a saved related-location scan")
                                             : NSLocalizedString("Select to rescan…", comment: "Re-select an exact app-related location to restore access"))
                                    }
                                        .controlSize(.small)
                                        .disabled(model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
                                        .help(
                                            NSLocalizedString(
                                                hasSavedAccess
                                                    ? "Measure this selected app-associated location again"
                                                    : "Re-select this exact file or folder to measure it again",
                                                comment: "Saved-location action help describing whether access is reusable or must be reselected"
                                            )
                                        )
                                }
                                if path != paths.last { Divider() }
                            } else {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(path)
                                        .font(.caption2.monospaced())
                                        .textSelection(.enabled)
                                    Text("No saved measurement · size unknown")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Button {
                                        model.rescanAssociatedFolder(path)
                                    } label: {
                                        Text(hasSavedAccess
                                             ? NSLocalizedString("Measure…", comment: "Start a first measurement using a saved location")
                                             : NSLocalizedString("Select to measure…", comment: "Select an exact unmeasured app-associated location"))
                                    }
                                    .controlSize(.small)
                                    .disabled(model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
                                    .help("Measure only this exact associated file or folder; saved size and access status remain unknown until then")
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text(title)
                }
                .font(.caption.weight(.medium))
            }
        }
    }

    private func savedApplicationHistorySection(
        entries: [SavedApplicationInventoryEntry], hasMore: Bool
    ) -> some View {
        DisclosureGroup(isExpanded: $isSavedApplicationHistoryExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Disker keeps this local history even when an app is outside the current Spotlight sample. That does not establish whether the app is installed. Saved paths are never scanned until you choose a measurement action.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if hasMore {
                    Label("More saved app records exist; refine the app filter to narrow this list.", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        savedApplicationHistoryRow(entry)
                        if entry.id != entries.last?.id { Divider() }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label {
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("Saved app history · %ld", comment: "Count of saved applications shown in the local history section"),
                    entries.count
                ))
                .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private func savedApplicationHistoryRow(_ entry: SavedApplicationInventoryEntry) -> some View {
        return DisclosureGroup(isExpanded: Binding(
            get: { expandedSavedApplicationPaths.contains(entry.bundlePath) },
            set: { isExpanded in
                if isExpanded { expandedSavedApplicationPaths.insert(entry.bundlePath) }
                else { expandedSavedApplicationPaths.remove(entry.bundlePath) }
            }
        )) {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.bundlePath)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(savedApplicationSpotlightStateText(entry.spotlightState))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let identifier = entry.bundleIdentifier {
                    Text("Bundle ID from selected bundle metadata · \(identifier)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let firstSeen = entry.firstSeenInSpotlightAt {
                    Text("First seen by Disker · \(firstSeen.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let lastSeen = entry.lastSeenInSpotlightAt {
                    Text("Last observed in Spotlight index · \(lastSeen.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let lastOpened = entry.launchServicesLastOpenedAt {
                    Text("Launch Services last-open date · \(lastOpened.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let bundleObservation = entry.bundleObservation {
                    HStack(spacing: 7) {
                        DiscoveryStatusBadge(
                            title: NSLocalizedString(
                                entry.bundleObservationWasCancelled
                                    ? "Cancelled scan"
                                    : bundleObservation.complete ? "Complete measurement" : "Partial measurement",
                                comment: "Coverage state for a saved application bundle measurement"
                            ),
                            style: entry.bundleObservationWasCancelled || !bundleObservation.complete ? .partial : .measured
                        )
                        Text(folderMeasurementSummary(bundleObservation))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("Last measured · \(bundleObservation.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No saved bundle measurement · size unknown")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Measure bundle…") {
                        model.chooseApplicationBundle(
                            startingAt: URL(fileURLWithPath: entry.bundlePath).deletingLastPathComponent(),
                            expectedPath: entry.bundlePath
                        )
                    }
                    .controlSize(.small)
                    .disabled(model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
                    .help(NSLocalizedString(
                        "Confirm this exact application bundle before Disker measures it",
                        comment: "Exact-path explanation for remeasuring a saved application bundle"
                    ))
                }

                if !entry.relatedLocations.isEmpty {
                    Divider()
                    Label {
                        Text(String.localizedStringWithFormat(
                            NSLocalizedString("Saved related locations · %ld", comment: "Count of saved app-associated locations"),
                            entry.relatedLocations.count
                        ))
                        .font(.caption.weight(.semibold))
                    } icon: {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    Text("Each location is shown separately. Overlapping paths are not added, and the link does not prove ownership.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(entry.relatedLocations) { location in
                        savedApplicationLocationRow(location)
                    }
                }
            }
            .padding(.top, 5)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "app")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.subheadline.weight(.medium))
                    Text(savedApplicationSpotlightStateText(entry.spotlightState))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func savedApplicationLocationRow(_ location: SavedApplicationLocation) -> some View {
        let observation = location.latestObservation
        let hasSavedAccess = model.rememberedScopes.contains { $0.path == location.path }
        return VStack(alignment: .leading, spacing: 5) {
            Text(location.path)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let observation {
                HStack(spacing: 7) {
                    DiscoveryStatusBadge(
                        title: NSLocalizedString(
                            location.latestObservationWasCancelled
                                ? "Cancelled scan"
                                : observation.complete ? "Complete measurement" : "Partial measurement",
                            comment: "Coverage state for a saved application-related location"
                        ),
                        style: location.latestObservationWasCancelled || !observation.complete ? .partial : .measured
                    )
                    Text(folderMeasurementSummary(observation))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if observation.isFileRoot {
                    Label("Selected file root", systemImage: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Last measured · \(observation.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if location.latestObservationWasCancelled {
                    Text("The last scan was cancelled; this measurement remains incomplete.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                linkedPathFileChangesDisclosure(for: observation)
            } else {
                Text("No saved measurement · size unknown")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                model.rescanAssociatedFolder(location.path)
            } label: {
                Text(hasSavedAccess
                     ? NSLocalizedString("Rescan…", comment: "Repeat a saved related-location scan")
                     : NSLocalizedString("Select to rescan…", comment: "Re-select an exact app-related location to restore access"))
            }
            .controlSize(.small)
            .disabled(model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
            .help(
                NSLocalizedString(
                    hasSavedAccess
                        ? "Measure this selected app-associated location again"
                        : "Re-select this exact file or folder to measure it again",
                    comment: "Saved-location action help describing whether access is reusable or must be reselected"
                )
            )
        }
        .padding(.vertical, 4)
    }

    private func savedApplicationSpotlightStateText(_ state: SavedApplicationSpotlightState) -> String {
        switch state {
        case .visibleInCurrentCatalog:
            NSLocalizedString("Observed in the current visible Spotlight sample", comment: "Saved application is also in the visible Spotlight catalog")
        case .availableInExtendedSearch:
            NSLocalizedString("Returned in the extended Spotlight sample; use the app filter to find it", comment: "Saved application is beyond the visible first-page Spotlight results but searchable")
        case .notObservedInCurrentSample:
            NSLocalizedString("Not observed in the current Spotlight sample · presence unknown", comment: "A bounded Spotlight sample omitted a saved app; installed state is unknown")
        case .unknown:
            NSLocalizedString("Current Spotlight presence has not been confirmed", comment: "No completed current Spotlight result establishes this saved app's presence")
        }
    }

    private func applicationBundlePathStatusText(_ status: SelectedScopePathProbe.Status) -> String {
        switch status {
        case .availableDirectory:
            "Bundle directory exists · contents not checked"
        case .availableDirectoryWithinBookmarkScope:
            "Selected bundle directory is available · ancestor paths were not checked"
        case .missingOrUnreachable:
            "Bundle path not found or its volume is unavailable · absence is unconfirmed"
        case .permissionOrAccessUnknown:
            "Bundle access could not be confirmed · presence is unknown"
        case .notDirectory:
            "The exact bundle path is not a directory"
        case .symbolicLink:
            "The bundle path is a symbolic link · not followed"
        case .invalidBookmark:
            "Saved bundle access could not be read · select the same bundle again"
        case .staleBookmark:
            "Saved bundle access is stale · select the same bundle again"
        case .mismatchedBookmark:
            "Saved bundle access resolves elsewhere · no check was performed"
        }
    }

    private func associatedPathStatusText(_ status: SelectedScopePathProbe.Status) -> String {
        switch status {
        case .availableDirectory:
            "Folder exists · contents not checked"
        case .availableDirectoryWithinBookmarkScope:
            "Selected folder is available · ancestor paths were not checked"
        case .missingOrUnreachable:
            "Path not found or its volume is unavailable · absence is unconfirmed"
        case .permissionOrAccessUnknown:
            "Access could not be confirmed · presence is unknown"
        case .notDirectory:
            "The exact path is not a directory · file contents were not checked"
        case .symbolicLink:
            "The path is a symbolic link · not followed"
        case .invalidBookmark:
            "Saved access could not be read · select the same folder again"
        case .staleBookmark:
            "Saved access is stale · select the same folder again"
        case .mismatchedBookmark:
            "Saved access resolves to a different path · no check was performed"
        }
    }

    private func projectResourcePathStatusText(_ status: SelectedScopePathProbe.Status) -> String {
        let key: String
        switch status {
        case .availableDirectory:
            key = "Project location is available as a directory · contents not checked"
        case .availableDirectoryWithinBookmarkScope:
            key = "Selected project folder is available · ancestor paths were not checked"
        case .missingOrUnreachable:
            key = "Project location not found or volume unavailable · absence unconfirmed"
        case .permissionOrAccessUnknown:
            key = "Project location access could not be confirmed · presence unknown"
        case .notDirectory:
            key = "The exact project location is not a directory"
        case .symbolicLink:
            key = "Project location is a symbolic link · not followed"
        case .invalidBookmark:
            key = "Saved project access could not be read · select the same folder again"
        case .staleBookmark:
            key = "Saved project access is stale · select the same folder again"
        case .mismatchedBookmark:
            key = "Saved project access resolves elsewhere · no check was performed"
        }
        return NSLocalizedString(key, comment: "Read-only status for the exact path of a linked project resource")
    }

    private func applicationDataLocationStatusText(_ status: SelectedScopePathProbe.Status) -> String {
        switch status {
        case .availableDirectory:
            NSLocalizedString(
                "Suggested folder exists · contents not checked",
                comment: "Exact application data folder path exists; contents were not scanned"
            )
        case .availableDirectoryWithinBookmarkScope:
            NSLocalizedString(
                "Selected folder is available · ancestor paths were not checked",
                comment: "The selected application data folder is available through its bookmark; sandbox hid ancestor paths"
            )
        case .missingOrUnreachable:
            NSLocalizedString(
                "Path not found; its absence is unconfirmed",
                comment: "Suggested application data path cannot be reached"
            )
        case .permissionOrAccessUnknown:
            NSLocalizedString(
                "Access could not be confirmed · presence unknown",
                comment: "Suggested application data path access is unknown"
            )
        case .notDirectory:
            NSLocalizedString(
                "Exact path is not a folder",
                comment: "Suggested application data path is not a directory"
            )
        case .symbolicLink:
            NSLocalizedString(
                "Symbolic link · not followed",
                comment: "Suggested application data path is a symbolic link"
            )
        case .invalidBookmark:
            NSLocalizedString(
                "Saved access unavailable · choose the folder again",
                comment: "Bookmark status for a suggested application data path"
            )
        case .staleBookmark:
            NSLocalizedString(
                "Saved access is stale · choose the folder again",
                comment: "Bookmark status for a suggested application data path"
            )
        case .mismatchedBookmark:
            NSLocalizedString(
                "Saved access points elsewhere · no check performed",
                comment: "Bookmark status for a suggested application data path"
            )
        }
    }

    private func associatedPathStatusSymbol(_ status: SelectedScopePathProbe.Status) -> String {
        switch status {
        case .availableDirectory, .availableDirectoryWithinBookmarkScope: "checkmark.circle"
        case .missingOrUnreachable: "questionmark.folder"
        case .permissionOrAccessUnknown, .invalidBookmark, .staleBookmark, .mismatchedBookmark:
            "exclamationmark.triangle"
        case .notDirectory: "doc"
        case .symbolicLink: "link"
        }
    }

    private func associatedPathStatusColor(_ status: SelectedScopePathProbe.Status) -> Color {
        status.isAvailableDirectory ? .green : .orange
    }

    private func associatedPathNeedsReselection(_ status: SelectedScopePathProbe.Status) -> Bool {
        switch status {
        case .permissionOrAccessUnknown, .invalidBookmark, .staleBookmark, .mismatchedBookmark:
            true
        case .availableDirectory, .availableDirectoryWithinBookmarkScope,
             .missingOrUnreachable, .notDirectory, .symbolicLink:
            false
        }
    }

    private func applicationAssociationRow(path: String, bundle: FolderObservation) -> some View {
        let folderName = URL(fileURLWithPath: path).lastPathComponent
        let hasSavedAccess = model.rememberedScopes.contains(where: { $0.path == path })
        let attribution = ApplicationPathAttribution.classify(
            bundleIdentifier: bundle.applicationBundleIdentifier,
            associatedFolderPath: path,
            homeDirectoryPath: CurrentUserHomeDirectory.path ?? "",
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
        case .probablePreferencesFilePathMatch:
            attributionSymbol = "doc.text"
        case .probableLogsPathMatch:
            attributionSymbol = "folder.badge.questionmark"
        case .probableSavedApplicationStatePathMatch:
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
                    if observation.isFileRoot {
                        Label("Selected file root", systemImage: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text(folderMeasurementSummary(observation))
                        Text("Measured \(observation.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                        if observation.complete {
                            Text("Complete")
                                .foregroundStyle(.green)
                            if let previous = model.previousCompleteObservation(for: observation),
                               let delta = ObservationComparison.allocatedByteDelta(
                                current: observation, previous: previous
                               ) {
                                Text(changeDescription(delta, since: previous.finishedAt))
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
                if let observation = model.latestFolderObservation(at: path) {
                    selectedPathHistoryDisclosure(
                        for: observation,
                        wasCancelled: model.scanWasCancelled(for: observation)
                    )
                    linkedPathFileChangesDisclosure(for: observation)
                }
            }
            Spacer(minLength: 4)
            Button(hasSavedAccess ? "Rescan" : "Select to rescan…") {
                model.rescanAssociatedFolder(path)
            }
            .controlSize(.small)
            .disabled(model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
            .help(hasSavedAccess ? "Measure this selected app-associated location again" : "Re-select this exact file or folder to measure it again")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Reveal associated location in Finder")
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

    private var sameSizeFileCandidateSection: some View {
        let currentSummaries = model.sameSizeFileCandidates.values
            .filter { summary in
                model.latestFolderObservation(at: summary.rootPath)?.id == summary.folderObservationID
            }
            .sorted {
                if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
                return $0.rootPath.localizedStandardCompare($1.rootPath) == .orderedAscending
            }
        let currentRootPaths = currentSummaries.prefix(5)
            .map(\.rootPath)

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("A complete no-follow inventory can surface regular files of the same logical size (at least 1 MiB). The selected folder may still have partial overall coverage when links or other items are excluded. Candidates are not confirmed duplicates; file contents have not been read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if currentRootPaths.isEmpty {
                    Text("A current list requires a complete regular-file inventory. Partial inventories do not create one; excluded links or other items can still leave the selected folder's overall coverage partial.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(currentRootPaths, id: \.self) { path in
                    if let summary = model.sameSizeFileCandidates[path],
                       let folder = model.latestFolderObservation(at: path),
                       folder.id == summary.folderObservationID {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Label(folder.displayName, systemImage: "folder")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(summary.observedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if summary.excludedSymlinkCount > 0 {
                                Text(sameSizeCandidateText(
                                    "%ld symlink entries were excluded; their targets were not followed.",
                                    Int64(summary.excludedSymlinkCount)
                                ))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if !folder.complete {
                                Text("The selected folder has partial overall coverage; this list includes only regular files from the complete no-follow inventory.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if summary.groups.isEmpty {
                                if summary.isCandidateIndexComplete {
                                    Text(sameSizeCandidateText(
                                        "No same-size groups at or above 1 MiB were found among %ld indexed regular files.",
                                        Int64(summary.eligibleFileCount)
                                    ))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("No groups were found in the indexed portion. The candidate index reached its size-bucket limit, so additional matches may be omitted.")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            } else {
                                ForEach(Array(summary.groups.prefix(3))) { group in
                                    sameSizeCandidateGroupRow(group)
                                }
                                if summary.groups.count > 3 {
                                    DisclosureGroup(sameSizeCandidateText(
                                        "Show %ld more size groups", Int64(summary.groups.count - 3)
                                    )) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(Array(summary.groups.dropFirst(3))) { group in
                                                sameSizeCandidateGroupRow(group)
                                            }
                                        }
                                        .padding(.top, 6)
                                    }
                                    .font(.caption)
                                }
                                if !summary.isCandidateIndexComplete {
                                    Text("The bounded candidate index omitted additional size groups or buckets; this list may be incomplete.")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            HStack {
                                Spacer()
                                Button("Choose folders for verification…") {
                                    chooseDuplicateFolders(
                                        startingAt: URL(fileURLWithPath: path).deletingLastPathComponent()
                                    )
                                }
                                .controlSize(.small)
                                .disabled(model.isVerifyingDuplicates || model.isScanning || model.isMeasuringOwnFootprint)
                            }
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
                if currentSummaries.count > currentRootPaths.count {
                    Text("Showing the five most recent complete candidate inventories. Other selected roots remain available in Folders.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("Same-size file candidates", systemImage: "doc.on.doc")
                .font(.headline)
        }
    }

    private func sameSizeCandidateGroupRow(_ group: SameSizeCandidateGroup) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(sameSizeCandidateText(
                "Files with logical size %@: %ld",
                format(group.logicalBytes), Int64(group.fileCount)
            ), systemImage: "equal.circle")
                .font(.caption.weight(.medium))
            ForEach(group.files, id: \.relativePath) { file in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(file.relativePath)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Text(sameSizeCandidateText("allocated ~%@", format(file.allocatedBytes)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if group.omittedFileCount > 0 {
                Text(sameSizeCandidateText(
                    "%ld more paths have this logical size.", Int64(group.omittedFileCount)
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sameSizeCandidateText(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: NSLocalizedString(key, comment: "Same-size file candidate details"),
            locale: Locale.current,
            arguments: arguments
        )
    }

    private func chooseDuplicateFolders() {
        chooseDuplicateFolders(startingAt: nil)
    }

    private func chooseDuplicateFolders(startingAt directory: URL?) {
        let panel = NSOpenPanel()
        panel.title = "Choose folders for duplicate verification"
        panel.prompt = "Choose Folders"
        panel.message = "Disker will inspect file metadata to find same-size candidates. It will not read file contents until you confirm the next step."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.directoryURL = directory
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
                memoryPressureSummary
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
                            let selectedRAMIndex = selectedRAMDate.flatMap { selectedDate in
                                ramSamples.indices.min {
                                    abs(ramSamples[$0].observedAt.timeIntervalSince(selectedDate))
                                        < abs(ramSamples[$1].observedAt.timeIntervalSince(selectedDate))
                                }
                            }
                            let selectedRAMSample = selectedRAMIndex.map { ramSamples[$0] }
                            if let selectedRAMSample {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(selectedRAMSample.observedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption.weight(.medium))
                                    Spacer()
                                    Text("Free \(format(selectedRAMSample.freeBytes))")
                                    Text("Compressed \(format(selectedRAMSample.compressedBytes))")
                                    if let swap = selectedRAMSample.swapUsage {
                                        Text("Swap \(format(swap.usedBytes))")
                                    } else {
                                        Text("Swap unavailable")
                                    }
                                    Button {
                                        guard let selectedRAMIndex, selectedRAMIndex > 0 else { return }
                                        selectedRAMDate = ramSamples[selectedRAMIndex - 1].observedAt
                                    } label: {
                                        Image(systemName: "chevron.left")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(selectedRAMIndex == 0)
                                    .help("Previous sample (⌘←)")
                                    .accessibilityLabel("Previous sample")
                                    .accessibilityHint("Moves selection to the previous RAM sample. Press Command–Left Arrow to activate.")
                                    .keyboardShortcut(.leftArrow, modifiers: .command)
                                    Button {
                                        guard let selectedRAMIndex,
                                              selectedRAMIndex + 1 < ramSamples.count else { return }
                                        selectedRAMDate = ramSamples[selectedRAMIndex + 1].observedAt
                                    } label: {
                                        Image(systemName: "chevron.right")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(selectedRAMIndex.map { $0 + 1 >= ramSamples.count } ?? true)
                                    .help("Next sample (⌘→)")
                                    .accessibilityLabel("Next sample")
                                    .accessibilityHint("Moves selection to the next RAM sample. Press Command–Right Arrow to activate.")
                                    .keyboardShortcut(.rightArrow, modifiers: .command)
                                    Button("Clear") { selectedRAMDate = nil }
                                        .buttonStyle(.link)
                                }
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            } else {
                                HStack(spacing: 8) {
                                    Text("No RAM sample selected")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 4)
                                    Button("Select latest sample") {
                                        selectedRAMDate = ramSamples.last?.observedAt
                                    }
                                    .buttonStyle(.link)
                                    .accessibilityHint("Selects the newest recorded RAM snapshot.")
                                }
                            }
                            Chart {
                                ForEach(ramSamples, id: \.observedAt) { sample in
                                    PointMark(
                                        x: .value("Sample time", sample.observedAt),
                                        y: .value("MiB", Double(sample.freeBytes) / 1_048_576)
                                    )
                                    .foregroundStyle(by: .value("Metric", "Free pages"))
                                    .symbolSize(selectedRAMSample?.observedAt == sample.observedAt ? 78 : 38)
                                    PointMark(
                                        x: .value("Sample time", sample.observedAt),
                                        y: .value("MiB", Double(sample.compressedBytes) / 1_048_576)
                                    )
                                    .foregroundStyle(by: .value("Metric", "Compressed pages"))
                                    .symbolSize(selectedRAMSample?.observedAt == sample.observedAt ? 78 : 38)
                                    if let swap = sample.swapUsage {
                                        PointMark(
                                            x: .value("Sample time", sample.observedAt),
                                            y: .value("MiB", Double(swap.usedBytes) / 1_048_576)
                                        )
                                        .foregroundStyle(by: .value("Metric", "Swap used"))
                                        .symbolSize(selectedRAMSample?.observedAt == sample.observedAt ? 78 : 38)
                                    }
                                }
                                if let selectedRAMSample {
                                    RuleMark(x: .value("Selected sample", selectedRAMSample.observedAt))
                                        .foregroundStyle(.secondary.opacity(0.55))
                                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                }
                            }
                            .chartForegroundStyleScale([
                                "Free pages": Color.blue,
                                "Compressed pages": Color.purple,
                                "Swap used": Color.orange
                            ])
                            .chartLegend(position: .bottom, alignment: .leading)
                            .chartYAxisLabel("MiB")
                            .chartYAxis {
                                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { _ in
                                    AxisGridLine()
                                    AxisValueLabel()
                                }
                            }
                            .chartPlotStyle { plot in
                                plot
                                    .background(Color.primary.opacity(0.018))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .chartXSelection(value: $selectedRAMDate)
                            .frame(height: 210)
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
                                    Chart(signal.points) { point in
                                        PointMark(
                                            x: .value("Observed time", point.observedAt),
                                            y: .value("Resident MiB", Double(point.residentBytes) / 1_048_576)
                                        )
                                        .foregroundStyle(.orange)
                                    }
                                    .chartXAxisLabel("Observed time")
                                    .chartYAxisLabel("Resident MiB")
                                    .frame(height: 112)
                                    .accessibilityLabel("Observed resident-size snapshots for \(signal.processName). Each dot is a measured sample; values between samples are unknown.")
                                    Text("Observed points only · values between samples are unknown")
                                        .font(.caption2)
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

    private var latestMemoryPressureTransition: MemoryPressureObservation? {
        model.history.memoryPressureObservations.max(by: { $0.observedAt < $1.observedAt })
    }

    private func memoryPressureLevelTitle(_ level: MemoryPressureLevel) -> String {
        NSLocalizedString(level.rawValue.capitalized, comment: "System-reported memory pressure transition level")
    }

    private var memoryPressureSummary: some View {
        let latest = latestMemoryPressureTransition
        let tint: Color = switch latest?.level {
        case .critical: .red
        case .warning: .orange
        case .normal: .green
        case nil: .secondary
        }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text("System memory pressure")
                    .font(.headline)
                if let latest {
                    HStack(spacing: 6) {
                        Text("Last reported transition")
                            .foregroundStyle(.secondary)
                        Text(memoryPressureLevelTitle(latest.level))
                            .fontWeight(.semibold)
                            .foregroundStyle(tint)
                        Text(latest.observedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("This is a stored transition, not a live reading; current pressure between events is unknown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No transition has been recorded. Current system pressure is unknown.")
                        .font(.subheadline.weight(.medium))
                    Text(isAutomaticRAMSamplingEnabled
                         ? "Disker records pressure only when macOS reports a transition while the app is active."
                         : "Enable RAM monitoring to record macOS-reported transitions while Disker is active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }

    private var memoryPressureCard: some View {
        let retained = model.history.memoryPressureObservations.sorted {
            $0.observedAt > $1.observedAt
        }
        let recentEvents = Array(retained.prefix(12))
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("These are system-wide transitions macOS reported while Disker was active and monitoring was enabled. Gaps and periods before the first event are unknown; no event does not mean normal pressure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if recentEvents.isEmpty {
                    Text("No pressure transitions have been recorded yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    if retained.count > recentEvents.count {
                        Text("Showing the latest \(recentEvents.count) of \(retained.count) retained transitions.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(recentEvents) { event in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(event.level == .critical ? .red : event.level == .warning ? .orange : .green)
                                .frame(width: 8, height: 8)
                            Text(memoryPressureLevelTitle(event.level))
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
            .padding(.top, 8)
        } label: {
            Label("Pressure transition history", systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.medium))
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }

    private func folderList(
        _ folders: [FolderObservation], title: String, scanCancelled: Bool,
        includeDetails: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title)).font(.title3.weight(.semibold))
            ForEach(folders.sorted { $0.allocatedBytes > $1.allocatedBytes }) { folder in
                let projectPaths = Set(folder.projectDirectorySummaries.map(\.rootRelativePath))
                let rankedSubdirectories = folder.subdirectorySummaries.filter {
                    !projectPaths.contains($0.rootRelativePath)
                }
                HStack(spacing: 14) {
                    Image(systemName: folder.isFileRoot ? "doc.text.fill" : "folder.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(folder.displayName).font(.headline)
                        Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if folder.gitMetadataEntryDetected {
                            Label("Git metadata marker detected", systemImage: "chevron.left.forwardslash.chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        HStack(spacing: 8) {
                            Text(folderMeasurementSummary(folder))
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
                        if folder.isFileRoot {
                            Label("Selected file root", systemImage: "doc.text")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if includeDetails && !folder.isFileRoot && !folder.fileExtensionSummaries.isEmpty {
                            fileExtensionSummary(for: folder)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(folderAllocatedValue(folder))
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
                            Text(directoryMeasurementSummary(gitUsage))
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

                let projectHasSavedLinks = model.history.projectResourceAssociations.contains {
                    URL(fileURLWithPath: $0.projectRootPath, isDirectory: true).standardizedFileURL.path
                        == URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL.path
                }
                if includeDetails && (folder.gitMetadataEntryDetected || projectHasSavedLinks) {
                    projectResourceSection(for: folder.path)
                }
                if includeDetails {
                    ForEach(model.projectRootsLinkingResource(folder.path).filter {
                        URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
                            != URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL.path
                    }, id: \.self) { projectRootPath in
                        projectResourceSection(for: projectRootPath)
                    }
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
                                        Label(LocalizedStringKey(hint.title), systemImage: hint.symbolName)
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                    }
                                    HStack(spacing: 8) {
                                        Text(directoryMeasurementSummary(directory))
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
                                Text(directoryAllocatedValue(directory))
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
                if includeDetails && folder.excludedSymlinkCount > 0 {
                    excludedSymlinkSection(for: folder)
                }
                if includeDetails && !folder.largestFiles.isEmpty {
                    largestFileSection(for: folder, scanCancelled: scanCancelled)
                }
            }
            if let latest = model.latestScan {
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("Scan finished %@ · %ld selected locations", comment: "Finished selected-folder scan time and root count"),
                    latest.finishedAt.formatted(date: .abbreviated, time: .shortened),
                    latest.folders.count
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func excludedSymlinkSection(for folder: FolderObservation) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("Disker did not follow these links or inspect their targets. Select a target as a separate folder if you want to measure it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if folder.excludedSymlinkPaths.isEmpty {
                    Text("This saved scan records \(folder.excludedSymlinkCount) excluded links but did not retain their names. Rescan the selected folder to record exact paths; Disker will not follow them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Rescan to record link names…") {
                        model.chooseFolders(
                            startingAt: URL(fileURLWithPath: folder.path).deletingLastPathComponent()
                        )
                    }
                    .buttonStyle(.link)
                } else {
                    ForEach(folder.excludedSymlinkPaths, id: \.self) { relativePath in
                        HStack(spacing: 8) {
                            Text(relativePath == "." ? "Selected root" : relativePath)
                                .font(.caption.monospaced())
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if relativePath != "." {
                                Button("Choose target to measure…") {
                                    let link = URL(fileURLWithPath: folder.path)
                                        .appendingPathComponent(relativePath)
                                    model.chooseFolders(startingAt: link.deletingLastPathComponent())
                                }
                                .buttonStyle(.link)
                                .help("Select a target folder explicitly; Disker will not follow this link")
                                Button {
                                    let link = URL(fileURLWithPath: folder.path)
                                        .appendingPathComponent(relativePath)
                                    NSWorkspace.shared.activateFileViewerSelecting([link])
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .buttonStyle(.borderless)
                                .help("Reveal the excluded link in Finder")
                                .accessibilityLabel("Reveal excluded link \(relativePath) in Finder")
                            }
                        }
                    }
                }
                if folder.excludedSymlinkPathsTruncated {
                    Text("Showing \(folder.excludedSymlinkPaths.count) of \(folder.excludedSymlinkCount) excluded links. The list is capped to keep local history bounded.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Review \(folder.excludedSymlinkCount) skipped symbolic links", systemImage: "arrow.turn.up.right")
                .font(.caption.weight(.medium))
        }
    }

    private func projectDirectorySection(
        for folder: FolderObservation, scanCancelled: Bool
    ) -> some View {
        let candidatePaths = Dictionary(
            DeveloperArtifactReview.make(from: folder).entries
                .map { ($0.relativePath, $0.path) },
            uniquingKeysWith: { first, _ in first }
        )
        return VStack(alignment: .leading, spacing: 9) {
            Label("Project and development-data candidates", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.subheadline.weight(.semibold))
            Text("Entries have a direct `.git` marker or a recognized development-data directory-name pattern. These are candidates, not verified project ownership or safe cleanup targets. Name matches do not inspect contents; nested folder totals overlap.")
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
                            if let candidatePath = candidatePaths[directory.rootRelativePath] {
                                Button("Measure exact folder…") {
                                    model.measureSelectedCandidate(at: candidatePath)
                                }
                                .buttonStyle(.link)
                                .font(.caption2)
                                .disabled(model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
                                .help("Confirm this exact candidate folder before a separate metadata-only measurement")
                                .accessibilityLabel("Measure candidate folder \(directory.rootRelativePath)")
                            }
                        }
                        if folder.gitMetadataEntryDetected,
                           StorageAreaHint.matchingDirectory(relativePath: directory.rootRelativePath) != nil,
                           let candidatePath = candidatePaths[directory.rootRelativePath] {
                            Button("Measure and link to project…") {
                                model.measureAndLinkProjectCandidate(at: candidatePath, to: folder.path)
                            }
                            .buttonStyle(.link)
                            .font(.caption2)
                            .disabled(model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
                            .help("Confirm this exact project data candidate, save your link, and measure it separately")
                            .accessibilityLabel("Measure and link project candidate \(directory.rootRelativePath)")
                        }
                        if let hint = StorageAreaHint.matchingDirectory(relativePath: directory.rootRelativePath) {
                            Label(LocalizedStringKey(hint.title), systemImage: "tag")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        HStack(spacing: 8) {
                            Text(directoryMeasurementSummary(directory))
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

    private func largestFileSection(for folder: FolderObservation, scanCancelled: Bool) -> some View {
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
            if folder.complete,
               model.fileInventoryReports[folder.path]?.folderObservationID == folder.id {
                Button {
                    databaseSidecarReviewFolder = folder
                } label: {
                    Label("Review SQLite sidecar names…", systemImage: "externaldrive")
                }
                .buttonStyle(.link)
                .help("Inspect exact database and SQLite sidecar filename relationships from this complete selected-folder inventory.")
                .accessibilityHint("Opens a read-only local review. File contents are not read and sizes are not combined.")
            }
            fileInventoryChangeSection(for: folder)
            newlyObservedLargeFileSection(for: folder, scanCancelled: scanCancelled)
            largeFileModificationSection(for: folder, scanCancelled: scanCancelled)
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
                            if let lastModifiedAt = file.lastModifiedAt {
                                Text("Modified \(lastModifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .help("Filesystem modification time from metadata; it does not indicate last use or cleanup safety.")
                            }
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

    private func fileInventoryChangeSection(
        for folder: FolderObservation,
        showHeading: Bool = true
    ) -> some View {
        let report = model.fileInventoryReports[folder.path]
        let reportMatchesCurrentScan = report?.folderObservationID == folder.id
        return VStack(alignment: .leading, spacing: 7) {
            if showHeading {
                Label("File changes across the selected folder", systemImage: "arrow.up.arrow.down")
                    .font(.caption.weight(.semibold))
            }
            if !reportMatchesCurrentScan {
                let followUp = NSLocalizedString(
                    report == nil
                        ? "No complete file-level baseline is available for this observation. A later scan that records a complete inventory can establish one; earlier changes cannot be reconstructed."
                        : "The prior complete report remains stored; Disker can compare again after a later complete inventory.",
                    comment: "Why file-level history is unavailable for the latest folder observation"
                )
                let explanation = Text(fileInventoryIncompleteness(for: folder))
                    + Text(" ")
                    + Text(followUp)
                    + Text(" ")
                    + Text(NSLocalizedString("Symlink targets are excluded.", comment: "File inventory symlink coverage boundary"))
                explanation
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                fileInventoryTrendSection(for: folder)
            } else if let report {
                if !report.hasBaseline {
                    Text("Baseline recorded at \(report.observedAt.formatted(date: .abbreviated, time: .shortened)). File-level changes appear after the next comparable full scan. Earlier growth cannot be reconstructed from current sizes. File names and size metadata stay on this Mac; contents are never read.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Compared every regular-file path with the prior complete inventory from \(report.previousObservedAt?.formatted(date: .abbreviated, time: .shortened) ?? "unknown time"). Net allocated estimate: \(report.netAllocatedDelta.map(formattedDelta) ?? "unknown"); net logical size: \(report.netLogicalDelta.map(formattedDelta) ?? "unknown"). File names and size metadata stay on this Mac; contents are never read. Clear History removes this baseline.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if report.symlinkExcludedCount > 0 {
                        Text("\(report.symlinkExcludedCount) symlink entries were excluded; their targets were not followed.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if report.changedPathCount == 0 {
                        Text("No regular-file size or path changes were measured.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(fileChangeCountSummary(report.changedPathCount)). Added, resized, and no-longer-present paths are evidence of inventory differences; they do not establish cause or deletion.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(report.changes) { change in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: change.kind == .added ? "plus.circle" : change.kind == .resized ? "arrow.up.left.and.arrow.down.right" : "minus.circle")
                                    .foregroundStyle(change.allocatedDelta > 0 ? .orange : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(change.relativePath.isEmpty ? folder.displayName : change.relativePath)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                    Text("Logical \(formattedDelta(change.logicalDelta)) · allocated estimate \(formattedDelta(change.allocatedDelta))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                if change.kind != .noLongerPresent {
                                    Button {
                                        let url = change.relativePath.isEmpty
                                            ? URL(fileURLWithPath: folder.path)
                                            : URL(fileURLWithPath: folder.path).appendingPathComponent(change.relativePath)
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    } label: {
                                        Image(systemName: "arrow.up.right.square")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Reveal measured path in Finder")
                                }
                            }
                            .font(.caption2)
                        }
                        if report.omittedChangeCount > 0 {
                            Text("\(report.omittedChangeCount) additional changes are included in the net totals but omitted from this bounded detail list.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if report.hasBaseline {
                    fileInventoryTrendSection(for: folder)
                }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func fileInventoryTrendSection(for folder: FolderObservation) -> some View {
        let points = Array((model.fileInventoryTrends[folder.path] ?? []).suffix(8).reversed())
        if !points.isEmpty {
            DisclosureGroup("Recent complete scan intervals (\(points.count))") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(points) { point in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(point.previousObservedAt.formatted(date: .abbreviated, time: .shortened)) → \(point.observedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2.weight(.medium))
                            Text("Gross growth ~\(point.grossAllocatedGrowth.map { format($0) } ?? "unknown") · reduced ~\(point.grossAllocatedReduction.map { format($0) } ?? "unknown") · net \(point.netAllocatedDelta.map(formattedDelta) ?? "unknown") · \(point.changedPathCount) paths")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption2)
        }
    }

    private func projectResourceSection(for projectRootPath: String) -> some View {
        let review = model.projectResourceReview(for: projectRootPath)
        let growthReview = ProjectResourceGrowthReview.make(for: review, in: model.history)
        let crossDomainEvidence = model.crossDomainResourceEvidence(for: projectRootPath)
        let standardizedRoot = URL(fileURLWithPath: projectRootPath, isDirectory: true).standardizedFileURL.path
        let projectLinkIDs = Set(crossDomainEvidence.links.filter {
            $0.domain == .project && $0.rootPath == standardizedRoot
        }.flatMap { $0.overlaps.map(\.otherLinkID) })
        let overlappingAppPaths = Array(Set(crossDomainEvidence.links.filter {
            $0.domain == .application && projectLinkIDs.contains($0.id)
        }.map(\.path))).sorted()
        return DisclosureGroup(isExpanded: Binding(
            get: { expandedProjectResourceRoots.contains(standardizedRoot) },
            set: { isExpanded in
                if isExpanded { expandedProjectResourceRoots.insert(standardizedRoot) }
                else { expandedProjectResourceRoots.remove(standardizedRoot) }
            }
        )) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Selected project · \(projectRootPath)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Paths are grouped here because you selected them. A link does not prove ownership or exclusive use. Measurements stay separate; shared storage, hard links, and overlapping paths can make totals misleading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !overlappingAppPaths.isEmpty {
                    DisclosureGroup("App-linked paths also intersect this project") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("These are exact or nested path relationships. They do not prove shared physical storage or ownership, and measurements are not combined.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(overlappingAppPaths, id: \.self) { path in
                                Text(path)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                }
                if review.entries.count > 1 {
                    projectResourceGrowthSection(growthReview)
                }
                ForEach(review.entries) { entry in
                    projectResourceRow(entry, projectRootPath: projectRootPath)
                }
                Button("Link folders and scan…") {
                    model.chooseProjectResourceFolders(for: projectRootPath)
                }
                .disabled(model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
                .help("Choose exact folders to associate with this selected project root and scan only those folders")
            }
            .padding(.top, 8)
        } label: {
            Label("Project resources", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func projectResourceGrowthSection(_ review: ProjectResourceGrowthReview) -> some View {
        let comparisons = review.rankedComparisonsByAllocatedDelta
        let unavailable = review.entries.filter { $0.status != .compared }
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                Text("Complete comparisons are ordered by allocated-estimate change, with largest increases first. Each row shows its own interval; linked paths may overlap, so values are never added and do not establish cause or reclaimable space.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if comparisons.isEmpty {
                    Text("No comparable complete interval is available yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(comparisons.prefix(8))) { entry in
                        projectResourceGrowthRow(entry)
                    }
                    if comparisons.count > 8 {
                        Text(String.localizedStringWithFormat(
                            NSLocalizedString("%ld more individual comparisons are available in the path rows below.", comment: "Count of linked path comparisons omitted from the compact project summary"),
                            Int32(comparisons.count - 8)
                        ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if !unavailable.isEmpty {
                    DisclosureGroup(String.localizedStringWithFormat(
                        NSLocalizedString("Paths without comparison · %ld", comment: "Count of project paths without a comparable complete interval"),
                        Int32(unavailable.count)
                    )) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(unavailable) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.path)
                                        .font(.caption2.monospaced())
                                        .textSelection(.enabled)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                    Text(projectResourceGrowthStatusText(entry.status))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption2)
                }
            }
            .padding(.top, 5)
        } label: {
            Label(
                String.localizedStringWithFormat(
                    NSLocalizedString("Linked path comparisons · %ld", comment: "Count of independent path-to-path historical comparisons"),
                    Int32(comparisons.count)
                ),
                systemImage: "arrow.left.arrow.right"
            )
        }
        .font(.caption)
    }

    @ViewBuilder
    private func projectResourceGrowthRow(_ entry: ProjectResourceGrowthReview.Entry) -> some View {
        if let current = entry.current, let previous = entry.previous,
           let logicalDelta = entry.logicalDelta, let allocatedDelta = entry.allocatedDelta {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.path)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("Complete scans: %@ → %@", comment: "Time interval for a single exact project resource path comparison"),
                    previous.finishedAt.formatted(date: .abbreviated, time: .shortened),
                    current.finishedAt.formatted(date: .abbreviated, time: .shortened)
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("Logical %@ · allocated estimate %@", comment: "Separate logical and allocated estimate changes for one project resource path"),
                    formattedDelta(logicalDelta), formattedDelta(allocatedDelta)
                ))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(allocatedDelta > 0 ? .orange : allocatedDelta < 0 ? .green : .secondary)
                Text("Complete coverage inside this selected path at both scans.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .background(alignment: .bottom) { Divider() }
        }
    }

    private func projectResourceGrowthStatusText(_ status: ProjectResourceGrowthReview.Status) -> String {
        switch status {
        case .compared: NSLocalizedString("Compared", comment: "A linked path has two comparable complete observations")
        case .unmeasured: NSLocalizedString("No measurement saved", comment: "A linked path has never been measured")
        case .cancelled: NSLocalizedString("Latest observation was cancelled", comment: "A cancelled scan suppresses linked path growth")
        case .partial: NSLocalizedString("Latest observation is partial", comment: "A partial scan suppresses linked path growth")
        case .overflowed: NSLocalizedString("Current accounting overflowed", comment: "An overflowed current scan cannot be compared")
        case .needsBaseline: NSLocalizedString("A second complete scan is needed", comment: "A linked path has no prior complete observation")
        case .volumeChanged: NSLocalizedString("Volume identity changed", comment: "A linked path moved to a different volume identity")
        case .timeOrderInvalid: NSLocalizedString("Observation timestamps are not increasing", comment: "A non-monotonic interval is withheld")
        case .previousOverflowed: NSLocalizedString("Prior accounting overflowed", comment: "An overflowed prior scan cannot be compared")
        case .deltaOverflowed: NSLocalizedString("Byte delta exceeds the supported range", comment: "A byte difference overflowed")
        }
    }

    private func projectResourceRow(
        _ entry: ProjectResourceReview.Entry, projectRootPath: String
    ) -> some View {
        let name = URL(fileURLWithPath: entry.path, isDirectory: true).lastPathComponent
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: entry.kind == .selectedProjectRoot ? "chevron.left.forwardslash.chevron.right" : "folder")
                .foregroundStyle(entry.kind == .selectedProjectRoot ? Color.blue : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.path)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(entry.kind == .selectedProjectRoot ? "Selected project root" : "User-linked location")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if entry.kind == .userLinkedFolder,
                   !model.rememberedScopes.contains(where: { $0.path == entry.path }) {
                    Label("Saved access unavailable · select this exact path again before a later scan", systemImage: "lock.open")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if entry.isSharedLink {
                    Label("Also linked from another selected project", systemImage: "person.2")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if !entry.overlappingPaths.isEmpty {
                    Label("Overlaps another selected path; keep measurements separate", systemImage: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let observation = entry.observation {
                    Text("\(folderMeasurementSummary(observation)) · measured \(observation.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if observation.complete && !entry.scanWasCancelled && !observation.byteAccountingOverflowed {
                        if let previous = model.previousCompleteObservation(for: observation),
                           let delta = ObservationComparison.allocatedByteDelta(
                            current: observation, previous: previous
                           ) {
                            Text(changeDescription(delta, since: previous.finishedAt))
                                .font(.caption2)
                                .foregroundStyle(delta >= 0 ? .orange : .green)
                        } else {
                            Text("First complete measurement")
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
                            wasCancelled: entry.scanWasCancelled,
                            accountingOverflowed: observation.byteAccountingOverflowed
                        ))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    }
                } else {
                    Text("No measurement saved · total unknown")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let observation = entry.observation {
                    selectedPathHistoryDisclosure(
                        for: observation,
                        wasCancelled: entry.scanWasCancelled
                    )
                    linkedPathFileChangesDisclosure(for: observation)
                }
                if model.checkingProjectResourcePaths.contains(entry.path) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Checking this exact location…")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else if let status = model.projectResourcePathStatuses[entry.path] {
                    Label(
                        projectResourcePathStatusText(status),
                        systemImage: associatedPathStatusSymbol(status)
                    )
                    .font(.caption2)
                    .foregroundStyle(associatedPathStatusColor(status))
                    Text("Presence only · no contents or ownership checked")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if associatedPathNeedsReselection(status) {
                        Button("Restore access…") {
                            model.reselectRememberedFolder(entry.path)
                        }
                        .font(.caption2)
                        .buttonStyle(.link)
                        .help("Select this same folder to refresh its saved read-only access")
                    }
                }
            }
            Spacer(minLength: 4)
            Button {
                model.checkProjectResourcePath(entry.path)
            } label: {
                Image(systemName: "checkmark.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(model.checkingProjectResourcePaths.contains(entry.path))
            .help("Check only this exact directory path. No folder contents are scanned.")
            .accessibilityLabel("Check project location \(name)")
            if entry.kind == .userLinkedFolder {
                Button {
                    model.rescanAssociatedFolder(entry.path)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isScanning || model.isMeasuringOwnFootprint || model.isVerifyingDuplicates)
                .help("Select this exact folder before scanning it again")
                .accessibilityLabel("Rescan linked folder \(name)")
                Button {
                    model.removeProjectResourceFolder(entry.path, from: projectRootPath)
                } label: {
                    Image(systemName: "link.badge.minus")
                }
                .buttonStyle(.borderless)
                .help("Remove the project link; files and scan history remain")
                .accessibilityLabel("Unlink \(name) from this project")
            }
        }
        .padding(.vertical, 6)
        .background(alignment: .bottom) { Divider() }
    }

    private func fileInventoryIncompleteness(for folder: FolderObservation) -> String {
        if model.scanWasCancelled(for: folder) {
            return NSLocalizedString("This scan was cancelled before a full inventory finished.", comment: "File inventory incompleteness caused by cancellation")
        }
        if folder.inaccessibleCount > 0 {
            return String.localizedStringWithFormat(
                NSLocalizedString("This scan could not access %ld entries, so file changes remain unknown.", comment: "File inventory incompleteness caused by inaccessible entries"),
                folder.inaccessibleCount
            )
        }
        if folder.changedDuringScanCount > 0 {
            return NSLocalizedString("Files or folders changed during the scan, so no consistent inventory was saved.", comment: "File inventory incompleteness caused by concurrent changes")
        }
        if folder.excludedVolumeBoundaryCount > 0 {
            return NSLocalizedString("A nested volume boundary was skipped, so the regular-file inventory is incomplete.", comment: "File inventory incompleteness caused by a nested volume")
        }
        if folder.excludedSpecialFileCount > 0 {
            return NSLocalizedString("Special filesystem entries prevented a complete regular-file inventory.", comment: "File inventory incompleteness caused by special entries")
        }
        if folder.byteAccountingOverflowed {
            return NSLocalizedString("Filesystem size accounting exceeded the supported integer range.", comment: "File inventory incompleteness caused by byte accounting overflow")
        }
        if folder.fileCount > 500_000 {
            return NSLocalizedString("This folder contains more than the 500,000-path inventory limit.", comment: "File inventory incompleteness caused by the inventory path limit")
        }
        return NSLocalizedString("A complete regular-file inventory was not recorded for this scan.", comment: "File-history status when the latest scan lacks a complete file inventory")
    }

    private func fileInventorySummary(_ report: FileInventoryChangeSet) -> String {
        let previousTime = report.previousObservedAt?.formatted(date: .abbreviated, time: .shortened)
            ?? NSLocalizedString("unknown time", comment: "Missing prior complete file inventory time")
        let growth = report.grossAllocatedGrowth.map { format($0) }
            ?? NSLocalizedString("unknown", comment: "Unavailable byte estimate")
        let reduction = report.grossAllocatedReduction.map { format($0) }
            ?? NSLocalizedString("unknown", comment: "Unavailable byte estimate")
        let net = report.netAllocatedDelta.map(formattedDelta)
            ?? NSLocalizedString("unknown", comment: "Unavailable net byte change")
        return String.localizedStringWithFormat(
            NSLocalizedString("Since %@: added or enlarged paths ~%@ allocated estimate · reduced paths ~%@ · net %@ · %ld changed paths", comment: "Exact file-inventory change summary since the previous complete selected-path baseline"),
            previousTime, growth, reduction, net, Int32(report.changedPathCount)
        )
    }

    private func newlyObservedLargeFileSection(
        for folder: FolderObservation, scanCancelled: Bool
    ) -> some View {
        let previous = model.previousCompleteObservation(for: folder)
        let entries = NewlyObservedLargeFileReview.make(
            from: folder, in: model.history, scanCancelled: scanCancelled
        )
        return VStack(alignment: .leading, spacing: 7) {
            Label("Newly observed large file paths", systemImage: "sparkle.magnifyingglass")
                .font(.caption.weight(.semibold))
            Text("A path absent from the prior complete inventory is not necessarily a file created during this interval. Files may have moved, been restored, or replaced. Ownership, usefulness, and reclaimable space are unknown; Disker reads no contents.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if scanCancelled || !folder.complete {
                Text("Unavailable because this selected-root scan was cancelled or incomplete.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if folder.largestFilesTruncated {
                Text("Unavailable because the current largest-file inventory was truncated; missing paths remain unknown.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if previous == nil {
                Text("A prior complete scan of this same path and volume is required.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if previous?.largestFilesTruncated == true {
                Text("The prior largest-file inventory was truncated; paths absent from it remain unknown.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if entries.isEmpty {
                Text("No file path at or above 100 MiB allocated estimate was absent from the prior complete inventory.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                if let previous {
                    Text("Compared with the complete inventory from \(previous.finishedAt.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Showing up to 20 largest matches by allocated estimate.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.rootRelativePath.isEmpty
                                 ? URL(fileURLWithPath: entry.path).lastPathComponent
                                 : entry.rootRelativePath)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(entry.evidence)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Logical \(format(entry.logicalBytes)) · Allocated ~\(format(entry.allocatedBytes))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderless)
                        .help("Review this file in Finder")
                        .accessibilityLabel("Reveal \(entry.rootRelativePath.isEmpty ? URL(fileURLWithPath: entry.path).lastPathComponent : entry.rootRelativePath) in Finder")
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func largeFileModificationSection(
        for folder: FolderObservation, scanCancelled: Bool
    ) -> some View {
        let entries = LargeFileModificationReview.make(
            from: folder, scanCancelled: scanCancelled, asOf: folder.finishedAt
        )
        return VStack(alignment: .leading, spacing: 7) {
            Label("Large files with older modification dates", systemImage: "calendar.badge.clock")
                .font(.caption.weight(.semibold))
            Text("Review metadata only: at least 100 MiB allocated estimate and no modification for 180 days. Modification time is not last use. These files may be unique or important; reclaimable space is unknown, and Disker does not read their contents.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if scanCancelled || !folder.complete {
                Text("Unavailable because this selected-root scan was cancelled or had incomplete coverage. Inaccessible items remain unknown.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if folder.largestFilesTruncated {
                Text("Unavailable because the largest-file inventory was truncated; omitted files remain unknown.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if entries.isEmpty {
                Text("No files met both review thresholds in this complete scan.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Showing up to 20 largest matches by allocated estimate.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.rootRelativePath.isEmpty
                                 ? URL(fileURLWithPath: entry.path).lastPathComponent
                                 : entry.rootRelativePath)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("Modified \(entry.ageDays) days ago · \(entry.lastModifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Logical \(format(entry.logicalBytes)) · Allocated ~\(format(entry.allocatedBytes))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderless)
                        .help("Review this file in Finder")
                        .accessibilityLabel("Reveal \(entry.rootRelativePath) in Finder")
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func fileExtensionSummary(for folder: FolderObservation) -> some View {
        let summaries = Array(folder.fileExtensionSummaries.prefix(5))
        let categories = FileExtensionBreakdown.categories(for: folder)
        let growth = ObservationComparison.growingFileExtensions(for: folder, in: model.history)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Filename composition by size")
                .font(.caption2.weight(.semibold))
            if let categories {
                SWFileExtensionBreakdownChart(categories: categories, coverageComplete: folder.complete)
            } else {
                ForEach(summaries) { item in
                    HStack(spacing: 8) {
                        Text(item.extensionName == "no extension" ? "No extension" : ".\(item.extensionName)")
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                        if FileArtifactHint.matching(extensionName: item.extensionName) != nil {
                            Image(systemName: "tag")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                                .help("Filename-based clue only; file contents and purpose are not verified.")
                        }
                        Text("\(item.fileCount) files")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(format(item.allocatedBytes))
                            .font(.caption2.monospacedDigit())
                    }
                }
                Text("A complete filename breakdown is unavailable for this saved observation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    private func header(_ title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
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

    private func allocatedHistoryUnit(for largestSample: Int64) -> (scale: Double, label: String) {
        if largestSample >= 1_073_741_824 {
            (1_073_741_824, "GiB")
        } else if largestSample >= 1_048_576 {
            (1_048_576, "MiB")
        } else if largestSample >= 1_024 {
            (1_024, "KiB")
        } else {
            (1, "bytes")
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
            let largestSample = visibleSamples.map(\.allocatedBytes).max() ?? 0
            let unit = allocatedHistoryUnit(for: largestSample)
            let unitScale = unit.scale
            let unitLabel = unit.label
            let values = visibleSamples.map { Double($0.allocatedBytes) / unitScale }
            let minimum = values.min() ?? 0
            let maximum = values.max() ?? minimum
            let padding = max((maximum - minimum) * 0.15, max(abs(maximum) * 0.03, 0.01))
            let selection = Binding<Date?>(
                get: { selectedFolderHistoryPath == folder.path ? selectedFolderHistoryDate : nil },
                set: {
                    selectedFolderHistoryPath = folder.path
                    selectedFolderHistoryDate = $0
                }
            )
            let selectedSample: FolderObservation? = selection.wrappedValue.flatMap { selectedDate in
                guard let first = visibleSamples.first,
                      let last = visibleSamples.last,
                      selectedDate >= first.finishedAt,
                      selectedDate <= last.finishedAt else { return nil }
                return visibleSamples.min {
                    abs($0.finishedAt.timeIntervalSince(selectedDate))
                        < abs($1.finishedAt.timeIntervalSince(selectedDate))
                }
            }
            Chart(visibleSamples, id: \.id) { sample in
                LineMark(
                    x: .value("Observed", sample.finishedAt),
                    y: .value("Allocated \(unitLabel)", Double(sample.allocatedBytes) / unitScale)
                )
                .foregroundStyle(.indigo)
                PointMark(
                    x: .value("Observed", sample.finishedAt),
                    y: .value("Allocated \(unitLabel)", Double(sample.allocatedBytes) / unitScale)
                )
                .foregroundStyle(.indigo)
                if let selectedSample, selectedSample.id == sample.id {
                    RuleMark(x: .value("Selected observation", selectedSample.finishedAt))
                        .foregroundStyle(.secondary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: max(0, minimum - padding)...(maximum + padding))
            .chartYAxisLabel(String.localizedStringWithFormat(
                NSLocalizedString("Allocated size (%@)", comment: "Allocated-size chart axis unit"),
                unitLabel
            ))
            .chartXSelection(value: selection)
            .frame(height: 112)
            .accessibilityLabel("Allocated-size history from \(visibleSamples.count) complete scans of \(folder.path)")
            if let selectedSample {
                let selectedIndex = visibleSamples.firstIndex(where: { $0.id == selectedSample.id })
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(format(selectedSample.allocatedBytes))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.indigo)
                    Text("Selected measurement")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(selectedSample.finishedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        guard let selectedIndex, selectedIndex > visibleSamples.startIndex else { return }
                        selection.wrappedValue = visibleSamples[selectedIndex - 1].finishedAt
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedIndex == nil || selectedIndex == visibleSamples.startIndex)
                    .help("Previous sample (⌘←)")
                    .accessibilityLabel("Previous sample")
                    .accessibilityHint("Moves selection to the previous complete measurement. Press Command–Left Arrow to activate.")
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    Button {
                        guard let selectedIndex, selectedIndex + 1 < visibleSamples.endIndex else { return }
                        selection.wrappedValue = visibleSamples[selectedIndex + 1].finishedAt
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedIndex.map { $0 + 1 >= visibleSamples.endIndex } ?? true)
                    .help("Next sample (⌘→)")
                    .accessibilityLabel("Next sample")
                    .accessibilityHint("Moves selection to the next complete measurement. Press Command–Right Arrow to activate.")
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    Button("Clear selection") {
                        selection.wrappedValue = nil
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                }
                .accessibilityElement(children: .combine)
            }
            Text(String.localizedStringWithFormat(
                NSLocalizedString(
                    "%ld complete scans of this selected path · %@ · drag across the chart or select the latest sample to inspect a saved measurement; then use ⌘←/⌘→ · focused vertical scale",
                    comment: "Path-history chart sample count, range, interaction, and scale disclosure"
                ),
                Int32(visibleSamples.count),
                historyRangeCaption(endingAt: latestDate)
            ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if selectedSample == nil {
                Button("Select latest sample") {
                    selection.wrappedValue = visibleSamples.last?.finishedAt
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
        } else if !fullSeries.isEmpty {
            Text(String.localizedStringWithFormat(
                NSLocalizedString("Fewer than two complete observations of this path in %@.", comment: "Path history has too few complete observations in selected range"),
                historyRangeCaption(endingAt: latestDate)
            ))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func selectedPathHistoryDisclosure(
        for observation: FolderObservation,
        wasCancelled: Bool
    ) -> some View {
        if !observation.complete || wasCancelled || observation.byteAccountingOverflowed {
            Text("Path history is withheld until this exact location has a complete scan.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            let series = ObservationComparison.completeFolderSeries(for: observation, in: model.history)
            if series.count > 1 {
                DisclosureGroup {
                    folderHistoryChart(for: observation)
                        .padding(.top, 4)
                } label: {
                    Label(
                        String.localizedStringWithFormat(
                            NSLocalizedString(
                                "Path history · %ld complete observations",
                                comment: "Count of complete observations available for one selected path"
                            ),
                            Int32(series.count)
                        ),
                        systemImage: "chart.xyaxis.line"
                    )
                }
                .font(.caption2)
            } else {
                Text("A second complete scan of this exact path is needed for a history chart.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func linkedPathFileChangesDisclosure(for folder: FolderObservation) -> some View {
        if let report = model.fileInventoryReports[folder.path],
           report.folderObservationID == folder.id {
            DisclosureGroup {
                fileInventoryChangeSection(for: folder, showHeading: false)
                    .padding(.top, 4)
            } label: {
                Label(fileInventoryDisclosureTitle(for: report), systemImage: "doc.badge.arrow.up")
            }
            .font(.caption2)
        }
    }

    private func fileInventoryDisclosureTitle(for report: FileInventoryChangeSet) -> String {
        if !report.hasBaseline {
            return NSLocalizedString("File inventory baseline", comment: "Disclosure for the first complete file inventory")
        }
        if report.changedPathCount == 0 {
            return NSLocalizedString("File changes · no changes", comment: "Disclosure for a complete comparison with no changed paths")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("Changed paths (%ld)", comment: "Count of changed file paths in one selected root"),
            Int32(report.changedPathCount)
        )
    }

    private func fileChangeCountSummary(_ count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("File change count: %ld", comment: "Count of file paths in a complete inventory comparison"),
            Int32(count)
        )
    }

    private var historyRangePicker: some View {
        Picker("History range", selection: $historyChartRange) {
            ForEach(ObservationTimeRange.allCases) { range in
                Text(NSLocalizedString(range.title, comment: "Storage history chart time range")).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("History chart range")
    }

    private func historyRangeCaption(endingAt date: Date) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("%@ ending %@", comment: "Selected history range and its end date"),
            NSLocalizedString(historyChartRange.title, comment: "Storage history chart time range"),
            date.formatted(date: .abbreviated, time: .shortened)
        )
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
        guard bytes != 0 else {
            return NSLocalizedString("No allocated-size change", comment: "Exact-path allocated estimate did not change")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("Since previous %@", comment: "Exact-path allocated estimate change since prior complete scan"),
            formattedDelta(bytes)
        )
    }

    private func changeDescription(_ bytes: Int64, since previous: Date) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("%@ since %@", comment: "Exact-path allocated estimate change and prior complete scan time"),
            changeDescription(bytes),
            previous.formatted(date: .abbreviated, time: .shortened)
        )
    }

    private func directoryChangeLabel(
        _ bytes: Int64, previous: FolderObservation, current: FolderObservation
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(changeDescription(bytes))
                .foregroundStyle(bytes >= 0 ? .orange : .green)
            Text(String.localizedStringWithFormat(
                NSLocalizedString("Complete scans: %@ → %@", comment: "Time interval for two complete, comparable selected-path scans"),
                previous.finishedAt.formatted(date: .abbreviated, time: .shortened),
                current.finishedAt.formatted(date: .abbreviated, time: .shortened)
            ))
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
        if accountingOverflowed {
            details.append(NSLocalizedString(
                "byte total exceeded the supported range and was capped",
                comment: "Coverage limitation caused by byte-accounting overflow"
            ))
        }
        if inaccessible > 0 {
            details.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld unmeasured", comment: "Count of inaccessible selected items"),
                inaccessible
            ))
        }
        if excludedSymlinks > 0 {
            details.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld symlinks not followed", comment: "Count of symbolic links excluded from scan"),
                excludedSymlinks
            ))
        }
        if excludedSpecialFiles > 0 {
            details.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld special files excluded", comment: "Count of unsupported special filesystem items"),
                excludedSpecialFiles
            ))
        }
        if excludedVolumeBoundaries > 0 {
            details.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld nested volume boundaries skipped", comment: "Count of nested volumes outside selected scan boundary"),
                excludedVolumeBoundaries
            ))
        }
        if changed > 0 {
            details.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld changed during scan", comment: "Count of items that changed during metadata measurement"),
                changed
            ))
        }
        if wasCancelled && details.isEmpty {
            details.append(NSLocalizedString("scan cancelled", comment: "Reason selected-folder coverage is incomplete"))
        }
        guard !details.isEmpty else {
            return NSLocalizedString("Coverage incomplete", comment: "Selected-folder coverage is incomplete")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("Partial · %@", comment: "Selected-folder coverage status and reasons"),
            details.joined(separator: " · ")
        )
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
    @State private var selectedHistoryPath: String?
    @State private var selectedHistoryDate: Date?

    let folder: FolderObservation
    let history: LocalHistory
    let onRescan: (URL) -> Void

    private var review: DeveloperArtifactReview {
        DeveloperArtifactReview.make(from: folder, in: history)
    }

    private var recommendations: DeveloperArtifactRecommendations {
        DeveloperArtifactRecommendations.make(from: review)
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
                Label("The scan's summary limit may omit matching paths; omitted candidates are unknown.", systemImage: "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }

            if review.entries.isEmpty {
                ContentUnavailableView("No measured candidates", systemImage: "shippingbox", description: Text("This scan did not retain any directories with a recognized name or direct Git marker."))
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            investigationRecommendations(scroll: scroll)
                            ForEach(review.entries) { entry in
                                developerArtifactEntry(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func investigationRecommendations(scroll: ScrollViewProxy) -> some View {
        if !folder.complete {
            Label("No prioritized investigation prompts for a partial scan", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        } else if recommendations.recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label("No prioritized investigation prompts", systemImage: "checkmark.circle")
                    .font(.callout.weight(.medium))
                Text("No complete candidate has recorded same-path growth or met the 100 MiB allocated-size threshold. Partial and unmatched paths remain visible below with their uncertainty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
        } else {
            VStack(alignment: .leading, spacing: 9) {
                Label("Prioritized to investigate", systemImage: "magnifyingglass")
                    .font(.headline)
                Text("Prompts use complete measurements and exact-path growth, or a large measured footprint. They do not mean data is unused or safe to remove. Reclaimable space is unknown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(recommendations.recommendations) { recommendation in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(recommendation.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer(minLength: 8)
                            Button("Review details") {
                                scroll.scrollTo(recommendation.entry.id, anchor: .top)
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                        Text(recommendation.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(recommendation.reasonDescription)
                            .font(.caption)
                        Text(recommendation.confidenceDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(recommendation.evidence)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(LocalizedStringKey(recommendation.possibleConsequence))
                            .font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Logical \(format(recommendation.entry.logicalBytes)) · allocated ~\(format(recommendation.entry.allocatedBytesEstimate)) · reclaimable unknown")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Evidence coverage: \(recommendation.coverage.description) Path purpose and ownership are not verified.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(LocalizedStringKey(recommendation.risk))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if !recommendation.overlappingCandidatePaths.isEmpty {
                            Text("Overlaps other measured candidates; do not add their sizes: \(recommendation.overlappingCandidatePaths.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if recommendation.coverage.candidateInventoryTruncated {
                            Text("Additional matching candidates were omitted from the bounded summary; those paths remain unknown.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
        }
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
                    Text(LocalizedStringKey(entry.category.title))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text(LocalizedStringKey(entry.risk))
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
            Text(LocalizedStringKey(entry.possibleConsequence))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.caution)
                .font(.caption)
                .foregroundStyle(entry.subtreeComplete && entry.selectedRootComplete ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            if let change = entry.historicalChange {
                Label(historicalChangeTitle(change.allocatedBytesChange), systemImage: historicalChangeSymbol(change.allocatedBytesChange))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(change.allocatedBytesChange > 0 ? Color.orange : Color.secondary)
                Text("Allocated estimate \(signed(change.allocatedBytesChange)) between complete scans on \(change.previousObservedAt.formatted(date: .abbreviated, time: .shortened)) and \(change.currentObservedAt.formatted(date: .abbreviated, time: .shortened)). This describes measured change; it does not identify cause or reclaimable space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let pace = change.observedBytesPerDay {
                    if let formattedPace = formatPace(pace) {
                        Text("Observed pace over that interval: ~\(formattedPace) per day; descriptive only.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Observed pace exceeds the display range; the interval change remains shown above.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Growth unknown: no comparable complete measurement of this exact path is retained.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            developerArtifactHistory(entry)

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
                Button("Confirm exact folder to rescan…") {
                    onRescan(URL(fileURLWithPath: entry.path, isDirectory: true))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Confirm this exact candidate folder in the native picker. Choosing another path starts no scan.")
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    @ViewBuilder
    private func developerArtifactHistory(_ entry: DeveloperArtifactReview.Entry) -> some View {
        if entry.history.count > 1 {
            DisclosureGroup {
                developerArtifactHistoryChart(entry)
                    .padding(.top, 4)
            } label: {
                Label(
                    String.localizedStringWithFormat(
                        NSLocalizedString("Candidate history · %ld complete scans", comment: "Count of complete observations for one exact development-data candidate"),
                        Int32(entry.history.count)
                    ),
                    systemImage: "chart.xyaxis.line"
                )
            }
            .font(.caption2)
        } else if entry.history.count == 1 {
            Text("One complete candidate observation is retained; another is needed for a history chart.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func developerArtifactHistoryChart(_ entry: DeveloperArtifactReview.Entry) -> some View {
        let samples = entry.history
        let first = samples[0]
        let last = samples[samples.count - 1]
        let largest = samples.map(\.allocatedBytes).max() ?? 0
        let unit = artifactHistoryUnit(for: largest)
        let values = samples.map { Double($0.allocatedBytes) / unit.scale }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? minimum
        let padding = max((maximum - minimum) * 0.15, max(abs(maximum) * 0.03, 0.01))
        let selection = Binding<Date?>(
            get: { selectedHistoryPath == entry.path ? selectedHistoryDate : nil },
            set: {
                selectedHistoryPath = entry.path
                selectedHistoryDate = $0
            }
        )
        let selectedSample: ObservationComparison.DirectoryHistoryPoint? = selection.wrappedValue.flatMap {
            selectedDate -> ObservationComparison.DirectoryHistoryPoint? in
            guard selectedDate >= first.finishedAt, selectedDate <= last.finishedAt else { return nil }
            return samples.min {
                abs($0.finishedAt.timeIntervalSince(selectedDate))
                    < abs($1.finishedAt.timeIntervalSince(selectedDate))
            }
        }

        return VStack(alignment: .leading, spacing: 6) {
            Text("Measured allocated-byte estimates for this exact directory. Nested candidates are shown separately; the line connects observations and does not represent measurements between scans.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Chart(samples) { sample in
                LineMark(
                    x: .value("Observed", sample.finishedAt),
                    y: .value("Allocated estimate (\(unit.label))", Double(sample.allocatedBytes) / unit.scale)
                )
                .foregroundStyle(.indigo)
                .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(
                    x: .value("Observed", sample.finishedAt),
                    y: .value("Allocated estimate (\(unit.label))", Double(sample.allocatedBytes) / unit.scale)
                )
                .foregroundStyle(.indigo)
                .symbolSize(34)
                if let selectedSample, selectedSample.id == sample.id {
                    RuleMark(x: .value("Selected observation", selectedSample.finishedAt))
                        .foregroundStyle(.secondary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: max(0, minimum - padding)...(maximum + padding))
            .chartYAxisLabel(
                String.localizedStringWithFormat(
                    NSLocalizedString("Allocated estimate (%@)", comment: "Unit label for exact development-candidate history chart"),
                    unit.label
                )
            )
            .chartXSelection(value: selection)
            .frame(height: 116)
            .accessibilityLabel(String.localizedStringWithFormat(
                NSLocalizedString("Candidate history for %@ · %ld complete scans", comment: "Accessible name for a development-candidate size history chart"),
                entry.path, Int32(samples.count)
            ))

            if let selectedSample {
                let selectedIndex = samples.firstIndex(where: { $0.id == selectedSample.id })
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("Logical %@ · allocated estimate ~%@", comment: "Separate logical and allocated estimates at one selected candidate observation"),
                        format(selectedSample.logicalBytes), format(selectedSample.allocatedBytes)
                    ))
                        .font(.caption2.monospacedDigit().weight(.medium))
                    Spacer(minLength: 4)
                    Text(selectedSample.finishedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: 6) {
                    Button {
                        guard let selectedIndex, selectedIndex > samples.startIndex else { return }
                        selection.wrappedValue = samples[selectedIndex - 1].finishedAt
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedIndex == nil || selectedIndex == samples.startIndex)
                    .help("Previous sample (⌘←)")
                    .accessibilityLabel("Previous sample")
                    .accessibilityHint("Moves to the previous complete candidate measurement.")
                    .keyboardShortcut(.leftArrow, modifiers: .command)

                    Button {
                        guard let selectedIndex, selectedIndex + 1 < samples.endIndex else { return }
                        selection.wrappedValue = samples[selectedIndex + 1].finishedAt
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedIndex.map { $0 + 1 >= samples.endIndex } ?? true)
                    .help("Next sample (⌘→)")
                    .accessibilityLabel("Next sample")
                    .accessibilityHint("Moves to the next complete candidate measurement.")
                    .keyboardShortcut(.rightArrow, modifiers: .command)

                    Button("Clear selection") {
                        selection.wrappedValue = nil
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                }
            } else {
                Button("Select latest sample") {
                    selection.wrappedValue = last.finishedAt
                }
                .buttonStyle(.link)
                .font(.caption2)
                .accessibilityHint("Selects the exact latest complete observation in this chart.")
            }
        }
    }

    private func artifactHistoryUnit(for largestSample: Int64) -> (scale: Double, label: String) {
        if largestSample >= 1_073_741_824 {
            (1_073_741_824, "GiB")
        } else if largestSample >= 1_048_576 {
            (1_048_576, "MiB")
        } else if largestSample >= 1_024 {
            (1_024, "KiB")
        } else {
            (1, "bytes")
        }
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

    private func formatPace(_ bytesPerDay: Double) -> String? {
        guard bytesPerDay.isFinite, bytesPerDay >= 0,
              bytesPerDay < Double(Int64.max) else { return nil }
        return format(Int64(bytesPerDay))
    }

    private func signed(_ bytes: Int64) -> String {
        let magnitude = bytes.magnitude > UInt64(Int64.max) ? Int64.max : Int64(bytes.magnitude)
        let formatted = format(magnitude)
        if bytes > 0 { return "+\(formatted)" }
        if bytes < 0 { return "−\(formatted)" }
        return formatted
    }

    private func historicalChangeTitle(_ bytes: Int64) -> String {
        if bytes > 0 { return "Observed growth" }
        if bytes < 0 { return "Observed decrease" }
        return "No allocated-size change observed"
    }

    private func historicalChangeSymbol(_ bytes: Int64) -> String {
        if bytes > 0 { return "arrow.up.right" }
        if bytes < 0 { return "arrow.down.right" }
        return "equal"
    }
}

private struct ApplicationFootprintReviewSheet: View {
    let bundleName: String
    let review: ApplicationFootprintReview
    let crossDomainEvidence: CrossDomainResourceEvidence

    private var removalReviewPlan: ApplicationRemovalReviewPlan {
        ApplicationRemovalReviewPlanner.makePlan(from: review)
    }

    private var linkedProjectPaths: [String] {
        let applicationLinkIDs = Set(crossDomainEvidence.links.filter {
            $0.domain == .application && $0.rootPath == review.bundlePath
        }.map(\.id))
        let projectLinkIDs = Set(crossDomainEvidence.links.filter {
            $0.domain == .application && applicationLinkIDs.contains($0.id)
        }.flatMap { $0.overlaps.map(\.otherLinkID) })
        return Array(Set(crossDomainEvidence.links.filter {
            $0.domain == .project && projectLinkIDs.contains($0.id)
        }.map(\.path))).sorted()
    }

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
                    Text("This review can total only complete, non-cancelled, non-overflowed measurements of disjoint paths you selected. Shared paths are excluded. The subtotal is not proof of app ownership or reclaimable physical space. Disker does not remove files.")
                } icon: {
                    Image(systemName: "info.circle.fill")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

                if !linkedProjectPaths.isEmpty {
                    DisclosureGroup("Paths also linked under a selected project") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Project grouping is user-selected. A path link does not prove ownership or shared physical storage. Cross-domain measurements stay separate and are not combined in this subtotal.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(linkedProjectPaths, id: \.self) { path in
                                Text(path)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                }

                selectedScopeSubtotal

                ForEach(review.entries) { entry in
                    entryCard(entry)
                }

            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    @ViewBuilder
    private var selectedScopeSubtotal: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Measured selected-scope subtotal", systemImage: "sum")
                .font(.headline)

            if let subtotal = review.measuredSelectedScopeSubtotal {
                Text("Logical size: \(format(subtotal.logicalBytes))")
                    .font(.subheadline.monospacedDigit())
                Text("Allocated estimate: ~\(format(subtotal.allocatedBytesEstimate))")
                    .font(.subheadline.monospacedDigit())
                Text(String.localizedStringWithFormat(
                    NSLocalizedString(
                        "%lld disjoint paths in this app review",
                        comment: "Count of selected paths included in the app review subtotal"
                    ),
                    Int64(subtotal.includedPaths.count)
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("No reliable subtotal is available from the latest measurements.", systemImage: "questionmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !review.subtotalExclusions.isEmpty {
                DisclosureGroup("Why paths were excluded (\(review.subtotalExclusions.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(review.subtotalExclusions) { exclusion in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(subtotalExclusionTitle(exclusion.reason))
                                    .font(.caption.weight(.semibold))
                                Text(exclusion.path)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                ForEach(exclusion.relatedPaths, id: \.self) { path in
                                    Text("Overlaps: \(path)")
                                        .font(.caption2.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func subtotalExclusionTitle(
        _ reason: ApplicationFootprintReview.SubtotalExclusionReason
    ) -> String {
        switch reason {
        case .sharedOrMultiOwner: "Shared or linked with another app · excluded"
        case .overlappingScope: "Overlaps another selected path · total withheld"
        case .missingLatestObservation: "No latest measurement · total withheld"
        case .incompleteObservation: "Latest scan was partial · total withheld"
        case .cancelledObservation: "Latest scan was cancelled · total withheld"
        case .accountingOverflow: "Source byte accounting overflowed · total withheld"
        case .invalidByteCount: "Invalid measured byte count · total withheld"
        case .subtotalOverflow: "Subtotal exceeded the supported range · total withheld"
        }
    }

    @ViewBuilder
    private func entryCard(_ entry: ApplicationFootprintReview.Entry) -> some View {
        let entrySymbol = entry.kind == .applicationBundle
            ? "app.fill"
            : entry.attribution?.evidence == .probablePreferencesFilePathMatch ? "doc.text" : "folder"
        let planRow = removalReviewPlan.rows.first { $0.path == entry.path }
        let appLinkIDs = Set(crossDomainEvidence.links.filter {
            $0.domain == .application && $0.rootPath == review.bundlePath && $0.path == entry.path
        }.map(\.id))
        let projectLinkIDs = Set(crossDomainEvidence.links.filter {
            $0.domain == .application && appLinkIDs.contains($0.id)
        }.flatMap { $0.overlaps.map(\.otherLinkID) })
        let overlappingProjectPaths = Array(Set(crossDomainEvidence.links.filter {
            $0.domain == .project && projectLinkIDs.contains($0.id)
        }.map(\.path))).sorted()
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(
                    entry.kind == .applicationBundle ? "Selected application bundle" : "Associated location",
                    systemImage: entrySymbol
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

            if let planRow {
                Label(planRow.disposition.title, systemImage: removalDispositionSymbol(planRow.disposition))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(removalDispositionColor(planRow.disposition))
                ForEach(planRow.reasons, id: \.self) { reason in
                    Text(reason.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Label(entry.cleanupReviewClass.title, systemImage: cleanupReviewSymbol(for: entry.cleanupReviewClass))
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.cleanupReviewClass == .sharedOrMultiOwner ? Color.orange : Color.secondary)
            Text(entry.cleanupReviewClass.guidance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let observation = entry.observation {
                Text("Last measured \(observation.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption.weight(.medium))
                VStack(alignment: .leading, spacing: 3) {
                    Text(folderMeasurementSummary(observation))
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

            if !overlappingProjectPaths.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Also linked under selected project", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption.weight(.medium))
                    ForEach(overlappingProjectPaths, id: \.self) { path in
                        Text(path)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Project grouping is user-selected. This path relationship does not confirm ownership or shared physical storage; keep measurements separate.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func removalDispositionSymbol(_ disposition: ApplicationRemovalReviewPlan.Disposition) -> String {
        switch disposition {
        case .excludedFromCleanup: "hand.raised.fill"
        case .inspectOnly: "eye"
        case .ownerReviewCandidate: "exclamationmark.shield"
        }
    }

    private func removalDispositionColor(_ disposition: ApplicationRemovalReviewPlan.Disposition) -> Color {
        switch disposition {
        case .excludedFromCleanup: .orange
        case .inspectOnly: .secondary
        case .ownerReviewCandidate: .orange
        }
    }

    private func cleanupReviewSymbol(for classification: ApplicationFootprintReview.CleanupReviewClass) -> String {
        switch classification {
        case .sharedOrMultiOwner: "person.2"
        case .possibleCache: "arrow.clockwise.circle"
        case .selectedBundle: "app.badge.checkmark"
        case .unknownOrPotentiallyUnique: "lock.shield"
        }
    }

    private func unmeasuredSummary(_ observation: FolderObservation, wasCancelled: Bool) -> String {
        var reasons: [String] = []
        if observation.inaccessibleCount > 0 {
            reasons.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld unmeasured", comment: "Count of inaccessible selected items"),
                observation.inaccessibleCount
            ))
        }
        if observation.excludedSymlinkCount > 0 {
            reasons.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld symlinks not followed", comment: "Count of symbolic links excluded from scan"),
                observation.excludedSymlinkCount
            ))
        }
        if observation.excludedSpecialFileCount > 0 {
            reasons.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld special files excluded", comment: "Count of unsupported special filesystem items"),
                observation.excludedSpecialFileCount
            ))
        }
        if observation.excludedVolumeBoundaryCount > 0 {
            reasons.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld nested volume boundaries skipped", comment: "Count of nested volumes outside selected scan boundary"),
                observation.excludedVolumeBoundaryCount
            ))
        }
        if observation.changedDuringScanCount > 0 {
            reasons.append(String.localizedStringWithFormat(
                NSLocalizedString("%ld changed during scan", comment: "Count of items that changed during metadata measurement"),
                observation.changedDuringScanCount
            ))
        }
        if observation.byteAccountingOverflowed {
            reasons.append(NSLocalizedString(
                "byte total exceeded the supported range and was capped",
                comment: "Coverage limitation caused by byte-accounting overflow"
            ))
        }
        if wasCancelled { reasons.append(NSLocalizedString("scan cancelled", comment: "Reason selected-folder coverage is incomplete")) }
        return reasons.isEmpty
            ? NSLocalizedString("some data may be unmeasured", comment: "No precise partial-coverage reason is available")
            : reasons.joined(separator: " · ")
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct DatabaseSidecarReviewSheet: View {
    let folder: FolderObservation
    let initialReview: DatabaseSidecarReview?
    let fileChangeReport: FileInventoryChangeSet?

    @State private var review: DatabaseSidecarReview?
    @State private var isLoading = true
    @State private var loadFailed = false

    init(
        folder: FolderObservation,
        initialReview: DatabaseSidecarReview? = nil,
        fileChangeReport: FileInventoryChangeSet? = nil
    ) {
        self.folder = folder
        self.initialReview = initialReview
        self.fileChangeReport = fileChangeReport
        _review = State(initialValue: initialReview)
        _isLoading = State(initialValue: initialReview == nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "externaldrive")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SQLite files in selected folder")
                            .font(.title3.weight(.semibold))
                        Text(folder.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if let review {
                        SWStatusBadge(
                            text: review.inventoryComplete ? "Complete inventory" : "Partial inventory",
                            style: review.inventoryComplete ? .success : .warning
                        )
                    }
                }

                Text("Related names are based on exact paths such as database.sqlite and database.sqlite-wal. Disker does not open database files, verify their contents, determine ownership, or add their sizes together.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("File-level size changes are shown only when two complete inventories match this selected folder and volume. If the bounded report omitted changed paths, an unlisted file's change remains unknown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isLoading {
                    ProgressView("Loading the saved file inventory…")
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if loadFailed {
                    Label("The saved file inventory could not be read. Scan this selected folder again to refresh it.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                } else if let review {
                    if review.groups.isEmpty && review.unpairedSidecars.isEmpty {
                        ContentUnavailableView(
                            review.inventoryComplete ? "No SQLite Sidecar Names Found" : "No SQLite Pair Observed",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text(review.inventoryComplete
                                ? "No exact database and SQLite sidecar filename relationships were observed in this selected regular-file inventory."
                                : "No exact database and SQLite sidecar pair was observed among measured files. Unmeasured files may contain a match.")
                        )
                    } else {
                        if !review.groups.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                Label("Matching database and sidecar names", systemImage: "link")
                                    .font(.headline)
                                ForEach(review.groups) { group in
                                    databaseGroup(group)
                                }
                                if review.omittedGroupCount > 0 {
                                    Text(String.localizedStringWithFormat(
                                        NSLocalizedString("Showing %ld groups; %ld additional matching groups were omitted from this bounded review.", comment: "Bounded SQLite relationship review group count"),
                                        Int32(review.groups.count), Int32(review.omittedGroupCount)
                                    ))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !review.unpairedSidecars.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(
                                    review.inventoryComplete
                                        ? "Sidecar-name candidates without a matching database path"
                                        : "Observed sidecar-name candidates",
                                    systemImage: "questionmark.folder"
                                )
                                    .font(.headline)
                                Text(review.inventoryComplete
                                    ? "A same-name database path was not found in this selected regular-file inventory. This does not establish that the sidecar is orphaned or unused."
                                    : "This inventory is partial; a matching database may be among unmeasured files. No absence, orphan, or unused conclusion can be made.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                ForEach(review.unpairedSidecars, id: \.relativePath) { entry in
                                    inventoryRow(
                                        entry,
                                        relationshipLabel: review.inventoryComplete ? "No matching path" : "Matching path unknown"
                                    )
                                }
                                if review.omittedUnpairedSidecarCount > 0 {
                                    Text(String.localizedStringWithFormat(
                                        NSLocalizedString("%ld additional sidecar-name candidates were omitted from this bounded review.", comment: "Bounded SQLite sidecar candidate count"),
                                        Int32(review.omittedUnpairedSidecarCount)
                                    ))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if review.excludedSymlinkCount > 0 {
                        Label(String.localizedStringWithFormat(
                            NSLocalizedString("%ld symlink entries were excluded; their targets were not followed.", comment: "Symlink boundary in SQLite sidecar review"),
                            Int32(review.excludedSymlinkCount)
                        ), systemImage: "arrow.turn.up.right")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !review.inventoryComplete {
                        Text("Only measured regular files are shown; unmeasured paths remain unknown.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("Measured %@. Each logical size and allocated-byte estimate belongs to its own path; allocation is not reclaimable space.", comment: "Observation date and byte-measurement meaning for the SQLite detail review"),
                        review.observedAt.formatted(date: .abbreviated, time: .shortened)
                    ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: folder.id) {
            guard initialReview == nil else {
                isLoading = false
                return
            }
            isLoading = true
            loadFailed = false
            review = nil
            let path = folder.path
            let observationID = folder.id
            let loadTask = Task.detached(priority: .utility) {
                try FileInventoryStore.loadSnapshot(
                    for: path,
                    matchingObservationID: observationID
                )
            }
            do {
                guard let snapshot = try await loadTask.value else {
                    loadFailed = true
                    isLoading = false
                    return
                }
                review = DatabaseSidecarReview.make(from: snapshot, fileChangeReport: fileChangeReport)
            } catch {
                loadFailed = true
            }
            isLoading = false
        }
    }

    @Environment(\.dismiss) private var dismiss

    @ViewBuilder
    private func databaseGroup(_ group: DatabaseSidecarReview.Group) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            inventoryRow(group.database, relationshipLabel: "Database filename")
            ForEach(group.sidecars, id: \.relativePath) { entry in
                inventoryRow(entry, relationshipLabel: "Exact sidecar-name match")
                    .padding(.leading, 16)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func inventoryRow(_ entry: FileInventoryEntry, relationshipLabel: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.relativePath)
                    .font(.caption.monospaced().weight(.medium))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("Logical \(format(entry.logicalBytes)) · allocated ~\(format(entry.allocatedBytes))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let review, let previousAt = review.previousFileInventoryObservationAt {
                    if let change = review.fileChangesByPath[entry.relativePath] {
                        Text(String.localizedStringWithFormat(
                            NSLocalizedString("Size change since %@: logical %@ · allocated estimate %@", comment: "Exact path logical and allocated estimate deltas from the previous complete inventory"),
                            previousAt.formatted(date: .abbreviated, time: .shortened),
                            formattedDelta(change.logicalDelta),
                            formattedDelta(change.allocatedDelta)
                        ))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(change.logicalDelta > 0 || change.allocatedDelta > 0 ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if review.omittedFileChangeCount == 0 {
                        Text(String.localizedStringWithFormat(
                            NSLocalizedString("No logical or allocated size change recorded since %@.", comment: "Exact path had no measured size change in a complete file inventory comparison"),
                            previousAt.formatted(date: .abbreviated, time: .shortened)
                        ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let omittedCount = review.omittedFileChangeCount {
                        Text(String.localizedStringWithFormat(
                            NSLocalizedString("Change unknown; the report omitted changed paths since %@ (%ld total).", comment: "Exact path may have changed but was absent from the bounded file change list"),
                            previousAt.formatted(date: .abbreviated, time: .shortened),
                            Int32(omittedCount)
                        ))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("No comparable complete inventory; size change is unknown.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            SWStatusBadge(text: relationshipLabel, style: .info)
            Button {
                let fileURL = URL(fileURLWithPath: folder.path, isDirectory: true)
                    .appendingPathComponent(entry.relativePath)
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Reveal this exact measured file path in Finder.")
            .accessibilityLabel(String.localizedStringWithFormat(
                NSLocalizedString("Reveal %@ in Finder", comment: "Reveal one exact SQLite review file in Finder"),
                entry.relativePath
            ))
            .accessibilityHint("Opens Finder at this measured path. Disker does not open its contents.")
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formattedDelta(_ bytes: Int64) -> String {
        let magnitude = bytes == Int64.min ? Int64.max : abs(bytes)
        return "\(bytes >= 0 ? "+" : "−")\(format(magnitude))"
    }
}
