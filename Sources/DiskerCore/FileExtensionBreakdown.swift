import Foundation

/// A bounded filename-category breakdown for one selected-root observation.
/// The last category combines retained categories outside the display limit
/// and any additional categories omitted by the scanner's storage bound.
public enum FileExtensionBreakdown {
    public static let otherCategoryName = "other extensions"

    /// Returns nil when the persisted summaries cannot support a complete,
    /// non-overflowed allocation breakdown. A partial folder observation may
    /// still return categories; callers must disclose that coverage is partial.
    public static func categories(
        for folder: FolderObservation,
        visibleLimit: Int = 5
    ) -> [FileExtensionUsage]? {
        guard visibleLimit > 0, !folder.byteAccountingOverflowed else { return nil }
        let summaries = folder.fileExtensionSummaries
        guard summaries.allSatisfy({
            $0.logicalBytes >= 0 && $0.allocatedBytes >= 0 && $0.fileCount >= 0
        }), folder.otherFileExtensionUsage.map({
            $0.logicalBytes >= 0 && $0.allocatedBytes >= 0 && $0.fileCount >= 0
        }) ?? true else { return nil }

        if folder.fileExtensionSummariesTruncated,
           folder.otherFileExtensionUsage == nil {
            // Older stored observations may not contain the omitted-category
            // aggregate. Their top entries remain useful as a list, but they
            // cannot form a truthful whole-breakdown chart.
            return nil
        }

        let retained = Array(summaries.prefix(visibleLimit))
        let omittedRetained = Array(summaries.dropFirst(visibleLimit))
        var omitted = omittedRetained
        if let storedOther = folder.otherFileExtensionUsage {
            omitted.append(storedOther)
        }
        guard !omitted.isEmpty else { return retained }

        var logicalBytes: Int64 = 0
        var allocatedBytes: Int64 = 0
        var fileCount = 0
        for category in omitted {
            let (nextLogical, logicalOverflow) = logicalBytes.addingReportingOverflow(category.logicalBytes)
            let (nextAllocated, allocatedOverflow) = allocatedBytes.addingReportingOverflow(category.allocatedBytes)
            let (nextFileCount, countOverflow) = fileCount.addingReportingOverflow(category.fileCount)
            guard !logicalOverflow, !allocatedOverflow, !countOverflow else { return nil }
            logicalBytes = nextLogical
            allocatedBytes = nextAllocated
            fileCount = nextFileCount
        }
        guard logicalBytes >= 0, allocatedBytes >= 0, fileCount >= 0 else { return nil }

        return retained + [FileExtensionUsage(
            extensionName: otherCategoryName,
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            fileCount: fileCount
        )]
    }
}
