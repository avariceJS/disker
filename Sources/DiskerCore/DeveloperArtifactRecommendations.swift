import Foundation

/// Read-only prompts for investigating measured development-storage candidates.
/// A recommendation is never a deletion instruction and does not imply that
/// data is unused, recoverable, or safe to remove.
public struct DeveloperArtifactRecommendations: Equatable, Sendable {
    public static let maximumRecommendations = 3
    /// A measured candidate can be surfaced without growth evidence when its
    /// allocated-byte estimate is at least this threshold (100 MiB).
    public static let largeCandidateThresholdBytes: Int64 = 100 * 1_024 * 1_024

    public let selectedRootPath: String
    public let observedAt: Date
    public let recommendations: [Recommendation]

    public enum Reason: Equatable, Sendable {
        /// Exact same-path growth in complete observations. This is a change in
        /// allocated-byte estimate, not an estimate of reclaimable space.
        case observedGrowth(allocatedBytes: Int64)
        /// Current allocated-byte estimate crossed the published threshold.
        /// This reason makes no claim about historical change.
        case largeMeasuredCandidate(allocatedBytes: Int64, thresholdBytes: Int64)
    }

    public struct Coverage: Equatable, Sendable {
        public let selectedRootComplete: Bool
        public let candidateSubtreeComplete: Bool
        public let candidateInventoryTruncated: Bool
        public let description: String
    }

    public struct Recommendation: Equatable, Identifiable, Sendable {
        /// Complete source row so presentation can jump to the existing review
        /// detail without reconstructing or weakening its provenance.
        public let entry: DeveloperArtifactReview.Entry
        public var id: String { path }
        public let path: String
        public let category: DeveloperArtifactReview.Category
        public let reason: Reason
        public let title: String
        public let reasonDescription: String
        public let confidenceDescription: String
        public let evidence: String
        public let possibleConsequence: String
        public let risk: String
        public let coverage: Coverage
        /// Intersecting candidate subtree paths. Their measured sizes are not
        /// additive and this model deliberately provides no aggregate total.
        public let overlappingCandidatePaths: [String]
        /// Metadata scans cannot determine safe or reclaimable bytes.
        public let reclaimableBytes: Int64? = nil
        public let investigationPrompt: String
    }

    /// Builds at most three ranked, read-only investigation prompts from the
    /// current review. Incomplete root coverage suppresses the whole result;
    /// incomplete candidate subtrees are individually excluded. Missing or
    /// unmatched historical rows are never interpreted as zero-byte changes.
    public static func make(from review: DeveloperArtifactReview) -> Self {
        guard review.selectedRootComplete else {
            return Self(selectedRootPath: review.selectedRootPath,
                        observedAt: review.observedAt, recommendations: [])
        }

        let eligible = review.entries.filter {
            $0.selectedRootComplete && $0.subtreeComplete
                && isStrictDescendant($0.path, of: review.selectedRootPath)
        }
        let growth = eligible.compactMap { entry -> (DeveloperArtifactReview.Entry, Int64)? in
            guard let change = entry.historicalChange?.allocatedBytesChange, change > 0 else {
                return nil
            }
            return (entry, change)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.path < $1.0.path
        }

        // A growth row is emitted once, ahead of all size-only rows. A current
        // measurement with no positive verified delta may still qualify by the
        // absolute threshold, but is explicitly described as having no growth
        // conclusion.
        let growthPaths = Set(growth.map { $0.0.path })
        let large = eligible.filter {
            !growthPaths.contains($0.path)
                && $0.allocatedBytesEstimate >= largeCandidateThresholdBytes
        }.sorted {
            if $0.allocatedBytesEstimate != $1.allocatedBytesEstimate {
                return $0.allocatedBytesEstimate > $1.allocatedBytesEstimate
            }
            return $0.path < $1.path
        }

        let ranked: [(DeveloperArtifactReview.Entry, Reason)] =
            growth.map { ($0.0, .observedGrowth(allocatedBytes: $0.1)) }
            + large.map { ($0, .largeMeasuredCandidate(
                allocatedBytes: $0.allocatedBytesEstimate,
                thresholdBytes: largeCandidateThresholdBytes
            )) }

        let recommendations = ranked.prefix(maximumRecommendations).map { entry, reason in
            Recommendation(
                entry: entry,
                path: entry.path,
                category: entry.category,
                reason: reason,
                title: title(for: reason),
                reasonDescription: reasonDescription(for: reason),
                confidenceDescription: confidenceDescription(for: reason),
                evidence: entry.evidence,
                possibleConsequence: entry.possibleConsequence,
                risk: entry.risk,
                coverage: Coverage(
                    selectedRootComplete: entry.selectedRootComplete,
                    candidateSubtreeComplete: entry.subtreeComplete,
                    candidateInventoryTruncated: review.candidatesTruncated,
                    description: review.candidatesTruncated
                        ? "Complete selected-root scan and complete candidate subtree at \(entry.observedAt); additional matching candidate summaries were omitted."
                        : "Complete selected-root scan and complete candidate subtree at \(entry.observedAt)."
                ),
                overlappingCandidatePaths: entry.overlappingCandidatePaths.sorted(),
                investigationPrompt: prompt(for: entry, reason: reason)
            )
        }

        return Self(selectedRootPath: review.selectedRootPath,
                    observedAt: review.observedAt,
                    recommendations: recommendations)
    }

    private static func prompt(
        for entry: DeveloperArtifactReview.Entry,
        reason: Reason
    ) -> String {
        switch reason {
        case .observedGrowth(let bytes):
            return "Review this exact path in its owning tool: its allocated-byte estimate increased by \(format(bytes)) between complete same-path observations. No cleanup or reclaimable-space conclusion is available."
        case .largeMeasuredCandidate(let bytes, let threshold):
            return "Review this exact path in its owning tool: its current allocated-byte estimate is \(format(bytes)) and meets the \(format(threshold)) review threshold. No growth, unused-data, cleanup, or reclaimable-space conclusion is available."
        }
    }

    private static func title(for reason: Reason) -> String {
        switch reason {
        case .observedGrowth: "Investigate observed storage growth"
        case .largeMeasuredCandidate: "Review a large measured candidate"
        }
    }

    private static func reasonDescription(for reason: Reason) -> String {
        switch reason {
        case .observedGrowth(let bytes):
            "Allocated-byte estimate increased by \(format(bytes)) between complete observations of this exact path."
        case .largeMeasuredCandidate(let bytes, let threshold):
            "Current allocated-byte estimate is \(format(bytes)), meeting the \(format(threshold)) review threshold; no growth conclusion is available."
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func confidenceDescription(for reason: Reason) -> String {
        switch reason {
        case .observedGrowth:
            "Evidence confidence: complete measurements of this exact path support the change; its purpose remains a name or Git-marker clue."
        case .largeMeasuredCandidate:
            "Evidence confidence: a complete scan measured this exact path; its purpose remains a name or Git-marker clue."
        }
    }

    private static func isStrictDescendant(_ path: String, of root: String) -> Bool {
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        let pathValue = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        return pathValue.hasPrefix(prefix) && pathValue != rootPath
    }
}
