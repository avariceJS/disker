import Foundation

public enum ObservationComparison {
    private static let minimumGrowthRateInterval: TimeInterval = 5 * 60
    private static let capacityScanBoundaryTolerance: TimeInterval = 60

    private static func observedBytePace(growthBytes: Int64, interval: TimeInterval) -> Double? {
        guard interval.isFinite, interval >= minimumGrowthRateInterval else { return nil }
        return Double(growthBytes) * 86_400 / interval
    }

    public struct FolderGrowthSignal: Equatable, Identifiable, Sendable {
        public var id: String { folder.path }
        public let folder: FolderObservation
        public let previous: FolderObservation
        public let growthBytes: Int64

        /// Straight-line observed pace scaled to 24 hours. Short intervals are
        /// omitted because timestamp and filesystem timing noise can dominate.
        public var observedBytesPerDay: Double? {
            ObservationComparison.observedBytePace(
                growthBytes: growthBytes,
                interval: folder.finishedAt.timeIntervalSince(previous.finishedAt)
            )
        }
    }

    /// Complete selected-root changes observed entirely inside the latest
    /// comparable interval where macOS reported less available capacity.
    /// This is temporal correlation only; it does not attribute capacity use.
    public struct CapacityIntervalFolderGrowth: Equatable, Sendable {
        public let previousCapacity: CapacityObservation
        public let currentCapacity: CapacityObservation
        public let availableBytesLost: UInt64
        public let folderGrowth: [FolderGrowthSignal]
    }

    public struct FileExtensionGrowthSignal: Equatable, Identifiable, Sendable {
        public var id: String { extensionName }
        public let extensionName: String
        public let growthBytes: Int64
        public let currentAllocatedBytes: Int64
    }

    public struct DirectoryGrowthSignal: Equatable, Identifiable, Sendable {
        public var id: String { folder.path + "\u{0}" + directory.rootRelativePath }
        public let folder: FolderObservation
        public let previousFolder: FolderObservation
        public let directory: DirectoryUsage
        public let previousDirectory: DirectoryUsage
        public let growthBytes: Int64

        /// Straight-line observed pace scaled to 24 hours, omitted for short
        /// intervals where timestamp and filesystem timing noise can dominate.
        public var observedBytesPerDay: Double? {
            ObservationComparison.observedBytePace(
                growthBytes: growthBytes,
                interval: folder.finishedAt.timeIntervalSince(previousFolder.finishedAt)
            )
        }
    }

    public struct FileGrowthSignal: Equatable, Identifiable, Sendable {
        public var id: String { folder.path + "\u{0}" + file.rootRelativePath }
        public let folder: FolderObservation
        public let previousFolder: FolderObservation
        public let file: FileUsageSummary
        public let previousFile: FileUsageSummary
        public let growthBytes: Int64
    }

    public struct ProcessGrowthSignal: Equatable, Identifiable, Sendable {
        public var id: Int32 { processID }
        public let processID: Int32
        public let processName: String
        public let firstObservedAt: Date
        public let lastObservedAt: Date
        public let firstResidentBytes: UInt64
        public let lastResidentBytes: UInt64

        public var growthBytes: UInt64 { lastResidentBytes - firstResidentBytes }
    }

    /// A cautious investigation signal from a continuous run of available
    /// samples spanning at least 15 minutes. The run includes at least three
    /// samples and requires a stable PID, process name, and kernel start time.
    public static func possibleProcessGrowth(in history: LocalHistory) -> [ProcessGrowthSignal] {
        guard let latestObservation = history.ramObservations.last,
              latestObservation.processListAvailable else { return [] }
        let threshold = UInt64(100 * 1024 * 1024)

        return latestObservation.largestProcesses.compactMap { latest -> ProcessGrowthSignal? in
            guard let startTime = latest.processStartTime else { return nil }
            var matching: [(observation: RAMObservation, process: ProcessRAMSample)] = []
            for observation in history.ramObservations.reversed() {
                guard observation.processListAvailable,
                      let process = observation.largestProcesses.first(where: {
                          $0.processID == latest.processID
                              && $0.name == latest.name
                              && $0.processStartTime == startTime
                      }),
                      observation.observedAt <= (matching.last?.observation.observedAt ?? latestObservation.observedAt)
                else { break }
                matching.append((observation, process))
            }
            guard matching.count >= 3,
                  let startingSample = matching.enumerated().first(where: { index, sample in
                      index >= 2
                          && matching[0].observation.observedAt.timeIntervalSince(sample.observation.observedAt) >= 15 * 60
                  })?.element else { return nil }
            let initial = startingSample.process
            guard latest.residentBytes >= initial.residentBytes,
                  latest.residentBytes - initial.residentBytes >= threshold else { return nil }

            return ProcessGrowthSignal(
                processID: latest.processID,
                processName: latest.name,
                firstObservedAt: startingSample.observation.observedAt,
                lastObservedAt: latestObservation.observedAt,
                firstResidentBytes: initial.residentBytes,
                lastResidentBytes: latest.residentBytes
            )
        }.sorted { $0.growthBytes > $1.growthBytes }
    }

    public static func previousComparableCapacity(
        for current: CapacityObservation, in history: LocalHistory
    ) -> CapacityObservation? {
        guard let currentIndex = history.capacityObservations.lastIndex(where: {
            $0.observedAt == current.observedAt
                && $0.totalBytes == current.totalBytes
                && $0.availableBytes == current.availableBytes
                && $0.availabilityBasis == current.availabilityBasis
                && $0.volumeUUID == current.volumeUUID
        }) else { return nil }

        return history.capacityObservations[..<currentIndex].reversed().first(where: {
            sameCapacityVolume($0, current)
                && $0.observedAt <= current.observedAt
        })
    }

    /// The trailing run for the same volume identity, reported capacity, and
    /// availability API basis. A volume, capacity, or method change starts a
    /// new run.
    public static func comparableCapacitySeries(in history: LocalHistory) -> [CapacityObservation] {
        guard let latest = history.capacityObservations.last else { return [] }
        var series: [CapacityObservation] = []
        for sample in history.capacityObservations.reversed() {
            // A system-clock rollback can leave an earlier stored sample with
            // a timestamp after the latest observation. Do not plot it as
            // future capacity history or let it anchor the visible range.
            guard sample.observedAt <= latest.observedAt else { continue }
            guard sample.totalBytes == latest.totalBytes,
                  sample.availabilityBasis == latest.availabilityBasis,
                  sameVolumeIdentity(sample, latest) else { break }
            series.append(sample)
        }
        return series.reversed()
    }

    /// Change in macOS-reported available bytes, comparable only for the same
    /// volume capacity and availability API basis.
    public static func availableCapacityDelta(
        current: CapacityObservation, previous: CapacityObservation
    ) -> Int64? {
        guard current.totalBytes == previous.totalBytes,
              current.availabilityBasis == previous.availabilityBasis,
              sameVolumeIdentity(current, previous),
              current.observedAt >= previous.observedAt
        else { return nil }
        let (delta, overflow) = current.availableBytes.subtractingReportingOverflow(previous.availableBytes)
        return overflow ? nil : delta
    }

    private static func sameCapacityVolume(
        _ lhs: CapacityObservation, _ rhs: CapacityObservation
    ) -> Bool {
        lhs.totalBytes == rhs.totalBytes
            && lhs.availabilityBasis == rhs.availabilityBasis
            && sameVolumeIdentity(lhs, rhs)
    }

    private static func sameVolumeIdentity(
        _ lhs: CapacityObservation, _ rhs: CapacityObservation
    ) -> Bool {
        switch (lhs.volumeUUID, rhs.volumeUUID) {
        case let (left?, right?): return left == right
        case (nil, nil): return true
        default: return false
        }
    }

    private static func sameFolderVolume(
        _ lhs: FolderObservation, _ rhs: FolderObservation
    ) -> Bool {
        switch (lhs.volumeDeviceID, rhs.volumeDeviceID) {
        case let (left?, right?): return left == right
        case (nil, nil): return true
        default: return false
        }
    }

    /// Complete observations of the same selected root through the specified
    /// current result. Partial scans and future observations are excluded.
    public static func completeFolderSeries(
        for current: FolderObservation, in history: LocalHistory
    ) -> [FolderObservation] {
        guard current.complete,
              let currentIndex = history.observations.firstIndex(where: { observation in
                  observation.folders.contains(where: { $0.id == current.id })
              }) else { return [] }

        var prior: [FolderObservation] = []
        for observation in history.observations[..<currentIndex].reversed() {
            guard let candidate = observation.folders.first(where: { $0.path == current.path }) else {
                continue
            }
            guard candidate.complete else { continue }
            guard sameFolderVolume(candidate, current) else { break }
            guard candidate.finishedAt <= current.finishedAt else { continue }
            prior.append(candidate)
        }
        // The persisted observation list is already bounded. Keep the whole
        // comparable run so the UI's "All saved" range can show every retained
        // complete observation for this exact selected path and volume.
        return prior.reversed() + [current]
    }

    public static func previousCompleteFolder(
        for current: FolderObservation,
        in history: LocalHistory
    ) -> FolderObservation? {
        guard current.complete,
              let currentIndex = history.observations.firstIndex(where: {
                  $0.folders.contains(where: { $0.id == current.id })
              })
        else { return nil }

        for observation in history.observations[..<currentIndex].reversed() {
            guard let candidate = observation.folders.first(where: {
                $0.path == current.path && $0.complete
            }) else { continue }
            guard sameFolderVolume(candidate, current) else { return nil }
            if candidate.finishedAt <= current.finishedAt { return candidate }
        }
        return nil
    }

    /// Positive allocated-byte changes for the latest complete observation of
    /// each exact selected path. A later partial observation suppresses a stale
    /// signal for that path until another complete scan is recorded.
    public static func growingFolders(
        in history: LocalHistory, limit: Int = 3
    ) -> [FolderGrowthSignal] {
        guard limit > 0 else { return [] }
        var latestByPath: [String: FolderObservation] = [:]
        for observation in history.observations {
            for folder in observation.folders {
                latestByPath[folder.path] = folder
            }
        }

        return latestByPath.values.compactMap { current -> FolderGrowthSignal? in
            guard current.complete,
                  let previous = previousCompleteFolder(for: current, in: history),
                  let delta = allocatedByteDelta(current: current, previous: previous),
                  delta > 0 else { return nil }
            return FolderGrowthSignal(folder: current, previous: previous, growthBytes: delta)
        }
        .sorted {
            if $0.growthBytes != $1.growthBytes { return $0.growthBytes > $1.growthBytes }
            return $0.folder.path < $1.folder.path
        }
        .prefix(limit)
        .map { $0 }
    }

    /// Joins a capacity loss interval to selected-root growth when the complete
    /// folder comparison overlaps the same most-recent capacity interval, with
    /// a small boundary tolerance for the scan→capacity sampling order.
    /// Overlapping roots remain independent signals; callers must not sum them
    /// or describe them as causes of the capacity movement.
    public static func folderGrowthDuringLatestCapacityLoss(
        in history: LocalHistory, limit: Int = 5
    ) -> CapacityIntervalFolderGrowth? {
        let capacitySeries = comparableCapacitySeries(in: history)
        guard limit > 0,
              let currentCapacity = capacitySeries.last,
              history.capacityObservations.last == currentCapacity,
              let previousCapacity = capacitySeries.dropLast().last,
              currentCapacity.observedAt > previousCapacity.observedAt,
              let availableDelta = availableCapacityDelta(
                  current: currentCapacity, previous: previousCapacity
              ),
              availableDelta < 0 else { return nil }

        let intervalStart = previousCapacity.observedAt
        let intervalEnd = currentCapacity.observedAt
        let earliestFolderBaseline = intervalStart.addingTimeInterval(-capacityScanBoundaryTolerance)
        let latestFolderResult = intervalEnd.addingTimeInterval(capacityScanBoundaryTolerance)
        let alignedGrowth = growingFolders(in: history, limit: Int.max).filter {
            $0.previous.finishedAt >= earliestFolderBaseline
                && $0.previous.finishedAt <= intervalEnd
                && $0.folder.finishedAt >= intervalStart
                && $0.folder.finishedAt <= latestFolderResult
                && $0.previous.finishedAt <= $0.folder.finishedAt
        }

        return CapacityIntervalFolderGrowth(
            previousCapacity: previousCapacity,
            currentCapacity: currentCapacity,
            availableBytesLost: availableDelta.magnitude,
            folderGrowth: Array(alignedGrowth.prefix(limit))
        )
    }

    /// Positive allocated-byte changes for filename categories across the
    /// latest complete observations of one exact selected path. Returns nil
    /// when either observation is partial, legacy data lacks summaries, or a
    /// category cap prevents a complete comparison.
    public static func growingFileExtensions(
        for current: FolderObservation,
        in history: LocalHistory,
        limit: Int = 5
    ) -> [FileExtensionGrowthSignal]? {
        guard limit > 0, current.complete,
              let latest = history.observations.reversed().lazy.compactMap({ observation in
                  observation.folders.first(where: { $0.path == current.path })
              }).first,
              latest.id == current.id,
              let previous = previousCompleteFolder(for: current, in: history),
              previous.complete,
              !current.fileExtensionSummariesTruncated,
              !previous.fileExtensionSummariesTruncated,
              let currentCategories = completeCategoryMetrics(for: current),
              let previousCategories = completeCategoryMetrics(for: previous)
        else { return nil }

        let names = Set(currentCategories.keys).union(previousCategories.keys)
        return names.compactMap { name -> FileExtensionGrowthSignal? in
            let now = currentCategories[name, default: 0]
            let before = previousCategories[name, default: 0]
            let (delta, overflow) = now.subtractingReportingOverflow(before)
            guard !overflow, delta > 0 else { return nil }
            return FileExtensionGrowthSignal(
                extensionName: name, growthBytes: delta, currentAllocatedBytes: now
            )
        }
        .sorted {
            if $0.growthBytes != $1.growthBytes { return $0.growthBytes > $1.growthBytes }
            return $0.extensionName < $1.extensionName
        }
        .prefix(limit)
        .map { $0 }
    }

    /// Positive subdirectory allocated-byte changes from the latest complete
    /// scan of each exact selected root. A path must appear in both complete
    /// observations; absence from a capped summary is never treated as zero.
    public static func growingDirectories(
        in history: LocalHistory,
        limit: Int = 3
    ) -> [DirectoryGrowthSignal] {
        guard limit > 0 else { return [] }
        var latestByPath: [String: FolderObservation] = [:]
        for observation in history.observations {
            for folder in observation.folders {
                latestByPath[folder.path] = folder
            }
        }

        var signals: [DirectoryGrowthSignal] = []
        for folder in latestByPath.values where folder.complete {
            for directory in directoryMap(in: folder).values {
                guard directory.complete,
                      let previous = previousCompleteDirectoryObservation(
                          for: directory, in: folder, history: history
                      ),
                      let delta = allocatedByteDelta(current: directory, previous: previous.directory),
                      delta > 0 else { continue }
                signals.append(DirectoryGrowthSignal(
                    folder: folder, previousFolder: previous.folder,
                    directory: directory, previousDirectory: previous.directory,
                    growthBytes: delta
                ))
            }
        }

        return Array(signals.sorted {
            if $0.growthBytes != $1.growthBytes { return $0.growthBytes > $1.growthBytes }
            if $0.folder.path != $1.folder.path { return $0.folder.path < $1.folder.path }
            return $0.directory.rootRelativePath < $1.directory.rootRelativePath
        }.prefix(limit))
    }

    /// Positive allocated-byte deltas for exact relative file paths present in
    /// both complete top-file summaries of the same selected root. Missing rows
    /// are unknown and are never interpreted as zero; summary truncation does
    /// not invalidate a path measured in both observations.
    public static func growingFiles(
        for current: FolderObservation,
        in history: LocalHistory,
        limit: Int = 5
    ) -> [FileGrowthSignal] {
        guard limit > 0, current.complete,
              let latest = history.observations.reversed().lazy.compactMap({ observation in
                  observation.folders.first(where: { $0.path == current.path })
              }).first,
              latest.id == current.id,
              let previous = previousCompleteFolder(for: current, in: history),
              previous.complete
        else { return [] }

        var previousByPath: [String: FileUsageSummary] = [:]
        for file in previous.largestFiles where previousByPath[file.rootRelativePath] == nil {
            previousByPath[file.rootRelativePath] = file
        }
        var signals: [FileGrowthSignal] = []
        for file in current.largestFiles {
            guard let prior = previousByPath[file.rootRelativePath] else { continue }
            let (delta, overflow) = file.allocatedBytes.subtractingReportingOverflow(prior.allocatedBytes)
            guard !overflow, delta > 0 else { continue }
            signals.append(FileGrowthSignal(
                folder: current, previousFolder: previous,
                file: file, previousFile: prior, growthBytes: delta
            ))
        }
        return signals.sorted {
            if $0.growthBytes != $1.growthBytes { return $0.growthBytes > $1.growthBytes }
            return $0.file.rootRelativePath.utf8.lexicographicallyPrecedes(
                $1.file.rootRelativePath.utf8
            )
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func directoryMap(in folder: FolderObservation) -> [String: DirectoryUsage] {
        var directories: [String: DirectoryUsage] = [:]
        for directory in folder.subdirectorySummaries {
            directories[directory.rootRelativePath] = directory
        }
        for directory in folder.projectDirectorySummaries {
            directories[directory.rootRelativePath] = directory
        }
        if let gitMetadata = folder.gitMetadataUsage {
            directories[gitMetadata.rootRelativePath] = gitMetadata
        }
        return directories
    }

    private static func completeCategoryMetrics(
        for folder: FolderObservation
    ) -> [String: Int64]? {
        guard folder.fileCount >= 0, folder.allocatedBytes >= 0 else { return nil }
        var result: [String: Int64] = [:]
        var totalFileCount = 0
        var totalAllocatedBytes: Int64 = 0
        for item in folder.fileExtensionSummaries {
            guard result[item.extensionName] == nil,
                  item.fileCount >= 0, item.allocatedBytes >= 0,
                  item.logicalBytes >= 0 else { return nil }
            let (count, countOverflow) = totalFileCount.addingReportingOverflow(item.fileCount)
            let (bytes, bytesOverflow) = totalAllocatedBytes.addingReportingOverflow(item.allocatedBytes)
            guard !countOverflow, !bytesOverflow else { return nil }
            totalFileCount = count
            totalAllocatedBytes = bytes
            result[item.extensionName] = item.allocatedBytes
        }
        guard totalFileCount == folder.fileCount,
              totalAllocatedBytes == folder.allocatedBytes else { return nil }
        return result
    }

    public static func allocatedByteDelta(
        current: FolderObservation,
        previous: FolderObservation
    ) -> Int64? {
        guard current.complete, previous.complete, current.path == previous.path,
              sameFolderVolume(current, previous) else { return nil }
        let (delta, overflow) = current.allocatedBytes.subtractingReportingOverflow(previous.allocatedBytes)
        return overflow ? nil : delta
    }

    public static func previousCompleteDirectory(
        for current: DirectoryUsage,
        in folder: FolderObservation,
        history: LocalHistory
    ) -> DirectoryUsage? {
        previousCompleteDirectoryObservation(for: current, in: folder, history: history)?.directory
    }

    private static func previousCompleteDirectoryObservation(
        for current: DirectoryUsage,
        in folder: FolderObservation,
        history: LocalHistory
    ) -> (folder: FolderObservation, directory: DirectoryUsage)? {
        guard folder.complete, current.complete,
              let currentIndex = history.observations.firstIndex(where: { observation in
                  observation.folders.contains(where: { $0.id == folder.id })
              })
        else { return nil }

        // Partial scans and roots not selected in an observation are skipped.
        // A complete same-root observation is an invalidation boundary when
        // the retained directory is absent or the volume identity changed,
        // even if its wall-clock time moved into the future after a rollback.
        for observation in history.observations[..<currentIndex].reversed() {
            guard let previousFolder = observation.folders.first(where: {
                $0.path == folder.path && $0.complete
            }) else { continue }
            guard sameFolderVolume(folder, previousFolder) else { return nil }
            let previousDirectory = directoryMap(in: previousFolder)[current.rootRelativePath]
            guard let previousDirectory, previousDirectory.complete else { return nil }
            if previousFolder.finishedAt <= folder.finishedAt {
                return (previousFolder, previousDirectory)
            }
        }
        return nil
    }

    public static func allocatedByteDelta(
        current: DirectoryUsage,
        previous: DirectoryUsage
    ) -> Int64? {
        guard current.complete, previous.complete,
              current.rootRelativePath == previous.rootRelativePath
        else { return nil }
        let (delta, overflow) = current.allocatedBytes.subtractingReportingOverflow(previous.allocatedBytes)
        return overflow ? nil : delta
    }
}
