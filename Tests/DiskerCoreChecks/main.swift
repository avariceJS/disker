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
        let checks: [(String, () throws -> Void)] = [
            ("capacity math", testCapacityMath),
            ("capacity clamping", testCapacityClamping),
            ("zero important-usage fallback", testImportantUsageFallback),
            ("live root volume capacity", testLiveCapacitySource),
            ("live RAM and process sample", testLiveRAMSample),
            ("metadata scan and symlink exclusion", testMetadataScanAndSymlinkExclusion),
            ("selected symlink root is incomplete", testSelectedSymlinkRootIsIncomplete),
            ("hard-link deduplication", testHardLinkDeduplication),
            ("sparse file size accounting", testSparseFileAccounting),
            ("missing root coverage", testMissingRootCoverage),
            ("immediate cancellation", testImmediateCancellation),
            ("history persistence and bounded retention", testHistoryPersistenceAndRetention),
            ("corrupt history is left untouched", testCorruptHistoryIsLeftUntouched),
            ("same-path complete history comparison", testSamePathCompleteHistoryComparison),
            ("scan progress callback", testScanProgressCallback),
            ("cancellation preserves partial coverage", testCancellationPreservesPartialCoverage),
        ]

        for (name, check) in checks {
            try check()
            print("PASS  \(name)")
        }
        print("\(checks.count) core checks passed.")
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

    private static func testImportantUsageFallback() throws {
        let resolved = CapacityObservation.resolvedAvailableCapacity(importantUsage: 0, standard: 42)
        try expect(resolved?.bytes == 42, "zero important-usage result should fall back to standard availability")
        try expect(resolved?.basis == .standardVolume, "fallback must identify the standard volume API")
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
            try expect(result.folders[0].complete, "readable synthetic folder should be complete")
        }
    }

    private static func testHardLinkDeduplication() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("original.bin")
            try Data(repeating: 0x7F, count: 2048).write(to: file)
            try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("linked.bin"))

            let result = FolderScanner.scan(roots: [root])
            try expect(result.folders[0].logicalBytes == 2048, "hard links must not double-count logical bytes")
            try expect(result.folders[0].fileCount == 1, "hard links must identify one file object")
        }
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
            try expect(result.folders[0].inaccessibleCount == 1, "excluded symlink root should be visible as an excluded item")
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
            }
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
        try expect(ObservationComparison.allocatedByteDelta(current: current, previous: earlierComplete) == 35, "allocated-size delta should use the matching complete path")
        let otherPath = syntheticFolder(path: "/other", bytes: 135, complete: true)
        try expect(ObservationComparison.allocatedByteDelta(current: current, previous: otherPath) == nil, "different paths must not be compared")
        try expect(ObservationComparison.previousCompleteFolder(for: laterIncomplete, in: history) == nil, "incomplete current observations must not produce a growth comparison")
    }

    private static func syntheticFolder(path: String, bytes: Int64, complete: Bool) -> FolderObservation {
        FolderObservation(
            path: path, displayName: URL(fileURLWithPath: path).lastPathComponent,
            logicalBytes: bytes, allocatedBytes: bytes, fileCount: 1,
            inaccessibleCount: complete ? 0 : 1, complete: complete
        )
    }

    private static func testScanProgressCallback() throws {
        try withTemporaryDirectory { root in
            for index in 0..<256 {
                try Data([UInt8(index % 255)]).write(to: root.appendingPathComponent("file-\(index).bin"))
            }
            var reported: ScanProgress?
            let result = FolderScanner.scan(roots: [root], progress: { reported = $0 })
            try expect(result.folders[0].fileCount == 256, "progress fixture should measure every file")
            try expect(reported?.visitedFiles == 256, "scanner should report its 256-file progress interval")
            try expect(reported?.currentPath.hasPrefix(root.path) == true, "progress should identify a path within the selected root")
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
}
