import Foundation

public enum ObservationComparison {
    public struct FolderGrowthSignal: Equatable, Identifiable, Sendable {
        public var id: String { folder.path }
        public let folder: FolderObservation
        public let previous: FolderObservation
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

    /// A cautious investigation signal from three consecutive manual samples.
    /// It requires stable PID, process name, and kernel-reported start time.
    public static func possibleProcessGrowth(in history: LocalHistory) -> [ProcessGrowthSignal] {
        let recent = Array(history.ramObservations.suffix(3))
        guard recent.count == 3,
              recent.allSatisfy(\.processListAvailable),
              let first = recent.first,
              let last = recent.last,
              last.observedAt.timeIntervalSince(first.observedAt) >= 15 * 60
        else { return [] }

        let firstSamples = first.largestProcesses
        let finalSamples = last.largestProcesses
        let threshold = UInt64(100 * 1024 * 1024)

        return firstSamples.compactMap { initial -> ProcessGrowthSignal? in
            guard let startTime = initial.processStartTime else { return nil }
            let matching = recent.compactMap { observation in
                observation.largestProcesses.first(where: {
                    $0.processID == initial.processID
                        && $0.name == initial.name
                        && $0.processStartTime == startTime
                })
            }
            guard matching.count == 3,
                  let latest = finalSamples.first(where: {
                      $0.processID == initial.processID
                          && $0.name == initial.name
                          && $0.processStartTime == startTime
                  }),
                  latest.residentBytes >= initial.residentBytes,
                  latest.residentBytes - initial.residentBytes >= threshold
            else { return nil }

            return ProcessGrowthSignal(
                processID: initial.processID,
                processName: initial.name,
                firstObservedAt: first.observedAt,
                lastObservedAt: last.observedAt,
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
        }) else { return nil }

        return history.capacityObservations[..<currentIndex].reversed().first(where: {
            $0.totalBytes == current.totalBytes
                && $0.availabilityBasis == current.availabilityBasis
                && $0.observedAt <= current.observedAt
        })
    }

    /// The trailing run of samples for the same reported volume size and
    /// availability API basis. A capacity or method change starts a new run.
    public static func comparableCapacitySeries(in history: LocalHistory) -> [CapacityObservation] {
        guard let latest = history.capacityObservations.last else { return [] }
        var series: [CapacityObservation] = []
        for sample in history.capacityObservations.reversed() {
            guard sample.totalBytes == latest.totalBytes,
                  sample.availabilityBasis == latest.availabilityBasis else { break }
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
              current.observedAt >= previous.observedAt
        else { return nil }
        let (delta, overflow) = current.availableBytes.subtractingReportingOverflow(previous.availableBytes)
        return overflow ? nil : delta
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

        let prior = history.observations[..<currentIndex].compactMap { observation in
            observation.folders.first(where: { $0.path == current.path && $0.complete })
        }
        return Array((prior + [current]).suffix(24))
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

        return history.observations[..<currentIndex].reversed().lazy
            .compactMap { observation in
                observation.folders.first(where: {
                    $0.path == current.path && $0.complete
                })
            }
            .first
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

    public static func allocatedByteDelta(
        current: FolderObservation,
        previous: FolderObservation
    ) -> Int64? {
        guard current.complete, previous.complete, current.path == previous.path else { return nil }
        let (delta, overflow) = current.allocatedBytes.subtractingReportingOverflow(previous.allocatedBytes)
        return overflow ? nil : delta
    }

    public static func previousCompleteDirectory(
        for current: DirectoryUsage,
        in folder: FolderObservation,
        history: LocalHistory
    ) -> DirectoryUsage? {
        guard folder.complete, current.complete,
              let currentIndex = history.observations.firstIndex(where: { observation in
                  observation.folders.contains(where: { $0.id == folder.id })
              })
        else { return nil }

        return history.observations[..<currentIndex].reversed().lazy
            .compactMap { observation -> DirectoryUsage? in
                guard let previousFolder = observation.folders.first(where: {
                    $0.path == folder.path && $0.complete
                }) else { return nil }
                return previousFolder.subdirectorySummaries.first(where: {
                    $0.rootRelativePath == current.rootRelativePath && $0.complete
                }) ?? previousFolder.gitMetadataUsage.flatMap {
                    $0.rootRelativePath == current.rootRelativePath && $0.complete ? $0 : nil
                }
            }
            .first
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
