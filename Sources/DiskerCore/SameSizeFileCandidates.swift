import Foundation

public struct SameSizeCandidateFile: Codable, Equatable, Sendable {
    public let relativePath: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64

    public init(relativePath: String, logicalBytes: Int64, allocatedBytes: Int64) {
        self.relativePath = relativePath
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
    }
}

public struct SameSizeCandidateGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: String { String(logicalBytes) }
    public let logicalBytes: Int64
    public let fileCount: Int
    public let files: [SameSizeCandidateFile]
    public let omittedFileCount: Int

    public init(
        logicalBytes: Int64,
        fileCount: Int,
        files: [SameSizeCandidateFile],
        omittedFileCount: Int
    ) {
        self.logicalBytes = logicalBytes
        self.fileCount = fileCount
        self.files = files
        self.omittedFileCount = omittedFileCount
    }
}

/// Same-logical-size metadata from one exact, complete selected-root inventory.
/// It is candidate awareness only; file contents have not been compared.
public struct SameSizeFileCandidateSummary: Codable, Equatable, Sendable {
    public let rootPath: String
    public let folderObservationID: UUID
    public let observedAt: Date
    public let excludedSymlinkCount: Int
    public let eligibleFileCount: Int
    public let groups: [SameSizeCandidateGroup]
    public let omittedGroupCount: Int
    public let sizeBucketLimitReached: Bool

    public init(
        rootPath: String,
        folderObservationID: UUID,
        observedAt: Date,
        excludedSymlinkCount: Int,
        eligibleFileCount: Int,
        groups: [SameSizeCandidateGroup],
        omittedGroupCount: Int,
        sizeBucketLimitReached: Bool
    ) {
        self.rootPath = rootPath
        self.folderObservationID = folderObservationID
        self.observedAt = observedAt
        self.excludedSymlinkCount = excludedSymlinkCount
        self.eligibleFileCount = eligibleFileCount
        self.groups = groups
        self.omittedGroupCount = omittedGroupCount
        self.sizeBucketLimitReached = sizeBucketLimitReached
    }

    public var isCandidateIndexComplete: Bool {
        !sizeBucketLimitReached && omittedGroupCount == 0
    }

    public func isValid(for rootKey: String) -> Bool {
        guard rootPath == rootKey,
              rootPath.hasPrefix("/"), !rootPath.utf8.contains(0),
              excludedSymlinkCount >= 0, eligibleFileCount >= 0,
              groups.count <= SameSizeFileCandidateIndex.maximumGroupsPerRoot,
              omittedGroupCount >= 0,
              omittedGroupCount <= eligibleFileCount / 2 else { return false }
        var seenSizes = Set<Int64>()
        var seenPaths = Set<String>()
        var groupedFileCount = 0
        for group in groups {
            guard group.logicalBytes >= SameSizeFileCandidateIndex.minimumLogicalBytes,
                  group.fileCount >= 2,
                  group.fileCount <= eligibleFileCount,
                  group.files.count >= 2,
                  group.files.count <= SameSizeFileCandidateIndex.maximumFilesPerGroup,
                  group.omittedFileCount == group.fileCount - group.files.count,
                  group.fileCount <= eligibleFileCount - groupedFileCount,
                  seenSizes.insert(group.logicalBytes).inserted else { return false }
            groupedFileCount += group.fileCount
            for file in group.files {
                guard SameSizeFileCandidateIndex.isSafeRelativePath(file.relativePath),
                      file.relativePath.utf8.count <= SameSizeFileCandidateIndex.maximumPathBytes,
                      file.logicalBytes == group.logicalBytes,
                      file.allocatedBytes >= 0,
                      seenPaths.insert(file.relativePath).inserted else { return false }
            }
        }
        return true
    }
}

/// Builds a bounded index from a complete regular-file inventory without reading
/// file contents. A size-bucket cap keeps work and persisted summaries bounded.
public enum SameSizeFileCandidateIndex {
    public static let minimumLogicalBytes: Int64 = 1_048_576
    public static let maximumTrackedSizeBuckets = 20_000
    public static let maximumGroupsPerRoot = 40
    public static let maximumFilesPerGroup = 5
    public static let maximumPathBytes = 4_096

    private struct Bucket {
        var fileCount: Int
        var files: [SameSizeCandidateFile]
    }

    public static func makeSummary(
        from snapshot: FileInventorySnapshot
    ) -> SameSizeFileCandidateSummary? {
        guard snapshot.complete else { return nil }
        var buckets: [Int64: Bucket] = [:]
        buckets.reserveCapacity(min(snapshot.entries.count, maximumTrackedSizeBuckets))
        var eligibleFileCount = 0
        var sizeBucketLimitReached = false

        for entry in snapshot.entries where entry.logicalBytes >= minimumLogicalBytes {
            eligibleFileCount += 1
            let file = SameSizeCandidateFile(
                relativePath: entry.relativePath,
                logicalBytes: entry.logicalBytes,
                allocatedBytes: entry.allocatedBytes
            )
            if var bucket = buckets[entry.logicalBytes] {
                bucket.fileCount += 1
                if bucket.files.count < maximumFilesPerGroup {
                    bucket.files.append(file)
                }
                buckets[entry.logicalBytes] = bucket
            } else if buckets.count < maximumTrackedSizeBuckets {
                buckets[entry.logicalBytes] = Bucket(fileCount: 1, files: [file])
            } else {
                sizeBucketLimitReached = true
            }
        }

        let candidates = buckets.compactMap { size, bucket -> SameSizeCandidateGroup? in
            guard bucket.fileCount >= 2 else { return nil }
            return SameSizeCandidateGroup(
                logicalBytes: size,
                fileCount: bucket.fileCount,
                files: bucket.files,
                omittedFileCount: bucket.fileCount - bucket.files.count
            )
        }.sorted {
            if $0.logicalBytes != $1.logicalBytes { return $0.logicalBytes > $1.logicalBytes }
            return $0.fileCount > $1.fileCount
        }

        return SameSizeFileCandidateSummary(
            rootPath: snapshot.rootPath,
            folderObservationID: snapshot.folderObservationID,
            observedAt: snapshot.observedAt,
            excludedSymlinkCount: snapshot.excludedSymlinkCount,
            eligibleFileCount: eligibleFileCount,
            groups: Array(candidates.prefix(maximumGroupsPerRoot)),
            omittedGroupCount: max(0, candidates.count - maximumGroupsPerRoot),
            sizeBucketLimitReached: sizeBucketLimitReached
        )
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
