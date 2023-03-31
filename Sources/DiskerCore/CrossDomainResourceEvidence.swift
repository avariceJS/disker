import Foundation

/// Read-only projection of explicitly linked application and project paths.
/// Path relationships are lexical evidence only and never establish ownership,
/// shared physical storage, or bytes that may be summed or reclaimed.
public struct CrossDomainResourceEvidence: Equatable, Sendable {
    public enum Domain: String, Equatable, Sendable {
        case application
        case project
    }

    public enum Provenance: Equatable, Sendable {
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
        public var id: String { "\(otherLinkID)|\(String(describing: pathRelation))" }
        public let otherLinkID: String
        public let otherDomain: Domain
        /// A lexical relationship between selected paths, not proof of shared
        /// storage. `volumeRelation` is unknown when either scan lacks an ID.
        public let pathRelation: PathRelation
        public let volumeRelation: VolumeRelation
    }

    public struct Link: Equatable, Sendable, Identifiable {
        public var id: String { "\(domain.rawValue)|\(rootPath)|\(path)|\(String(describing: provenance))" }
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

    public static func make(
        forProjectRootPath projectRootPath: String,
        in history: LocalHistory,
        homeDirectoryPath: String
    ) -> Self {
        let selectedProjectRoot = standardized(projectRootPath)
        let latestByPath = latestObservations(in: history)
        var rawLinks: [(Domain, String, String, Provenance)] = []

        for association in history.applicationAssociations {
            let bundlePath = standardized(association.bundlePath)
            rawLinks.append((.application, bundlePath, bundlePath, .selectedApplicationBundle))
            for linkedPath in association.relatedFolderPaths {
                let path = standardized(linkedPath)
                rawLinks.append((.application, bundlePath, path, .userLinkedApplicationFolder))

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
                            rawLinks.append((
                                .application, bundlePath, path,
                                .signatureCoveredSharedGroupClaim(groupIdentifier: group)
                            ))
                        }
                    case .declaredSharedGroupContainerClaim:
                        if let group = attribution.groupIdentifier {
                            rawLinks.append((
                                .application, bundlePath, path,
                                .declaredSharedGroupClaim(groupIdentifier: group)
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
            guard root == selectedProjectRoot else { continue }
            let rootProvenance: Provenance = latestByPath[root]?.gitMetadataEntryDetected == true
                ? .gitMarkedSelectedProject : .selectedProjectRoot
            rawLinks.append((.project, root, root, rootProvenance))
            for path in association.relatedFolderPaths {
                rawLinks.append((.project, root, standardized(path), .userLinkedProjectFolder))
            }
        }

        // Stable de-duplication protects the projection from legacy duplicate
        // app links while retaining distinct provenance for the same path.
        var seen = Set<String>()
        let uniqueLinks = rawLinks.filter { domain, root, path, provenance in
            seen.insert("\(domain.rawValue)|\(root)|\(path)|\(String(describing: provenance))").inserted
        }
        let unfinishedByObservationID = Dictionary(
            history.observations.flatMap { scan in scan.folders.map { ($0.id, scan.cancelled) } },
            uniquingKeysWith: { latest, _ in latest }
        )
        let links = uniqueLinks.map { domain, root, path, provenance in
            Link(
                domain: domain,
                rootPath: root,
                path: path,
                provenance: provenance,
                observation: latestByPath[path],
                scanWasCancelled: latestByPath[path].flatMap { unfinishedByObservationID[$0.id] } ?? false,
                overlaps: []
            )
        }.sorted { $0.id < $1.id }

        let linked = links.map { link in
            Link(
                domain: link.domain,
                rootPath: link.rootPath,
                path: link.path,
                provenance: link.provenance,
                observation: link.observation,
                scanWasCancelled: link.scanWasCancelled,
                overlaps: links.compactMap { other -> Overlap? in
                    guard link.domain != other.domain,
                          let relation = pathRelation(link.path, other.path) else { return nil }
                    return Overlap(
                        otherLinkID: other.id,
                        otherDomain: other.domain,
                        pathRelation: relation,
                        volumeRelation: volumeRelation(link.observation?.volumeDeviceID,
                                                       other.observation?.volumeDeviceID)
                    )
                }.sorted { $0.id < $1.id }
            )
        }
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
