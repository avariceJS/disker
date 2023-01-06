import Foundation

public enum ObservationComparison {
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
