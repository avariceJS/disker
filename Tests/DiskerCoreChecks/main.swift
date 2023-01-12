import DiskerCore
import Darwin
import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): message
        }
    }
}

@main
private struct DiskerCoreChecks {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--benchmark-root" {
            try benchmarkSelectedRoot(at: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }

        let checks: [(String, () throws -> Void)] = [
            ("capacity math", testCapacityMath),
            ("capacity clamping", testCapacityClamping),
            ("comparable capacity history", testCapacityHistoryComparison),
            ("explicit application bundle history index", testApplicationBundleIndex),
            ("explicit app-folder associations", testApplicationFolderAssociations),
            ("zero important-usage fallback", testImportantUsageFallback),
            ("live root volume capacity", testLiveCapacitySource),
            ("live RAM and process sample", testLiveRAMSample),
            ("cautious sustained process growth signal", testPossibleProcessGrowth),
            ("metadata scan and symlink exclusion", testMetadataScanAndSymlinkExclusion),
            ("selected-scope duplicate verification", testDuplicateVerification),
            ("duplicate verification cancellation", testDuplicateVerificationCancellation),
            ("duplicate directory mutation coverage", testDuplicateDirectoryMutationCoverage),
            ("nested directory usage summaries", testNestedDirectorySummaries),
            ("cautious development storage hints", testStorageAreaHints),
            ("Git metadata marker detection", testGitMetadataMarkerDetection),
            ("Git metadata footprint survives summary cap", testGitMetadataUsageSurvivesSummaryCap),
            ("selected symlink root is incomplete", testSelectedSymlinkRootIsIncomplete),
            ("hard-link deduplication", testHardLinkDeduplication),
            ("directory summary cap and stable order", testDirectorySummaryCap),
            ("old history JSON defaults new fields", testOldHistoryDecoding),
            ("sparse file size accounting", testSparseFileAccounting),
            ("missing root coverage", testMissingRootCoverage),
            ("immediate cancellation", testImmediateCancellation),
            ("history persistence and bounded retention", testHistoryPersistenceAndRetention),
            ("history reset is limited to its own file", testHistoryClearIsScoped),
            ("corrupt history fails closed and can be reset", testCorruptHistoryIsLeftUntouched),
            ("same-path complete history comparison", testSamePathCompleteHistoryComparison),
            ("same-root complete directory growth comparison", testDirectoryGrowthComparison),
            ("scan progress callback", testScanProgressCallback),
            ("directory mutations make coverage partial", testDirectoryMutationCoverage),
            ("cancellation preserves partial coverage", testCancellationPreservesPartialCoverage),
        ]

        for (name, check) in checks {
            try check()
            print("PASS  \(name)")
        }
        print("\(checks.count) core checks passed.")
    }

    private static func benchmarkSelectedRoot(at root: URL) throws {
        var before = rusage()
        _ = getrusage(RUSAGE_SELF, &before)
        let start = ContinuousClock.now
        let observation = FolderScanner.scan(roots: [root])
        let elapsed = start.duration(to: .now).components
        var after = rusage()
        _ = getrusage(RUSAGE_SELF, &after)

        guard let folder = observation.folders.first else {
            throw CheckFailure.assertion("benchmark scan produced no selected-root observation")
        }
        let userCPU = timevalSeconds(after.ru_utime) - timevalSeconds(before.ru_utime)
        let systemCPU = timevalSeconds(after.ru_stime) - timevalSeconds(before.ru_stime)
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        print("Selected-root metadata scan (no file contents): \(folder.fileCount) files")
        print("Elapsed: \(String(format: "%.3f", seconds)) s · process CPU: \(String(format: "%.3f", userCPU + systemCPU)) s")
        print("Logical: \(folder.logicalBytes) bytes · allocated estimate: \(folder.allocatedBytes) bytes")
        print("Coverage: \(folder.complete ? "complete" : "partial") · inaccessible: \(folder.inaccessibleCount) · symlinks excluded: \(folder.excludedSymlinkCount) · changed: \(folder.changedDuringScanCount)")
    }

    private static func timevalSeconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    private static func testCapacityMath() throws {
        let sample = CapacityObservation(totalBytes: 100, availableBytes: 35)
        try expect(sample.notAvailableBytes == 65, "not-available bytes should be total minus available")
    }

    private static func testCapacityClamping() throws {
        let sample = CapacityObservation(totalBytes: 100, availableBytes: 200)
        try expect(sample.availableBytes == 100, "available bytes should not exceed total capacity")
        try expect(sample.notAvailableBytes == 0, "not-available bytes should never be negative")
    }

    private static func testCapacityHistoryComparison() throws {
        let previous = CapacityObservation(
            observedAt: Date(timeIntervalSince1970: 100), totalBytes: 1_000,
            availableBytes: 700, availabilityBasis: .importantUsage
        )
        let current = CapacityObservation(
            observedAt: Date(timeIntervalSince1970: 200), totalBytes: 1_000,
            availableBytes: 650, availabilityBasis: .importantUsage
        )
        let history = LocalHistory(capacityObservations: [previous, current])
        try expect(ObservationComparison.comparableCapacitySeries(in: history) == [previous, current],
                   "capacity history should expose a comparable sequence")
        try expect(ObservationComparison.previousComparableCapacity(for: current, in: history) == previous,
                   "capacity history should find the preceding sample for the same volume size and method")
        try expect(ObservationComparison.availableCapacityDelta(current: current, previous: previous) == -50,
                   "available-capacity change should preserve its sign")
        let changedVolume = CapacityObservation(
            observedAt: current.observedAt, totalBytes: 2_000,
            availableBytes: 1_650, availabilityBasis: .importantUsage
        )
        try expect(ObservationComparison.availableCapacityDelta(current: changedVolume, previous: previous) == nil,
                   "a changed volume capacity must not be compared")
        let changedMethod = CapacityObservation(
            observedAt: current.observedAt, totalBytes: 1_000,
            availableBytes: 650, availabilityBasis: .standardVolume
        )
        try expect(ObservationComparison.availableCapacityDelta(current: changedMethod, previous: previous) == nil,
                   "different macOS availability methods must not be compared")
        let methodChangedHistory = LocalHistory(capacityObservations: [previous, current, changedMethod])
        try expect(ObservationComparison.comparableCapacitySeries(in: methodChangedHistory) == [changedMethod],
                   "capacity history chart data must start a new series after the API basis changes")
    }

    private static func testApplicationBundleIndex() throws {
        func folder(_ path: String, _ bytes: Int64, _ complete: Bool = true) -> FolderObservation {
            FolderObservation(
                path: path, displayName: URL(fileURLWithPath: path).lastPathComponent,
                logicalBytes: bytes, allocatedBytes: bytes, fileCount: 1,
                inaccessibleCount: 0, complete: complete
            )
        }
        let firstBundle = folder("/Applications/Example.app", 900)
        let laterBundle = folder("/Applications/Example.app", 500, false)
        let otherBundle = folder("/Applications/Other.app", 700)
        let notBundle = folder("/Projects/Example.app-cache", 10)
        let history = LocalHistory(observations: [
            ScanObservation(startedAt: Date(timeIntervalSince1970: 1), folders: [firstBundle, notBundle], cancelled: false),
            ScanObservation(startedAt: Date(timeIntervalSince1970: 2), folders: [laterBundle, otherBundle], cancelled: false)
        ])
        let indexed = ApplicationBundleIndex.latestMeasurements(in: history)
        try expect(indexed.count == 2, "the application index should include only selected .app root paths")
        try expect(indexed.first?.path == otherBundle.path && indexed.last?.path == laterBundle.path,
                   "latest bundle measurements should be sorted by allocated estimate")
        try expect(indexed.last?.complete == false && indexed.last?.allocatedBytes == 500,
                   "the latest partial observation should replace an older complete bundle measurement")
    }

    private static func testApplicationFolderAssociations() throws {
        try withTemporaryDirectory { root in
            let folder = root.appendingPathComponent("selected-support", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let sentinel = folder.appendingPathComponent("user-state.sqlite")
            let sentinelContents = Data("synthetic user state".utf8)
            try sentinelContents.write(to: sentinel)
            let fileURL = root.appendingPathComponent("Disker/observations.json")
            let bundlePath = "/Applications/Example.app"

            try ObservationStore.associateApplicationFolders(
                [folder.path, folder.path], with: bundlePath, to: fileURL
            )
            try ObservationStore.associateApplicationFolders(
                ["/synthetic/second-support"], with: bundlePath, to: fileURL
            )
            var history = try ObservationStore.load(from: fileURL)
            try expect(history.applicationAssociations.count == 1, "folder links should be grouped under the explicitly selected bundle path")
            try expect(history.applicationAssociations[0].relatedFolderPaths == [folder.path, "/synthetic/second-support"],
                       "associations should deduplicate exact paths and preserve selection order")

            history = try ObservationStore.removeApplicationFolderAssociation(folder.path, from: bundlePath, at: fileURL)
            try expect(history.applicationAssociations[0].relatedFolderPaths == ["/synthetic/second-support"],
                       "removing a link should remove only that relationship")
            let fileAfterAssociation = try Data(contentsOf: sentinel)
            try expect(fileAfterAssociation == sentinelContents,
                       "adding or removing a relationship must leave selected folder contents unchanged")

            let bounded = ApplicationFolderAssociation(
                bundlePath: bundlePath, relatedFolderPaths: (0..<60).map { "/synthetic/\($0)" }
            )
            try expect(bounded.relatedFolderPaths.count == 50,
                       "one app association should retain no more than 50 selected folder paths")
        }
    }

    private static func testImportantUsageFallback() throws {
        let resolved = CapacityObservation.resolvedAvailableCapacity(importantUsage: 0, standard: 42)
        try expect(resolved?.bytes == 42, "zero important-usage result should fall back to standard availability")
        try expect(resolved?.basis == .standardVolume, "fallback must identify the standard volume API")
        let negative = CapacityObservation.resolvedAvailableCapacity(importantUsage: -1, standard: 24)
        try expect(negative?.bytes == 24, "negative important-usage result should fall back to a valid standard value")
        try expect(CapacityObservation.resolvedAvailableCapacity(importantUsage: -1, standard: nil) == nil, "negative capacity values must not be presented as measurements")
    }

    private static func testLiveCapacitySource() throws {
        let sample = try CapacityObservation.current()
        try expect(sample.totalBytes > 0, "macOS should report nonzero root volume capacity")
        try expect(sample.availableBytes <= sample.totalBytes, "available capacity cannot exceed total")
        print("  / volume: total \(sample.totalBytes) bytes; available \(sample.availableBytes) bytes")
    }

    private static func testLiveRAMSample() throws {
        let sample = try RAMObservation.current(processLimit: 1)
        try expect(sample.physicalBytes > 0, "macOS should report installed physical RAM")
        try expect(sample.largestProcesses.count <= 1, "process list should respect its requested limit")
        try expect(sample.sampledProcessCount > 0, "process list should include accessible processes")
        print("  RAM: \(sample.physicalBytes) bytes; process list available: \(sample.processListAvailable); \(sample.sampledProcessCount) processes sampled")
    }

    private static func testPossibleProcessGrowth() throws {
        let processStart = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            ramObservation(at: 0, processStart: processStart, residentBytes: 50 * 1_048_576),
            ramObservation(at: 15 * 60, processStart: processStart, residentBytes: 100 * 1_048_576),
            ramObservation(at: 30 * 60, processStart: processStart, residentBytes: 220 * 1_048_576),
        ]
        let signals = ObservationComparison.possibleProcessGrowth(
            in: LocalHistory(ramObservations: samples)
        )
        try expect(signals.count == 1, "three consecutive samples over the minimum interval should expose a substantial sustained growth signal")
        try expect(signals[0].processID == 4242 && signals[0].growthBytes == 170 * 1_048_576, "the signal should report the same process and observed resident-size change")

        let reusedPID = ramObservation(
            at: 30 * 60,
            processStart: processStart.addingTimeInterval(1),
            residentBytes: 220 * 1_048_576
        )
        try expect(ObservationComparison.possibleProcessGrowth(
            in: LocalHistory(ramObservations: [samples[0], samples[1], reusedPID])
        ).isEmpty, "a reused PID with a different kernel start time must not be compared")

        let unavailable = RAMObservation(
            observedAt: Date(timeIntervalSince1970: 30 * 60), physicalBytes: 16_000,
            freeBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
            compressedBytes: 0, processListAvailable: false,
            sampledProcessCount: 0, unavailableProcessCount: 1,
            largestProcesses: samples[2].largestProcesses
        )
        try expect(ObservationComparison.possibleProcessGrowth(
            in: LocalHistory(ramObservations: [samples[0], samples[1], unavailable])
        ).isEmpty, "an unavailable process list must suppress growth signals")
        try expect(ObservationComparison.possibleProcessGrowth(
            in: LocalHistory(ramObservations: Array(samples.prefix(2)))
        ).isEmpty, "two short-interval samples must not look like sustained growth")
    }

    private static func testMetadataScanAndSymlinkExclusion() throws {
        try withTemporaryDirectory { root in
            let data = Data(repeating: 0x5A, count: 8192)
            try data.write(to: root.appendingPathComponent("payload.bin"))
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("Disker-outside-\(UUID().uuidString)")
            try Data(repeating: 0x11, count: 4096).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            let nested = root.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data(repeating: 0x2B, count: 1024).write(to: nested.appendingPathComponent("nested.bin"))
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("external-link"),
                withDestinationURL: outside
            )
            try FileManager.default.createSymbolicLink(
                at: nested.appendingPathComponent("loop"),
                withDestinationURL: root
            )

            let result = FolderScanner.scan(roots: [root])
            try expect(result.folders.count == 1, "one selected root should yield one result")
            try expect(result.folders[0].logicalBytes == Int64(data.count + 1024), "nested files should count while symlink targets remain excluded")
            try expect(result.folders[0].fileCount == 2, "both regular files should be counted once")
            try expect(result.folders[0].excludedSymlinkCount == 2, "root coverage should count nested symlinks separately")
            try expect(result.folders[0].inaccessibleCount == 0, "excluded symlinks should not inflate access errors")
            try expect(!result.folders[0].complete, "excluded symlink targets should make coverage explicitly partial")
            let nestedSummary = try requireSummary("nested", in: result.folders[0])
            try expect(nestedSummary.logicalBytes == 1024, "nested summary should include its measured descendant files")
            try expect(nestedSummary.excludedSymlinkCount == 1, "nested summary should report its own excluded symlink")
            try expect(!nestedSummary.complete, "a subtree with an excluded symlink should not look fully measured")
        }
    }

    private static func testDuplicateVerification() throws {
        try withTemporaryDirectory { root in
            let first = root.appendingPathComponent("first.bin")
            let second = root.appendingPathComponent("second.bin")
            let different = root.appendingPathComponent("different.bin")
            let unique = root.appendingPathComponent("unique.bin")
            let sharedBytes = Data("same synthetic bytes".utf8)
            try sharedBytes.write(to: first)
            try sharedBytes.write(to: second)
            try Data("other synthetic data".utf8).write(to: different)
            try Data("short".utf8).write(to: unique)
            try FileManager.default.linkItem(at: first, to: root.appendingPathComponent("z-hard-link.bin"))
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("alias.bin"), withDestinationURL: first
            )

            var lastProgress: DuplicateVerificationProgress?
            let result = DuplicateVerifier.verify(roots: [root], progress: { lastProgress = $0 })
            try expect(result.groups.count == 1, "only byte-identical same-size files should form a duplicate group")
            try expect(result.groups[0].files.map(\.path) == [first.path, second.path], "hard-link aliases should not be reported as separate files")
            try expect(result.groups[0].files.allSatisfy { $0.logicalBytes == UInt64(sharedBytes.count) }, "duplicate candidates should retain exact logical sizes")
            try expect(result.checkedFileCount == 3, "only regular files in shared-size buckets should be hashed")
            try expect(result.excludedSymlinkCount == 1 && !result.complete, "symlinks should remain excluded and make verification coverage partial")
            try expect(lastProgress?.bytesHashed == UInt64(sharedBytes.count * 3), "progress should report bytes actually read from size-matched candidates")
            let firstAfterVerification = try Data(contentsOf: first)
            let secondAfterVerification = try Data(contentsOf: second)
            try expect(firstAfterVerification == sharedBytes && secondAfterVerification == sharedBytes, "verification must leave all selected files unchanged")

            let group = result.groups[0]
            let plan = try CleanupPlanner.makePlan(
                from: result, preserving: [group.sha256: first.path]
            )
            try expect(plan.entries.count == 1 && plan.entries[0].targetPath == second.path, "a dry-run plan should list only exact non-preserved paths")
            try expect(plan.entries[0].preservedPath == first.path && plan.entries[0].verifiedSHA256 == group.sha256, "each proposed action should carry its chosen keeper and content evidence")
            try expect(plan.entries[0].reclaimableBytes == nil && plan.entries[0].risk == .unknown, "duplicate equality must not invent reclaimed bytes or low risk")
            try expect(!plan.sourceCoverageComplete && plan.selectedRootPaths == [root.path], "the plan should preserve its partial-scope provenance")
            let firstAfterPlan = try Data(contentsOf: first)
            let secondAfterPlan = try Data(contentsOf: second)
            try expect(firstAfterPlan == sharedBytes && secondAfterPlan == sharedBytes, "generating a dry-run plan must not alter selected files")

            do {
                _ = try CleanupPlanner.makePlan(from: result, preserving: [group.sha256: unique.path])
                throw CheckFailure.assertion("cleanup planning should reject a keeper outside the verified group")
            } catch CleanupPlanError.keeperNotInVerifiedGroup { }

            let outside = root.deletingLastPathComponent().appendingPathComponent("outside.bin")
            try sharedBytes.write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            let unscopedGroup = DuplicateGroup(sha256: group.sha256, files: [
                group.files[0], DuplicateFile(
                    path: outside.path, logicalBytes: UInt64(sharedBytes.count), allocatedBytes: 4096
                )
            ])
            let unscopedResult = DuplicateVerificationResult(
                selectedRootPaths: [root.path], groups: [unscopedGroup], checkedFileCount: 2,
                inaccessibleCount: 0, excludedSymlinkCount: 0,
                excludedSpecialFileCount: 0, changedDuringCheckCount: 0, cancelled: false
            )
            do {
                _ = try CleanupPlanner.makePlan(
                    from: unscopedResult, preserving: [group.sha256: first.path]
                )
                throw CheckFailure.assertion("cleanup planning should reject paths outside the selected scope")
            } catch CleanupPlanError.pathOutsideSelectedScope { }
            let outsideAfterPlan = try Data(contentsOf: outside)
            try expect(outsideAfterPlan == sharedBytes, "rejected out-of-scope plans must leave files unchanged")
        }
    }

    private static func testDuplicateVerificationCancellation() throws {
        try withTemporaryDirectory { root in
            try Data("synthetic bytes".utf8).write(to: root.appendingPathComponent("one.bin"))
            try Data("synthetic bytes".utf8).write(to: root.appendingPathComponent("two.bin"))
            let result = DuplicateVerifier.verify(roots: [root], shouldCancel: { true })
            try expect(result.cancelled && !result.complete, "cancelled duplicate verification must stay explicitly incomplete")
            try expect(result.groups.isEmpty && result.checkedFileCount == 0, "immediate cancellation must not read or report file content")
        }
    }

    private static func testDuplicateDirectoryMutationCoverage() throws {
        try withTemporaryDirectory { root in
            let data = Data("synthetic same-size candidate".utf8)
            try data.write(to: root.appendingPathComponent("first.bin"))
            try data.write(to: root.appendingPathComponent("second.bin"))
            var mutated = false
            let result = DuplicateVerifier.verify(roots: [root], progress: { _ in
                guard !mutated else { return }
                mutated = true
                try? Data("created after enumeration".utf8)
                    .write(to: root.appendingPathComponent("late-file.bin"))
            })
            try expect(mutated, "the verification progress checkpoint should run after candidate hashing")
            try expect(result.changedDuringCheckCount > 0 && !result.complete, "a directory entry change during hashing must make final coverage partial")
            try expect(result.groups.count == 1, "already verified groups may be retained alongside an explicit partial-coverage result")
        }
    }

    private static func testNestedDirectorySummaries() throws {
        try withTemporaryDirectory { root in
            let first = root.appendingPathComponent("alpha", isDirectory: true)
            let second = first.appendingPathComponent("deep", isDirectory: true)
            let sibling = root.appendingPathComponent("beta", isDirectory: true)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            try Data(repeating: 0x31, count: 1200).write(to: first.appendingPathComponent("one.bin"))
            try Data(repeating: 0x32, count: 800).write(to: second.appendingPathComponent("two.bin"))
            try Data(repeating: 0x33, count: 500).write(to: sibling.appendingPathComponent("three.bin"))

            let folder = FolderScanner.scan(roots: [root]).folders[0]
            let alpha = try requireSummary("alpha", in: folder)
            let deep = try requireSummary("alpha/deep", in: folder)
            let beta = try requireSummary("beta", in: folder)
            try expect(folder.logicalBytes == 2500 && folder.fileCount == 3, "root totals must include each distinct file object")
            try expect(alpha.logicalBytes == 2000 && alpha.fileCount == 2, "parent subtree must include nested descendants")
            try expect(deep.logicalBytes == 800 && deep.fileCount == 1, "deep subtree should include only its own descendant")
            try expect(beta.logicalBytes == 500 && beta.fileCount == 1, "sibling subtree should remain independent")
            try expect(alpha.complete && deep.complete && beta.complete, "fully enumerated subtrees should be complete")
        }
    }

    private static func testStorageAreaHints() throws {
        try expect(StorageAreaHint.matching(relativePath: "Packages/App/.build/debug") == .swiftPackageBuild,
                   "Swift build products should be recognized by an exact path component")
        try expect(StorageAreaHint.matching(relativePath: "Library/Developer/Xcode/DerivedData/App") == .xcodeDerivedData,
                   "Xcode derived data should be recognized in a nested selected scope")
        try expect(StorageAreaHint.matching(relativePath: "frontend/node_modules/react") == .javascriptDependencies,
                   "JavaScript dependency trees should be recognized by their exact name")
        try expect(StorageAreaHint.matching(relativePath: "project/.venv/lib") == .pythonEnvironment,
                   "Python environments should be recognized without inspecting their contents")
        try expect(StorageAreaHint.matching(relativePath: "project/node_modules_backup") == nil,
                   "similar but non-exact names must not be classified")
        try expect(StorageAreaHint.matching(relativePath: "project/output") == nil,
                   "unrecognized directory names must remain unclassified")
        try expect(StorageAreaHint.matching(relativePath: "project/.git/objects") == nil,
                   "Git metadata should keep its dedicated marker and footprint presentation")
    }

    private static func testGitMetadataMarkerDetection() throws {
        try withTemporaryDirectory { root in
            let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
            try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: false)
            try Data("synthetic marker data".utf8).write(to: gitDirectory.appendingPathComponent("HEAD"))

            let nestedProject = root.appendingPathComponent("vendor/project", isDirectory: true)
            try FileManager.default.createDirectory(at: nestedProject, withIntermediateDirectories: true)
            try Data("gitdir: ../.git/worktrees/project".utf8)
                .write(to: nestedProject.appendingPathComponent(".git"))

            let folder = FolderScanner.scan(roots: [root]).folders[0]
            try expect(folder.gitMetadataEntryDetected, "a direct .git marker should label the selected root as a likely project scope")
            let gitUsage = folder.gitMetadataUsage
            try expect(gitUsage?.rootRelativePath == ".git", "a direct .git directory should have its own selected-root-relative measurement")
            try expect(gitUsage?.logicalBytes == 21 && gitUsage?.fileCount == 1, "Git metadata metrics should come from directory entries without parsing their contents")
            let vendor = try requireSummary("vendor", in: folder)
            let nested = try requireSummary("vendor/project", in: folder)
            try expect(!vendor.gitMetadataEntryDetected, "a nested project's marker must not be attributed to its ancestor")
            try expect(nested.gitMetadataEntryDetected, "a .git file marker should identify its immediate containing directory")
            try expect(folder.logicalBytes > 0, "metadata scan should count marker file size without parsing its contents")
            let selectedGitFile = FolderScanner.scan(roots: [nestedProject]).folders[0]
            try expect(selectedGitFile.gitMetadataEntryDetected && selectedGitFile.gitMetadataUsage == nil, "a direct .git file is a marker only, with no payload or external path resolution")

            let symlinkRoot = root.appendingPathComponent("symlink-project", isDirectory: true)
            try FileManager.default.createDirectory(at: symlinkRoot, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: symlinkRoot.appendingPathComponent(".git"),
                withDestinationURL: gitDirectory
            )
            let selectedSymlinkMarker = FolderScanner.scan(roots: [symlinkRoot]).folders[0]
            try expect(!selectedSymlinkMarker.gitMetadataEntryDetected && selectedSymlinkMarker.gitMetadataUsage == nil, "a .git symlink must not be followed or attributed")
            try expect(selectedSymlinkMarker.excludedSymlinkCount == 1 && !selectedSymlinkMarker.complete, "a .git symlink should remain visible as partial coverage")
        }
    }

    private static func testGitMetadataUsageSurvivesSummaryCap() throws {
        try withTemporaryDirectory { root in
            let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
            try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: false)
            try Data().write(to: gitDirectory.appendingPathComponent("HEAD"))
            for index in 0..<101 {
                let directory = root.appendingPathComponent(String(format: "large-%03d", index), isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try Data(repeating: 0x47, count: 8192).write(to: directory.appendingPathComponent("payload.bin"))
            }
            let folder = FolderScanner.scan(roots: [root]).folders[0]
            try expect(folder.subdirectorySummaries.count == 100 && folder.subdirectorySummariesTruncated, "the ordinary leaderboard should remain capped at 100 entries")
            try expect(!folder.subdirectorySummaries.contains(where: { $0.rootRelativePath == ".git" }), "small Git metadata may fall below the largest-folder cutoff")
            try expect(folder.gitMetadataUsage?.logicalBytes == 0, "the direct Git metadata measurement should survive outside the capped leaderboard")
        }
    }

    private static func testHardLinkDeduplication() throws {
        try withTemporaryDirectory { root in
            let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
            let originalDirectory = root.appendingPathComponent("original", isDirectory: true)
            try FileManager.default.createDirectory(at: linkedDirectory, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: false)
            let file = originalDirectory.appendingPathComponent("payload.bin")
            try Data(repeating: 0x7F, count: 2048).write(to: file)
            try FileManager.default.linkItem(at: file, to: linkedDirectory.appendingPathComponent("payload.bin"))

            let result = FolderScanner.scan(roots: [root])
            try expect(result.folders[0].logicalBytes == 2048, "hard links must not double-count logical bytes")
            try expect(result.folders[0].fileCount == 1, "hard links must identify one file object")
            let directory = try requireSummary("linked", in: result.folders[0])
            try expect(directory.logicalBytes == 2048 && directory.fileCount == 1, "lexicographically first hard-link path should deterministically own subtree bytes")
            let original = try requireSummary("original", in: result.folders[0])
            try expect(original.logicalBytes == 0 && original.fileCount == 0, "later hard-link path must not duplicate subtree bytes")
        }
    }

    private static func testDirectorySummaryCap() throws {
        try withTemporaryDirectory { root in
            for index in 0..<105 {
                let directory = root.appendingPathComponent(String(format: "dir-%03d", index), isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try Data([UInt8(index % 255)]).write(to: directory.appendingPathComponent("payload.bin"))
            }
            let folder = FolderScanner.scan(roots: [root]).folders[0]
            try expect(folder.subdirectorySummaries.count == 100, "only the 100 largest subdirectories should be persisted")
            try expect(folder.subdirectorySummariesTruncated, "folder must expose summary truncation")
            let paths = folder.subdirectorySummaries.map(\.rootRelativePath)
            try expect(paths == paths.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }), "equal-size summaries should have stable UTF-8 path ordering")
            try expect(paths.first == "dir-000" && paths.last == "dir-099", "stable tie-break should retain the first 100 equal-size paths")
        }
    }

    private static func testOldHistoryDecoding() throws {
        let json = #"{"observations":[{"id":"00000000-0000-0000-0000-000000000001","startedAt":1,"finishedAt":2,"cancelled":false,"folders":[{"id":"00000000-0000-0000-0000-000000000002","path":"/synthetic","displayName":"synthetic","logicalBytes":50,"allocatedBytes":40,"fileCount":1,"inaccessibleCount":0,"finishedAt":2,"complete":true,"subdirectorySummaries":[{"rootRelativePath":"child","logicalBytes":1,"allocatedBytes":1,"fileCount":1,"incompleteCount":0,"excludedSymlinkCount":0,"complete":true}]}]}]}"#
        let history = try JSONDecoder().decode(LocalHistory.self, from: Data(json.utf8))
        guard let folder = history.observations.first?.folders.first else {
            throw CheckFailure.assertion("old history JSON should decode one folder")
        }
        try expect(folder.excludedSymlinkCount == 0, "old folder history should default symlink count to zero")
        try expect(folder.changedDuringScanCount == 0, "old folder history should default mutation count to zero")
        try expect(!folder.gitMetadataEntryDetected, "old folder history should default Git marker state to false")
        try expect(folder.gitMetadataUsage == nil, "old folder history should default retained Git metrics to absent")
        try expect(history.ramObservations.isEmpty, "old folder history should default manual RAM history to empty")
        try expect(history.capacityObservations.isEmpty, "old history should default capacity observations to empty")
        try expect(history.applicationAssociations.isEmpty, "old history should default application associations to empty")
        try expect(folder.subdirectorySummaries.count == 1, "old folder history should preserve existing directory summaries")
        try expect(folder.subdirectorySummaries[0].changedDuringScanCount == 0, "old directory summaries should default mutation count to zero")
        try expect(!folder.subdirectorySummaries[0].gitMetadataEntryDetected, "old directory summaries should default Git marker state to false")
        try expect(!folder.subdirectorySummariesTruncated, "old folder history should default truncation to false")

        let oldProcessJSON = #"{"processID":123,"name":"OldSample","residentBytes":4096}"#
        let oldProcess = try JSONDecoder().decode(ProcessRAMSample.self, from: Data(oldProcessJSON.utf8))
        try expect(oldProcess.processStartTime == nil, "old process samples without a start time should remain readable but ineligible for PID-safe trends")
    }

    private static func testSparseFileAccounting() throws {
        try withTemporaryDirectory { root in
            let sparseURL = root.appendingPathComponent("sparse.bin")
            let descriptor = sparseURL.path.withCString {
                open($0, O_CREAT | O_WRONLY | O_TRUNC, S_IRUSR | S_IWUSR)
            }
            try expect(descriptor >= 0, "synthetic sparse file should be created")
            let logicalSize: off_t = 64 * 1024 * 1024
            let truncateResult = ftruncate(descriptor, logicalSize)
            close(descriptor)
            try expect(truncateResult == 0, "synthetic sparse file should be extended without writing contents")

            let result = FolderScanner.scan(roots: [root])
            try expect(result.folders[0].logicalBytes == Int64(logicalSize), "logical accounting should include sparse file length")
            try expect(result.folders[0].allocatedBytes < result.folders[0].logicalBytes, "allocated estimate should distinguish unallocated sparse regions")
        }
    }

    private static func testSelectedSymlinkRootIsIncomplete() throws {
        try withTemporaryDirectory { root in
            let target = root.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data(repeating: 0x3A, count: 512).write(to: target.appendingPathComponent("payload.bin"))
            let selectedLink = root.appendingPathComponent("selected-link")
            try FileManager.default.createSymbolicLink(at: selectedLink, withDestinationURL: target)

            let result = FolderScanner.scan(roots: [selectedLink])
            try expect(result.folders[0].logicalBytes == 0, "selected symlink target must not be measured")
            try expect(!result.folders[0].complete, "selected symlink must not appear as a complete zero-byte scan")
            try expect(result.folders[0].inaccessibleCount == 0, "excluded symlink root should not look like a metadata access failure")
            try expect(result.folders[0].excludedSymlinkCount == 1, "selected symlink root should be separately counted")
        }
    }

    private static func testMissingRootCoverage() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskerMissing-\(UUID().uuidString)")
        let result = FolderScanner.scan(roots: [path])
        try expect(result.folders[0].logicalBytes == 0, "missing root has no measured bytes")
        try expect(!result.folders[0].complete, "missing root must be marked incomplete")
        try expect(result.folders[0].inaccessibleCount == 1, "missing root must count an access failure")
    }

    private static func testImmediateCancellation() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskerCancelled-\(UUID().uuidString)", isDirectory: true)
        let result = FolderScanner.scan(roots: [path], shouldCancel: { true })
        try expect(result.cancelled, "cancellation must be recorded")
        try expect(result.folders.isEmpty, "cancelled scan must not report an unvisited root as measured")
    }

    private static func testHistoryPersistenceAndRetention() throws {
        try withTemporaryDirectory { root in
            let fileURL = root.appendingPathComponent("nested/history.json")
            let firstID = UUID()
            var latestID = UUID()
            for index in 0...180 {
                let id = index == 0 ? firstID : UUID()
                latestID = id
                let folder = FolderObservation(
                    path: "/synthetic", displayName: "synthetic",
                    logicalBytes: Int64(index), allocatedBytes: Int64(index),
                    fileCount: 1, inaccessibleCount: 0, complete: index != 180
                )
                let observation = ScanObservation(
                    id: id, startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    folders: [folder], cancelled: index == 180
                )
                try ObservationStore.append(observation, to: fileURL)
            }

            let reloaded = try ObservationStore.load(from: fileURL)
            try expect(reloaded.observations.count == 180, "history should retain at most 180 observations")
            try expect(!reloaded.observations.contains(where: { $0.id == firstID }), "oldest observation should be evicted at the retention bound")
            try expect(reloaded.observations.last?.id == latestID, "newest observation should survive a restart")
            try expect(reloaded.observations.last?.cancelled == true, "cancelled scan status should persist")
            try expect(reloaded.observations.last?.folders.first?.complete == false, "incomplete folder coverage should persist")
            for index in 0...180 {
                try ObservationStore.append(ramSample(at: TimeInterval(index)), to: fileURL)
            }
            let withRAMHistory = try ObservationStore.load(from: fileURL)
            try expect(withRAMHistory.ramObservations.count == 180, "manual RAM history should retain at most 180 samples")
            try expect(withRAMHistory.ramObservations.first?.observedAt == Date(timeIntervalSince1970: 1), "RAM history should evict only the oldest samples")
            try expect(withRAMHistory.observations.count == 180, "saving RAM samples must preserve folder history")
            try ObservationStore.append(
                ScanObservation(startedAt: .now, folders: [], cancelled: false), to: fileURL
            )
            let afterFolderAppend = try ObservationStore.load(from: fileURL)
            try expect(afterFolderAppend.ramObservations.count == 180, "saving folder scans must preserve manual RAM history")
            for index in 0...180 {
                try ObservationStore.append(CapacityObservation(
                    observedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    totalBytes: 1_000, availableBytes: Int64(900 - index),
                    availabilityBasis: .standardVolume
                ), to: fileURL)
            }
            let withCapacityHistory = try ObservationStore.load(from: fileURL)
            try expect(withCapacityHistory.capacityObservations.count == 180, "capacity history should retain at most 180 samples")
            try expect(withCapacityHistory.capacityObservations.first?.availableBytes == 899, "capacity history should evict only its oldest samples")
            try expect(withCapacityHistory.capacityObservations.last?.availableBytes == 720, "latest capacity sample should survive reload")
            try expect(withCapacityHistory.ramObservations.count == 180 && withCapacityHistory.observations.count == 180,
                       "capacity samples should preserve folder and RAM history")
        }
    }

    private static func testCorruptHistoryIsLeftUntouched() throws {
        try withTemporaryDirectory { root in
            let fileURL = root.appendingPathComponent("history.json")
            let corruptData = Data("{not valid json".utf8)
            try corruptData.write(to: fileURL)
            do {
                _ = try ObservationStore.append(
                    ScanObservation(startedAt: .now, folders: [], cancelled: false),
                    to: fileURL
                )
                throw CheckFailure.assertion("append should fail closed for corrupt history")
            } catch is HistoryDecodeError {
                let persistedData = try Data(contentsOf: fileURL)
                try expect(persistedData == corruptData, "corrupt history must remain unchanged")
                try ObservationStore.clear(at: fileURL)
                let reset = try ObservationStore.load(from: fileURL)
                try expect(reset.observations.isEmpty, "explicit history reset should recover from a corrupt store")
            }
        }
    }

    private static func testHistoryClearIsScoped() throws {
        try withTemporaryDirectory { root in
            let fileURL = root.appendingPathComponent("nested/history.json")
            let neighboringFile = root.appendingPathComponent("user-file.txt")
            let sentinel = Data("synthetic user file stays intact".utf8)
            try sentinel.write(to: neighboringFile)
            let observation = ScanObservation(
                startedAt: .now,
                folders: [syntheticFolder(path: "/synthetic", bytes: 100, complete: true)],
                cancelled: false
            )
            try ObservationStore.append(observation, to: fileURL)
            try ObservationStore.append(ramSample(at: 1), to: fileURL)
            try ObservationStore.associateApplicationFolders(
                ["/synthetic/support"], with: "/synthetic/Test.app", to: fileURL
            )

            try ObservationStore.clear(at: fileURL)
            try ObservationStore.clear(at: fileURL)
            let reloaded = try ObservationStore.load(from: fileURL)
            try expect(reloaded.observations.isEmpty, "clearing history should leave an empty store")
            try expect(reloaded.ramObservations.isEmpty, "clearing local history should clear manual RAM samples too")
            try expect(reloaded.applicationAssociations.isEmpty, "clearing local history should clear app-folder associations")
            let preservedNeighbor = try Data(contentsOf: neighboringFile)
            try expect(preservedNeighbor == sentinel, "history reset must not remove neighboring files")
        }
    }

    private static func testSamePathCompleteHistoryComparison() throws {
        let earlierComplete = syntheticFolder(path: "/selected", bytes: 100, complete: true)
        let laterIncomplete = syntheticFolder(path: "/selected", bytes: 900, complete: false)
        let current = syntheticFolder(path: "/selected", bytes: 135, complete: true)
        let future = syntheticFolder(path: "/selected", bytes: 1_000, complete: true)
        let history = LocalHistory(observations: [
            ScanObservation(startedAt: .now, folders: [earlierComplete], cancelled: false),
            ScanObservation(startedAt: .now, folders: [laterIncomplete], cancelled: true),
            ScanObservation(startedAt: .now, folders: [current], cancelled: false),
            ScanObservation(startedAt: .now, folders: [future], cancelled: false),
        ])

        let previous = ObservationComparison.previousCompleteFolder(for: current, in: history)
        try expect(previous?.id == earlierComplete.id, "comparison should skip incomplete scans and never use future observations")
        try expect(ObservationComparison.completeFolderSeries(for: current, in: history).map(\.id) == [earlierComplete.id, current.id],
                   "folder history series should include only earlier complete scans of the same path")
        try expect(ObservationComparison.allocatedByteDelta(current: current, previous: earlierComplete) == 35, "allocated-size delta should use the matching complete path")
        let otherPath = syntheticFolder(path: "/other", bytes: 135, complete: true)
        try expect(ObservationComparison.allocatedByteDelta(current: current, previous: otherPath) == nil, "different paths must not be compared")
        try expect(ObservationComparison.previousCompleteFolder(for: laterIncomplete, in: history) == nil, "incomplete current observations must not produce a growth comparison")
        try expect(ObservationComparison.completeFolderSeries(for: laterIncomplete, in: history).isEmpty,
                   "an incomplete current observation must not be plotted as a complete growth series")
    }

    private static func testDirectoryGrowthComparison() throws {
        let earlier = folderWithDirectory(
            id: UUID(), path: "/selected", bytes: 300, complete: true,
            directory: directory("Projects/Example", bytes: 100, complete: true)
        )
        let otherRoot = folderWithDirectory(
            id: UUID(), path: "/different", bytes: 500, complete: true,
            directory: directory("Projects/Example", bytes: 900, complete: true)
        )
        let incompletePrior = folderWithDirectory(
            id: UUID(), path: "/selected", bytes: 900, complete: false,
            directory: directory("Projects/Example", bytes: 800, complete: false)
        )
        let current = folderWithDirectory(
            id: UUID(), path: "/selected", bytes: 350, complete: true,
            directory: directory("Projects/Example", bytes: 125, complete: true)
        )
        let future = folderWithDirectory(
            id: UUID(), path: "/selected", bytes: 700, complete: true,
            directory: directory("Projects/Example", bytes: 1_000, complete: true)
        )
        let history = LocalHistory(observations: [
            ScanObservation(startedAt: .now, folders: [earlier], cancelled: false),
            ScanObservation(startedAt: .now, folders: [otherRoot], cancelled: false),
            ScanObservation(startedAt: .now, folders: [incompletePrior], cancelled: true),
            ScanObservation(startedAt: .now, folders: [current], cancelled: false),
            ScanObservation(startedAt: .now, folders: [future], cancelled: false),
        ])

        let currentDirectory = try requireSummary("Projects/Example", in: current)
        let previous = ObservationComparison.previousCompleteDirectory(
            for: currentDirectory, in: current, history: history
        )
        try expect(previous?.allocatedBytes == 100, "directory comparison should use the prior complete same-root summary, skipping partial and different-root scans")
        if let previous {
            try expect(ObservationComparison.allocatedByteDelta(current: currentDirectory, previous: previous) == 25, "directory growth should compare allocated estimates")
        }
        let changedPath = directory("Projects/Other", bytes: 100, complete: true)
        try expect(ObservationComparison.allocatedByteDelta(current: currentDirectory, previous: changedPath) == nil, "different relative subfolder paths must not be compared")

        let partialCurrent = directory("Projects/Example", bytes: 999, complete: false)
        try expect(ObservationComparison.previousCompleteDirectory(for: partialCurrent, in: current, history: history) == nil, "partial current directory coverage must not yield a growth signal")
        let earlierGitFolder = folderWithGitMetadata(id: UUID(), path: "/selected", bytes: 50, complete: true)
        let currentGitFolder = folderWithGitMetadata(id: UUID(), path: "/selected", bytes: 75, complete: true)
        let laterGitFolder = folderWithGitMetadata(id: UUID(), path: "/selected", bytes: 999, complete: true)
        let gitHistory = LocalHistory(observations: [
            ScanObservation(startedAt: .now, folders: [earlierGitFolder], cancelled: false),
            ScanObservation(startedAt: .now, folders: [currentGitFolder], cancelled: false),
            ScanObservation(startedAt: .now, folders: [laterGitFolder], cancelled: false),
        ])
        let currentGitUsage = currentGitFolder.gitMetadataUsage!
        let previousGitUsage = ObservationComparison.previousCompleteDirectory(
            for: currentGitUsage, in: currentGitFolder, history: gitHistory
        )
        try expect(previousGitUsage?.allocatedBytes == 50, "retained Git metrics should compare same-root, prior complete component measurements")
        try expect(ObservationComparison.allocatedByteDelta(current: currentGitUsage, previous: previousGitUsage!) == 25, "retained Git metrics should expose their allocated-estimate delta")
        let partialGitFolder = folderWithGitMetadata(id: UUID(), path: "/selected", bytes: 100, complete: false)
        try expect(ObservationComparison.previousCompleteDirectory(
            for: partialGitFolder.gitMetadataUsage!, in: partialGitFolder,
            history: LocalHistory(observations: gitHistory.observations + [
                ScanObservation(startedAt: .now, folders: [partialGitFolder], cancelled: true)
            ])
        ) == nil, "partial root coverage must suppress Git component growth comparisons")
        let partialFolder = folderWithDirectory(
            id: UUID(), path: "/selected", bytes: 400, complete: false,
            directory: directory("Projects/Example", bytes: 125, complete: true)
        )
        let partialHistory = LocalHistory(observations: history.observations + [
            ScanObservation(startedAt: .now, folders: [partialFolder], cancelled: true)
        ])
        try expect(ObservationComparison.previousCompleteDirectory(
            for: partialFolder.subdirectorySummaries[0], in: partialFolder, history: partialHistory
        ) == nil, "partial root observations must not be compared even if a subtree summary appears complete")
    }

    private static func folderWithDirectory(
        id: UUID, path: String, bytes: Int64, complete: Bool, directory: DirectoryUsage
    ) -> FolderObservation {
        FolderObservation(
            id: id, path: path, displayName: URL(fileURLWithPath: path).lastPathComponent,
            logicalBytes: bytes, allocatedBytes: bytes, fileCount: 1,
            inaccessibleCount: complete ? 0 : 1, complete: complete,
            subdirectorySummaries: [directory]
        )
    }

    private static func directory(_ path: String, bytes: Int64, complete: Bool) -> DirectoryUsage {
        DirectoryUsage(
            rootRelativePath: path, logicalBytes: bytes, allocatedBytes: bytes,
            fileCount: 1, incompleteCount: complete ? 0 : 1,
            excludedSymlinkCount: 0, complete: complete
        )
    }

    private static func folderWithGitMetadata(
        id: UUID, path: String, bytes: Int64, complete: Bool
    ) -> FolderObservation {
        FolderObservation(
            id: id, path: path, displayName: URL(fileURLWithPath: path).lastPathComponent,
            logicalBytes: bytes, allocatedBytes: bytes, fileCount: 1,
            inaccessibleCount: complete ? 0 : 1, complete: complete,
            gitMetadataEntryDetected: true,
            gitMetadataUsage: directory(".git", bytes: bytes, complete: complete)
        )
    }

    private static func syntheticFolder(path: String, bytes: Int64, complete: Bool) -> FolderObservation {
        FolderObservation(
            path: path, displayName: URL(fileURLWithPath: path).lastPathComponent,
            logicalBytes: bytes, allocatedBytes: bytes, fileCount: 1,
            inaccessibleCount: complete ? 0 : 1, complete: complete
        )
    }

    private static func ramSample(at timestamp: TimeInterval) -> RAMObservation {
        RAMObservation(
            observedAt: Date(timeIntervalSince1970: timestamp), physicalBytes: 16_000,
            freeBytes: 2_000, activeBytes: 4_000, inactiveBytes: 3_000,
            wiredBytes: 2_000, compressedBytes: 1_000,
            processListAvailable: true, sampledProcessCount: 0,
            unavailableProcessCount: 0, largestProcesses: []
        )
    }

    private static func ramObservation(
        at timestamp: TimeInterval, processStart: Date, residentBytes: UInt64
    ) -> RAMObservation {
        RAMObservation(
            observedAt: Date(timeIntervalSince1970: timestamp), physicalBytes: 16_000,
            freeBytes: 2_000, activeBytes: 4_000, inactiveBytes: 3_000,
            wiredBytes: 2_000, compressedBytes: 1_000,
            processListAvailable: true, sampledProcessCount: 1,
            unavailableProcessCount: 0,
            largestProcesses: [ProcessRAMSample(
                processID: 4242, name: "Synthetic", processStartTime: processStart,
                residentBytes: residentBytes
            )]
        )
    }

    private static func requireSummary(_ path: String, in folder: FolderObservation) throws -> DirectoryUsage {
        guard let summary = folder.subdirectorySummaries.first(where: { $0.rootRelativePath == path }) else {
            throw CheckFailure.assertion("missing subdirectory summary for \(path)")
        }
        return summary
    }

    private static func testScanProgressCallback() throws {
        try withTemporaryDirectory { root in
            for index in 0..<256 {
                try Data([UInt8(index % 255)]).write(to: root.appendingPathComponent("file-\(index).bin"))
            }
            for index in 0..<300 {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent("directory-\(index)", isDirectory: true),
                    withIntermediateDirectories: false
                )
            }
            var reported: ScanProgress?
            var usageBefore = rusage()
            _ = getrusage(RUSAGE_SELF, &usageBefore)
            let scanStartedAt = Date.now
            let result = FolderScanner.scan(roots: [root], progress: { reported = $0 })
            let wallSeconds = Date.now.timeIntervalSince(scanStartedAt)
            var usageAfter = rusage()
            _ = getrusage(RUSAGE_SELF, &usageAfter)
            try expect(result.folders[0].fileCount == 256, "progress fixture should measure every file")
            try expect(result.folders[0].complete, "wide directory trees should not exhaust open directory descriptors")
            try expect(reported?.visitedFiles == 256, "scanner should report its 256-file progress interval")
            try expect(reported?.currentPath.hasPrefix(root.path) == true, "progress should identify a path within the selected root")
            let cpuSeconds = usageSeconds(usageAfter.ru_utime) + usageSeconds(usageAfter.ru_stime)
                - usageSeconds(usageBefore.ru_utime) - usageSeconds(usageBefore.ru_stime)
            print(String(format: "  synthetic scan (256 files, 300 directories): %.3f s wall, %.3f s process CPU", wallSeconds, cpuSeconds))
        }
    }

    private static func testDirectoryMutationCoverage() throws {
        try withTemporaryDirectory { root in
            for index in 0..<256 {
                try Data([UInt8(index % 255)]).write(to: root.appendingPathComponent(String(format: "file-%03d.bin", index)))
            }
            var changedDirectory = false
            let result = FolderScanner.scan(roots: [root], progress: { _ in
                guard !changedDirectory else { return }
                changedDirectory = true
                try? Data([0x7F]).write(to: root.appendingPathComponent("added-during-scan.bin"))
            })
            guard let folder = result.folders.first else {
                throw CheckFailure.assertion("mutation fixture should produce a folder observation")
            }
            try expect(changedDirectory, "fixture should mutate the directory during the scan")
            try expect(!folder.complete, "a directory that changes while being enumerated must not look like a complete snapshot")
            try expect(folder.changedDuringScanCount > 0, "the changed directory should have an explicit coverage count")
        }
    }

    private static func testCancellationPreservesPartialCoverage() throws {
        try withTemporaryDirectory { root in
            for index in 0..<32 {
                try Data([UInt8(index)]).write(to: root.appendingPathComponent("file-\(index).bin"))
            }
            var cancellationChecks = 0
            let result = FolderScanner.scan(roots: [root], shouldCancel: {
                cancellationChecks += 1
                return cancellationChecks > 8
            })
            try expect(result.cancelled, "mid-scan cancellation should be recorded")
            try expect(result.folders.count == 1, "a started folder should retain its partial observation")
            try expect(!result.folders[0].complete, "cancelled folder must be incomplete")
            try expect(result.folders[0].fileCount < 32, "cancelled scan should stop before visiting all fixture files")
        }
    }

    private static func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskerChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure.assertion(message) }
    }

    private static func usageSeconds(_ time: timeval) -> Double {
        Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
}
