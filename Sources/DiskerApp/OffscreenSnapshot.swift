#if DEBUG
import AppKit
import DiskerCore
import SwiftUI

struct DiskerSnapshotRequest {
    let outputURL: URL
    let section: String
    let width: CGFloat
    let height: CGFloat
    let appearanceName: NSAppearance.Name?
    let suppressSpotlightDiscovery: Bool
    let includeProjectCandidate: Bool
    let includeProjectProfile: Bool
    let includeApplicationProfile: Bool
    let includeSnapshotDiscoveredApplicationCandidate: Bool
    let projectCandidateSearchText: String
    let includeDatabaseSidecarReview: Bool
    let usePartialDatabaseSidecarFixture: Bool
    let useOmittedDatabaseChangeFixture: Bool
    let storeURLs: DashboardModelStoreURLs

    var colorScheme: ColorScheme {
        let selectedAppearance = appearanceName
            ?? NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return selectedAppearance == .darkAqua ? .dark : .light
    }

    static func from(arguments: [String]) -> DiskerSnapshotRequest? {
        guard let outputIndex = arguments.firstIndex(of: "--snapshot-output"),
              arguments.indices.contains(outputIndex + 1) else { return nil }
        let sectionIndex = arguments.firstIndex(of: "--snapshot-section")
        let appearanceIndex = arguments.firstIndex(of: "--snapshot-appearance")
        let suppressSpotlightDiscovery = !arguments.contains("--snapshot-enable-spotlight")
        let section = sectionIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            ?? "Overview"
        let includeProjectCandidate = arguments.contains("--snapshot-project-candidate")
        let includeProjectProfile = arguments.contains("--snapshot-project-profile")
        let includeApplicationProfile = arguments.contains("--snapshot-application-profile")
        let includeSnapshotDiscoveredApplicationCandidate = arguments.contains("--snapshot-discovered-app-data")
        let projectCandidateSearchIndex = arguments.firstIndex(of: "--snapshot-project-search")
        let projectCandidateSearchText = projectCandidateSearchIndex.flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        } ?? ""
        let includeDatabaseSidecarReview = arguments.contains("--snapshot-database-sidecars")
        let usePartialDatabaseSidecarFixture = arguments.contains("--snapshot-database-sidecars-partial")
        let useOmittedDatabaseChangeFixture = arguments.contains("--snapshot-database-sidecars-omitted")
        let defaultHeight: CGFloat = includeApplicationProfile ? 900 : includeProjectProfile ? 850 : includeProjectCandidate ? 1_200
            : includeSnapshotDiscoveredApplicationCandidate ? 1_400
            : includeDatabaseSidecarReview ? 540 : 900
        let width = dimension(named: "--snapshot-width", in: arguments, fallback: 1_280, range: 760...2_560)
        let height = dimension(named: "--snapshot-height", in: arguments, fallback: Int(defaultHeight), range: 540...2_400)
        let appearance = appearanceIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let appearanceName: NSAppearance.Name?
        switch appearance?.lowercased() {
        case "light": appearanceName = .aqua
        case "dark": appearanceName = .darkAqua
        default: appearanceName = nil
        }
        let snapshotStoreDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Disker-Offscreen-Snapshot-\(UUID().uuidString)", isDirectory: true)
        // Debug snapshots must never load or update the user's shared Application Support history.
        return DiskerSnapshotRequest(
            outputURL: URL(fileURLWithPath: arguments[outputIndex + 1]),
            section: section,
            width: CGFloat(width),
            height: CGFloat(height),
            appearanceName: appearanceName,
            suppressSpotlightDiscovery: suppressSpotlightDiscovery,
            includeProjectCandidate: includeProjectCandidate,
            includeProjectProfile: includeProjectProfile,
            includeApplicationProfile: includeApplicationProfile,
            includeSnapshotDiscoveredApplicationCandidate: includeSnapshotDiscoveredApplicationCandidate,
            projectCandidateSearchText: projectCandidateSearchText,
            includeDatabaseSidecarReview: includeDatabaseSidecarReview || usePartialDatabaseSidecarFixture
                || useOmittedDatabaseChangeFixture,
            usePartialDatabaseSidecarFixture: usePartialDatabaseSidecarFixture,
            useOmittedDatabaseChangeFixture: useOmittedDatabaseChangeFixture,
            storeURLs: DashboardModelStoreURLs(
                observations: snapshotStoreDirectory.appendingPathComponent("observations.json"),
                fileInventory: snapshotStoreDirectory.appendingPathComponent("file-inventory.plist"),
                selectedScopeBookmarks: snapshotStoreDirectory.appendingPathComponent("selected-scopes.json"),
                storageMonitoringPreferences: snapshotStoreDirectory.appendingPathComponent("storage-monitoring.json"),
                applicationDiscoveryScopes: snapshotStoreDirectory.appendingPathComponent(
                    "application-discovery-scopes.json"
                )
            )
        )
    }

    private static func dimension(
        named name: String, in arguments: [String], fallback: Int, range: ClosedRange<Int>
    ) -> Int {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1),
              let value = Int(arguments[index + 1]) else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

struct DiskerSnapshotHost: View {
    let request: DiskerSnapshotRequest

    var body: some View {
        Group {
            if request.includeDatabaseSidecarReview {
                let fixture = databaseSidecarReviewFixture(
                    partial: request.usePartialDatabaseSidecarFixture,
                    includeOmittedChange: request.useOmittedDatabaseChangeFixture
                )
                DatabaseSidecarReviewSheet(folder: fixture.folder, initialReview: fixture.review)
            } else if request.includeProjectProfile {
                let history = DashboardModel(includeSnapshotProjectCandidate: true).history
                let review = ProjectResourceReview.make(for: "/synthetic/QA/DemoProject", in: history)
                let monitoringStatuses = StorageMonitoringObservationReview.make(
                    for: review.entries.map(\.path), in: history
                )
                let fileChanges = FileInventoryChangeSet(
                    rootPath: "/synthetic/QA/DemoProject",
                    folderObservationID: review.entries.first(where: {
                        $0.path == "/synthetic/QA/DemoProject"
                    })?.observation?.id ?? UUID(),
                    previousObservedAt: Date().addingTimeInterval(-3_600),
                    observedAt: Date(),
                    volumeDeviceID: 42,
                    changes: [FileInventoryChange(
                        relativePath: "runs/latest/checkpoint.bin",
                        kind: .resized,
                        logicalDelta: 67_108_864,
                        allocatedDelta: 70_254_592,
                        logicalBytes: 134_217_728,
                        allocatedBytes: 140_509_184
                    )],
                    changedPathCount: 1,
                    omittedChangeCount: 0,
                    netLogicalDelta: 67_108_864,
                    netAllocatedDelta: 70_254_592,
                    grossAllocatedGrowth: 70_254_592,
                    grossAllocatedReduction: 0,
                    symlinkExcludedCount: 0,
                    hasBaseline: true
                )
                let modelsPath = "/synthetic/QA/DemoProject/models"
                let modelsChanges = FileInventoryChangeSet(
                    rootPath: modelsPath,
                    folderObservationID: review.entries.first(where: { $0.path == modelsPath })?.observation?.id ?? UUID(),
                    previousObservedAt: Date().addingTimeInterval(-1_800),
                    observedAt: Date(),
                    volumeDeviceID: 42,
                    changes: [FileInventoryChange(
                        relativePath: "dataset/latest-part.bin",
                        kind: .added,
                        logicalDelta: 2_097_152,
                        allocatedDelta: 2_101_248,
                        logicalBytes: 2_097_152,
                        allocatedBytes: 2_101_248
                    )],
                    changedPathCount: 1,
                    omittedChangeCount: 0,
                    netLogicalDelta: 2_097_152,
                    netAllocatedDelta: 2_101_248,
                    grossAllocatedGrowth: 2_101_248,
                    grossAllocatedReduction: 0,
                    symlinkExcludedCount: 0,
                    hasBaseline: true
                )
                ProjectProfileSheet(
                    review: review,
                    growthReview: ProjectResourceGrowthReview.make(for: review, in: history),
                    monitoringObservationStatuses: monitoringStatuses,
                    appLinkedOverlapPaths: [],
                    fileChangesByPath: [
                        "/synthetic/QA/DemoProject": fileChanges,
                        modelsPath: modelsChanges,
                    ],
                    rememberedScopePaths: [
                        "/synthetic/QA/DemoProject",
                        "/synthetic/QA/DemoProject/models",
                    ],
                    monitoredScopePaths: [
                        "/synthetic/QA/DemoProject",
                        "/synthetic/QA/DemoProject/models",
                    ],
                    monitoringSessionOpen: true,
                    onRescan: {},
                    onLinkLocations: {}
                )
            } else if request.includeApplicationProfile {
                let fixture = applicationProfileFixture()
                let applicationReview = ApplicationFootprintReview.make(
                    for: fixture.bundle, in: fixture.history, homeDirectoryPath: "/Users/synthetic"
                )
                ApplicationFootprintReviewSheet(
                    bundleName: fixture.bundle.displayName,
                    bundlePath: fixture.bundle.path,
                    review: applicationReview,
                    history: fixture.history,
                    discoveryRecord: fixture.discoveryRecord,
                    crossDomainEvidence: CrossDomainResourceEvidence.make(
                        forApplicationBundlePath: fixture.bundle.path,
                        in: fixture.history,
                        homeDirectoryPath: "/Users/synthetic"
                    ),
                    monitoringObservationStatuses: StorageMonitoringObservationReview.make(
                        for: applicationReview.entries.map(\.path), in: fixture.history
                    ),
                    rememberedScopePaths: [fixture.bundle.path, fixture.dataPath],
                    monitoredScopePaths: [fixture.bundle.path],
                    monitoringSessionOpen: true
                )
                .frame(minWidth: 640, minHeight: 580)
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                DashboardView(
                    initialSection: request.includeSnapshotDiscoveredApplicationCandidate
                        ? "Applications" : request.section,
                    expandSavedApplicationHistory: true,
                    suppressSpotlightDiscovery: request.suppressSpotlightDiscovery,
                    expandFirstSavedApplicationForSnapshot: true,
                    includeSnapshotProjectCandidate: request.includeProjectCandidate,
                    initialProjectCandidateSearchText: request.projectCandidateSearchText,
                    initialProjectProfileRootPath: request.includeProjectProfile ? "/synthetic/QA/DemoProject" : nil,
                    includeSnapshotDiscoveredApplicationCandidate: request.includeSnapshotDiscoveredApplicationCandidate,
                    storeURLs: request.storeURLs
                )
            }
        }
        .frame(width: request.width, height: request.height)
        .environment(\.colorScheme, request.colorScheme)
        .task {
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            captureWhenReady(attempt: 0)
        }
    }

    private func applicationProfileFixture() -> (
        bundle: FolderObservation, dataPath: String, history: LocalHistory,
        discoveryRecord: ApplicationDiscoveryRecord
    ) {
        let observedAt = Date()
        let baselineAt = observedAt.addingTimeInterval(-86_400)
        let bundle = FolderObservation(
            path: "/synthetic/Applications/DemoApp.app",
            volumeDeviceID: 42,
            displayName: "Demo App",
            logicalBytes: 92_274_688,
            allocatedBytes: 96_468_992,
            fileCount: 142,
            inaccessibleCount: 0,
            finishedAt: observedAt,
            complete: true,
            applicationBundleIdentifier: "com.example.DemoApp",
            selectedAsApplicationBundle: true
        )
        let dataPath = "/synthetic/QA/DemoAppData"
        let data = FolderObservation(
            path: dataPath,
            volumeDeviceID: 42,
            displayName: "DemoAppData",
            logicalBytes: 12_582_912,
            allocatedBytes: 13_107_200,
            fileCount: 27,
            inaccessibleCount: 0,
            finishedAt: observedAt,
            complete: true
        )
        let baselineBundle = FolderObservation(
            path: bundle.path,
            volumeDeviceID: 42,
            displayName: bundle.displayName,
            logicalBytes: bundle.logicalBytes - 20_971_520,
            allocatedBytes: bundle.allocatedBytes - 22_020_096,
            fileCount: bundle.fileCount - 6,
            inaccessibleCount: 0,
            finishedAt: baselineAt,
            complete: true,
            applicationBundleIdentifier: bundle.applicationBundleIdentifier,
            selectedAsApplicationBundle: true
        )
        let baselineData = FolderObservation(
            path: data.path,
            volumeDeviceID: 42,
            displayName: data.displayName,
            logicalBytes: data.logicalBytes - 4_194_304,
            allocatedBytes: data.allocatedBytes - 4_456_448,
            fileCount: data.fileCount - 4,
            inaccessibleCount: 0,
            finishedAt: baselineAt,
            complete: true
        )
        let record = ApplicationDiscoveryRecord(
            path: bundle.path,
            displayName: bundle.displayName,
            firstSeenAt: observedAt.addingTimeInterval(-86_400 * 14),
            lastSeenAt: observedAt.addingTimeInterval(-120),
            launchServicesLastOpenedAt: observedAt.addingTimeInterval(-86_400 * 2)
        )
        let history = LocalHistory(
            observations: [
                ScanObservation(
                    startedAt: baselineAt,
                    finishedAt: baselineAt,
                    folders: [baselineBundle, baselineData],
                    cancelled: false
                ),
                ScanObservation(
                    startedAt: observedAt,
                    finishedAt: observedAt,
                    folders: [bundle, data],
                    cancelled: false
                ),
            ],
            applicationAssociations: [ApplicationFolderAssociation(
                bundlePath: bundle.path,
                bundleIdentifier: "com.example.DemoApp",
                relatedFolderPaths: [dataPath],
                updatedAt: observedAt
            )],
            discoveredApplications: [record]
        )
        return (bundle, dataPath, history, record)
    }

    private func databaseSidecarReviewFixture(
        partial: Bool,
        includeOmittedChange: Bool
    ) -> (folder: FolderObservation, review: DatabaseSidecarReview) {
        let observedAt = Date()
        let observationID = UUID(uuidString: "BBE6BA6B-0E1B-4B5F-91D8-846782F0779B")!
        let folder = FolderObservation(
            id: observationID,
            path: "/synthetic/QA/SQLiteProject",
            volumeDeviceID: 42,
            displayName: "SQLiteProject",
            logicalBytes: partial ? 13_107_200 : 96_894_976 + (includeOmittedChange ? 100 : 0),
            allocatedBytes: partial ? 13_107_200 : 93_110_272 + (includeOmittedChange ? 100 : 0),
            fileCount: partial ? 2 : 8 + (includeOmittedChange ? 100 : 0),
            inaccessibleCount: 0,
            finishedAt: observedAt,
            complete: !partial,
            excludedSymlinkCount: 1
        )
        let completeEntries = [
            FileInventoryEntry(relativePath: "data/events.sqlite", logicalBytes: 2_097_152, allocatedBytes: 1_900_544),
            FileInventoryEntry(relativePath: "data/events.sqlite-shm", logicalBytes: 32_768, allocatedBytes: 32_768),
            FileInventoryEntry(relativePath: "data/events.sqlite-wal", logicalBytes: 524_288, allocatedBytes: 516_096),
            FileInventoryEntry(relativePath: "data/orphan.sqlite3-wal", logicalBytes: 12_582_912, allocatedBytes: 12_582_912),
            FileInventoryEntry(relativePath: "runs/training.sqlite3", logicalBytes: 81_788_928, allocatedBytes: 78_643_200),
        ] + (includeOmittedChange ? (0..<99).map { index in
            FileInventoryEntry(
                relativePath: "growth/retained-\(index).dat", logicalBytes: 1, allocatedBytes: 1
            )
        } + [FileInventoryEntry(relativePath: "growth/omitted.dat", logicalBytes: 1, allocatedBytes: 1)] : [])
        let entries = partial
            ? completeEntries.filter { $0.relativePath.hasSuffix("-wal") }
            : completeEntries
        let snapshot = FileInventorySnapshot(
            rootPath: folder.path,
            folderObservationID: observationID,
            volumeDeviceID: folder.volumeDeviceID,
            observedAt: observedAt,
            entries: entries,
            complete: !partial,
            excludedSymlinkCount: 1
        )
        let walChange = FileInventoryChange(
            relativePath: "data/events.sqlite-wal", kind: .resized,
            logicalDelta: 262_144, allocatedDelta: 258_048,
            logicalBytes: 524_288, allocatedBytes: 516_096
        )
        let retainedChangeRows = includeOmittedChange
            ? [walChange] + (0..<99).map { index in
                FileInventoryChange(
                    relativePath: "growth/retained-\(index).dat", kind: .added,
                    logicalDelta: 1, allocatedDelta: 1, logicalBytes: 1, allocatedBytes: 1
                )
            }
            : [walChange]
        let walChangeReport: FileInventoryChangeSet? = partial ? nil : FileInventoryChangeSet(
            rootPath: folder.path,
            folderObservationID: observationID,
            previousObservedAt: observedAt.addingTimeInterval(-300),
            observedAt: observedAt,
            volumeDeviceID: folder.volumeDeviceID,
            changes: retainedChangeRows,
            changedPathCount: includeOmittedChange ? 101 : 1,
            omittedChangeCount: includeOmittedChange ? 1 : 0,
            netLogicalDelta: includeOmittedChange ? 262_243 : 262_144,
            netAllocatedDelta: includeOmittedChange ? 258_147 : 258_048,
            symlinkExcludedCount: 1,
            hasBaseline: true
        )
        return (folder, DatabaseSidecarReview.make(from: snapshot, fileChangeReport: walChangeReport))
    }

    @MainActor
    private func captureWhenReady(attempt: Int) {
        let largestWindow = NSApp.windows
            .filter({ $0.contentView != nil })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        guard let window = NSApp.keyWindow ?? largestWindow,
              let contentView = window.contentView else {
            retryOrFail(attempt: attempt, reason: "No native window is available to snapshot.")
            return
        }
        if let appearanceName = request.appearanceName {
            window.appearance = NSAppearance(named: appearanceName)
        }
        window.setContentSize(NSSize(width: request.width, height: request.height))
        contentView.frame = CGRect(origin: .zero, size: window.contentView?.frame.size ?? .zero)
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()
        guard contentView.bounds.width > 0, contentView.bounds.height > 0,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            retryOrFail(attempt: attempt, reason: "The native window has no drawable content bounds.")
            return
        }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            retryOrFail(attempt: attempt, reason: "AppKit could not encode the native window bitmap.")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: request.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: request.outputURL, options: .atomic)
            print("Disker snapshot saved: \(request.outputURL.path) (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh))")
            removeIsolatedSnapshotStore()
            NSApp.terminate(nil)
        } catch {
            retryOrFail(attempt: attempt, reason: "Snapshot write failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func retryOrFail(attempt: Int, reason: String) {
        guard attempt < 10 else {
            fputs("Disker snapshot failed: \(reason)\n", stderr)
            removeIsolatedSnapshotStore()
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            captureWhenReady(attempt: attempt + 1)
        }
    }

    private func removeIsolatedSnapshotStore() {
        let directory = request.storeURLs.observations.deletingLastPathComponent().standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        guard directory.deletingLastPathComponent().standardizedFileURL == temporaryDirectory,
              directory.lastPathComponent.hasPrefix("Disker-Offscreen-Snapshot-")
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
