@_spi(DiskerTesting) import DiskerCore
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
            ("checked byte accounting saturates on overflow", testCheckedByteAccounting),
            ("overflow disclosure persists with folder history", testByteAccountingOverflowPersistence),
            ("duplicate allocated-byte overflow marks verification partial", testDuplicateAccountingOverflow),
            ("capacity clamping", testCapacityClamping),
            ("low available capacity warning threshold", testLowAvailableCapacityWarning),
            ("comparable capacity history", testCapacityHistoryComparison),
            ("selected-folder growth aligned with capacity loss", testCapacityIntervalFolderGrowth),
            ("bounded history chart ranges", testObservationTimeRanges),
            ("explicit application bundle history index", testApplicationBundleIndex),
            ("explicitly selected app bundle identity read", testApplicationBundleMetadata),
            ("evidence-scoped application container attribution", testApplicationPathAttribution),
            ("read-only app footprint review", testApplicationFootprintReview),
            ("explicit app-folder associations", testApplicationFolderAssociations),
            ("bounded read-only selected-scope bookmarks", testSelectedScopeBookmarks),
            ("local stores reject symlinks", testLocalStoresRejectSymlinks),
            ("zero important-usage fallback", testImportantUsageFallback),
            ("live root volume capacity", testLiveCapacitySource),
            ("live RAM and process sample", testLiveRAMSample),
            ("opt-in RAM monitoring policy", testRAMMonitoringPolicy),
            ("opt-in selected-root storage monitoring policy", testStorageMonitoringPolicy),
            ("system memory-pressure transition mapping", testMemoryPressureEventMapping),
            ("cautious sustained process growth signal", testPossibleProcessGrowth),
            ("metadata scan and symlink exclusion", testMetadataScanAndSymlinkExclusion),
            ("selected root overlap boundaries", testSelectedRootOverlap),
            ("nested volume boundaries are skipped and partial", testNestedVolumeBoundary),
            ("special filesystem entries remain partial and uncounted", testSpecialFileExclusion),
            ("metadata-only filename extension summaries", testFileExtensionSummaries),
            ("Disker own-footprint scan stays in app-owned scope", testDiskerFootprintScope),
            ("selected-scope duplicate verification", testDuplicateVerification),
            ("duplicate reads stay inside selected root volumes", testDuplicateVolumeBoundary),
            ("duplicate verification root limit", testDuplicateVerificationRootLimit),
            ("duplicate verification cancellation", testDuplicateVerificationCancellation),
            ("duplicate directory mutation coverage", testDuplicateDirectoryMutationCoverage),
            ("duplicate files are revalidated after hashing", testDuplicateFileRevalidation),
            ("nested directory usage summaries", testNestedDirectorySummaries),
            ("cautious development storage hints", testStorageAreaHints),
            ("read-only developer artifact review", testDeveloperArtifactReview),
            ("cautious file artifact hints", testFileArtifactHints),
            ("Git metadata marker detection", testGitMetadataMarkerDetection),
            ("Git metadata footprint survives summary cap", testGitMetadataUsageSurvivesSummaryCap),
            ("selected symlink root is incomplete", testSelectedSymlinkRootIsIncomplete),
            ("hard-link deduplication", testHardLinkDeduplication),
            ("directory summary cap and stable order", testDirectorySummaryCap),
            ("bounded largest-file metadata summaries", testLargestFileSummaries),
            ("old history JSON defaults new fields", testOldHistoryDecoding),
            ("sparse file size accounting", testSparseFileAccounting),
            ("missing root coverage", testMissingRootCoverage),
            ("permission-denied subtree remains partial", testPermissionDeniedSubtreeCoverage),
            ("immediate cancellation", testImmediateCancellation),
            ("history persistence and bounded retention", testHistoryPersistenceAndRetention),
            ("loaded history obeys retention bounds", testLoadedHistoryRetentionBounds),
            ("history reset is limited to its own file", testHistoryClearIsScoped),
            ("history reset invalidates stale async work", testHistoryGeneration),
            ("corrupt history fails closed and can be reset", testCorruptHistoryIsLeftUntouched),
            ("same-path complete history comparison", testSamePathCompleteHistoryComparison),
            ("selected-folder growth highlights", testFolderGrowthHighlights),
            ("same-root complete directory growth comparison", testDirectoryGrowthComparison),
            ("same-path complete largest-file growth", testLargestFileGrowthComparison),
            ("selected file root mutation remains partial", testSelectedFileRootMutationCoverage),
            ("scan progress callback", testScanProgressCallback),
            ("directory mutations make coverage partial", testDirectoryMutationCoverage),
            ("selected directory root mutations make coverage partial", testSelectedDirectoryRootMutationCoverage),
            ("file mutations during enumeration make coverage partial", testFileMutationCoverage),
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

    private static func testCheckedByteAccounting() throws {
        let exact = CheckedByteCount.adding(Int64.max - 1, 1)
        try expect(exact.value == Int64.max && !exact.overflowed,
                   "a byte total at Int64.max should remain exact")
        let addition = CheckedByteCount.adding(Int64.max, 1)
        try expect(addition.value == Int64.max && addition.overflowed,
                   "an overflowing byte sum should saturate and report overflow")
        let allocation = CheckedByteCount.multiplying(Int64.max, 512)
        try expect(allocation.value == Int64.max && allocation.overflowed,
                   "an overflowing allocated-byte estimate should saturate and report overflow")
    }

    private static func testByteAccountingOverflowPersistence() throws {
        let folder = FolderObservation(
            path: "/synthetic/huge", displayName: "huge", logicalBytes: Int64.max,
            allocatedBytes: Int64.max, fileCount: 2, inaccessibleCount: 0, complete: false,
            byteAccountingOverflowed: true
        )
        let encoded = try JSONEncoder().encode(folder)
        let decoded = try JSONDecoder().decode(FolderObservation.self, from: encoded)
        try expect(decoded.byteAccountingOverflowed,
                   "a capped byte estimate must retain its overflow explanation after history reload")
    }

    private static func testDuplicateAccountingOverflow() throws {
        let result = DuplicateVerificationResult(
            selectedRootPaths: ["/synthetic"], groups: [], checkedFileCount: 0,
            inaccessibleCount: 0, excludedSymlinkCount: 0, excludedSpecialFileCount: 0,
            excludedVolumeBoundaryCount: 2,
            changedDuringCheckCount: 0, cancelled: false, byteAccountingOverflowed: true
        )
        try expect(!result.complete, "an overflowing allocated estimate must prevent claiming complete duplicate coverage")
        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(DuplicateVerificationResult.self, from: encoded)
        try expect(decoded.byteAccountingOverflowed && decoded.excludedVolumeBoundaryCount == 2
                   && !decoded.complete,
                   "duplicate overflow and nested-volume coverage must survive Codable round-trip")

        let legacyJSON = #"{"verifiedAt":null,"selectedRootPaths":["/synthetic"],"groups":[],"checkedFileCount":0,"inaccessibleCount":0,"excludedSymlinkCount":0,"excludedSpecialFileCount":0,"changedDuringCheckCount":0,"cancelled":false}"#
        let legacy = try JSONDecoder().decode(DuplicateVerificationResult.self, from: Data(legacyJSON.utf8))
        try expect(!legacy.byteAccountingOverflowed && !legacy.selectedRootLimitExceeded
                   && legacy.excludedVolumeBoundaryCount == 0 && legacy.complete,
                   "legacy duplicate results should default newer coverage flags to false and zero boundaries")
    }

    private static func testCapacityClamping() throws {
        let sample = CapacityObservation(totalBytes: 100, availableBytes: 200)
        try expect(sample.availableBytes == 100, "available bytes should not exceed total capacity")
        try expect(sample.notAvailableBytes == 0, "not-available bytes should never be negative")
    }

    private static func testLowAvailableCapacityWarning() throws {
        let gibibyte: Int64 = 1_073_741_824
        let smallerVolume = CapacityObservation(
            totalBytes: 100 * gibibyte, availableBytes: 10 * gibibyte
        )
        try expect(smallerVolume.lowAvailableCapacityThreshold == 10 * gibibyte
                   && !smallerVolume.isLowOnAvailableCapacity,
                   "volumes below 200 GiB should use the 10 GiB warning threshold inclusively")
        let belowSmallThreshold = CapacityObservation(
            totalBytes: 100 * gibibyte, availableBytes: 10 * gibibyte - 1
        )
        try expect(belowSmallThreshold.isLowOnAvailableCapacity,
                   "available capacity below the threshold should raise a dashboard signal")

        let largerVolume = CapacityObservation(
            totalBytes: 1_000 * gibibyte, availableBytes: 50 * gibibyte
        )
        try expect(largerVolume.lowAvailableCapacityThreshold == 50 * gibibyte
                   && !largerVolume.isLowOnAvailableCapacity,
                   "larger volumes should use five percent of system-reported capacity")
        let belowLargeThreshold = CapacityObservation(
            totalBytes: 1_000 * gibibyte, availableBytes: 50 * gibibyte - 1
        )
        try expect(belowLargeThreshold.isLowOnAvailableCapacity,
                   "large-volume warning should trigger only below the five-percent boundary")
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

        let identifiedPrevious = CapacityObservation(
            observedAt: Date(timeIntervalSince1970: 300), totalBytes: 1_000,
            availableBytes: 700, availabilityBasis: .importantUsage, volumeUUID: "volume-a"
        )
        let identifiedCurrent = CapacityObservation(
            observedAt: Date(timeIntervalSince1970: 400), totalBytes: 1_000,
            availableBytes: 650, availabilityBasis: .importantUsage, volumeUUID: "volume-a"
        )
        let replacementVolume = CapacityObservation(
            observedAt: Date(timeIntervalSince1970: 500), totalBytes: 1_000,
            availableBytes: 620, availabilityBasis: .importantUsage, volumeUUID: "volume-b"
        )
        let volumeHistory = LocalHistory(capacityObservations: [
            identifiedPrevious, identifiedCurrent, replacementVolume,
        ])
        try expect(ObservationComparison.previousComparableCapacity(
            for: replacementVolume, in: volumeHistory
        ) == nil, "a replacement volume with the same size and API must not inherit another volume's history")
        try expect(ObservationComparison.availableCapacityDelta(
            current: replacementVolume, previous: identifiedCurrent
        ) == nil, "capacity deltas must not cross volume UUIDs")
        try expect(ObservationComparison.comparableCapacitySeries(in: volumeHistory) == [replacementVolume],
                   "volume UUID changes must begin a new capacity-history series")
        let transitionHistory = LocalHistory(capacityObservations: [previous, identifiedCurrent])
        try expect(ObservationComparison.previousComparableCapacity(
            for: identifiedCurrent, in: transitionHistory
        ) == nil, "legacy capacity without a volume UUID must not be compared with an identified volume")
        try expect(ObservationComparison.comparableCapacitySeries(in: transitionHistory) == [identifiedCurrent],
                   "capacity history should begin a fresh run when volume identity first becomes available")

        let futureDatedCapacity = CapacityObservation(
            observedAt: Date(timeIntervalSince1970: 600), totalBytes: 1_000,
            availableBytes: 800, availabilityBasis: .importantUsage, volumeUUID: "volume-clock"
        )
        let capacityAfterClockRollback = CapacityObservation(
            observedAt: Date(timeIntervalSince1970: 500), totalBytes: 1_000,
            availableBytes: 750, availabilityBasis: .importantUsage, volumeUUID: "volume-clock"
        )
        let clockRollbackCapacityHistory = LocalHistory(capacityObservations: [
            futureDatedCapacity, capacityAfterClockRollback,
        ])
        try expect(ObservationComparison.comparableCapacitySeries(in: clockRollbackCapacityHistory)
                   == [capacityAfterClockRollback],
                   "capacity history should exclude an earlier-insertion sample timestamped after the latest sample")

        let legacyCapacityJSON = #"{"observedAt":1,"totalBytes":1000,"availableBytes":500,"availabilityBasis":"importantUsage"}"#
        let legacyCapacity = try JSONDecoder().decode(
            CapacityObservation.self, from: Data(legacyCapacityJSON.utf8)
        )
        try expect(legacyCapacity.volumeUUID == nil && legacyCapacity.volumeName == nil,
                   "older capacity observations should decode without volume identity fields")
    }

    private static func testObservationTimeRanges() throws {
        let latest = Date(timeIntervalSince1970: 1_000_000)
        try expect(ObservationTimeRange.day.includes(latest.addingTimeInterval(-86_400), relativeTo: latest),
                   "24-hour chart range should include its exact lower boundary")
        try expect(!ObservationTimeRange.day.includes(latest.addingTimeInterval(-86_401), relativeTo: latest),
                   "24-hour chart range should exclude older observations")
        try expect(ObservationTimeRange.week.includes(latest.addingTimeInterval(-7 * 86_400), relativeTo: latest),
                   "7-day chart range should include its exact lower boundary")
        try expect(!ObservationTimeRange.week.includes(latest.addingTimeInterval(-7 * 86_400 - 1), relativeTo: latest),
                   "7-day chart range should exclude older observations")
        try expect(ObservationTimeRange.month.includes(latest.addingTimeInterval(-30 * 86_400), relativeTo: latest),
                   "30-day chart range should include its exact lower boundary")
        try expect(!ObservationTimeRange.month.includes(latest.addingTimeInterval(-30 * 86_400 - 1), relativeTo: latest),
                   "30-day chart range should exclude older observations")
        try expect(ObservationTimeRange.all.includes(Date(timeIntervalSince1970: 0), relativeTo: latest),
                   "all-saved chart range should retain the full bounded series")
        try expect(!ObservationTimeRange.all.includes(latest.addingTimeInterval(1), relativeTo: latest),
                   "chart ranges should exclude observations later than their anchor")
    }

    private static func testApplicationBundleIndex() throws {
        func folder(
            _ path: String, _ bytes: Int64, _ complete: Bool = true,
            bundleIdentifier: String? = nil, selectedAsApplicationBundle: Bool = false
        ) -> FolderObservation {
            FolderObservation(
                path: path, displayName: URL(fileURLWithPath: path).lastPathComponent,
                logicalBytes: bytes, allocatedBytes: bytes, fileCount: 1,
                inaccessibleCount: 0, complete: complete,
                applicationBundleIdentifier: bundleIdentifier,
                selectedAsApplicationBundle: selectedAsApplicationBundle
            )
        }
        let firstBundle = folder("/Applications/Example.app", 900, true, bundleIdentifier: "com.example.App", selectedAsApplicationBundle: true)
        let laterBundle = folder("/Applications/Example.app", 500, false, bundleIdentifier: "com.example.App", selectedAsApplicationBundle: true)
        let otherBundle = folder("/Applications/Other.app", 700, selectedAsApplicationBundle: true)
        let unreadableBundle = folder("/Applications/Unknown.app", 600)
        let genericAppDirectory = folder("/Projects/Example.app", 1000)
        let notBundle = folder("/Projects/Example.app-cache", 10)
        let enriched = ScanObservation(
            startedAt: Date(timeIntervalSince1970: 3),
            folders: [firstBundle, notBundle], cancelled: false
        ).includingApplicationBundleIdentities([
            firstBundle.path: ApplicationBundleIdentity(
                bundleIdentifier: "com.example.App",
                claimedGroupIdentifiers: ["TEAMID.group.example.shared"],
                signatureValidated: true,
                signedBundleIdentifier: "com.example.App"
            )
        ], selectedApplicationBundlePaths: [firstBundle.path])
        try expect(enriched.folders[0].applicationBundleIdentifier == "com.example.App",
                   "explicit bundle identity should be attached to the matching selected root")
        try expect(enriched.folders[0].applicationGroupIdentifiers == ["TEAMID.group.example.shared"],
                   "embedded group claims should persist with that selected app root")
        try expect(enriched.folders[0].applicationSignatureValidated
                   && enriched.folders[0].applicationSignedBundleIdentifier == "com.example.App",
                   "signature validation and its signed bundle ID should persist with the selected app root")
        try expect(enriched.folders[0].selectedAsApplicationBundle,
                   "explicit app-picker provenance should attach to the selected root")
        try expect(enriched.folders[1].applicationBundleIdentifier == nil,
                   "bundle identity must not leak to other selected roots")
        let unreadableSelection = ScanObservation(
            startedAt: Date(timeIntervalSince1970: 4), folders: [unreadableBundle], cancelled: false
        ).includingApplicationBundleIdentities([:], selectedApplicationBundlePaths: [unreadableBundle.path])
        try expect(unreadableSelection.folders[0].selectedAsApplicationBundle
                   && unreadableSelection.folders[0].applicationBundleIdentifier == nil,
                   "explicit app selections must remain identifiable even when bundle metadata is unavailable")
        let history = LocalHistory(observations: [
            ScanObservation(startedAt: Date(timeIntervalSince1970: 1), folders: [firstBundle, notBundle, genericAppDirectory], cancelled: false),
            ScanObservation(startedAt: Date(timeIntervalSince1970: 2), folders: [laterBundle, otherBundle, unreadableSelection.folders[0]], cancelled: false),
            ScanObservation(startedAt: Date(timeIntervalSince1970: 3), folders: [
                folder("/Applications/Example.app", 450, false)
            ], cancelled: false)
        ])
        let indexed = ApplicationBundleIndex.latestMeasurements(in: history)
        try expect(indexed.count == 3 && !indexed.contains(where: { $0.path == genericAppDirectory.path }),
                   "a generic folder ending in .app must not be classified as an application bundle")
        try expect(indexed.map(\.path) == [otherBundle.path, unreadableBundle.path, laterBundle.path],
                   "explicit app selections, even without readable IDs, should be sorted by measured size")
        try expect(indexed.last?.complete == false && indexed.last?.allocatedBytes == 450,
                   "a later saved-folder scan should replace the older app-picker measurement")
        try expect(indexed.last?.applicationBundleIdentifier == nil
                   && indexed.last?.applicationSignatureValidated == false,
                   "saved-folder scans must not inherit stale app identity or signature evidence")
        let encodedBundle = try JSONEncoder().encode(enriched.folders[0])
        let decodedBundle = try JSONDecoder().decode(FolderObservation.self, from: encodedBundle)
        try expect(decodedBundle.applicationBundleIdentifier == "com.example.App",
                   "bundle identifiers should persist with application observations")
        try expect(decodedBundle.applicationSignatureValidated
                   && decodedBundle.applicationSignedBundleIdentifier == "com.example.App",
                   "validated signature identity should survive observation encoding")
        try expect(decodedBundle.selectedAsApplicationBundle,
                   "app-picker provenance should survive observation encoding")
        guard var legacyBundleObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(firstBundle)
        ) as? [String: Any] else {
            throw CheckFailure.assertion("encoded app observation should be a JSON object")
        }
        legacyBundleObject.removeValue(forKey: "selectedAsApplicationBundle")
        let legacySelectedBundle = try JSONDecoder().decode(
            FolderObservation.self, from: JSONSerialization.data(withJSONObject: legacyBundleObject)
        )
        try expect(legacySelectedBundle.selectedAsApplicationBundle,
                   "legacy app observations with stored bundle IDs should retain their explicit-app classification")
    }

    private static func testApplicationPathAttribution() throws {
        let home = "/Users/synthetic"
        let identifier = "com.example.Sample"
        let container = "\(home)/Library/Containers/\(identifier)"
        let appSupport = "\(home)/Library/Application Support/\(identifier)"
        let appCaches = "\(home)/Library/Caches/\(identifier)"
        let exact = ApplicationPathAttribution.classify(
            bundleIdentifier: identifier, associatedFolderPath: container,
            homeDirectoryPath: home
        )
        try expect(exact.evidence == .probableContainerPathMatch,
                   "the exact macOS app-container path should receive a probable identifier match")
        try expect(exact.explanation.contains("signing identity") && exact.explanation.contains("exclusive use"),
                   "container attribution must disclose unchecked signing identity and exclusivity")
        let validatedContainer = ApplicationPathAttribution.classify(
            bundleIdentifier: identifier, associatedFolderPath: container,
            homeDirectoryPath: home, signatureValidated: true,
            signedBundleIdentifier: identifier
        )
        try expect(validatedContainer.evidence == .validatedBundleIdentifierPathMatch,
                   "a locally validated signed bundle ID should receive stronger exact-container evidence")
        try expect(validatedContainer.title.contains("ownership unverified")
                   && validatedContainer.explanation.contains("origin"),
                   "a valid signature match must not imply the selected folder's provenance")
        let mismatchedSignatureID = ApplicationPathAttribution.classify(
            bundleIdentifier: identifier, associatedFolderPath: container,
            homeDirectoryPath: home, signatureValidated: true,
            signedBundleIdentifier: "com.example.Other"
        )
        try expect(mismatchedSignatureID.evidence == .probableContainerPathMatch,
                   "a signed identifier that differs from the declared ID must remain only probable")

        let descendant = ApplicationPathAttribution.classify(
            bundleIdentifier: identifier,
            associatedFolderPath: container + "/Data/Library/Application Support",
            homeDirectoryPath: home
        )
        try expect(descendant.evidence == .probableContainerPathMatch,
                   "a selected descendant inside the exact app container should retain the path evidence")
        let normalizedDescendant = ApplicationPathAttribution.classify(
            bundleIdentifier: identifier,
            associatedFolderPath: container + "/Data/../Library",
            homeDirectoryPath: home
        )
        let escapedContainer = ApplicationPathAttribution.classify(
            bundleIdentifier: identifier,
            associatedFolderPath: container + "/../../Containers/\(identifier)-other",
            homeDirectoryPath: home
        )
        try expect(normalizedDescendant.evidence == .probableContainerPathMatch
                   && escapedContainer.evidence == .userSelectedOnly,
                   "standardized dot segments may remain within the exact root but cannot escape its boundary")

        let groupIdentifier = "TEAMID.group.shared"
        let groupContainer = "\(home)/Library/Group Containers/\(groupIdentifier)"
        for path in [appSupport, appCaches, appSupport + "-other"] {
            let namedSupport = ApplicationPathAttribution.classify(
                bundleIdentifier: identifier, associatedFolderPath: path,
                homeDirectoryPath: home
            )
            try expect(namedSupport.evidence == (path.hasSuffix("-other")
                ? .userSelectedOnly : .probableNamedSupportPathMatch),
                "only exact bundle-ID directory names under conventional support/cache roots get weak name evidence")
        }
        let exactSharedGroup = ApplicationPathAttribution.classify(
            bundleIdentifier: identifier,
            associatedFolderPath: groupContainer,
            homeDirectoryPath: home,
            claimedGroupIdentifiers: [groupIdentifier]
        )
        try expect(exactSharedGroup.evidence == .declaredSharedGroupContainerClaim,
                   "the exact path of an embedded App Group should receive the shared-container label")
        let sharedGroup = ApplicationPathAttribution.classify(
            bundleIdentifier: identifier,
            associatedFolderPath: groupContainer + "/Documents",
            homeDirectoryPath: home,
            claimedGroupIdentifiers: [groupIdentifier]
        )
        try expect(sharedGroup.evidence == .declaredSharedGroupContainerClaim
                   && sharedGroup.groupIdentifier == groupIdentifier,
                   "an exact embedded App Groups claim should identify a shared group-container path")
        try expect(sharedGroup.explanation.contains("shared with other group members")
                   && sharedGroup.explanation.contains("not matched a locally validated signed identifier"),
                   "shared-container attribution must disclose shared use and its unmatched signed identity")
        let mismatchedGroupIdentity = ApplicationPathAttribution.classify(
            bundleIdentifier: identifier,
            associatedFolderPath: groupContainer,
            homeDirectoryPath: home,
            claimedGroupIdentifiers: [groupIdentifier],
            signatureValidated: true,
            signedBundleIdentifier: "com.example.Other"
        )
        try expect(mismatchedGroupIdentity.evidence == .declaredSharedGroupContainerClaim
                   && mismatchedGroupIdentity.explanation.contains("not matched a locally validated signed identifier"),
                   "a valid signature for a different bundle ID must not strengthen an App Group path claim")
        let signatureCoveredSharedGroup = ApplicationPathAttribution.classify(
            bundleIdentifier: identifier,
            associatedFolderPath: groupContainer + "/Documents",
            homeDirectoryPath: home,
            claimedGroupIdentifiers: [groupIdentifier],
            signatureValidated: true,
            signedBundleIdentifier: identifier
        )
        try expect(signatureCoveredSharedGroup.evidence == .signatureCoveredSharedGroupClaim
                   && signatureCoveredSharedGroup.explanation.contains("does not establish developer trust")
                   && signatureCoveredSharedGroup.explanation.contains("container is shared"),
                   "signature-covered group claims should disclose that access and developer trust remain unverified")

        for path in [
            "\(home)/Library/Containers/\(identifier)-other",
            "\(home)/Library/Group Containers/\(identifier)",
            "/Volumes/Other/Library/Containers/\(identifier)",
        ] {
            let result = ApplicationPathAttribution.classify(
                bundleIdentifier: identifier, associatedFolderPath: path,
                homeDirectoryPath: home
            )
            try expect(result.evidence == .userSelectedOnly,
                       "nearby, group-container, or out-of-home paths must not inherit app-container evidence")
        }

        let missingID = ApplicationPathAttribution.classify(
            bundleIdentifier: nil, associatedFolderPath: container,
            homeDirectoryPath: home
        )
        let invalidID = ApplicationPathAttribution.classify(
            bundleIdentifier: "com.example/Other", associatedFolderPath: container,
            homeDirectoryPath: home
        )
        let traversalID = ApplicationPathAttribution.classify(
            bundleIdentifier: "..", associatedFolderPath: "\(home)/Library",
            homeDirectoryPath: home
        )
        try expect(missingID.evidence == .userSelectedOnly
                   && invalidID.evidence == .userSelectedOnly
                   && traversalID.evidence == .userSelectedOnly,
                   "missing or path-like bundle identifiers must not be treated as attribution evidence")
        let unclaimedGroup = ApplicationPathAttribution.classify(
            bundleIdentifier: identifier, associatedFolderPath: groupContainer,
            homeDirectoryPath: home
        )
        let nearbyGroup = ApplicationPathAttribution.classify(
            bundleIdentifier: identifier,
            associatedFolderPath: groupContainer + "-other",
            homeDirectoryPath: home,
            claimedGroupIdentifiers: [groupIdentifier]
        )
        try expect(unclaimedGroup.evidence == .userSelectedOnly
                   && nearbyGroup.evidence == .userSelectedOnly,
                   "unclaimed and near-miss App Group paths must remain user-selected only")

        let suggestions = ApplicationDataLocationCandidates.suggestions(
            bundleIdentifier: identifier, homeDirectoryPath: home,
            claimedGroupIdentifiers: [groupIdentifier, groupIdentifier, "bad/group"]
        )
        try expect(suggestions.map(\.path) == [container, appSupport, appCaches, groupContainer],
                   "app-data suggestions should be exact, deduplicated conventional paths")
        try expect(suggestions[0].evidence == .probableAppContainer
                   && suggestions[1].evidence == .probableNamedSupportDirectory
                   && suggestions[2].evidence == .probableNamedSupportDirectory
                   && suggestions[3].evidence == .declaredSharedGroupClaim,
                   "suggested paths should retain probable and shared-claim evidence without overstating ownership")
        try expect(suggestions.allSatisfy({ $0.explanation.contains("not been checked")
                                           || $0.explanation.contains("shared by design") }),
                   "location suggestions should explicitly remain unmeasured and confidence-limited")

        let validatedSuggestions = ApplicationDataLocationCandidates.suggestions(
            bundleIdentifier: identifier, homeDirectoryPath: home,
            claimedGroupIdentifiers: [groupIdentifier], signatureValidated: true,
            signedBundleIdentifier: identifier
        )
        try expect(validatedSuggestions.map(\.evidence) == [
            .validatedAppContainerIdentifier, .probableNamedSupportDirectory,
            .probableNamedSupportDirectory, .signatureCoveredSharedGroupClaim,
        ], "matching local signature evidence should refine only evidence it actually covers")
        let mismatchedSuggestions = ApplicationDataLocationCandidates.suggestions(
            bundleIdentifier: identifier, homeDirectoryPath: home,
            claimedGroupIdentifiers: [groupIdentifier], signatureValidated: true,
            signedBundleIdentifier: "com.example.Other"
        )
        try expect(mismatchedSuggestions.map(\.evidence) == [
            .probableAppContainer, .probableNamedSupportDirectory,
            .probableNamedSupportDirectory, .declaredSharedGroupClaim,
        ], "a mismatched signed ID must not strengthen suggested path evidence")
        try expect(ApplicationDataLocationCandidates.suggestions(
            bundleIdentifier: "../Other", homeDirectoryPath: home,
            claimedGroupIdentifiers: [groupIdentifier]
        ).isEmpty, "invalid identifiers must not generate app-data paths")
    }

    private static func testApplicationFootprintReview() throws {
        let home = "/Users/synthetic"
        let identifier = "com.example.Sample"
        let groupIdentifier = "TEAM.group.shared"
        let bundlePath = "/Applications/Sample.app"
        let containerPath = "\(home)/Library/Containers/\(identifier)"
        let containerChild = "\(containerPath)/Documents"
        let groupPath = "\(home)/Library/Group Containers/\(groupIdentifier)"
        let supportPath = "\(home)/Library/Application Support/\(identifier)"
        let cachePath = "\(home)/Library/Caches/\(identifier)"
        let unknownPath = "/Volumes/External/Selected by owner"
        let bundle = FolderObservation(
            path: bundlePath, displayName: "Sample",
            logicalBytes: 100, allocatedBytes: 120, fileCount: 2,
            inaccessibleCount: 0, complete: true
        )
            .includingApplicationBundleIdentity(
                ApplicationBundleIdentity(
                    bundleIdentifier: identifier,
                    claimedGroupIdentifiers: [groupIdentifier],
                    signatureValidated: true,
                    signedBundleIdentifier: identifier
                ),
                selectedAsApplicationBundle: true
            )
        let oldSupportObservation = syntheticFolder(
            path: supportPath, bytes: 300, complete: true,
            finishedAt: Date(timeIntervalSince1970: 100)
        )
        let latestPartialSupportObservation = syntheticFolder(
            path: supportPath, bytes: 450, complete: false,
            finishedAt: Date(timeIntervalSince1970: 200)
        )
        let groupObservation = syntheticFolder(path: groupPath, bytes: 700, complete: true)
        let childObservation = syntheticFolder(path: containerChild, bytes: 200, complete: true)
        let observations = [
            ScanObservation(startedAt: Date(timeIntervalSince1970: 100), folders: [
                bundle, oldSupportObservation, groupObservation, childObservation,
            ], cancelled: false),
            ScanObservation(startedAt: Date(timeIntervalSince1970: 200), folders: [
                latestPartialSupportObservation,
            ], cancelled: true),
        ]
        let association = ApplicationFolderAssociation(
            bundlePath: bundlePath,
            relatedFolderPaths: [
                containerPath, containerChild, groupPath, supportPath, cachePath,
                unknownPath, groupPath,
            ]
        )
        let otherBundlePath = "/Applications/Other.app"
        let history = LocalHistory(
            observations: observations,
            applicationAssociations: [
                association,
                ApplicationFolderAssociation(bundlePath: otherBundlePath, relatedFolderPaths: [unknownPath]),
            ]
        )

        let review = ApplicationFootprintReview.make(
            for: bundle, in: history, homeDirectoryPath: home
        )
        let byPath = Dictionary(uniqueKeysWithValues: review.entries.map { ($0.path, $0) })
        try expect(review.entries.count == 7 && review.entries.first?.kind == .applicationBundle,
                   "the read-only review should show the bundle and deduplicated associated paths")
        try expect(byPath[bundlePath]?.observation == bundle
                   && byPath[bundlePath]?.observation?.logicalBytes == 100
                   && byPath[bundlePath]?.observation?.allocatedBytes == 120
                   && review.reclaimableBytes == nil,
                   "the bundle row should preserve distinct logical and allocated bytes without inferring reclaimable space")
        try expect(byPath[supportPath]?.observation == latestPartialSupportObservation
                   && byPath[supportPath]?.observation?.complete == false
                   && byPath[supportPath]?.scanWasCancelled == true,
                   "a newer partial measurement must remain visibly partial instead of falling back to stale complete data")
        try expect(byPath[groupPath]?.isShared == true
                   && byPath[groupPath]?.attribution?.evidence == .signatureCoveredSharedGroupClaim,
                   "signature-covered group data must remain explicitly shared in the review")
        try expect(byPath[groupPath]?.cleanupReviewClass == .sharedOrMultiOwner
                   && byPath[unknownPath]?.cleanupReviewClass == .sharedOrMultiOwner,
                   "group claims and multiply-associated paths must disclose linked consumers without asserting current use")
        try expect(byPath[cachePath]?.cleanupReviewClass == .possibleCache
                   && byPath[cachePath]?.cleanupReviewClass.guidance.contains("unverified") == true,
                   "a cache name may only produce a low-confidence review class with explicit recovery uncertainty")
        try expect(byPath[bundlePath]?.cleanupReviewClass == .selectedBundle
                   && byPath[supportPath]?.cleanupReviewClass == .unknownOrPotentiallyUnique
                   && byPath[containerPath]?.cleanupReviewClass == .unknownOrPotentiallyUnique,
                   "bundle replacement uncertainty and potential user data must remain distinct from possible caches")
        try expect(byPath[containerPath]?.overlappingPaths == [containerChild]
                   && byPath[containerChild]?.overlappingPaths == [containerPath],
                   "nested reviewed scopes must be marked as overlapping rather than summed")
        try expect(byPath[cachePath]?.attribution?.evidence == .probableNamedSupportPathMatch
                   && byPath[unknownPath]?.attribution?.evidence == .userSelectedOnly
                   && byPath[unknownPath]?.isShared == true
                   && byPath[unknownPath]?.otherAssociatedBundlePaths == [otherBundlePath],
                   "cache clues, user-only evidence, and links to another app must remain distinguishable")
        try expect(byPath[cachePath]?.observation == nil && review.reclaimableBytes == nil,
                   "unmeasured locations and reclaimable physical bytes must remain unknown")
    }

    private static func testApplicationBundleMetadata() throws {
        try withTemporaryDirectory { root in
            let bundle = root.appendingPathComponent("Synthetic.app", isDirectory: true)
            let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": "com.synthetic.DiskerFixture",
                "CFBundlePackageType": "APPL",
            ]
            let plist = try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0
            )
            try plist.write(to: contents.appendingPathComponent("Info.plist"))

            let unsignedIdentity = try requireApplicationIdentity(at: bundle)
            try expect(unsignedIdentity.bundleIdentifier == "com.synthetic.DiskerFixture",
                       "an explicitly selected app bundle should expose its declared identifier")
            try expect(unsignedIdentity.claimedGroupIdentifiers.isEmpty,
                       "an unsigned selected app must not receive invented App Groups claims")
            try expect(!unsignedIdentity.signatureValidated && unsignedIdentity.signedBundleIdentifier == nil,
                       "an unsigned selected app must not be labeled with validated signing identity")

            let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: false)
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"),
                to: executableDirectory.appendingPathComponent("Synthetic")
            )
            let entitlementsURL = root.appendingPathComponent("synthetic.entitlements")
            let entitlements: [String: Any] = [
                "com.apple.security.application-groups": [
                    "TEAMID.group.synthetic.shared", "TEAMID.group.synthetic.shared", "bad/group"
                ]
            ]
            let entitlementData = try PropertyListSerialization.data(
                fromPropertyList: entitlements, format: .xml, options: 0
            )
            try entitlementData.write(to: entitlementsURL)
            let signer = Process()
            signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signer.arguments = [
                "--force", "--sign", "-", "--entitlements", entitlementsURL.path, bundle.path
            ]
            signer.standardOutput = Pipe()
            signer.standardError = Pipe()
            try signer.run()
            signer.waitUntilExit()
            try expect(signer.terminationStatus == 0,
                       "the synthetic app should accept an ad-hoc fixture signature")
            let signedIdentity = try requireApplicationIdentity(at: bundle)
            try expect(signedIdentity.signatureValidated
                       && signedIdentity.signedBundleIdentifier == "com.synthetic.DiskerFixture",
                       "a valid ad-hoc signature should expose its signed bundle identifier")
            try expect(signedIdentity.claimedGroupIdentifiers == ["TEAMID.group.synthetic.shared"],
                       "only unique, path-safe App Groups claims should be read from the embedded signature")

            let oversizedClaims: [String: Any] = [
                "com.apple.security.application-groups": (0..<65).map {
                    "TEAMID.group.synthetic.\($0)"
                }
            ]
            let oversizedData = try PropertyListSerialization.data(
                fromPropertyList: oversizedClaims, format: .xml, options: 0
            )
            try oversizedData.write(to: entitlementsURL)
            let oversizedSigner = Process()
            oversizedSigner.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            oversizedSigner.arguments = [
                "--force", "--sign", "-", "--entitlements", entitlementsURL.path, bundle.path
            ]
            oversizedSigner.standardOutput = Pipe()
            oversizedSigner.standardError = Pipe()
            try oversizedSigner.run()
            oversizedSigner.waitUntilExit()
            try expect(oversizedSigner.terminationStatus == 0,
                       "the synthetic app should accept an oversized entitlement fixture")
            let oversizedIdentity = try requireApplicationIdentity(at: bundle)
            try expect(oversizedIdentity.claimedGroupIdentifiers.isEmpty,
                       "oversized App Groups claims should be ignored instead of persisted without a bound")

            try Data("tampered synthetic executable".utf8).write(
                to: executableDirectory.appendingPathComponent("Synthetic")
            )
            let tamperedIdentity = try requireApplicationIdentity(at: bundle)
            try expect(!tamperedIdentity.signatureValidated
                       && tamperedIdentity.signedBundleIdentifier == nil,
                       "a modified executable must not retain validated signature evidence")

            let ordinaryFolder = root.appendingPathComponent("ordinary-folder", isDirectory: true)
            try FileManager.default.createDirectory(at: ordinaryFolder, withIntermediateDirectories: false)
            try expect(ApplicationBundleMetadata.identity(fromSelectedBundleAt: ordinaryFolder) == nil,
                       "bundle identity lookup must not inspect non-app folders")
        }
    }

    private static func requireApplicationIdentity(at url: URL) throws -> ApplicationBundleIdentity {
        guard let identity = ApplicationBundleMetadata.identity(fromSelectedBundleAt: url) else {
            throw CheckFailure.assertion("selected synthetic .app bundle should provide its Info.plist identity")
        }
        return identity
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
                [folder.path, folder.path], with: bundlePath,
                bundleIdentifier: "com.example.App", to: fileURL
            )
            try ObservationStore.associateApplicationFolders(
                ["/synthetic/second-support"], with: bundlePath, to: fileURL
            )
            var history = try ObservationStore.load(from: fileURL)
            try expect(history.applicationAssociations.count == 1, "folder links should be grouped under the explicitly selected bundle path")
            try expect(history.applicationAssociations[0].bundleIdentifier == "com.example.App",
                       "an explicitly selected app identifier should persist with its folder relationships")
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
            try expect(bounded.adding(["/synthetic/overflow"]) == nil,
                       "adding a 51st unique folder should fail instead of silently dropping a saved link")
        }
    }

    private static func testSelectedScopeBookmarks() throws {
        try expect(
            SelectedScopeBookmarkStore.creationOptions(isSandboxed: false).isEmpty
                && SelectedScopeBookmarkStore.resolutionOptions(isSandboxed: false).isEmpty,
            "the standard unsandboxed app must create and resolve ordinary bookmarks"
        )
        try expect(
            SelectedScopeBookmarkStore.creationOptions(isSandboxed: true)
                == [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
                && SelectedScopeBookmarkStore.resolutionOptions(isSandboxed: true) == [.withSecurityScope],
            "the sandboxed app must create read-only security-scoped bookmarks and resolve their scope"
        )
        try withTemporaryDirectory { base in
            let root = base.appendingPathComponent("selected-folder", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let fixture = root.appendingPathComponent("keep.bin")
            let bytes = Data("synthetic selected-scope fixture".utf8)
            try bytes.write(to: fixture)
            let storeURL = base.appendingPathComponent("nested/scopes.json")

            let saved = try SelectedScopeBookmarkStore.remember([root], at: storeURL)
            try expect(saved.count == 1 && saved[0].path == root.standardizedFileURL.path,
                       "a selected folder should be stored once by its canonical path")
            let loaded = try SelectedScopeBookmarkStore.load(from: storeURL)
            try expect(loaded == saved, "saved scope bookmarks should round-trip locally")
            let permissions = try FileManager.default.attributesOfItem(atPath: storeURL.path)[.posixPermissions] as? NSNumber
            try expect(permissions?.intValue == 0o600,
                       "saved permission bookmarks should be readable only by the local account")
            let directoryPermissions = try FileManager.default.attributesOfItem(
                atPath: storeURL.deletingLastPathComponent().path
            )[.posixPermissions] as? NSNumber
            try expect(directoryPermissions?.intValue == 0o700,
                       "the scope store directory should be accessible only by the local account")
            let resolved = try SelectedScopeBookmarkStore.resolve(loaded[0], at: storeURL)
            try expect(resolved.standardizedFileURL.path == root.standardizedFileURL.path,
                       "a bookmark should resolve to its selected folder")
            let scopeStoreBeforeProbe = try Data(contentsOf: storeURL)
            try expect(SelectedScopePathProbe.isAvailable(
                at: root.path, using: loaded[0]
            ),
                       "a saved read-only scope should permit a no-follow metadata availability check at its exact path")
            let differentPath = base.appendingPathComponent("different-folder", isDirectory: true)
            try FileManager.default.createDirectory(at: differentPath, withIntermediateDirectories: false)
            let movedBookmarkData = try differentPath.bookmarkData(
                options: SelectedScopeBookmarkStore.creationOptions(isSandboxed: false),
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let mismatchedBookmark = SelectedScopeBookmark(
                path: root.standardizedFileURL.path, bookmarkData: movedBookmarkData
            )
            let scopeStoreBeforeMismatch = try Data(contentsOf: storeURL)
            var rejectedMovedBookmark = false
            var attemptedUnsafeRefresh = false
            do {
                _ = try SelectedScopeBookmarkStore.resolve(
                    mismatchedBookmark,
                    at: storeURL,
                    resolvingBookmarkData: { _ in (url: differentPath, isStale: true) },
                    creatingBookmarkData: { _ in
                        attemptedUnsafeRefresh = true
                        return movedBookmarkData
                    }
                )
            } catch SelectedScopeBookmarkError.bookmarkPathChanged {
                rejectedMovedBookmark = true
            }
            let scopeStoreAfterMismatch = try Data(contentsOf: storeURL)
            try expect(rejectedMovedBookmark && !attemptedUnsafeRefresh,
                       "a moved stale bookmark must fail before refreshing data for another path")
            try expect(scopeStoreAfterMismatch == scopeStoreBeforeMismatch,
                       "rejecting a moved bookmark must preserve the saved bookmark and path association")
            try expect(!SelectedScopePathProbe.isAvailable(
                at: differentPath.path, using: loaded[0]
            ),
                       "a bookmark that resolves to another path must not make the recorded path appear available")
            let scopeStoreAfterProbe = try Data(contentsOf: storeURL)
            try expect(scopeStoreAfterProbe == scopeStoreBeforeProbe,
                       "a read-only path availability check must not refresh or rewrite the saved bookmark")
            let refreshedBookmarkData = try root.bookmarkData(
                options: SelectedScopeBookmarkStore.creationOptions(isSandboxed: false),
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let staleResolution = try SelectedScopeBookmarkStore.resolve(
                loaded[0],
                at: storeURL,
                resolvingBookmarkData: { _ in (url: root, isStale: true) },
                creatingBookmarkData: { _ in refreshedBookmarkData }
            )
            let refreshedBookmarks = try SelectedScopeBookmarkStore.load(from: storeURL)
            try expect(staleResolution.standardizedFileURL.path == root.standardizedFileURL.path
                       && refreshedBookmarks.count == 1
                       && refreshedBookmarks[0].path == root.standardizedFileURL.path
                       && refreshedBookmarks[0].bookmarkData == refreshedBookmarkData,
                       "a stale same-path bookmark should refresh in place without changing its scope identity")
            let selectedAlias = base.appendingPathComponent("selected-alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: selectedAlias, withDestinationURL: root)
            try expect(!SelectedScopePathProbe.isAvailable(at: selectedAlias.path),
                       "an availability check must not follow a selected symlink")
            try expect(!SelectedScopePathProbe.isAvailable(at: base.appendingPathComponent("missing-folder").path),
                       "an unavailable selected path must remain an explicit false result")
            let rescanned = FolderScanner.scan(roots: [resolved])
            try expect(rescanned.folders.first?.complete == true && rescanned.folders.first?.fileCount == 1,
                       "the metadata scanner should be able to rescan a resolved selected-scope bookmark")
            try expect(rescanned.folders.first?.logicalBytes == Int64(bytes.count),
                       "bookmark rescans should report fixture metadata without changing its size")

            let repeated = try SelectedScopeBookmarkStore.remember([root], at: storeURL)
            try expect(repeated.count == 1, "selecting the same folder again should update rather than duplicate it")
            let forgotten = try SelectedScopeBookmarkStore.remove(path: root.path, at: storeURL)
            try expect(forgotten.isEmpty, "forget should remove the saved access bookmark")
            let appBundle = base.appendingPathComponent("Sample.app", isDirectory: true)
            try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: false)
            let savedBundle = try SelectedScopeBookmarkStore.remember([appBundle], at: storeURL)
            try expect(savedBundle.map(\.path) == [appBundle.standardizedFileURL.path],
                       "the same bounded store should accept an explicitly selected app bundle")
            _ = try SelectedScopeBookmarkStore.remove(path: appBundle.path, at: storeURL)
            let unchangedBytes = try Data(contentsOf: fixture)
            try expect(unchangedBytes == bytes,
                       "remembering, resolving, and forgetting a scope must not alter selected files")

            let crowdedStore = base.appendingPathComponent("crowded.json")
            var locations: [URL] = []
            for index in 0...SelectedScopeBookmarkStore.maximumBookmarkCount {
                let location = base.appendingPathComponent("scope-\(index)", isDirectory: true)
                try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
                locations.append(location)
            }
            do {
                _ = try SelectedScopeBookmarkStore.remember(locations, at: crowdedStore)
                throw CheckFailure.assertion("scope store should reject more than its bounded capacity")
            } catch SelectedScopeBookmarkError.tooManyBookmarks { }
            let rejectedBookmarks = try SelectedScopeBookmarkStore.load(from: crowdedStore)
            try expect(rejectedBookmarks.isEmpty,
                       "a rejected over-limit selection must not partially persist permissions")

            let fullStore = base.appendingPathComponent("full-scope-store.json")
            let existingLocations = Array(locations.prefix(SelectedScopeBookmarkStore.maximumBookmarkCount))
            _ = try SelectedScopeBookmarkStore.remember(existingLocations, at: fullStore)
            let overflowLocation = locations[SelectedScopeBookmarkStore.maximumBookmarkCount]
            let overflowBookmarkData = try overflowLocation.bookmarkData(
                options: SelectedScopeBookmarkStore.creationOptions(isSandboxed: false),
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let overflowBookmark = SelectedScopeBookmark(
                path: overflowLocation.standardizedFileURL.path,
                bookmarkData: overflowBookmarkData
            )
            let fullStoreBeforeRefresh = try Data(contentsOf: fullStore)
            var attemptedOverflowRefresh = false
            var overflowRejected = false
            do {
                _ = try SelectedScopeBookmarkStore.resolve(
                    overflowBookmark,
                    at: fullStore,
                    resolvingBookmarkData: { _ in (url: overflowLocation, isStale: true) },
                    creatingBookmarkData: { _ in
                        attemptedOverflowRefresh = true
                        return overflowBookmarkData
                    }
                )
            } catch SelectedScopeBookmarkError.tooManyBookmarks {
                overflowRejected = true
            }
            let fullStoreAfterRefresh = try Data(contentsOf: fullStore)
            let fullStoreEntriesAfterRefresh = try SelectedScopeBookmarkStore.load(from: fullStore)
            try expect(overflowRejected && !attemptedOverflowRefresh,
                       "stale refresh should reject a missing scope at capacity before minting another bookmark")
            try expect(fullStoreAfterRefresh == fullStoreBeforeRefresh
                       && fullStoreEntriesAfterRefresh.count == SelectedScopeBookmarkStore.maximumBookmarkCount,
                       "a rejected stale refresh must preserve the bounded bookmark store")
        }
    }

    private static func testLocalStoresRejectSymlinks() throws {
        try withTemporaryDirectory { root in
            let historyTarget = root.appendingPathComponent("history-target.json")
            let historyLink = root.appendingPathComponent("history-link.json")
            let historyBytes = Data("{}".utf8)
            try historyBytes.write(to: historyTarget)
            try FileManager.default.createSymbolicLink(atPath: historyLink.path, withDestinationPath: historyTarget.path)
            var historyRejected = false
            do {
                _ = try ObservationStore.load(from: historyLink)
            } catch {
                historyRejected = error.localizedDescription.contains("not a regular file")
            }
            try expect(historyRejected, "history loading must reject a symlink instead of reading its target")
            let historyAfterRejection = try Data(contentsOf: historyTarget)
            try expect(historyAfterRejection == historyBytes,
                       "rejecting a history symlink must leave its target unchanged")
            try ObservationStore.clear(at: historyLink)
            try expect(!FileManager.default.fileExists(atPath: historyLink.path),
                       "clearing a local history symlink should remove only the link")
            let historyAfterClear = try Data(contentsOf: historyTarget)
            try expect(historyAfterClear == historyBytes,
                       "clearing a local history symlink must never remove or change its target")

            let bookmarkTarget = root.appendingPathComponent("bookmark-target.json")
            let bookmarkLink = root.appendingPathComponent("bookmark-link.json")
            let bookmarkBytes = Data("[]".utf8)
            try bookmarkBytes.write(to: bookmarkTarget)
            try FileManager.default.createSymbolicLink(atPath: bookmarkLink.path, withDestinationPath: bookmarkTarget.path)
            var bookmarkRejected = false
            do {
                _ = try SelectedScopeBookmarkStore.load(from: bookmarkLink)
            } catch {
                bookmarkRejected = error.localizedDescription.contains("not a regular file")
            }
            try expect(bookmarkRejected, "bookmark loading must reject a symlink instead of reading its target")
            let bookmarkAfterRejection = try Data(contentsOf: bookmarkTarget)
            try expect(bookmarkAfterRejection == bookmarkBytes,
                       "rejecting a bookmark symlink must leave its target unchanged")
            try SelectedScopeBookmarkStore.clear(at: bookmarkLink)
            try expect(!FileManager.default.fileExists(atPath: bookmarkLink.path),
                       "clearing a local bookmark symlink should remove only the link")
            let bookmarkAfterClear = try Data(contentsOf: bookmarkTarget)
            try expect(bookmarkAfterClear == bookmarkBytes,
                       "clearing a local bookmark symlink must never remove or change its target")

            let oversizedBookmark = root.appendingPathComponent("oversized-bookmarks.json")
            guard FileManager.default.createFile(atPath: oversizedBookmark.path, contents: Data()) else {
                throw CheckFailure.assertion("synthetic oversized bookmark file should be created")
            }
            let descriptor = open(oversizedBookmark.path, O_WRONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw CheckFailure.assertion("synthetic oversized bookmark file should open")
            }
            let truncateResult = ftruncate(descriptor, off_t(8 * 1024 * 1024 + 1))
            close(descriptor)
            try expect(truncateResult == 0, "synthetic oversized bookmark fixture should remain sparse")
            var sizeRejected = false
            do {
                _ = try SelectedScopeBookmarkStore.load(from: oversizedBookmark)
            } catch {
                sizeRejected = error.localizedDescription.contains("size limit")
            }
            try expect(sizeRejected, "bookmark stores should reject files above their bounded read size")

            let storeTargetDirectory = root.appendingPathComponent("real-store", isDirectory: true)
            let storeDirectoryLink = root.appendingPathComponent("linked-store", isDirectory: true)
            try FileManager.default.createDirectory(at: storeTargetDirectory, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storeTargetDirectory.path)
            let targetHistory = storeTargetDirectory.appendingPathComponent("observations.json")
            let targetHistoryBytes = Data("{}".utf8)
            try targetHistoryBytes.write(to: targetHistory)
            try FileManager.default.createSymbolicLink(
                atPath: storeDirectoryLink.path, withDestinationPath: storeTargetDirectory.path
            )
            let linkedHistory = storeDirectoryLink.appendingPathComponent("observations.json")
            var directoryRejected = false
            do {
                _ = try ObservationStore.append(
                    ScanObservation(startedAt: .now, folders: [], cancelled: false), to: linkedHistory
                )
            } catch {
                directoryRejected = error.localizedDescription.contains("private data folder")
            }
            try expect(directoryRejected, "local stores must reject a symlinked private-data directory")
            var clearDirectoryRejected = false
            do {
                try ObservationStore.clear(at: linkedHistory)
            } catch {
                clearDirectoryRejected = error.localizedDescription.contains("private data folder")
            }
            try expect(clearDirectoryRejected, "history reset must reject a symlinked private-data directory")
            let targetHistoryAfterRejection = try Data(contentsOf: targetHistory)
            try expect(targetHistoryAfterRejection == targetHistoryBytes,
                       "rejecting a symlinked store directory must leave its contents unchanged")
            let targetDirectoryPermissions = try FileManager.default.attributesOfItem(
                atPath: storeTargetDirectory.path
            )[.posixPermissions] as? NSNumber
            try expect(targetDirectoryPermissions?.intValue == 0o755,
                       "rejecting a symlinked store directory must not alter the target directory's permissions")
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
        print("  / volume: \(sample.volumeName ?? "unknown") · UUID \(sample.volumeUUID ?? "unavailable") · total \(sample.totalBytes) bytes; available \(sample.availableBytes) bytes")
    }

    private static func testLiveRAMSample() throws {
        let sample = try RAMObservation.current(processLimit: 1)
        try expect(sample.physicalBytes > 0, "macOS should report installed physical RAM")
        try expect(sample.largestProcesses.count <= 1, "process list should respect its requested limit")
        try expect(sample.sampledProcessCount > 0, "process list should include accessible processes")
        if let swap = sample.swapUsage {
            try expect(swap.usedBytes <= swap.totalBytes && swap.availableBytes <= swap.totalBytes,
                       "reported swap use should be bounded by the total swap allocation, including the zero-allocation state")
        }
        let swapSummary = sample.swapUsage.map {
            $0.totalBytes == 0 ? "no swap allocated" : "\($0.usedBytes)/\($0.totalBytes) swap bytes used/total"
        } ?? "swap statistics unavailable"
        print("  RAM: \(sample.physicalBytes) bytes; process list available: \(sample.processListAvailable); \(sample.sampledProcessCount) processes sampled; \(swapSummary)")
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

        let rollbackSamples = [
            ramObservation(at: 0, processStart: processStart, residentBytes: 100 * 1_048_576),
            ramObservation(at: 60 * 60, processStart: processStart, residentBytes: 150 * 1_048_576),
            ramObservation(at: 15 * 60, processStart: processStart, residentBytes: 250 * 1_048_576),
        ]
        try expect(ObservationComparison.possibleProcessGrowth(
            in: LocalHistory(ramObservations: rollbackSamples)
        ).isEmpty,
                   "a timestamp inversion must break the continuous RAM growth sample run")

        let fiveMinuteSamples = [0, 5, 10, 15].enumerated().map { index, minutes in
            ramObservation(
                at: TimeInterval(minutes * 60), processStart: processStart,
                residentBytes: UInt64([50, 100, 150, 220][index]) * 1_048_576
            )
        }
        let automaticSignals = ObservationComparison.possibleProcessGrowth(
            in: LocalHistory(ramObservations: fiveMinuteSamples)
        )
        try expect(automaticSignals.count == 1 && automaticSignals[0].growthBytes == 170 * 1_048_576
                   && automaticSignals[0].firstObservedAt == Date(timeIntervalSince1970: 0),
                   "five-minute samples should use four observations to cover a 15-minute growth interval")
        let tooShortSamples = Array(fiveMinuteSamples.prefix(3))
        try expect(ObservationComparison.possibleProcessGrowth(
            in: LocalHistory(ramObservations: tooShortSamples)
        ).isEmpty, "three five-minute samples should not be compared as a 15-minute trend")

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

    private static func testRAMMonitoringPolicy() throws {
        try expect(RAMMonitoringPolicy.interval == 300, "automatic RAM sampling should use a five-minute cadence")
        try expect(RAMMonitoringPolicy.shouldSample(enabled: true, appIsActive: true, sampleInProgress: false),
                   "an opted-in active app may take a scheduled sample")
        try expect(!RAMMonitoringPolicy.shouldSample(enabled: false, appIsActive: true, sampleInProgress: false),
                   "RAM sampling should remain off unless explicitly enabled")
        try expect(!RAMMonitoringPolicy.shouldSample(enabled: true, appIsActive: false, sampleInProgress: false),
                   "automatic RAM sampling should pause while Disker is inactive")
        try expect(!RAMMonitoringPolicy.shouldSample(enabled: true, appIsActive: true, sampleInProgress: true),
                   "scheduled samples should not overlap an active manual sample")
        try expect(RAMMonitoringPolicy.shouldObservePressure(enabled: true, appIsActive: true),
                   "system pressure events should be observed during an opted-in active session")
        try expect(!RAMMonitoringPolicy.shouldObservePressure(enabled: true, appIsActive: false)
                   && !RAMMonitoringPolicy.shouldObservePressure(enabled: false, appIsActive: true),
                   "pressure observation should stop when Disker is inactive or monitoring is disabled")
    }

    private static func testStorageMonitoringPolicy() throws {
        let start = Date(timeIntervalSince1970: 10_000)
        let roots: Set<String> = ["/saved/alpha", "/saved/beta", "/saved/gamma"]
        let base = StorageMonitoringPolicy.Input(
            enabled: true,
            enabledAt: start,
            appIsActive: true,
            savedRootIdentifiers: roots,
            selectedRootIdentifiers: roots
        )

        try expect(StorageMonitoringPolicy.defaultInterval == 900,
                   "storage monitoring should default to a fifteen-minute cadence")
        let defaults = StorageMonitoringPolicy.evaluate(
            StorageMonitoringPolicy.Input(enabled: true, interval: 1, enabledAt: start, appIsActive: true,
                                          savedRootIdentifiers: roots, selectedRootIdentifiers: roots),
            at: start.addingTimeInterval(299)
        )
        try expect(defaults.effectiveInterval == 300 && defaults.nextScheduledRootIdentifier == nil,
                   "the cadence must clamp to five minutes and wait a full interval after opt-in")
        let minimumReached = StorageMonitoringPolicy.evaluate(base, at: start.addingTimeInterval(900))
        try expect(minimumReached.nextScheduledRootIdentifier == "/saved/alpha",
                   "the first due root should be selected in stable lexical order")

        let rootStarted = StorageMonitoringPolicy.Input(
            enabled: true, interval: 300, enabledAt: start, appIsActive: true,
            savedRootIdentifiers: roots, selectedRootIdentifiers: roots,
            scheduledScanRootIdentifiers: ["/saved/alpha"],
            lastScheduledStartByRoot: ["/saved/alpha": start.addingTimeInterval(300)]
        )
        let whileRootBusy = StorageMonitoringPolicy.evaluate(rootStarted, at: start.addingTimeInterval(600))
        try expect(whileRootBusy.nextScheduledRootIdentifier == nil,
                   "a scheduled scan must not overlap another scheduled root")
        let oneDuePerEvaluation = StorageMonitoringPolicy.evaluate(
            StorageMonitoringPolicy.Input(
                enabled: true, interval: 300, enabledAt: start, appIsActive: true,
                savedRootIdentifiers: roots, selectedRootIdentifiers: roots,
                lastScheduledStartByRoot: ["/saved/alpha": start.addingTimeInterval(600)]
            ),
            at: start.addingTimeInterval(600)
        )
        try expect(oneDuePerEvaluation.nextScheduledRootIdentifier == "/saved/beta",
                   "each evaluation should return at most one due root in deterministic order")

        let rollback = StorageMonitoringPolicy.evaluate(
            StorageMonitoringPolicy.Input(
                enabled: true, interval: 300, enabledAt: start, appIsActive: true,
                savedRootIdentifiers: roots, selectedRootIdentifiers: roots,
                lastScheduledStartByRoot: ["/saved/alpha": start.addingTimeInterval(600)]
            ),
            at: start.addingTimeInterval(599)
        )
        try expect(rollback.nextScheduledRootIdentifier == "/saved/beta",
                   "a wall-clock rollback must not make a previously scanned root due again")
        let afterRollback = StorageMonitoringPolicy.evaluate(
            StorageMonitoringPolicy.Input(
                enabled: true, interval: 300, enabledAt: start, appIsActive: true,
                savedRootIdentifiers: roots, selectedRootIdentifiers: ["/saved/alpha"],
                lastScheduledStartByRoot: ["/saved/alpha": start.addingTimeInterval(600)]
            ),
            at: start.addingTimeInterval(900)
        )
        try expect(afterRollback.nextScheduledRootIdentifier == "/saved/alpha",
                   "a root should become due only after its full interval has elapsed")

        let disabled = StorageMonitoringPolicy.evaluate(
            StorageMonitoringPolicy.Input(scheduledScanRootIdentifiers: ["/saved/alpha"]), at: start
        )
        let inactive = StorageMonitoringPolicy.evaluate(
            StorageMonitoringPolicy.Input(enabled: true, appIsActive: false,
                                          scheduledScanRootIdentifiers: ["/saved/alpha"]), at: start
        )
        try expect(disabled.cancelScheduledRootIdentifiers == ["/saved/alpha"]
                   && inactive.cancelScheduledRootIdentifiers == ["/saved/alpha"],
                   "disabling monitoring or app inactivity should cancel scheduled scans")

        let excluded = StorageMonitoringPolicy.evaluate(
            StorageMonitoringPolicy.Input(
                enabled: true, enabledAt: start, appIsActive: true,
                savedRootIdentifiers: roots.subtracting(["/saved/alpha"]),
                selectedRootIdentifiers: roots,
                pausedRootIdentifiers: ["/saved/beta"],
                resettingRootIdentifiers: ["/saved/gamma"],
                scheduledScanRootIdentifiers: roots
            ),
            at: start.addingTimeInterval(900)
        )
        try expect(excluded.eligibleRootIdentifiers.isEmpty
                   && excluded.cancelScheduledRootIdentifiers == roots,
                   "forgotten, paused, and resetting roots must be ineligible and cancel scheduled work")

        let manualTakeover = StorageMonitoringPolicy.evaluate(
            StorageMonitoringPolicy.Input(
                enabled: true, enabledAt: start, appIsActive: true,
                savedRootIdentifiers: roots, selectedRootIdentifiers: roots,
                manualScanRootIdentifiers: ["/saved/alpha"],
                scheduledScanRootIdentifiers: ["/saved/alpha"]
            ),
            at: start.addingTimeInterval(900)
        )
        try expect(manualTakeover.cancelScheduledRootIdentifiers == ["/saved/alpha"]
                   && manualTakeover.nextScheduledRootIdentifier == nil,
                   "manual scanning should supersede its scheduled scan and block scheduling while busy")
        let globalBusy = StorageMonitoringPolicy.evaluate(
            StorageMonitoringPolicy.Input(enabled: true, enabledAt: start, appIsActive: true,
                                          globalScanInProgress: true,
                                          savedRootIdentifiers: roots, selectedRootIdentifiers: roots),
            at: start.addingTimeInterval(900)
        )
        try expect(globalBusy.nextScheduledRootIdentifier == nil,
                   "scheduled monitoring must wait for any unrelated global scan to finish")
        let malformedCadence = StorageMonitoringPolicy.evaluate(
            StorageMonitoringPolicy.Input(enabled: true, interval: .infinity, enabledAt: start,
                                          appIsActive: true, savedRootIdentifiers: roots,
                                          selectedRootIdentifiers: roots),
            at: start.addingTimeInterval(900)
        )
        try expect(malformedCadence.effectiveInterval == StorageMonitoringPolicy.defaultInterval,
                   "non-finite interval settings should fall back to the safe default")
    }

    private static func testMemoryPressureEventMapping() throws {
        try expect(MemoryPressureLevel.from(events: .normal) == .normal,
                   "a system normal-pressure transition should remain normal")
        try expect(MemoryPressureLevel.from(events: .warning) == .warning,
                   "a system warning-pressure transition should remain warning")
        try expect(MemoryPressureLevel.from(events: .critical) == .critical,
                   "a system critical-pressure transition should remain critical")
        try expect(MemoryPressureLevel.from(events: [.warning, .critical]) == .critical,
                   "when event flags overlap, the most severe pressure level should be retained")
        try expect(MemoryPressureLevel.from(events: []) == nil,
                   "unknown dispatch event flags must not be presented as a pressure state")

        let event = MemoryPressureObservation(
            observedAt: Date(timeIntervalSince1970: 42), level: .warning
        )
        let restored = try JSONDecoder().decode(
            MemoryPressureObservation.self, from: JSONEncoder().encode(event)
        )
        try expect(restored == event, "system pressure transitions should persist with their timestamp and level")
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
            var rootMetadata = stat()
            try expect(root.path.withCString({ lstat($0, &rootMetadata) }) == 0,
                       "selected root should remain available for volume metadata validation")
            let expectedVolumeDeviceID = UInt64(truncatingIfNeeded: rootMetadata.st_dev)
            try expect(result.folders[0].volumeDeviceID == expectedVolumeDeviceID,
                       "folder observations should retain the selected root's no-follow device identity")
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

    private static func testSelectedRootOverlap() throws {
        try expect(
            SelectedRootScope.hasOverlappingPaths(["/Users/example/Project", "/Users/example/Project/Build"]),
            "a selected parent and child folder should be recognized as overlapping scopes"
        )
        try expect(
            SelectedRootScope.hasOverlappingPaths(["/Users/example/Project", "/Users/example/Project"]),
            "the same path selected twice should be recognized as an overlapping scope"
        )
        try expect(
            !SelectedRootScope.hasOverlappingPaths(["/Users/example/Project", "/Users/example/Project-Archive"]),
            "a sibling path with the same textual prefix must not be treated as a descendant"
        )
        try expect(
            SelectedRootScope.hasOverlappingPaths(["/", "/Users/example/Project"]),
            "the filesystem root should overlap every descendant path"
        )
    }

    private static func testNestedVolumeBoundary() throws {
        try withTemporaryDirectory { root in
            try Data(repeating: 0x41, count: 4096).write(to: root.appendingPathComponent("root.bin"))
            let sameVolumeDirectory = root.appendingPathComponent("ordinary", isDirectory: true)
            try FileManager.default.createDirectory(at: sameVolumeDirectory, withIntermediateDirectories: false)
            try Data(repeating: 0x42, count: 2048).write(to: sameVolumeDirectory.appendingPathComponent("child.bin"))
            let syntheticMount = root.appendingPathComponent("mounted", isDirectory: true)
            try FileManager.default.createDirectory(at: syntheticMount, withIntermediateDirectories: false)
            try Data(repeating: 0x43, count: 8192).write(to: syntheticMount.appendingPathComponent("external.bin"))
            let syntheticMountedFile = root.appendingPathComponent("mounted-file.bin")
            try Data(repeating: 0x44, count: 1024).write(to: syntheticMountedFile)

            var rootMetadata = stat()
            try expect(root.path.withCString({ lstat($0, &rootMetadata) }) == 0,
                       "synthetic scan root should expose its actual device identifier")
            let rootDeviceID = UInt64(truncatingIfNeeded: rootMetadata.st_dev)
            let differentDeviceID = rootDeviceID == UInt64.max ? rootDeviceID - 1 : rootDeviceID + 1
            let result = FolderScanner.scan(
                roots: [root], simulatedDeviceIDsByPath: [
                    syntheticMount.path: differentDeviceID,
                    syntheticMountedFile.path: differentDeviceID,
                ]
            )
            guard let folder = result.folders.first else {
                throw CheckFailure.assertion("one selected root should yield a synthetic mount-boundary result")
            }
            try expect(folder.logicalBytes == 6144 && folder.fileCount == 2,
                       "root totals should include same-volume files but exclude nested-volume content")
            try expect(folder.excludedVolumeBoundaryCount == 2 && !folder.complete
                       && folder.inaccessibleCount == 0,
                       "an excluded nested volume should be reported as partial, not as a permission failure")
            let ordinary = try requireSummary("ordinary", in: folder)
            let mount = try requireSummary("mounted", in: folder)
            try expect(ordinary.complete && ordinary.logicalBytes == 2048,
                       "ordinary same-volume child directories should still be scanned completely")
            try expect(!mount.complete && mount.logicalBytes == 0 && mount.excludedVolumeBoundaryCount == 1,
                       "the excluded mountpoint should remain visible as a zero-byte incomplete boundary")
        }
    }

    private static func testFileExtensionSummaries() throws {
        try withTemporaryDirectory { root in
            let database = root.appendingPathComponent("events.sqlite")
            let databaseBytes = Data(repeating: 0x31, count: 8_300)
            try databaseBytes.write(to: database)
            try FileManager.default.linkItem(
                at: database, to: root.appendingPathComponent("events.db")
            )
            try Data(repeating: 0x52, count: 12_500)
                .write(to: root.appendingPathComponent("weights.safetensors"))
            try Data(repeating: 0x73, count: 2_600)
                .write(to: root.appendingPathComponent("server.log"))
            try Data(repeating: 0x14, count: 1_300)
                .write(to: root.appendingPathComponent("README"))

            let folder = FolderScanner.scan(roots: [root]).folders[0]
            let summaries = Dictionary(uniqueKeysWithValues: folder.fileExtensionSummaries.map {
                ($0.extensionName, $0)
            })
            try expect(folder.complete && folder.fileCount == 4,
                       "extension summaries should describe the same complete deduplicated file scan")
            try expect(summaries["db"]?.fileCount == 1 && summaries["sqlite"] == nil,
                       "a hard link should contribute once under its deterministic retained filename")
            try expect(summaries["safetensors"]?.fileCount == 1
                       && summaries["log"]?.fileCount == 1
                       && summaries["no extension"]?.fileCount == 1,
                       "metadata summaries should classify safe filename extensions and extensionless files")
            try expect(folder.fileExtensionSummaries.reduce(Int64(0)) { $0 + $1.logicalBytes }
                       == folder.logicalBytes
                       && folder.fileExtensionSummaries.reduce(Int64(0)) { $0 + $1.allocatedBytes }
                       == folder.allocatedBytes,
                       "untruncated file-extension metrics should account for each measured file object once")
            let databaseAfterScan = try Data(contentsOf: database)
            try expect(databaseAfterScan == databaseBytes,
                       "metadata-only extension classification must leave file contents unchanged")

            let encoded = try JSONEncoder().encode(folder)
            let decoded = try JSONDecoder().decode(FolderObservation.self, from: encoded)
            try expect(decoded.fileExtensionSummaries == folder.fileExtensionSummaries
                       && !decoded.fileExtensionSummariesTruncated,
                       "bounded extension summaries should persist with the folder observation")

            let manyRoot = root.appendingPathComponent("many-extensions", isDirectory: true)
            try FileManager.default.createDirectory(at: manyRoot, withIntermediateDirectories: false)
            for index in 0..<35 {
                let ext = String(format: "e%02d", index)
                try Data(repeating: UInt8(index), count: 100)
                    .write(to: manyRoot.appendingPathComponent("sample.\(ext)"))
            }
            let capped = FolderScanner.scan(roots: [manyRoot]).folders[0]
            try expect(capped.fileExtensionSummaries.count == 30
                       && capped.fileExtensionSummariesTruncated
                       && capped.otherFileExtensionCategoryCount == 5
                       && capped.otherFileExtensionUsage?.fileCount == 5,
                       "extension metadata should retain a stable top cap and aggregate omitted categories")
            try expect(capped.fileExtensionSummaries.reduce(Int64(0)) { $0 + $1.logicalBytes }
                           + (capped.otherFileExtensionUsage?.logicalBytes ?? 0) == capped.logicalBytes
                       && capped.fileExtensionSummaries.reduce(Int64(0)) { $0 + $1.allocatedBytes }
                           + (capped.otherFileExtensionUsage?.allocatedBytes ?? 0) == capped.allocatedBytes,
                       "the retained categories plus omitted-category aggregate should reconcile to measured totals")
            let cappedDecoded = try JSONDecoder().decode(
                FolderObservation.self, from: JSONEncoder().encode(capped)
            )
            try expect(cappedDecoded.otherFileExtensionUsage == capped.otherFileExtensionUsage
                       && cappedDecoded.otherFileExtensionCategoryCount == 5,
                       "omitted filename-category totals should persist as a bounded aggregate")
        }
    }

    private static func testDiskerFootprintScope() throws {
        try withTemporaryDirectory { root in
            let bundle = root.appendingPathComponent("Disker.app", isDirectory: true)
            let support = root.appendingPathComponent("Application Support/Disker", isDirectory: true)
            let neighboring = root.appendingPathComponent("Application Support/AnotherApp", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: neighboring, withIntermediateDirectories: true)
            let bundleData = Data(repeating: 0x31, count: 19)
            let supportData = Data(repeating: 0x52, count: 23)
            let neighboringData = Data(repeating: 0x73, count: 4096)
            try bundleData.write(to: bundle.appendingPathComponent("binary"))
            try supportData.write(to: support.appendingPathComponent("observations.json"))
            try neighboringData.write(to: neighboring.appendingPathComponent("private.bin"))

            let result = DiskerFootprintScanner.scan(
                bundleURL: bundle, supportDirectory: support
            )
            try expect(result.folders.map(\.path) == [bundle.path, support.path],
                       "the own-footprint check should scan only the app bundle and its dedicated support directory")
            try expect(result.folders.map(\.logicalBytes) == [Int64(bundleData.count), Int64(supportData.count)],
                       "neighboring application support data must not contribute to Disker's footprint")
            try expect(result.folders.allSatisfy(\.complete),
                       "ordinary synthetic bundle and support directories should have complete coverage")
            let bundleAfter = try Data(contentsOf: bundle.appendingPathComponent("binary"))
            let supportAfter = try Data(contentsOf: support.appendingPathComponent("observations.json"))
            let neighboringAfter = try Data(contentsOf: neighboring.appendingPathComponent("private.bin"))
            try expect(bundleAfter == bundleData
                       && supportAfter == supportData
                       && neighboringAfter == neighboringData,
                       "metadata-only own-footprint measurement must leave all synthetic contents unchanged")

            let linkedSupport = root.appendingPathComponent("linked-support", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linkedSupport, withDestinationURL: neighboring)
            let linkedResult = DiskerFootprintScanner.scan(
                bundleURL: bundle, supportDirectory: linkedSupport
            )
            try expect(linkedResult.folders.count == 2
                       && linkedResult.folders[1].excludedSymlinkCount == 1
                       && !linkedResult.folders[1].complete,
                       "a symlinked support root should be reported as partial without following its target")

            try expect(DiskerFootprintScanner.selectedRoots(
                bundleURL: bundle, supportDirectory: bundle
            ).map(\.path) == [bundle.path],
                       "the same app and support path should not be measured twice")
        }
    }

    private static func testSpecialFileExclusion() throws {
        try withTemporaryDirectory { root in
            let regularFile = root.appendingPathComponent("payload.txt")
            try Data(repeating: 0x31, count: 512).write(to: regularFile)
            let nested = root.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            for pipeURL in [root.appendingPathComponent("root-stream.db"), nested.appendingPathComponent("nested-stream.sqlite")] {
                let result = pipeURL.path.withCString { mkfifo($0, mode_t(S_IRUSR | S_IWUSR)) }
                try expect(result == 0, "synthetic FIFO fixtures should be created without reading or writing their endpoints")
            }

            let folder = FolderScanner.scan(roots: [root]).folders[0]
            try expect(folder.fileCount == 1 && folder.fileExtensionSummaries.map(\.extensionName) == ["txt"],
                       "special entries must not enter regular-file totals or filename categories")
            try expect(folder.excludedSpecialFileCount == 2 && folder.inaccessibleCount == 0 && !folder.complete,
                       "excluded special entries should be visible as partial coverage, not access failures")
            let nestedSummary = try requireSummary("nested", in: folder)
            try expect(nestedSummary.excludedSpecialFileCount == 1 && !nestedSummary.complete,
                       "special entries should make only their containing subtree partial")
            let decoded = try JSONDecoder().decode(
                FolderObservation.self, from: JSONEncoder().encode(folder)
            )
            try expect(decoded.excludedSpecialFileCount == 2
                       && decoded.subdirectorySummaries.first(where: { $0.rootRelativePath == "nested" })?
                            .excludedSpecialFileCount == 1,
                       "special-entry coverage counts should persist at root and subtree levels")

            let selectedFIFO = root.appendingPathComponent("nested/nested-stream.sqlite")
            let selected = FolderScanner.scan(roots: [selectedFIFO]).folders[0]
            try expect(selected.excludedSpecialFileCount == 1 && selected.fileCount == 0 && !selected.complete,
                       "a selected special-file root should remain excluded and explicitly incomplete")
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

            var progressEvents: [DuplicateVerificationProgress] = []
            var lastProgress: DuplicateVerificationProgress?
            var readEstimate: DuplicateVerificationReadEstimate?
            let result = DuplicateVerifier.verify(
                roots: [root],
                progress: {
                    progressEvents.append($0)
                    lastProgress = $0
                },
                authorizeContentRead: { estimate in
                    readEstimate = estimate
                    return true
                }
            )
            try expect(result.groups.count == 1, "only byte-identical same-size files should form a duplicate group")
            try expect(result.groups[0].files.map(\.path) == [first.path, second.path], "hard-link aliases should not be reported as separate files")
            try expect(result.groups[0].files.allSatisfy { $0.logicalBytes == UInt64(sharedBytes.count) }, "duplicate candidates should retain exact logical sizes")
            try expect(result.checkedFileCount == 3, "only regular files in shared-size buckets should be hashed")
            try expect(result.excludedSymlinkCount == 1 && !result.complete, "symlinks should remain excluded and make verification coverage partial")
            let metadataProgress = progressEvents.first { $0.phase == .readingMetadata }
            let awaitingAuthorizationProgress = progressEvents.first { $0.phase == .awaitingContentAuthorization }
            let contentProgress = progressEvents.first { $0.phase == .readingContents }
            guard let metadataIndex = progressEvents.firstIndex(where: { $0.phase == .readingMetadata }),
                  let authorizationIndex = progressEvents.firstIndex(where: { $0.phase == .awaitingContentAuthorization }),
                  let contentIndex = progressEvents.firstIndex(where: { $0.phase == .readingContents }) else {
                throw CheckFailure.assertion("duplicate verification should report metadata, consent, and content phases")
            }
            try expect(metadataIndex < authorizationIndex && authorizationIndex < contentIndex,
                       "metadata inspection and explicit content authorization must precede content reads")
            try expect(metadataProgress?.entriesVisited == 6
                       && metadataProgress?.bytesHashed == 0 && metadataProgress?.candidateBytes == 0,
                       "metadata progress should identify examined entries without implying a file-content read")
            try expect(contentProgress?.entriesVisited == 6
                       && contentProgress?.bytesHashed == 0
                       && contentProgress?.candidateFileCount == 3
                       && contentProgress?.candidateBytes == UInt64(sharedBytes.count * 3),
                       "the content phase should begin only after metadata identifies the candidate read volume")
            try expect(readEstimate?.selectedRootPaths == [root.path]
                       && readEstimate?.candidateFileCount == 3
                       && readEstimate?.candidateBytes == UInt64(sharedBytes.count * 3)
                       && readEstimate?.entriesVisited == 6
                       && readEstimate?.excludedSymlinkCount == 1
                       && readEstimate?.metadataCoverageComplete == false,
                       "the pre-read estimate should describe candidate bytes, selected scope, and partial coverage")
            try expect(awaitingAuthorizationProgress?.candidateFileCount == 3
                       && awaitingAuthorizationProgress?.candidateBytes == UInt64(sharedBytes.count * 3)
                       && awaitingAuthorizationProgress?.bytesHashed == 0,
                       "the consent phase should show estimated candidates before hashing starts")
            try expect(lastProgress?.bytesHashed == UInt64(sharedBytes.count * 3), "progress should report bytes actually read from size-matched candidates")

            var deniedReadProgress: [DuplicateVerificationProgress] = []
            var deniedReadEstimate: DuplicateVerificationReadEstimate?
            let deniedRead = DuplicateVerifier.verify(
                roots: [root],
                progress: { deniedReadProgress.append($0) },
                authorizeContentRead: { estimate in
                    deniedReadEstimate = estimate
                    return false
                }
            )
            try expect(deniedRead.cancelled && deniedRead.checkedFileCount == 0 && deniedRead.groups.isEmpty
                       && deniedReadEstimate?.candidateBytes == UInt64(sharedBytes.count * 3),
                       "declining the candidate read estimate should end verification before hashing files")
            try expect(!deniedReadProgress.contains(where: { $0.phase == .readingContents || $0.bytesHashed > 0 }),
                       "declining consent must not report any file-content bytes read")

            let uniqueRoot = root.appendingPathComponent("unique-only", isDirectory: true)
            try FileManager.default.createDirectory(at: uniqueRoot, withIntermediateDirectories: false)
            try Data("one unique file".utf8).write(to: uniqueRoot.appendingPathComponent("only.bin"))
            var unnecessaryAuthorizationRequested = false
            let uniqueOnly = DuplicateVerifier.verify(roots: [uniqueRoot], authorizeContentRead: { _ in
                unnecessaryAuthorizationRequested = true
                return true
            })
            try expect(!unnecessaryAuthorizationRequested && uniqueOnly.complete && uniqueOnly.checkedFileCount == 0,
                       "verification without size-matched candidates should finish without requesting file-read consent")
            let firstAfterVerification = try Data(contentsOf: first)
            let secondAfterVerification = try Data(contentsOf: second)
            try expect(firstAfterVerification == sharedBytes && secondAfterVerification == sharedBytes, "verification must leave all selected files unchanged")

            let group = result.groups[0]
            let plan = try CleanupPlanner.makePlan(
                from: result, preserving: [group.sha256: first.path]
            )
            try expect(plan.verifiedAt == result.verifiedAt,
                       "the dry-run plan should retain the time of its source content verification")
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

    private static func testDuplicateVolumeBoundary() throws {
        try withTemporaryDirectory { root in
            let matchingBytes = Data("selected-root duplicate".utf8)
            let first = root.appendingPathComponent("first.bin")
            let second = root.appendingPathComponent("second.bin")
            let mountedFile = root.appendingPathComponent("mounted-file.bin")
            try matchingBytes.write(to: first)
            try matchingBytes.write(to: second)
            try matchingBytes.write(to: mountedFile)

            let mountedDirectory = root.appendingPathComponent("mounted", isDirectory: true)
            try FileManager.default.createDirectory(at: mountedDirectory, withIntermediateDirectories: false)
            try matchingBytes.write(to: mountedDirectory.appendingPathComponent("external-a.bin"))
            try matchingBytes.write(to: mountedDirectory.appendingPathComponent("external-b.bin"))

            var rootMetadata = stat()
            try expect(root.path.withCString({ lstat($0, &rootMetadata) }) == 0,
                       "synthetic duplicate root should expose its actual device identifier")
            let rootDeviceID = UInt64(truncatingIfNeeded: rootMetadata.st_dev)
            let differentDeviceID = rootDeviceID == UInt64.max ? rootDeviceID - 1 : rootDeviceID + 1
            let result = DuplicateVerifier.verify(
                roots: [root], simulatedDeviceIDsByPath: [
                    mountedDirectory.path: differentDeviceID,
                    mountedFile.path: differentDeviceID,
                ],
                authorizeContentRead: { _ in true }
            )
            try expect(result.groups.count == 1
                       && result.groups[0].files.map(\.path) == [first.path, second.path],
                       "only duplicate files inside the selected root volume should be reported")
            try expect(result.checkedFileCount == 2 && result.excludedVolumeBoundaryCount == 2
                       && !result.complete,
                       "cross-volume candidates should not be read and should make verification partial")
            try expect(result.selectedRootPaths == [root.path],
                       "verification provenance should retain the single explicitly selected root")
        }
    }

    private static func testDuplicateVerificationCancellation() throws {
        try withTemporaryDirectory { root in
            try Data("synthetic bytes".utf8).write(to: root.appendingPathComponent("one.bin"))
            try Data("synthetic bytes".utf8).write(to: root.appendingPathComponent("two.bin"))
            let result = DuplicateVerifier.verify(
                roots: [root], shouldCancel: { true }, authorizeContentRead: { _ in true }
            )
            try expect(result.cancelled && !result.complete, "cancelled duplicate verification must stay explicitly incomplete")
            try expect(result.groups.isEmpty && result.checkedFileCount == 0, "immediate cancellation must not read or report file content")
        }
    }

    private static func testDuplicateVerificationRootLimit() throws {
        let roots = (0...DuplicateVerifier.maximumSelectedRootCount).map {
            URL(fileURLWithPath: "/synthetic/duplicate-root-\($0)")
        }
        let result = DuplicateVerifier.verify(roots: roots, authorizeContentRead: { _ in true })
        try expect(result.selectedRootLimitExceeded && !result.complete,
                   "duplicate verification must reject over-limit root sets explicitly")
        try expect(result.verifiedAt == nil && result.selectedRootPaths.isEmpty,
                   "a rejected request must not claim a verification time or accepted scope")
        try expect(result.checkedFileCount == 0 && result.groups.isEmpty,
                   "over-limit rejection must happen before opening roots or reading file contents")
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
            }, authorizeContentRead: { _ in true })
            try expect(mutated, "the verification progress checkpoint should run after candidate hashing")
            try expect(result.changedDuringCheckCount > 0 && !result.complete, "a directory entry change during hashing must make final coverage partial")
            try expect(result.groups.count == 1, "already verified groups may be retained alongside an explicit partial-coverage result")
        }
    }

    private static func testDuplicateFileRevalidation() throws {
        try withTemporaryDirectory { root in
            let first = root.appendingPathComponent("alpha.bin")
            let second = root.appendingPathComponent("beta.bin")
            let original = Data(repeating: 0x2A, count: 1024 * 1024)
            try original.write(to: first)
            try original.write(to: second)

            var changedPreviouslyHashedFile = false
            let result = DuplicateVerifier.verify(roots: [root], progress: { progress in
                guard !changedPreviouslyHashedFile, progress.currentPath == second.path else { return }
                changedPreviouslyHashedFile = true
                do {
                    let file = try FileHandle(forWritingTo: first)
                    try file.seek(toOffset: 0)
                    try file.write(contentsOf: Data(repeating: 0x7B, count: original.count))
                    try file.close()
                } catch {
                    // The assertions below make a failed mutation visible.
                }
            }, authorizeContentRead: { _ in true })
            try expect(changedPreviouslyHashedFile, "the fixture should mutate an earlier file while a later file is being hashed")
            try expect(result.changedDuringCheckCount > 0 && !result.complete,
                       "final file metadata validation should detect a mutation after hashing that file")
            try expect(result.groups.isEmpty,
                       "a changed candidate must be removed before duplicate groups are reported")
            let plan = try CleanupPlanner.makePlan(from: result, preserving: [:])
            try expect(plan.entries.isEmpty,
                       "a changed candidate must not appear in a read-only cleanup plan")
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
        let projectHints: [(String, StorageAreaHint)] = [
            ("frontend/.npm/_cacache", .npmData),
            ("frontend/.pnpm-store/v3", .pnpmStore),
            ("frontend/.yarn/cache", .yarnData),
            ("android/.gradle/caches", .gradleData),
            ("java/.m2/repository", .mavenData),
            ("rust/.cargo/registry", .cargoData),
            ("rust/target/debug", .buildOutputCandidate),
            ("ios/Pods/Library", .cocoaPodsDependencies),
            ("ios/Carthage/Build", .carthageDependencies),
            ("Library/Developer/CoreSimulator/Devices", .simulatorData),
            ("Library/Containers/Docker/Data", .dockerData),
            ("research/checkpoints", .modelDataDirectory),
            ("training/datasets", .datasetDirectory),
            ("service/logs", .logDirectory),
            ("Library/Developer/Xcode/Archives", .xcodeArchives),
            ("archive/App.xcarchive", .xcodeArchiveBundle),
            ("App.dSYM", .debugSymbols),
            ("web/.next", .webBuildOutput),
            ("web/.turbo", .webBuildCache),
            ("web/coverage", .testCoverageOutput),
        ]
        for (path, expectedHint) in projectHints {
            try expect(StorageAreaHint.matching(relativePath: path) == expectedHint,
                       "known development storage names should map to descriptive, non-ownership hints")
        }
        try expect(StorageAreaHint.matching(relativePath: "project/node_modules_backup") == nil,
                   "similar but non-exact names must not be classified")
        try expect(StorageAreaHint.matching(relativePath: "project/output") == nil,
                   "unrecognized directory names must remain unclassified")
        try expect(StorageAreaHint.matching(relativePath: "project/.git/objects") == nil,
                   "Git metadata should keep its dedicated marker and footprint presentation")
        try expect(StorageAreaHint.matchingDirectory(relativePath: "project/node_modules") == .javascriptDependencies,
                   "a directly named development folder should get an independent summary")
        try expect(StorageAreaHint.matchingDirectory(relativePath: "research/checkpoints") == .modelDataDirectory,
                   "a directly named model/checkpoint folder should become a separate candidate")
        try expect(StorageAreaHint.matchingDirectory(relativePath: "archive/App.xcarchive") == .xcodeArchiveBundle,
                   "an Xcode archive bundle should become a separate candidate")
        try expect(StorageAreaHint.matchingDirectory(relativePath: "web/dist") == .webBuildOutput,
                   "a directly named web build output should become a separate candidate")
        try expect(StorageAreaHint.matchingDirectory(relativePath: "project/.build/debug") == nil,
                   "a recognized ancestor must not classify every descendant as an independent candidate")
    }

    private static func testDeveloperArtifactReview() throws {
        let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let build = DirectoryUsage(
            rootRelativePath: "Project/.build", logicalBytes: 3_000, allocatedBytes: 2_048,
            fileCount: 4, incompleteCount: 0, excludedSymlinkCount: 0, complete: true
        )
        let dependencies = DirectoryUsage(
            rootRelativePath: "Project/.build/node_modules", logicalBytes: 1_200, allocatedBytes: 1_024,
            fileCount: 2, incompleteCount: 0, excludedSymlinkCount: 0, complete: true
        )
        let userData = DirectoryUsage(
            rootRelativePath: "research/datasets", logicalBytes: 9_000, allocatedBytes: 8_192,
            fileCount: 1, incompleteCount: 1, excludedSymlinkCount: 1, complete: false
        )
        let gitMarker = DirectoryUsage(
            rootRelativePath: "source", logicalBytes: 400, allocatedBytes: 512,
            fileCount: 2, incompleteCount: 0, excludedSymlinkCount: 0,
            gitMetadataEntryDetected: true, complete: true
        )
        let directGit = DirectoryUsage(
            rootRelativePath: ".git", logicalBytes: 128, allocatedBytes: 512,
            fileCount: 2, incompleteCount: 0, excludedSymlinkCount: 0,
            complete: true
        )
        let symbols = DirectoryUsage(
            rootRelativePath: "Release/App.dSYM", logicalBytes: 2_000, allocatedBytes: 2_048,
            fileCount: 3, incompleteCount: 0, excludedSymlinkCount: 0, complete: true
        )
        let traversalPath = DirectoryUsage(
            rootRelativePath: "../../outside/node_modules", logicalBytes: 1_000, allocatedBytes: 1_024,
            fileCount: 1, incompleteCount: 0, excludedSymlinkCount: 0, complete: true
        )
        let folder = FolderObservation(
            path: "/Volumes/Work", displayName: "Work", logicalBytes: 20_000,
            allocatedBytes: 18_000, fileCount: 12, inaccessibleCount: 1,
            finishedAt: finishedAt, complete: false, gitMetadataEntryDetected: true,
            gitMetadataUsage: directGit,
            projectDirectorySummaries: [userData, dependencies, gitMarker, build, symbols, traversalPath],
            projectDirectorySummariesTruncated: true
        )

        let review = DeveloperArtifactReview.make(from: folder)
        try expect(review.selectedRootPath == folder.path && review.observedAt == finishedAt,
                   "review should retain selected-root and observation provenance")
        try expect(!review.selectedRootComplete && review.candidatesTruncated,
                   "partial root coverage and omitted candidates must remain explicit")
        try expect(review.entries.map(\.relativePath) == [".git", "Project/.build", "Project/.build/node_modules", "Release/App.dSYM", "research/datasets", "source"],
                   "review rows should be deduplicated and deterministically sorted by exact relative path")
        let byPath = Dictionary(uniqueKeysWithValues: review.entries.map { ($0.relativePath, $0) })
        try expect(byPath["Project/.build"]?.category == .buildProducts
                   && byPath["Project/.build/node_modules"]?.category == .dependencies
                   && byPath["research/datasets"]?.category == .userData
                   && byPath["Release/App.dSYM"]?.category == .archiveOrSymbols,
                   "similar development candidates should retain distinct risk-relevant categories")
        try expect(byPath["source"]?.category == .sourceControl && byPath[".git"]?.category == .sourceControl,
                   "nested repository markers and the direct Git footprint should get source-control classification")
        try expect(byPath[".git"]?.logicalBytes == 128 && byPath[".git"]?.allocatedBytesEstimate == 512,
                   "Git footprint should preserve separate logical and allocated estimates")
        try expect(byPath["Project/.build"]?.overlappingCandidatePaths == byPath["Project/.build/node_modules"].map { [$0.path] }
                   && byPath["Project/.build/node_modules"]?.overlappingCandidatePaths == byPath["Project/.build"].map { [$0.path] },
                   "nested subtree measurements should call out overlap instead of implying additive usage")
        try expect(byPath["research/datasets"]?.subtreeComplete == false
                   && byPath["research/datasets"]?.caution.contains("partial coverage") == true,
                   "partial candidate coverage should be explicitly disclosed")
        try expect(byPath["Project/.build"]?.selectedRootComplete == false
                   && byPath["Project/.build"]?.caution.contains("selected-root scan is partial") == true,
                   "a complete subtree must not hide that its selected-root observation was partial")
        try expect(byPath["research/datasets"]?.risk.contains("High") == true
                   && byPath["research/datasets"]?.possibleConsequence.contains("permanently lose") == true,
                   "irreplaceable user data should receive a high-risk consequence warning")
        try expect(byPath["Release/App.dSYM"]?.risk.contains("High") == true,
                   "debug symbols should not be treated as routine low-risk build output")
        try expect(byPath["Project/.build"]?.evidence.contains("name-only") == true
                   && byPath[".git"]?.evidence.contains("not followed or parsed") == true,
                   "evidence should explain the name-only rule and avoid following or parsing Git markers")
        try expect(review.entries.allSatisfy({ $0.path.hasPrefix(folder.path + "/") })
                   && review.entries.allSatisfy({ $0.logicalBytes >= 0 && $0.allocatedBytesEstimate >= 0 }),
                   "review paths must stay under the selected root and sizes must remain valid nonnegative metrics")
        try expect(byPath["Project/.build"]?.caution.contains("do not add their sizes") == true,
                   "overlapping directory measurements must carry an explicit no-sum caution")
        try expect(!String(describing: review).contains("reclaimableBytes"),
                   "artifact review must not present a reclaimable-byte estimate")
        try expect(!review.entries.contains(where: { $0.relativePath == traversalPath.rootRelativePath }),
                   "persisted candidate paths containing traversal components must not escape the selected root")
    }

    private static func testFileArtifactHints() throws {
        let examples: [(String, FileArtifactHint)] = [
            ("sqlite", .database), ("sqlite-wal", .database), ("sqlite3-journal", .database),
            ("db", .database), ("db-wal", .database), ("db-shm", .database),
            ("log", .log), ("dmg", .archiveOrInstaller), ("zip", .archiveOrInstaller),
            ("gguf", .modelOrCheckpoint), ("safetensors", .modelOrCheckpoint),
            ("parquet", .structuredData), ("jsonl", .structuredData),
        ]
        for (name, expected) in examples {
            try expect(FileArtifactHint.matching(extensionName: name) == expected,
                       "known extension should get a filename-only artifact hint")
        }
        try expect(FileArtifactHint.matching(extensionName: "unknown") == nil,
                   "unknown file extensions must remain unclassified")
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
            try expect(folder.projectDirectorySummaries.contains(where: {
                $0.rootRelativePath == "vendor/project"
            }), "nested .git files should also identify bounded repository-marker folders")
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

            let specialMarkerRoot = root.appendingPathComponent("special-marker", isDirectory: true)
            try FileManager.default.createDirectory(at: specialMarkerRoot, withIntermediateDirectories: false)
            let specialMarkerResult = specialMarkerRoot.appendingPathComponent(".git")
                .path.withCString { mkfifo($0, mode_t(S_IRUSR | S_IWUSR)) }
            try expect(specialMarkerResult == 0, "synthetic special Git-like markers should be created without opening them")
            let specialMarker = FolderScanner.scan(roots: [specialMarkerRoot]).folders[0]
            try expect(!specialMarker.gitMetadataEntryDetected && specialMarker.projectDirectorySummaries.isEmpty,
                       "special filesystem entries named .git should not be presented as repository markers")
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
            for index in 0..<21 {
                let project = root.appendingPathComponent(String(format: "project-%03d", index), isDirectory: true)
                let projectGit = project.appendingPathComponent(".git", isDirectory: true)
                try FileManager.default.createDirectory(at: projectGit, withIntermediateDirectories: true)
                try Data("synthetic".utf8).write(to: project.appendingPathComponent("main.swift"))
                try Data().write(to: projectGit.appendingPathComponent("HEAD"))
            }
            let buildOutput = root.appendingPathComponent(".build", isDirectory: true)
            try FileManager.default.createDirectory(at: buildOutput, withIntermediateDirectories: false)
            try Data(repeating: 0x42, count: 512).write(to: buildOutput.appendingPathComponent("module.o"))
            let folder = FolderScanner.scan(roots: [root]).folders[0]
            try expect(folder.subdirectorySummaries.count == 100 && folder.subdirectorySummariesTruncated, "the ordinary leaderboard should remain capped at 100 entries")
            try expect(!folder.subdirectorySummaries.contains(where: { $0.rootRelativePath == ".git" }), "small Git metadata may fall below the largest-folder cutoff")
            try expect(folder.gitMetadataUsage?.logicalBytes == 0, "the direct Git metadata measurement should survive outside the capped leaderboard")
            try expect(folder.projectDirectorySummaries.count == 20 && folder.projectDirectorySummariesTruncated,
                       "project and named development-data candidates should share an independent 20-entry summary")
            try expect(folder.projectDirectorySummaries.contains(where: {
                $0.rootRelativePath == ".build" && !$0.gitMetadataEntryDetected
            }), "a named build-data folder should survive outside the ordinary 100 largest-folder cap")
            try expect(folder.projectDirectorySummaries.allSatisfy({
                $0.gitMetadataEntryDetected || StorageAreaHint.matchingDirectory(relativePath: $0.rootRelativePath) != nil
            }), "dedicated project summaries should contain only direct Git markers or exact named-folder candidates")
            try expect(!folder.subdirectorySummaries.contains(where: { $0.rootRelativePath == "project-020" }),
                       "small repository folders should remain available even below the ordinary largest-folder cutoff")
            let restored = try JSONDecoder().decode(FolderObservation.self, from: JSONEncoder().encode(folder))
            try expect(restored.projectDirectorySummaries == folder.projectDirectorySummaries
                       && restored.projectDirectorySummariesTruncated,
                       "bounded repository-marker summaries should persist with the folder observation")
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
            try expect(result.folders[0].largestFiles.count == 1
                       && result.folders[0].largestFiles[0].rootRelativePath == "linked/payload.bin",
                       "the deterministic hard-link owner should appear once in the largest-file summary: \(result.folders[0].largestFiles)")
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

    private static func testLargestFileSummaries() throws {
        try withTemporaryDirectory { root in
            let nested = root.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            let largeURL = nested.appendingPathComponent("large.dat")
            let mediumURL = root.appendingPathComponent("medium.dat")
            let smallURL = root.appendingPathComponent("small.dat")
            try Data(repeating: 0x4C, count: 32 * 1024).write(to: largeURL)
            try Data(repeating: 0x4D, count: 12 * 1024).write(to: mediumURL)
            try Data(repeating: 0x53, count: 4 * 1024).write(to: smallURL)

            let folder = FolderScanner.scan(roots: [root]).folders[0]
            var largeMetadata = stat()
            let largeMetadataResult = largeURL.path.withCString { lstat($0, &largeMetadata) }
            try expect(folder.complete, "large-file metadata summaries should not alter scan coverage")
            try expect(largeMetadataResult == 0, "synthetic large-file metadata should remain available")
            try expect(folder.largestFiles.map(\.rootRelativePath) == ["nested/large.dat", "medium.dat", "small.dat"],
                       "largest files should use descending allocated estimate with stable paths")
            try expect(folder.largestFiles.first?.logicalBytes == 32 * 1024
                       && folder.largestFiles.first?.allocatedBytes == Int64(largeMetadata.st_blocks) * 512,
                       "file summaries should preserve separate logical and filesystem allocated byte values")
            try expect(!folder.largestFilesTruncated,
                       "a small selected tree should report no omitted largest-file rows")

            let encoded = try JSONEncoder().encode(folder)
            let restored = try JSONDecoder().decode(FolderObservation.self, from: encoded)
            try expect(restored.largestFiles == folder.largestFiles,
                       "bounded largest-file paths and byte estimates should persist in local history")

            let fileRoot = FolderScanner.scan(roots: [largeURL]).folders[0]
            try expect(fileRoot.largestFiles.count == 1
                       && fileRoot.largestFiles[0].rootRelativePath.isEmpty
                       && fileRoot.largestFiles[0].logicalBytes == 32 * 1024,
                       "a selected regular-file root should identify the file without duplicating its path")

            let cappedRoot = root.appendingPathComponent("many", isDirectory: true)
            try FileManager.default.createDirectory(at: cappedRoot, withIntermediateDirectories: false)
            for index in 0..<23 {
                let url = cappedRoot.appendingPathComponent(String(format: "file-%02d.bin", index))
                try Data(repeating: UInt8(index), count: (index + 1) * 4096).write(to: url)
            }
            let capped = FolderScanner.scan(roots: [cappedRoot]).folders[0]
            try expect(capped.largestFiles.count == 20 && capped.largestFilesTruncated,
                       "largest-file history should retain a bounded list and disclose omitted files")
            try expect(capped.largestFiles.first?.rootRelativePath == "file-22.bin"
                       && capped.largestFiles.last?.rootRelativePath == "file-03.bin",
                       "the bounded file summary should retain the 20 largest allocated estimates")
        }
    }

    private static func testOldHistoryDecoding() throws {
        let json = #"{"observations":[{"id":"00000000-0000-0000-0000-000000000001","startedAt":1,"finishedAt":2,"cancelled":false,"folders":[{"id":"00000000-0000-0000-0000-000000000002","path":"/synthetic","displayName":"synthetic","logicalBytes":50,"allocatedBytes":40,"fileCount":1,"inaccessibleCount":0,"finishedAt":2,"complete":true,"subdirectorySummaries":[{"rootRelativePath":"child","logicalBytes":1,"allocatedBytes":1,"fileCount":1,"incompleteCount":0,"excludedSymlinkCount":0,"complete":true}]}]}],"applicationAssociations":[{"bundlePath":"/Applications/Legacy.app","relatedFolderPaths":["/Users/synthetic/Library/Containers/com.legacy.App"],"updatedAt":3}]}"#
        let history = try JSONDecoder().decode(LocalHistory.self, from: Data(json.utf8))
        guard let folder = history.observations.first?.folders.first else {
            throw CheckFailure.assertion("old history JSON should decode one folder")
        }
        try expect(folder.volumeDeviceID == nil, "legacy folder history should default to unknown volume identity")
        try expect(folder.excludedSymlinkCount == 0, "old folder history should default symlink count to zero")
        try expect(folder.excludedSpecialFileCount == 0, "old folder history should default special-file count to zero")
        try expect(folder.changedDuringScanCount == 0, "old folder history should default mutation count to zero")
        try expect(!folder.byteAccountingOverflowed, "old folder history should default byte-overflow disclosure to false")
        try expect(!folder.gitMetadataEntryDetected, "old folder history should default Git marker state to false")
        try expect(folder.gitMetadataUsage == nil, "old folder history should default retained Git metrics to absent")
        try expect(folder.applicationBundleIdentifier == nil,
                   "legacy folder observations should remain without an inferred bundle identifier")
        try expect(!folder.selectedAsApplicationBundle,
                   "legacy generic folder observations should not be inferred as app-picker selections")
        try expect(folder.applicationGroupIdentifiers.isEmpty,
                   "legacy folder observations should not gain inferred App Groups claims")
        try expect(!folder.applicationSignatureValidated && folder.applicationSignedBundleIdentifier == nil,
                   "legacy folder history should default to unvalidated signature metadata")
        try expect(history.ramObservations.isEmpty, "old folder history should default manual RAM history to empty")
        try expect(history.memoryPressureObservations.isEmpty,
                   "older history should default system pressure transition history to empty")
        try expect(history.capacityObservations.isEmpty, "old history should default capacity observations to empty")
        try expect(history.applicationAssociations.count == 1,
                   "old history should preserve application associations when decoding the added optional bundle identifier")
        try expect(history.applicationAssociations.first?.bundleIdentifier == nil,
                   "legacy app-folder associations without an identifier must remain unverified")
        try expect(folder.subdirectorySummaries.count == 1, "old folder history should preserve existing directory summaries")
        try expect(folder.subdirectorySummaries[0].changedDuringScanCount == 0, "old directory summaries should default mutation count to zero")
        try expect(folder.subdirectorySummaries[0].excludedSpecialFileCount == 0, "old directory summaries should default special-file count to zero")
        try expect(folder.excludedVolumeBoundaryCount == 0
                   && folder.subdirectorySummaries[0].excludedVolumeBoundaryCount == 0,
                   "older history should default nested-volume boundary counts to zero")
        try expect(!folder.subdirectorySummaries[0].gitMetadataEntryDetected, "old directory summaries should default Git marker state to false")
        try expect(!folder.subdirectorySummariesTruncated, "old folder history should default truncation to false")
        try expect(folder.largestFiles.isEmpty && !folder.largestFilesTruncated,
                   "old folder history should default largest-file summaries to absent and untruncated")
        try expect(folder.fileExtensionSummaries.isEmpty && !folder.fileExtensionSummariesTruncated,
                   "old folder history should default filename-extension summaries to empty and untruncated")
        try expect(folder.otherFileExtensionUsage == nil && folder.otherFileExtensionCategoryCount == 0,
                   "old folder history should not invent an omitted filename-category aggregate")

        let oldProcessJSON = #"{"processID":123,"name":"OldSample","residentBytes":4096}"#
        let oldProcess = try JSONDecoder().decode(ProcessRAMSample.self, from: Data(oldProcessJSON.utf8))
        try expect(oldProcess.processStartTime == nil, "old process samples without a start time should remain readable but ineligible for PID-safe trends")

        let oldRAMJSON = #"{"observedAt":1,"physicalBytes":16000,"freeBytes":2000,"activeBytes":4000,"inactiveBytes":3000,"wiredBytes":2000,"compressedBytes":1000,"processListAvailable":true,"sampledProcessCount":0,"unavailableProcessCount":0,"largestProcesses":[]}"#
        let oldRAM = try JSONDecoder().decode(RAMObservation.self, from: Data(oldRAMJSON.utf8))
        try expect(oldRAM.swapUsage == nil, "legacy RAM observations without swap metrics should remain readable and explicitly unavailable")
        let measuredSwap = SwapUsage(
            totalBytes: 4096, availableBytes: 1024, usedBytes: 3072, pageSize: 4096
        )
        let currentRAM = RAMObservation(
            observedAt: Date(timeIntervalSince1970: 2), physicalBytes: 16_000,
            freeBytes: 2_000, activeBytes: 4_000, inactiveBytes: 3_000,
            wiredBytes: 2_000, compressedBytes: 1_000,
            processListAvailable: true, sampledProcessCount: 0,
            unavailableProcessCount: 0, largestProcesses: [], swapUsage: measuredSwap
        )
        let restoredRAM = try JSONDecoder().decode(
            RAMObservation.self, from: JSONEncoder().encode(currentRAM)
        )
        try expect(restoredRAM.swapUsage == measuredSwap,
                   "manual and automatic RAM history should preserve optional swap measurements")
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
            try expect(result.folders[0].volumeDeviceID == nil,
                       "selected symlinks must not trigger volume identity lookup on their targets")
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

    private static func testPermissionDeniedSubtreeCoverage() throws {
        try withTemporaryDirectory { root in
            let knownFile = root.appendingPathComponent("known.bin")
            try Data([1, 2, 3, 4]).write(to: knownFile)
            let restricted = root.appendingPathComponent("restricted", isDirectory: true)
            try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: false)
            try Data(repeating: 7, count: 32).write(to: restricted.appendingPathComponent("unavailable.bin"))
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: restricted.path)
            defer { _ = chmod(restricted.path, 0o700) }

            let probe = restricted.path.withCString { open($0, O_RDONLY | O_DIRECTORY) }
            let accessWasDenied = probe < 0 && errno == EACCES
            if probe >= 0 { close(probe) }
            try expect(accessWasDenied, "synthetic permissions must deny traversal before testing scan coverage")

            let folder = FolderScanner.scan(roots: [root]).folders[0]
            try expect(!folder.complete && folder.inaccessibleCount == 1,
                       "an inaccessible subtree must make the selected root partial")
            try expect(folder.logicalBytes == 4 && folder.fileCount == 1,
                       "the scanner must retain measured data while excluding inaccessible child bytes")
            let inaccessible = try requireSummary("restricted", in: folder)
            try expect(inaccessible.logicalBytes == 0 && inaccessible.incompleteCount == 1 && !inaccessible.complete,
                       "the inaccessible subtree must be disclosed as incomplete, not complete zero usage")
        }
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
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
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
                if index == 0 {
                    // Simulate a history file created by an older build before
                    // owner-only permissions were enforced.
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: fileURL.deletingLastPathComponent().path
                    )
                    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
                }
            }

            let reloaded = try ObservationStore.load(from: fileURL)
            try expect(reloaded.observations.count == 180, "history should retain at most 180 observations")
            try expect(!reloaded.observations.contains(where: { $0.id == firstID }), "oldest observation should be evicted at the retention bound")
            try expect(reloaded.observations.last?.id == latestID, "newest observation should survive a restart")
            try expect(reloaded.observations.last?.cancelled == true, "cancelled scan status should persist")
            try expect(reloaded.observations.last?.folders.first?.complete == false, "incomplete folder coverage should persist")
            let historyPermissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
            try expect(historyPermissions?.intValue == 0o600,
                       "saved observations containing user paths should be readable only by the local account")
            let historyDirectoryPermissions = try FileManager.default.attributesOfItem(
                atPath: fileURL.deletingLastPathComponent().path
            )[.posixPermissions] as? NSNumber
            try expect(historyDirectoryPermissions?.intValue == 0o700,
                       "the observation directory should be accessible only by the local account")
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

            let pressureFileURL = root.appendingPathComponent("pressure-history.json")
            for index in 0...180 {
                try ObservationStore.append(MemoryPressureObservation(
                    observedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    level: index.isMultiple(of: 2) ? .normal : .warning
                ), to: pressureFileURL)
            }
            let pressureHistory = try ObservationStore.load(from: pressureFileURL)
            try expect(pressureHistory.memoryPressureObservations.count == 180,
                       "system pressure transition history should remain bounded")
            try expect(pressureHistory.memoryPressureObservations.first?.observedAt == Date(timeIntervalSince1970: 1)
                       && pressureHistory.memoryPressureObservations.last?.level == .normal,
                       "pressure event history should preserve the latest ordered transitions")
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

    private static func testLoadedHistoryRetentionBounds() throws {
        try withTemporaryDirectory { root in
            let fileURL = root.appendingPathComponent("history.json")
            let observations = (0...180).map { index in
                let timestamp = Date(timeIntervalSince1970: TimeInterval(index))
                let folder = FolderObservation(
                    path: "/synthetic/\(index)", displayName: "fixture",
                    logicalBytes: Int64(index), allocatedBytes: Int64(index),
                    fileCount: 1, inaccessibleCount: 0, finishedAt: timestamp, complete: true
                )
                return ScanObservation(startedAt: timestamp, folders: [folder], cancelled: false)
            }
            let originalData = try JSONEncoder().encode(LocalHistory(observations: observations))
            try originalData.write(to: fileURL)

            let loaded = try ObservationStore.load(from: fileURL)
            try expect(loaded.observations.count == 180,
                       "loading a larger but valid legacy history must retain only the configured latest observations")
            try expect(loaded.observations.first?.startedAt == Date(timeIntervalSince1970: 1)
                       && loaded.observations.last?.startedAt == Date(timeIntervalSince1970: 180),
                       "history loading should discard only observations older than the retention window")
            let persistedData = try Data(contentsOf: fileURL)
            try expect(persistedData == originalData,
                       "bounded loading must not rewrite a user's local history without a later save")
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
            try ObservationStore.append(MemoryPressureObservation(
                observedAt: Date(timeIntervalSince1970: 2), level: .warning
            ), to: fileURL)
            try ObservationStore.associateApplicationFolders(
                ["/synthetic/support"], with: "/synthetic/Test.app", to: fileURL
            )

            try ObservationStore.clear(at: fileURL)
            try ObservationStore.clear(at: fileURL)
            let reloaded = try ObservationStore.load(from: fileURL)
            try expect(reloaded.observations.isEmpty, "clearing history should leave an empty store")
            try expect(reloaded.ramObservations.isEmpty, "clearing local history should clear manual RAM samples too")
            try expect(reloaded.memoryPressureObservations.isEmpty,
                       "clearing local history should clear system pressure transitions too")
            try expect(reloaded.applicationAssociations.isEmpty, "clearing local history should clear app-folder associations")
            let preservedNeighbor = try Data(contentsOf: neighboringFile)
            try expect(preservedNeighbor == sentinel, "history reset must not remove neighboring files")
        }
    }

    private static func testHistoryGeneration() throws {
        var generation = HistoryGeneration()
        let pendingScan = generation.token()
        try expect(generation.accepts(pendingScan), "work should be accepted in the generation where it began")

        generation.advance()
        try expect(!generation.accepts(pendingScan), "clearing history should invalidate previously queued work")
        try expect(generation.accepts(generation.token()), "new work should be accepted after history clear")
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
        let volumeAFirst = syntheticFolder(path: "/Volumes/Data/project", bytes: 100, complete: true, volumeDeviceID: 101)
        let volumeB = syntheticFolder(path: "/Volumes/Data/project", bytes: 900, complete: true, volumeDeviceID: 202)
        let volumeAReturned = syntheticFolder(path: "/Volumes/Data/project", bytes: 150, complete: true, volumeDeviceID: 101)
        let volumeHistory = LocalHistory(observations: [
            ScanObservation(startedAt: .now, folders: [volumeAFirst], cancelled: false),
            ScanObservation(startedAt: .now, folders: [volumeB], cancelled: false),
            ScanObservation(startedAt: .now, folders: [volumeAReturned], cancelled: false),
        ])
        try expect(ObservationComparison.previousCompleteFolder(for: volumeAReturned, in: volumeHistory) == nil,
                   "a different immediately preceding volume must not be selected as a prior folder observation")
        try expect(ObservationComparison.allocatedByteDelta(current: volumeAReturned, previous: volumeB) == nil,
                   "the same path on a different or reattached volume must not be compared")
        try expect(ObservationComparison.completeFolderSeries(for: volumeAReturned, in: volumeHistory).map(\.id)
                   == [volumeAReturned.id],
                   "folder history must start a new series after the mounted volume identity changes")
        try expect(ObservationComparison.previousCompleteFolder(for: laterIncomplete, in: history) == nil, "incomplete current observations must not produce a growth comparison")
        try expect(ObservationComparison.completeFolderSeries(for: laterIncomplete, in: history).isEmpty,
                   "an incomplete current observation must not be plotted as a complete growth series")

        let futureDatedEarlierEntry = syntheticFolder(
            path: "/selected/clock-change", bytes: 500, complete: true,
            finishedAt: Date(timeIntervalSince1970: 2_000)
        )
        let currentAfterClockChange = syntheticFolder(
            path: "/selected/clock-change", bytes: 250, complete: true,
            finishedAt: Date(timeIntervalSince1970: 1_000)
        )
        let clockChangeHistory = LocalHistory(observations: [
            ScanObservation(startedAt: futureDatedEarlierEntry.finishedAt,
                            folders: [futureDatedEarlierEntry], cancelled: false),
            ScanObservation(startedAt: currentAfterClockChange.finishedAt,
                            folders: [currentAfterClockChange], cancelled: false),
        ])
        try expect(ObservationComparison.completeFolderSeries(
            for: currentAfterClockChange, in: clockChangeHistory
        ) == [currentAfterClockChange],
                   "folder history must exclude an earlier-insertion scan timestamped after the current result")
        try expect(ObservationComparison.previousCompleteFolder(
            for: currentAfterClockChange, in: clockChangeHistory
        ) == nil && ObservationComparison.growingFolders(in: clockChangeHistory).isEmpty,
                   "folder growth must not compare against a scan timestamped after the current result")
        let sameVolumeBeforeReplacement = syntheticFolder(
            path: "/selected/volume-clock-change", bytes: 100, complete: true,
            volumeDeviceID: 101, finishedAt: Date(timeIntervalSince1970: 100)
        )
        let futureReplacementVolume = syntheticFolder(
            path: sameVolumeBeforeReplacement.path, bytes: 900, complete: true,
            volumeDeviceID: 202, finishedAt: Date(timeIntervalSince1970: 300)
        )
        let sameVolumeAfterRollback = syntheticFolder(
            path: sameVolumeBeforeReplacement.path, bytes: 150, complete: true,
            volumeDeviceID: 101, finishedAt: Date(timeIntervalSince1970: 200)
        )
        let volumeRollbackHistory = LocalHistory(observations: [
            ScanObservation(startedAt: sameVolumeBeforeReplacement.finishedAt,
                            folders: [sameVolumeBeforeReplacement], cancelled: false),
            ScanObservation(startedAt: futureReplacementVolume.finishedAt,
                            folders: [futureReplacementVolume], cancelled: false),
            ScanObservation(startedAt: sameVolumeAfterRollback.finishedAt,
                            folders: [sameVolumeAfterRollback], cancelled: false),
        ])
        try expect(ObservationComparison.previousCompleteFolder(
            for: sameVolumeAfterRollback, in: volumeRollbackHistory
        ) == nil && ObservationComparison.completeFolderSeries(
            for: sameVolumeAfterRollback, in: volumeRollbackHistory
        ) == [sameVolumeAfterRollback]
                   && ObservationComparison.growingFolders(in: volumeRollbackHistory).isEmpty,
                   "a clock-future observation on a replacement volume must remain a history boundary")

        let retainedFolders = (0..<40).map { index in
            syntheticFolder(path: "/selected/long-history", bytes: Int64(index), complete: true)
        }
        let retainedHistory = LocalHistory(observations: retainedFolders.map { folder in
            ScanObservation(startedAt: folder.finishedAt, folders: [folder], cancelled: false)
        })
        try expect(ObservationComparison.completeFolderSeries(
            for: retainedFolders[retainedFolders.count - 1], in: retainedHistory
        ).count == 40,
                   "folder chart series should include every complete observation retained by history")
    }

    private static func testFolderGrowthHighlights() throws {
        let history = LocalHistory(observations: [
            ScanObservation(startedAt: .now, folders: [
                syntheticFolder(path: "/selected/growing", bytes: 100, complete: true),
                syntheticFolder(path: "/selected/largest-growth", bytes: 200, complete: true),
                syntheticFolder(path: "/selected/shrinking", bytes: 300, complete: true),
                syntheticFolder(path: "/selected/partial", bytes: 100, complete: true),
            ], cancelled: false),
            ScanObservation(startedAt: .now, folders: [
                syntheticFolder(path: "/selected/growing", bytes: 240, complete: true),
                syntheticFolder(path: "/selected/largest-growth", bytes: 500, complete: true),
                syntheticFolder(path: "/selected/shrinking", bytes: 250, complete: true),
                syntheticFolder(path: "/selected/partial", bytes: 900, complete: false),
            ], cancelled: true),
        ])

        let signals = ObservationComparison.growingFolders(in: history)
        try expect(signals.map(\.folder.path) == ["/selected/largest-growth", "/selected/growing"],
                   "growth highlights should rank positive complete same-path changes and omit shrinking roots")
        try expect(signals.map(\.growthBytes) == [300, 140],
                   "growth highlights should report allocated-byte deltas against prior complete scans")
        try expect(signals.allSatisfy { $0.folder.complete && $0.previous.complete },
                   "growth highlights must never use a partial observation")

        let rateStart = Date(timeIntervalSince1970: 50_000)
        let rateHistory = LocalHistory(observations: [
            ScanObservation(startedAt: rateStart, folders: [
                syntheticFolder(path: "/selected/rate", bytes: 1_000, complete: true,
                                finishedAt: rateStart),
            ], cancelled: false),
            ScanObservation(startedAt: rateStart.addingTimeInterval(3_600), folders: [
                syntheticFolder(path: "/selected/rate", bytes: 1_000 + 60_000_000,
                                complete: true, finishedAt: rateStart.addingTimeInterval(3_600)),
            ], cancelled: false),
        ])
        let rateSignal = ObservationComparison.growingFolders(in: rateHistory).first
        try expect(rateSignal?.observedBytesPerDay == 1_440_000_000,
                   "growth pace should scale the measured delta over a full one-hour interval")
        let shortRateHistory = LocalHistory(observations: [
            ScanObservation(startedAt: rateStart, folders: [
                syntheticFolder(path: "/selected/rate", bytes: 1_000, complete: true,
                                finishedAt: rateStart),
            ], cancelled: false),
            ScanObservation(startedAt: rateStart.addingTimeInterval(299), folders: [
                syntheticFolder(path: "/selected/rate", bytes: 2_000, complete: true,
                                finishedAt: rateStart.addingTimeInterval(299)),
            ], cancelled: false),
        ])
        try expect(ObservationComparison.growingFolders(in: shortRateHistory).first?.observedBytesPerDay == nil,
                   "growth rate should be hidden for intervals shorter than five minutes")
        try expect(ObservationComparison.growingFolders(in: history, limit: 1).map(\.folder.path)
                   == ["/selected/largest-growth"],
                   "growth highlights should respect the requested result limit")
        try expect(ObservationComparison.growingFolders(in: history, limit: 0).isEmpty,
                   "growth highlights should allow an empty result limit")

        let laterPartial = syntheticFolder(path: "/selected/growing", bytes: 1_000, complete: false)
        let partialLatest = LocalHistory(observations: history.observations + [
            ScanObservation(startedAt: .now, folders: [laterPartial], cancelled: true)
        ])
        try expect(!ObservationComparison.growingFolders(in: partialLatest).contains {
            $0.folder.path == "/selected/growing"
        }, "a newer partial result should suppress stale growth for that selected path")

        let extensionPath = "/selected/extension-growth"
        let extensionPrevious = FolderObservation(
            id: UUID(), path: extensionPath, displayName: "extension-growth",
            logicalBytes: 1_000, allocatedBytes: 1_000, fileCount: 2,
            fileExtensionSummaries: [
                FileExtensionUsage(extensionName: "db", logicalBytes: 800, allocatedBytes: 800, fileCount: 1),
                FileExtensionUsage(extensionName: "log", logicalBytes: 200, allocatedBytes: 200, fileCount: 1),
            ],
            inaccessibleCount: 0, finishedAt: Date(timeIntervalSince1970: 100), complete: true
        )
        let extensionCurrent = FolderObservation(
            id: UUID(), path: extensionPath, displayName: "extension-growth",
            logicalBytes: 1_160, allocatedBytes: 1_160, fileCount: 3,
            fileExtensionSummaries: [
                FileExtensionUsage(extensionName: "db", logicalBytes: 800, allocatedBytes: 800, fileCount: 1),
                FileExtensionUsage(extensionName: "log", logicalBytes: 300, allocatedBytes: 300, fileCount: 1),
                FileExtensionUsage(extensionName: "sqlite", logicalBytes: 60, allocatedBytes: 60, fileCount: 1),
            ],
            inaccessibleCount: 0, finishedAt: Date(timeIntervalSince1970: 200), complete: true
        )
        let extensionHistory = LocalHistory(observations: [
            ScanObservation(startedAt: .now, folders: [extensionPrevious], cancelled: false),
            ScanObservation(startedAt: .now, folders: [extensionCurrent], cancelled: false),
        ])
        let extensionGrowth = ObservationComparison.growingFileExtensions(
            for: extensionCurrent, in: extensionHistory
        )
        try expect(extensionGrowth?.map(\.extensionName) == ["log", "sqlite"]
                   && extensionGrowth?.map(\.growthBytes) == [100, 60]
                   && extensionGrowth?.map(\.currentAllocatedBytes) == [300, 60],
                   "filename-category growth should include deltas and current allocated estimates for the same complete root")
        let cappedCurrent = FolderObservation(
            id: UUID(), path: extensionPath, displayName: "extension-growth",
            logicalBytes: 1_200, allocatedBytes: 1_200, fileCount: 4,
            fileExtensionSummaries: extensionCurrent.fileExtensionSummaries,
            fileExtensionSummariesTruncated: true,
            inaccessibleCount: 0, finishedAt: Date(timeIntervalSince1970: 300), complete: true
        )
        let cappedHistory = LocalHistory(observations: extensionHistory.observations + [
            ScanObservation(startedAt: .now, folders: [cappedCurrent], cancelled: false)
        ])
        try expect(ObservationComparison.growingFileExtensions(for: cappedCurrent, in: cappedHistory) == nil,
                   "truncated filename categories must not produce incomplete growth claims")
        let partialExtension = FolderObservation(
            id: UUID(), path: extensionPath, displayName: "extension-growth",
            logicalBytes: 1_300, allocatedBytes: 1_300, fileCount: 4,
            fileExtensionSummaries: extensionCurrent.fileExtensionSummaries,
            inaccessibleCount: 1, finishedAt: Date(timeIntervalSince1970: 400), complete: false
        )
        let partialExtensionHistory = LocalHistory(observations: extensionHistory.observations + [
            ScanObservation(startedAt: .now, folders: [partialExtension], cancelled: true)
        ])
        try expect(ObservationComparison.growingFileExtensions(for: extensionCurrent, in: partialExtensionHistory) == nil,
                   "a newer partial scan must suppress filename-category growth from an older complete observation")
    }

    private static func testCapacityIntervalFolderGrowth() throws {
        let start = Date(timeIntervalSince1970: 10_000)
        let end = start.addingTimeInterval(1_000)
        let capacityBefore = CapacityObservation(
            observedAt: start, totalBytes: 10_000, availableBytes: 8_000, volumeUUID: "internal"
        )
        let capacityAfter = CapacityObservation(
            observedAt: end, totalBytes: 10_000, availableBytes: 7_000, volumeUUID: "internal"
        )
        let parentBefore = syntheticFolder(
            path: "/selected/project", bytes: 100, complete: true,
            finishedAt: start.addingTimeInterval(-10)
        )
        let parentAfter = syntheticFolder(
            path: "/selected/project", bytes: 180, complete: true,
            finishedAt: end.addingTimeInterval(-10)
        )
        let nestedBefore = syntheticFolder(
            path: "/selected/project/.build", bytes: 20, complete: true,
            finishedAt: start.addingTimeInterval(-5)
        )
        let nestedAfter = syntheticFolder(
            path: "/selected/project/.build", bytes: 45, complete: true,
            finishedAt: end.addingTimeInterval(-20)
        )
        let outsideBefore = syntheticFolder(
            path: "/selected/outside-window", bytes: 10, complete: true,
            finishedAt: start.addingTimeInterval(-61)
        )
        let outsideAfter = syntheticFolder(
            path: "/selected/outside-window", bytes: 30, complete: true,
            finishedAt: end.addingTimeInterval(-20)
        )
        let partialBefore = syntheticFolder(
            path: "/selected/partial", bytes: 10, complete: true,
            finishedAt: start.addingTimeInterval(100)
        )
        let partialDuring = syntheticFolder(
            path: "/selected/partial", bytes: 50, complete: true,
            finishedAt: end.addingTimeInterval(-100)
        )
        let partialLatest = syntheticFolder(
            path: "/selected/partial", bytes: 900, complete: false,
            finishedAt: end.addingTimeInterval(-10)
        )
        let lateBefore = syntheticFolder(
            path: "/selected/late-result", bytes: 10, complete: true,
            finishedAt: start.addingTimeInterval(100)
        )
        let lateAfter = syntheticFolder(
            path: "/selected/late-result", bytes: 30, complete: true,
            finishedAt: end.addingTimeInterval(61)
        )
        let history = LocalHistory(
            observations: [
                ScanObservation(startedAt: start, folders: [
                    parentBefore, nestedBefore, outsideBefore, partialBefore, lateBefore,
                ], cancelled: false),
                ScanObservation(startedAt: end, folders: [
                    parentAfter, nestedAfter, outsideAfter, partialDuring, lateAfter,
                ], cancelled: false),
                ScanObservation(startedAt: end, folders: [partialLatest], cancelled: true),
            ],
            capacityObservations: [capacityBefore, capacityAfter]
        )

        let interval = ObservationComparison.folderGrowthDuringLatestCapacityLoss(in: history)
        try expect(interval?.availableBytesLost == 1_000,
                   "the joined interval should retain the system-reported available-space loss")
        try expect(interval?.folderGrowth.map(\.folder.path) == [
            "/selected/project", "/selected/project/.build",
        ], "complete root comparisons overlapping the capacity interval should be shown independently, including nested roots")
        try expect(interval?.folderGrowth.map(\.growthBytes) == [80, 25],
                   "aligned signals should use exact same-path allocated-byte deltas")
        try expect(interval?.folderGrowth.allSatisfy {
            $0.previous.finishedAt >= start.addingTimeInterval(-60)
                && $0.folder.finishedAt <= end.addingTimeInterval(60)
                && $0.previous.complete && $0.folder.complete
        } == true, "the joined signal should use complete scans within the interval or its 60-second sampling boundary tolerance")
        try expect(interval?.folderGrowth.contains(where: {
            $0.folder.path == outsideAfter.path || $0.folder.path == partialLatest.path
                || $0.folder.path == lateAfter.path
        }) == false, "out-of-window comparisons and paths with a newer partial scan must remain unknown")

        let noLoss = LocalHistory(
            observations: history.observations,
            capacityObservations: [capacityBefore, CapacityObservation(
                observedAt: end, totalBytes: 10_000, availableBytes: 8_100, volumeUUID: "internal"
            )]
        )
        try expect(ObservationComparison.folderGrowthDuringLatestCapacityLoss(in: noLoss) == nil,
                   "folder growth must not be framed as accompanying a capacity loss when available space did not decrease")

        let incompatibleCapacityBasis = CapacityObservation(
            observedAt: end, totalBytes: 10_000, availableBytes: 7_000,
            availabilityBasis: .standardVolume, volumeUUID: "internal"
        )
        try expect(ObservationComparison.folderGrowthDuringLatestCapacityLoss(in: LocalHistory(
            observations: history.observations,
            capacityObservations: [capacityBefore, incompatibleCapacityBasis]
        )) == nil, "a change in volume or availability basis must break the capacity interval")

        let noAlignedGrowth = LocalHistory(capacityObservations: [capacityBefore, capacityAfter])
        try expect(ObservationComparison.folderGrowthDuringLatestCapacityLoss(in: noAlignedGrowth)?.folderGrowth.isEmpty == true,
                   "a real capacity loss with no aligned selected scans must remain explicitly unassigned")
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
        let directoryGrowth = ObservationComparison.growingDirectories(in: history)
        try expect(directoryGrowth.count == 1
                   && directoryGrowth[0].folder.path == "/selected"
                   && directoryGrowth[0].directory.rootRelativePath == "Projects/Example"
                   && directoryGrowth[0].growthBytes == 875,
                   "directory highlights should compare the latest complete same-path subfolder observation")
        let rateStart = Date(timeIntervalSince1970: 70_000)
        let rateEarlier = folderWithDirectory(
            id: UUID(), path: "/selected/rate-project", bytes: 1_000, complete: true,
            directory: directory("Sources", bytes: 1_000, complete: true), finishedAt: rateStart
        )
        let rateCurrent = folderWithDirectory(
            id: UUID(), path: "/selected/rate-project", bytes: 60_001_000, complete: true,
            directory: directory("Sources", bytes: 60_001_000, complete: true),
            finishedAt: rateStart.addingTimeInterval(3_600)
        )
        let directoryRate = ObservationComparison.growingDirectories(in: LocalHistory(observations: [
            ScanObservation(startedAt: rateStart, folders: [rateEarlier], cancelled: false),
            ScanObservation(startedAt: rateStart.addingTimeInterval(3_600), folders: [rateCurrent], cancelled: false),
        ])).first
        try expect(directoryRate?.observedBytesPerDay == 1_440_000_000,
                   "subfolder growth pace should use the same exact-root one-hour comparison interval")
        try expect(ObservationComparison.growingDirectories(in: history, limit: 0).isEmpty,
                   "directory growth highlights should honor an empty limit")
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
        try expect(ObservationComparison.growingDirectories(in: partialHistory).isEmpty,
                   "a newer partial root scan must suppress older subfolder growth signals")

        let oldProjectDirectory = DirectoryUsage(
            rootRelativePath: "vendor/small-project", logicalBytes: 100,
            allocatedBytes: 100, fileCount: 1, incompleteCount: 0,
            excludedSymlinkCount: 0, gitMetadataEntryDetected: true, complete: true
        )
        let newProjectDirectory = DirectoryUsage(
            rootRelativePath: "vendor/small-project", logicalBytes: 125,
            allocatedBytes: 125, fileCount: 1, incompleteCount: 0,
            excludedSymlinkCount: 0, gitMetadataEntryDetected: true, complete: true
        )
        let oldProjectFolder = FolderObservation(
            id: UUID(), path: "/project-root", displayName: "project-root",
            logicalBytes: 100, allocatedBytes: 100, fileCount: 1,
            inaccessibleCount: 0, complete: true,
            projectDirectorySummaries: [oldProjectDirectory]
        )
        let newProjectFolder = FolderObservation(
            id: UUID(), path: "/project-root", displayName: "project-root",
            logicalBytes: 125, allocatedBytes: 125, fileCount: 1,
            inaccessibleCount: 0, complete: true,
            projectDirectorySummaries: [newProjectDirectory]
        )
        let projectHistory = LocalHistory(observations: [
            ScanObservation(startedAt: .now, folders: [oldProjectFolder], cancelled: false),
            ScanObservation(startedAt: .now, folders: [newProjectFolder], cancelled: false),
        ])
        try expect(ObservationComparison.previousCompleteDirectory(
            for: newProjectDirectory, in: newProjectFolder, history: projectHistory
        )?.allocatedBytes == 100,
                   "repository-marker paths should compare with the prior complete same-root observation")
        let projectGrowth = ObservationComparison.growingDirectories(in: projectHistory)
        try expect(projectGrowth.count == 1 && projectGrowth[0].directory.rootRelativePath == "vendor/small-project"
                   && projectGrowth[0].growthBytes == 25,
                   "repository-marker summaries omitted from the ordinary leaderboard should still support growth history")

        let oldModelData = DirectoryUsage(
            rootRelativePath: "research/checkpoints", logicalBytes: 80,
            allocatedBytes: 64, fileCount: 2, incompleteCount: 0,
            excludedSymlinkCount: 0, gitMetadataEntryDetected: false, complete: true
        )
        let newModelData = DirectoryUsage(
            rootRelativePath: "research/checkpoints", logicalBytes: 180,
            allocatedBytes: 128, fileCount: 3, incompleteCount: 0,
            excludedSymlinkCount: 0, gitMetadataEntryDetected: false, complete: true
        )
        let oldDataFolder = FolderObservation(
            id: UUID(), path: "/selected-data", displayName: "selected-data",
            logicalBytes: 80, allocatedBytes: 64, fileCount: 2,
            inaccessibleCount: 0, complete: true,
            projectDirectorySummaries: [oldModelData]
        )
        let newDataFolder = FolderObservation(
            id: UUID(), path: "/selected-data", displayName: "selected-data",
            logicalBytes: 180, allocatedBytes: 128, fileCount: 3,
            inaccessibleCount: 0, complete: true,
            projectDirectorySummaries: [newModelData]
        )
        let dataHistory = LocalHistory(observations: [
            ScanObservation(startedAt: .now, folders: [oldDataFolder], cancelled: false),
            ScanObservation(startedAt: .now, folders: [newDataFolder], cancelled: false),
        ])
        let dataGrowth = ObservationComparison.growingDirectories(in: dataHistory)
        try expect(dataGrowth.count == 1
                   && dataGrowth[0].directory.rootRelativePath == "research/checkpoints"
                   && dataGrowth[0].growthBytes == 64,
                   "exact-name model-data candidates should participate in same-path complete growth comparisons without Git markers")

        let completeWithoutPath = folderWithDirectory(
            id: UUID(), path: "/selected", bytes: 200, complete: true,
            directory: directory("Projects/Other", bytes: 200, complete: true)
        )
        let reappeared = folderWithDirectory(
            id: UUID(), path: "/selected", bytes: 350, complete: true,
            directory: directory("Projects/Example", bytes: 125, complete: true)
        )
        let reappearanceHistory = LocalHistory(observations: [
            ScanObservation(startedAt: .now, folders: [earlier], cancelled: false),
            ScanObservation(startedAt: .now, folders: [completeWithoutPath], cancelled: false),
            ScanObservation(startedAt: .now, folders: [reappeared], cancelled: false),
        ])
        try expect(ObservationComparison.previousCompleteDirectory(
            for: reappeared.subdirectorySummaries[0], in: reappeared, history: reappearanceHistory
        ) == nil, "directory comparisons must not bridge a complete observation where the retained path is absent")
        try expect(ObservationComparison.growingDirectories(in: reappearanceHistory).isEmpty,
                   "directory growth must not infer change across an absent complete observation")

        let futureDatedRoot = folderWithDirectory(
            id: UUID(), path: "/clock-rollback", bytes: 500, complete: true,
            directory: directory("Project", bytes: 500, complete: true),
            finishedAt: Date(timeIntervalSince1970: 2_000)
        )
        let currentAfterClockRollback = folderWithDirectory(
            id: UUID(), path: "/clock-rollback", bytes: 250, complete: true,
            directory: directory("Project", bytes: 250, complete: true),
            finishedAt: Date(timeIntervalSince1970: 1_000)
        )
        let clockRollbackHistory = LocalHistory(observations: [
            ScanObservation(startedAt: futureDatedRoot.finishedAt, folders: [futureDatedRoot], cancelled: false),
            ScanObservation(startedAt: currentAfterClockRollback.finishedAt, folders: [currentAfterClockRollback], cancelled: false),
        ])
        let currentClockDirectory = try requireSummary("Project", in: currentAfterClockRollback)
        try expect(ObservationComparison.previousCompleteDirectory(
            for: currentClockDirectory, in: currentAfterClockRollback, history: clockRollbackHistory
        ) == nil && ObservationComparison.growingDirectories(in: clockRollbackHistory).isEmpty,
                   "directory growth must skip prior entries timestamped after the current scan")

        let directoryBeforeAbsence = folderWithDirectory(
            id: UUID(), path: "/clock-absence", bytes: 100, complete: true,
            directory: directory("Project", bytes: 100, complete: true),
            finishedAt: Date(timeIntervalSince1970: 100)
        )
        let directoryAbsentFuture = folderWithDirectory(
            id: UUID(), path: "/clock-absence", bytes: 200, complete: true,
            directory: directory("Elsewhere", bytes: 200, complete: true),
            finishedAt: Date(timeIntervalSince1970: 300)
        )
        let directoryAfterRollback = folderWithDirectory(
            id: UUID(), path: "/clock-absence", bytes: 250, complete: true,
            directory: directory("Project", bytes: 250, complete: true),
            finishedAt: Date(timeIntervalSince1970: 200)
        )
        let directoryAbsenceHistory = LocalHistory(observations: [
            ScanObservation(startedAt: directoryBeforeAbsence.finishedAt,
                            folders: [directoryBeforeAbsence], cancelled: false),
            ScanObservation(startedAt: directoryAbsentFuture.finishedAt,
                            folders: [directoryAbsentFuture], cancelled: false),
            ScanObservation(startedAt: directoryAfterRollback.finishedAt,
                            folders: [directoryAfterRollback], cancelled: false),
        ])
        let currentAfterAbsence = try requireSummary("Project", in: directoryAfterRollback)
        try expect(ObservationComparison.previousCompleteDirectory(
            for: currentAfterAbsence, in: directoryAfterRollback, history: directoryAbsenceHistory
        ) == nil && ObservationComparison.growingDirectories(in: directoryAbsenceHistory).isEmpty,
                   "a clock-future complete scan where the retained directory is absent must prevent bridging to older history")

        let directoryBeforeVolumeChange = folderWithDirectory(
            id: UUID(), path: "/clock-volume", bytes: 100, complete: true,
            directory: directory("Project", bytes: 100, complete: true),
            finishedAt: Date(timeIntervalSince1970: 100), volumeDeviceID: 101
        )
        let directoryOnReplacementVolume = folderWithDirectory(
            id: UUID(), path: "/clock-volume", bytes: 900, complete: true,
            directory: directory("Project", bytes: 900, complete: true),
            finishedAt: Date(timeIntervalSince1970: 300), volumeDeviceID: 202
        )
        let directoryOnOriginalVolumeAfterRollback = folderWithDirectory(
            id: UUID(), path: "/clock-volume", bytes: 150, complete: true,
            directory: directory("Project", bytes: 150, complete: true),
            finishedAt: Date(timeIntervalSince1970: 200), volumeDeviceID: 101
        )
        let directoryVolumeHistory = LocalHistory(observations: [
            ScanObservation(startedAt: directoryBeforeVolumeChange.finishedAt,
                            folders: [directoryBeforeVolumeChange], cancelled: false),
            ScanObservation(startedAt: directoryOnReplacementVolume.finishedAt,
                            folders: [directoryOnReplacementVolume], cancelled: false),
            ScanObservation(startedAt: directoryOnOriginalVolumeAfterRollback.finishedAt,
                            folders: [directoryOnOriginalVolumeAfterRollback], cancelled: false),
        ])
        let originalVolumeDirectory = try requireSummary("Project", in: directoryOnOriginalVolumeAfterRollback)
        try expect(ObservationComparison.previousCompleteDirectory(
            for: originalVolumeDirectory, in: directoryOnOriginalVolumeAfterRollback,
            history: directoryVolumeHistory
        ) == nil && ObservationComparison.growingDirectories(in: directoryVolumeHistory).isEmpty,
                   "a clock-future root on a replacement volume must prevent bridging directory history")
    }

    private static func testLargestFileGrowthComparison() throws {
        func withFiles(_ folder: FolderObservation, _ files: [FileUsageSummary], truncated: Bool) -> FolderObservation {
            FolderObservation(
                id: folder.id, path: folder.path, volumeDeviceID: folder.volumeDeviceID,
                displayName: folder.displayName, logicalBytes: folder.logicalBytes,
                allocatedBytes: folder.allocatedBytes, fileCount: folder.fileCount,
                inaccessibleCount: folder.inaccessibleCount, finishedAt: folder.finishedAt,
                complete: folder.complete, largestFiles: files, largestFilesTruncated: truncated
            )
        }

        let before = withFiles(
            syntheticFolder(path: "/selected/project", bytes: 1_000, complete: true,
                            volumeDeviceID: 42, finishedAt: Date(timeIntervalSince1970: 100)),
            [
                FileUsageSummary(rootRelativePath: "data/model.bin", logicalBytes: 100, allocatedBytes: 100),
                FileUsageSummary(rootRelativePath: "cache/old.bin", logicalBytes: 50, allocatedBytes: 50),
            ],
            truncated: true
        )
        let current = withFiles(
            syntheticFolder(path: before.path, bytes: 1_250, complete: true,
                            volumeDeviceID: 42, finishedAt: Date(timeIntervalSince1970: 200)),
            [
                FileUsageSummary(rootRelativePath: "new.bin", logicalBytes: 900, allocatedBytes: 900),
                FileUsageSummary(rootRelativePath: "data/model.bin", logicalBytes: 400, allocatedBytes: 350),
                FileUsageSummary(rootRelativePath: "cache/old.bin", logicalBytes: 20, allocatedBytes: 20),
            ],
            truncated: true
        )
        let history = LocalHistory(observations: [
            ScanObservation(startedAt: before.finishedAt, folders: [before], cancelled: false),
            ScanObservation(startedAt: current.finishedAt, folders: [current], cancelled: false),
        ])
        let signals = ObservationComparison.growingFiles(for: current, in: history)
        try expect(signals.map(\.file.rootRelativePath) == ["data/model.bin"]
                   && signals.map(\.growthBytes) == [250]
                   && signals[0].file.allocatedBytes == 350,
                   "file growth should compare positive allocated changes for an exact path present in both complete top-file lists")
        try expect(ObservationComparison.growingFiles(for: current, in: history, limit: 0).isEmpty,
                   "file growth comparison should respect an empty result limit")

        let unrelated = withFiles(
            syntheticFolder(path: "/other/project", bytes: 1_250, complete: true,
                            volumeDeviceID: 42, finishedAt: current.finishedAt),
            current.largestFiles,
            truncated: true
        )
        let unrelatedHistory = LocalHistory(observations: [
            ScanObservation(startedAt: before.finishedAt, folders: [before], cancelled: false),
            ScanObservation(startedAt: unrelated.finishedAt, folders: [unrelated], cancelled: false),
        ])
        try expect(ObservationComparison.growingFiles(for: unrelated, in: unrelatedHistory).isEmpty,
                   "identical relative file names under a different selected root must not be compared")

        let partial = withFiles(
            syntheticFolder(path: current.path, bytes: 1_500, complete: false,
                            volumeDeviceID: 42, finishedAt: Date(timeIntervalSince1970: 300)),
            [FileUsageSummary(rootRelativePath: "data/model.bin", logicalBytes: 500, allocatedBytes: 500)],
            truncated: false
        )
        let partialHistory = LocalHistory(observations: history.observations + [
            ScanObservation(startedAt: partial.finishedAt, folders: [partial], cancelled: true),
        ])
        try expect(ObservationComparison.growingFiles(for: current, in: partialHistory).isEmpty,
                   "a newer partial observation must suppress a stale file-growth signal")
        try expect(ObservationComparison.growingFiles(for: partial, in: partialHistory).isEmpty,
                   "partial file observations must never produce growth signals")
    }

    private static func folderWithDirectory(
        id: UUID, path: String, bytes: Int64, complete: Bool, directory: DirectoryUsage,
        finishedAt: Date = .now, volumeDeviceID: UInt64? = nil
    ) -> FolderObservation {
        FolderObservation(
            id: id, path: path, volumeDeviceID: volumeDeviceID,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            logicalBytes: bytes, allocatedBytes: bytes, fileCount: 1,
            inaccessibleCount: complete ? 0 : 1, finishedAt: finishedAt, complete: complete,
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

    private static func syntheticFolder(
        path: String, bytes: Int64, complete: Bool, volumeDeviceID: UInt64? = nil,
        finishedAt: Date = .now
    ) -> FolderObservation {
        FolderObservation(
            path: path, volumeDeviceID: volumeDeviceID,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            logicalBytes: bytes, allocatedBytes: bytes, fileCount: 1,
            inaccessibleCount: complete ? 0 : 1, finishedAt: finishedAt, complete: complete
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
            try FileManager.default.linkItem(
                at: root.appendingPathComponent("file-0.bin"),
                to: root.appendingPathComponent("hard-link-alias.bin")
            )
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
            try expect(reported?.countedFileObjects == 256, "scanner should report its 256-unique-file-object progress interval")
            try expect(reported?.currentPath.hasPrefix(root.path) == true, "progress should identify a path within the selected root")

            let emptyTree = root.appendingPathComponent("empty-tree", isDirectory: true)
            try FileManager.default.createDirectory(at: emptyTree, withIntermediateDirectories: false)
            for index in 0..<300 {
                try FileManager.default.createDirectory(
                    at: emptyTree.appendingPathComponent("directory-\(index)", isDirectory: true),
                    withIntermediateDirectories: false
                )
            }
            var emptyTreeProgress: ScanProgress?
            let emptyTreeResult = FolderScanner.scan(roots: [emptyTree], progress: { emptyTreeProgress = $0 })
            try expect(emptyTreeResult.folders[0].complete && emptyTreeResult.folders[0].fileCount == 0,
                       "empty directory trees should scan completely without fabricating file totals")
            try expect(emptyTreeProgress?.countedFileObjects == 0
                       && emptyTreeProgress?.currentPath.hasPrefix(emptyTree.path) == true,
                       "directory-entry progress should advance even when the tree contains no files")
            let cpuSeconds = usageSeconds(usageAfter.ru_utime) + usageSeconds(usageAfter.ru_stime)
                - usageSeconds(usageBefore.ru_utime) - usageSeconds(usageBefore.ru_stime)
            print(String(format: "  synthetic scan (256 unique file objects, 300 directories, one extra hard-link path): %.3f s wall, %.3f s process CPU", wallSeconds, cpuSeconds))
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

    private static func testSelectedDirectoryRootMutationCoverage() throws {
        try withTemporaryDirectory { temporaryRoot in
            let selectedRoot = temporaryRoot.appendingPathComponent("selected-root", isDirectory: true)
            let movedRoot = temporaryRoot.appendingPathComponent("moved-root", isDirectory: true)
            try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: false)
            for index in 0..<256 {
                try Data([UInt8(index % 255)]).write(
                    to: selectedRoot.appendingPathComponent(String(format: "file-%03d.bin", index))
                )
            }
            var rootReplaced = false
            let result = FolderScanner.scan(roots: [selectedRoot], progress: { _ in
                guard !rootReplaced else { return }
                rootReplaced = true
                try? FileManager.default.moveItem(at: selectedRoot, to: movedRoot)
                try? FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: false)
            })
            guard let folder = result.folders.first else {
                throw CheckFailure.assertion("replaced root fixture should produce a folder observation")
            }
            try expect(rootReplaced, "fixture should replace the selected root during its scan")
            try expect(!folder.complete && folder.changedDuringScanCount > 0,
                       "a selected directory replaced during enumeration must not look like a complete snapshot")
        }
    }

    private static func testFileMutationCoverage() throws {
        try withTemporaryDirectory { root in
            let changedFile = root.appendingPathComponent("file-000.bin")
            try Data([0x01]).write(to: changedFile)
            for index in 1..<512 {
                try Data([UInt8(index % 255)]).write(
                    to: root.appendingPathComponent(String(format: "file-%03d.bin", index))
                )
            }
            var changedFileDuringEnumeration = false
            let result = FolderScanner.scan(roots: [root], progress: { _ in
                guard !changedFileDuringEnumeration else { return }
                changedFileDuringEnumeration = true
                try? Data(repeating: 0x7F, count: 4096).write(to: changedFile)
            })
            guard let folder = result.folders.first else {
                throw CheckFailure.assertion("file mutation fixture should produce a folder observation")
            }
            try expect(changedFileDuringEnumeration, "fixture should change a previously sampled file during enumeration")
            try expect(!folder.complete, "a file changed before parent-directory revalidation must not appear complete")
            try expect(folder.changedDuringScanCount > 0, "the changed file should have an explicit coverage count")
        }
    }

    private static func testSelectedFileRootMutationCoverage() throws {
        try withTemporaryDirectory { root in
            let selectedFile = root.appendingPathComponent("selected.bin")
            let laterDirectory = root.appendingPathComponent("later-root", isDirectory: true)
            try Data([0x01, 0x02, 0x03, 0x04]).write(to: selectedFile)
            try FileManager.default.createDirectory(at: laterDirectory, withIntermediateDirectories: false)
            for index in 0..<256 {
                try Data([UInt8(index % 255)]).write(
                    to: laterDirectory.appendingPathComponent(String(format: "file-%03d.bin", index))
                )
            }

            var changedSelectedFile = false
            let result = FolderScanner.scan(roots: [selectedFile, laterDirectory], progress: { _ in
                guard !changedSelectedFile else { return }
                changedSelectedFile = true
                try? Data(repeating: 0x7F, count: 8).write(to: selectedFile)
            })
            try expect(changedSelectedFile, "later selected-root progress should mutate the earlier file fixture")
            guard result.folders.count == 2 else {
                throw CheckFailure.assertion("both selected roots should produce observations")
            }
            let fileObservation = result.folders[0]
            try expect(fileObservation.logicalBytes == 4, "the file root should retain its sampled metadata total")
            try expect(!fileObservation.complete && fileObservation.changedDuringScanCount > 0,
                       "a selected file changed during a later root scan must be marked partial (complete=\(fileObservation.complete), changed=\(fileObservation.changedDuringScanCount), callback=\(changedSelectedFile))")
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
