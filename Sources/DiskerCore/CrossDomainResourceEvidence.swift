import Foundation

/// Read-only projection of explicitly linked application and project paths.
/// Path relationships are lexical evidence only and never establish ownership,
/// shared physical storage, or bytes that may be summed or reclaimed.
public struct CrossDomainResourceEvidence: Equatable, Sendable {
    public enum Domain: String, Hashable, Sendable {
        case application
        case project
    }

    public enum Focus: Equatable, Sendable {
        case applicationBundle(String)
        case projectRoot(String)
    }

    public enum Provenance: Equatable, Hashable, Sendable {
        case selectedApplicationBundle
        case userLinkedApplicationFolder
        case declaredSharedGroupClaim(groupIdentifier: String)
        case signatureCoveredSharedGroupClaim(groupIdentifier: String)
        case selectedProjectRoot
        case gitMarkedSelectedProject
        case userLinkedProjectFolder
    }

    public enum PathRelation: Equatable, Sendable {
        case exact
        case leftContainsRight
        case rightContainsLeft
    }

    public enum VolumeRelation: Equatable, Sendable {
        case same(UInt64)
        case different(left: UInt64, right: UInt64)
        case unknown
    }

    public struct Overlap: Equatable, Sendable, Identifiable {
        public var id: String { stableIdentifier([otherLinkID, pathRelation.identifierComponent]) }
        public let otherLinkID: String
        public let otherDomain: Domain
        /// A lexical relationship between selected paths, not proof of shared
        /// storage. `volumeRelation` is unknown when either scan lacks an ID.
        public let pathRelation: PathRelation
        public let volumeRelation: VolumeRelation
    }

    public struct Link: Equatable, Sendable, Identifiable {
        public var id: String {
            stableIdentifier([domain.rawValue, rootPath, path, provenance.identifierComponent])
        }
        public let domain: Domain
        public let rootPath: String
        public let path: String
        public let provenance: Provenance
        public let observation: FolderObservation?
        public let scanWasCancelled: Bool
        public let overlaps: [Overlap]
    }

    /// Links remain separate. Overlapping observations are never aggregated.
    public let links: [Link]

    private struct RawLink: Hashable {
        let domain: Domain
        let rootPath: String
        let path: String
        let provenance: Provenance
    }

    public static func make(
        forProjectRootPath projectRootPath: String,
        in history: LocalHistory,
        homeDirectoryPath: String
    ) -> Self {
        make(focusingOn: .projectRoot(projectRootPath), in: history, homeDirectoryPath: homeDirectoryPath)
    }

    public static func make(
        forApplicationBundlePath bundlePath: String,
        in history: LocalHistory,
        homeDirectoryPath: String
    ) -> Self {
        make(focusingOn: .applicationBundle(bundlePath), in: history, homeDirectoryPath: homeDirectoryPath)
    }

    public static func make(
        focusingOn focus: Focus,
        in history: LocalHistory,
        homeDirectoryPath: String
    ) -> Self {
        let selectedApplicationBundle: String?
        let selectedProjectRoot: String?
        switch focus {
        case .applicationBundle(let path):
            selectedApplicationBundle = standardized(path)
            selectedProjectRoot = nil
        case .projectRoot(let path):
            selectedApplicationBundle = nil
            selectedProjectRoot = standardized(path)
        }
        let latestByPath = latestObservations(in: history)
        var rawLinks: [RawLink] = []

        for association in history.applicationAssociations {
            let bundlePath = standardized(association.bundlePath)
            guard selectedApplicationBundle == nil || bundlePath == selectedApplicationBundle else { continue }
            rawLinks.append(RawLink(
                domain: .application, rootPath: bundlePath, path: bundlePath,
                provenance: .selectedApplicationBundle
            ))
            for linkedPath in association.relatedFolderPaths {
                let path = standardized(linkedPath)
                rawLinks.append(RawLink(
                    domain: .application, rootPath: bundlePath, path: path,
                    provenance: .userLinkedApplicationFolder
                ))

                if let bundle = latestByPath[bundlePath],
                   let identifier = bundle.applicationBundleIdentifier {
                    let attribution = ApplicationPathAttribution.classify(
                        bundleIdentifier: identifier,
                        associatedFolderPath: path,
                        homeDirectoryPath: homeDirectoryPath,
                        claimedGroupIdentifiers: bundle.applicationGroupIdentifiers,
                        signatureValidated: bundle.applicationSignatureValidated,
                        signedBundleIdentifier: bundle.applicationSignedBundleIdentifier
                    )
                    switch attribution.evidence {
                    case .signatureCoveredSharedGroupClaim:
                        if let group = attribution.groupIdentifier {
                            rawLinks.append(RawLink(
                                domain: .application, rootPath: bundlePath, path: path,
                                provenance: .signatureCoveredSharedGroupClaim(groupIdentifier: group)
                            ))
                        }
                    case .declaredSharedGroupContainerClaim:
                        if let group = attribution.groupIdentifier {
                            rawLinks.append(RawLink(
                                domain: .application, rootPath: bundlePath, path: path,
                                provenance: .declaredSharedGroupClaim(groupIdentifier: group)
                            ))
                        }
                    default:
                        break
                    }
                }
            }
        }

        for association in history.projectResourceAssociations {
            let root = standardized(association.projectRootPath)
            guard selectedProjectRoot == nil || root == selectedProjectRoot else { continue }
            let rootProvenance: Provenance = latestByPath[root]?.gitMetadataEntryDetected == true
                ? .gitMarkedSelectedProject : .selectedProjectRoot
            rawLinks.append(RawLink(
                domain: .project, rootPath: root, path: root, provenance: rootProvenance
            ))
            for path in association.relatedFolderPaths {
                rawLinks.append(RawLink(
                    domain: .project, rootPath: root, path: standardized(path),
                    provenance: .userLinkedProjectFolder
                ))
            }
        }

        // Structured de-duplication protects the projection from legacy duplicate
        // links and remains unambiguous for legal path characters such as '|'.
        let uniqueLinks = Set(rawLinks).sorted {
            stableIdentifier([$0.domain.rawValue, $0.rootPath, $0.path, $0.provenance.identifierComponent])
                < stableIdentifier([$1.domain.rawValue, $1.rootPath, $1.path, $1.provenance.identifierComponent])
        }
        let unfinishedByObservationID = Dictionary(
            history.observations.flatMap { scan in scan.folders.map { ($0.id, scan.cancelled) } },
            uniquingKeysWith: { latest, _ in latest }
        )
        let links = uniqueLinks.map { raw in
            Link(
                domain: raw.domain,
                rootPath: raw.rootPath,
                path: raw.path,
                provenance: raw.provenance,
                observation: latestByPath[raw.path],
                scanWasCancelled: latestByPath[raw.path].flatMap { unfinishedByObservationID[$0.id] } ?? false,
                overlaps: []
            )
        }

        let focusedDomain: Domain = selectedApplicationBundle == nil ? .project : .application
        let focusedLinks = links.filter { $0.domain == focusedDomain }
        let oppositeCandidates = links.filter { $0.domain != focusedDomain }
        let candidatesByPath = Dictionary(grouping: oppositeCandidates, by: \.path)
        let sortedCandidatePaths = Array(Set(oppositeCandidates.map(\.path))).sorted()
        var overlapsByLinkID: [String: [Overlap]] = [:]
        var relevantCandidateIDs = Set<String>()
        for focused in focusedLinks {
            var candidateIDs = Set<String>()
            var matches: [Link] = []
            for candidate in candidatesByPath[focused.path, default: []]
            where candidateIDs.insert(candidate.id).inserted {
                matches.append(candidate)
            }

            var ancestorPath = ""
            for component in focused.path.split(separator: "/") {
                ancestorPath += "/" + component
                guard ancestorPath != focused.path else { continue }
                for candidate in candidatesByPath[ancestorPath, default: []]
                where candidateIDs.insert(candidate.id).inserted {
                    matches.append(candidate)
                }
            }

            let descendantPrefix = focused.path == "/" ? "/" : focused.path + "/"
            var low = 0
            var high = sortedCandidatePaths.count
            while low < high {
                let middle = (low + high) / 2
                if sortedCandidatePaths[middle] < descendantPrefix { low = middle + 1 }
                else { high = middle }
            }
            while low < sortedCandidatePaths.count,
                  sortedCandidatePaths[low].hasPrefix(descendantPrefix) {
                for candidate in candidatesByPath[sortedCandidatePaths[low], default: []]
                where candidateIDs.insert(candidate.id).inserted {
                    matches.append(candidate)
                }
                low += 1
            }

            for candidate in matches {
                guard let relation = Self.pathRelation(focused.path, candidate.path) else { continue }
                relevantCandidateIDs.insert(candidate.id)
                let volume = Self.volumeRelation(
                    focused.observation?.volumeDeviceID, candidate.observation?.volumeDeviceID
                )
                overlapsByLinkID[focused.id, default: []].append(Overlap(
                    otherLinkID: candidate.id,
                    otherDomain: candidate.domain,
                    pathRelation: relation,
                    volumeRelation: volume
                ))
            }
        }
        let relevantLinks = links.filter {
            $0.domain == focusedDomain || relevantCandidateIDs.contains($0.id)
        }
        let linked = relevantLinks.map { link in
            Link(
                domain: link.domain,
                rootPath: link.rootPath,
                path: link.path,
                provenance: link.provenance,
                observation: link.observation,
                scanWasCancelled: link.scanWasCancelled,
                overlaps: overlapsByLinkID[link.id, default: []].sorted { $0.id < $1.id }
            )
        }.sorted { $0.id < $1.id }
        return Self(links: linked)
    }

    private static func latestObservations(in history: LocalHistory) -> [String: FolderObservation] {
        var latest: [String: FolderObservation] = [:]
        for scan in history.observations.reversed() {
            for observation in scan.folders where latest[standardized(observation.path)] == nil {
                latest[standardized(observation.path)] = observation
            }
        }
        return latest
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private static func pathRelation(_ left: String, _ right: String) -> PathRelation? {
        if left == right { return .exact }
        if isWithin(right, root: left) { return .leftContainsRight }
        if isWithin(left, root: right) { return .rightContainsLeft }
        return nil
    }

    private static func isWithin(_ path: String, root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") && path != "/" }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func volumeRelation(_ left: UInt64?, _ right: UInt64?) -> VolumeRelation {
        guard let left, let right else { return .unknown }
        return left == right ? .same(left) : .different(left: left, right: right)
    }
}

private extension CrossDomainResourceEvidence.Provenance {
    var identifierComponent: String {
        switch self {
        case .selectedApplicationBundle: "selected-application"
        case .userLinkedApplicationFolder: "user-linked-application-folder"
        case .declaredSharedGroupClaim(let group): "declared-group:\(stableIdentifier([group]))"
        case .signatureCoveredSharedGroupClaim(let group): "signed-group:\(stableIdentifier([group]))"
        case .selectedProjectRoot: "selected-project"
        case .gitMarkedSelectedProject: "git-marked-project"
        case .userLinkedProjectFolder: "user-linked-project-folder"
        }
    }
}

private extension CrossDomainResourceEvidence.PathRelation {
    var identifierComponent: String {
        switch self {
        case .exact: "exact"
        case .leftContainsRight: "left-contains-right"
        case .rightContainsLeft: "right-contains-left"
        }
    }

}

private func stableIdentifier(_ components: [String]) -> String {
    components.map { "\($0.utf8.count):\($0)" }.joined()
}
