import Foundation

public enum ObservationComparison {
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
}
