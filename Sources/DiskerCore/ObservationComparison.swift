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
                })
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
