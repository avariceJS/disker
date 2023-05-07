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
    let includeSnapshotDiscoveredApplicationCandidate: Bool
    let includeDatabaseSidecarReview: Bool
    let usePartialDatabaseSidecarFixture: Bool
    let useOmittedDatabaseChangeFixture: Bool

    static func from(arguments: [String]) -> DiskerSnapshotRequest? {
        guard let outputIndex = arguments.firstIndex(of: "--snapshot-output"),
              arguments.indices.contains(outputIndex + 1) else { return nil }
        let sectionIndex = arguments.firstIndex(of: "--snapshot-section")
        let appearanceIndex = arguments.firstIndex(of: "--snapshot-appearance")
        let suppressSpotlightDiscovery = !arguments.contains("--snapshot-enable-spotlight")
        let section = sectionIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            ?? "Overview"
        let includeProjectCandidate = arguments.contains("--snapshot-project-candidate")
        let includeSnapshotDiscoveredApplicationCandidate = arguments.contains("--snapshot-discovered-app-data")
        let includeDatabaseSidecarReview = arguments.contains("--snapshot-database-sidecars")
        let usePartialDatabaseSidecarFixture = arguments.contains("--snapshot-database-sidecars-partial")
        let useOmittedDatabaseChangeFixture = arguments.contains("--snapshot-database-sidecars-omitted")
        let appearance = appearanceIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let appearanceName: NSAppearance.Name?
        switch appearance?.lowercased() {
        case "light": appearanceName = .aqua
        case "dark": appearanceName = .darkAqua
        default: appearanceName = nil
        }
        return DiskerSnapshotRequest(
            outputURL: URL(fileURLWithPath: arguments[outputIndex + 1]),
            section: section,
            width: 1_280,
            height: includeProjectCandidate ? 1_200
                : includeSnapshotDiscoveredApplicationCandidate ? 1_400
                : includeDatabaseSidecarReview ? 540 : 900,
            appearanceName: appearanceName,
            suppressSpotlightDiscovery: suppressSpotlightDiscovery,
            includeProjectCandidate: includeProjectCandidate,
            includeSnapshotDiscoveredApplicationCandidate: includeSnapshotDiscoveredApplicationCandidate,
            includeDatabaseSidecarReview: includeDatabaseSidecarReview || usePartialDatabaseSidecarFixture
                || useOmittedDatabaseChangeFixture,
            usePartialDatabaseSidecarFixture: usePartialDatabaseSidecarFixture,
            useOmittedDatabaseChangeFixture: useOmittedDatabaseChangeFixture
        )
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
            } else {
                DashboardView(
                    initialSection: request.includeSnapshotDiscoveredApplicationCandidate
                        ? "Applications" : request.section,
                    expandSavedApplicationHistory: true,
                    suppressSpotlightDiscovery: request.suppressSpotlightDiscovery,
                    expandFirstSavedApplicationForSnapshot: true,
                    includeSnapshotProjectCandidate: request.includeProjectCandidate,
                    includeSnapshotDiscoveredApplicationCandidate: request.includeSnapshotDiscoveredApplicationCandidate
                )
            }
        }
        .frame(width: request.width, height: request.height)
        .task {
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            captureWhenReady(attempt: 0)
        }
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
            NSApp.terminate(nil)
        } catch {
            retryOrFail(attempt: attempt, reason: "Snapshot write failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func retryOrFail(attempt: Int, reason: String) {
        guard attempt < 10 else {
            fputs("Disker snapshot failed: \(reason)\n", stderr)
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            captureWhenReady(attempt: attempt + 1)
        }
    }
}
#endif
