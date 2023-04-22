import Foundation
import Security

public struct ApplicationBundleIdentity: Equatable, Sendable {
    public let bundleIdentifier: String
    /// Embedded App Groups entitlement claims. Security's signing-information
    /// lookup does not validate the signature; consumers must label this claim.
    public let claimedGroupIdentifiers: [String]
    /// The static signature passed strict validation when the bundle was read.
    public let signatureValidated: Bool
    /// The identifier covered by the signature, when Security provided one.
    public let signedBundleIdentifier: String?

    public init(
        bundleIdentifier: String, claimedGroupIdentifiers: [String] = [],
        signatureValidated: Bool = false, signedBundleIdentifier: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.claimedGroupIdentifiers = claimedGroupIdentifiers
        self.signatureValidated = signatureValidated
        self.signedBundleIdentifier = signedBundleIdentifier
    }
}

public enum ApplicationBundleMetadata {
    private static let maximumEmbeddedGroupEntries = 256
    private static let maximumPersistedGroupIdentifiers = 64
    private static let maximumGroupIdentifierLength = 255

    /// Reads the declared bundle ID and embedded App Groups claim only from the
    /// app the user selected. This is separate from file-tree size scanning.
    public static func identity(fromSelectedBundleAt url: URL) -> ApplicationBundleIdentity? {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { return nil }

        var claimedGroups: [String] = []
        var signatureValidated = false
        var signedBundleIdentifier: String?
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        if createStatus == errSecSuccess, let staticCode {
            var signingInformation: CFDictionary?
            let informationStatus = SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &signingInformation
            )
            if informationStatus == errSecSuccess,
               let dictionary = signingInformation as? [String: Any],
               let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
                claimedGroups = validGroupIdentifiers(
                    entitlements["com.apple.security.application-groups"]
                )
            }
            let validationStatus = SecStaticCodeCheckValidity(
                staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil
            )
            signatureValidated = validationStatus == errSecSuccess
            if signatureValidated,
               let dictionary = signingInformation as? [String: Any] {
                signedBundleIdentifier = dictionary[kSecCodeInfoIdentifier as String] as? String
            }
        }

        return ApplicationBundleIdentity(
            bundleIdentifier: bundleIdentifier,
            claimedGroupIdentifiers: claimedGroups,
            signatureValidated: signatureValidated,
            signedBundleIdentifier: signedBundleIdentifier
        )
    }

    private static func validGroupIdentifiers(_ value: Any?) -> [String] {
        guard let identifiers = value as? [String],
              identifiers.count <= maximumEmbeddedGroupEntries else { return [] }

        var uniqueIdentifiers = Set<String>()
        for identifier in identifiers where identifier.utf8.count <= maximumGroupIdentifierLength
            && isValidIdentifier(identifier) {
            uniqueIdentifiers.insert(identifier)
            if uniqueIdentifiers.count > maximumPersistedGroupIdentifiers {
                return []
            }
        }
        return uniqueIdentifiers.sorted()
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value)
                    || (65...90).contains($0.value)
                    || (97...122).contains($0.value)
                    || $0 == "-" || $0 == "."
              }) else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty }
    }
}

public struct ApplicationPathAttribution: Equatable, Sendable {
    public enum Evidence: Equatable, Sendable {
        /// The validated signature's signed identifier matches the declared
        /// bundle ID, whose entitlement claims this shared group.
        case signatureCoveredSharedGroupClaim
        /// The selected bundle's embedded entitlement claims this shared group.
        /// Signature validity and membership are not verified.
        case declaredSharedGroupContainerClaim
        /// A locally validated signature carries the identifier matching the
        /// selected user's per-app container path.
        case validatedBundleIdentifierPathMatch
        /// The exact selected bundle ID matches macOS's per-app container path.
        /// Code-signing identity and exclusive use have not been checked.
        case probableContainerPathMatch
        /// Exact directory-name match under conventional support/cache roots.
        /// This weak clue does not establish ownership.
        case probableNamedSupportPathMatch
        /// Exact bundle-ID match under the user's conventional Logs directory.
        /// This weak clue does not establish origin or ownership.
        case probableLogsPathMatch
        /// Exact saved-state name match under the user's conventional state root.
        /// Saved state may contain unique user data.
        case probableSavedApplicationStatePathMatch
        /// The user selected this relationship, but Disker found no known path evidence.
        case userSelectedOnly
    }

    public let evidence: Evidence
    public let bundleIdentifier: String?
    public let groupIdentifier: String?

    public var title: String {
        switch evidence {
        case .signatureCoveredSharedGroupClaim: "Signature-covered shared App Group claim"
        case .declaredSharedGroupContainerClaim: "Declared shared App Group path"
        case .validatedBundleIdentifierPathMatch: "Signed ID + conventional container path · ownership unverified"
        case .probableContainerPathMatch: "Probable app container path"
        case .probableNamedSupportPathMatch: "Possible app data path · name match"
        case .probableLogsPathMatch: "Possible app logs path · name match"
        case .probableSavedApplicationStatePathMatch: "Possible saved app state · name match"
        case .userSelectedOnly: "User-selected association"
        }
    }

    public var explanation: String {
        switch evidence {
        case .signatureCoveredSharedGroupClaim:
            "A locally valid static signature covers the selected app's bundle ID and embedded App Groups claim for this exact path. This does not establish developer trust or OS-granted access. The container is shared; current use and exclusive ownership are not established."
        case .declaredSharedGroupContainerClaim:
            "The selected app's embedded App Groups claim names this exact path. Disker has not matched a locally validated signed identifier to the declared bundle ID or established OS-granted access. This container is shared with other group members."
        case .validatedBundleIdentifierPathMatch:
            "The selected app's locally validated signature carries this bundle identifier, which matches the conventional per-app container path. Disker has not established this folder's origin, current use, or exclusive ownership."
        case .probableContainerPathMatch:
            "This path matches the selected app's CFBundleIdentifier under ~/Library/Containers. Disker has not verified the app's signing identity or exclusive use of the data."
        case .probableNamedSupportPathMatch:
            "This path's exact directory name matches the selected app's CFBundleIdentifier under Application Support or Caches. This is a name match only; app ownership, current use, and exclusive use are not established."
        case .probableLogsPathMatch:
            "This path's exact directory name matches the selected app's CFBundleIdentifier under ~/Library/Logs. This is a name match only; log origin, current use, and exclusive ownership are not established."
        case .probableSavedApplicationStatePathMatch:
            "This path matches the selected app's conventional saved-state name under ~/Library/Saved Application State. This is a name match only; origin, current use, and exclusive ownership are not established, and it may contain user state."
        case .userSelectedOnly:
            "You selected this folder for the app. Disker found no verified ownership relationship; the folder may be shared or unrelated."
        }
    }

    public static func classify(
        bundleIdentifier: String?, associatedFolderPath: String,
        homeDirectoryPath: String, claimedGroupIdentifiers: [String] = [],
        signatureValidated: Bool = false, signedBundleIdentifier: String? = nil
    ) -> ApplicationPathAttribution {
        let validatedBundleIdentity = signatureValidated
            && bundleIdentifier != nil
            && signedBundleIdentifier == bundleIdentifier
        let candidate = URL(fileURLWithPath: associatedFolderPath).standardizedFileURL.path
        let libraryRoot = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .standardizedFileURL

        for groupIdentifier in Set(claimedGroupIdentifiers.filter(isValidBundleIdentifier)).sorted() {
            let groupRoot = libraryRoot
                .appendingPathComponent("Group Containers", isDirectory: true)
                .appendingPathComponent(groupIdentifier, isDirectory: true)
                .standardizedFileURL.path
            if isWithin(candidate, root: groupRoot) {
                return ApplicationPathAttribution(
                    evidence: validatedBundleIdentity
                        ? .signatureCoveredSharedGroupClaim : .declaredSharedGroupContainerClaim,
                    bundleIdentifier: bundleIdentifier,
                    groupIdentifier: groupIdentifier
                )
            }
        }

        if let bundleIdentifier, isValidBundleIdentifier(bundleIdentifier) {
            let containerRoot = libraryRoot
                .appendingPathComponent("Containers", isDirectory: true)
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .standardizedFileURL.path
            if isWithin(candidate, root: containerRoot) {
                return ApplicationPathAttribution(
                    evidence: validatedBundleIdentity
                        ? .validatedBundleIdentifierPathMatch : .probableContainerPathMatch,
                    bundleIdentifier: bundleIdentifier,
                    groupIdentifier: nil
                )
            }
            for directory in ["Application Support", "Caches"] {
                let namedRoot = libraryRoot
                    .appendingPathComponent(directory, isDirectory: true)
                    .appendingPathComponent(bundleIdentifier, isDirectory: true)
                    .standardizedFileURL.path
                if isWithin(candidate, root: namedRoot) {
                    return ApplicationPathAttribution(
                        evidence: .probableNamedSupportPathMatch,
                        bundleIdentifier: bundleIdentifier,
                        groupIdentifier: nil
                    )
                }
            }
            let logsRoot = libraryRoot.appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent(bundleIdentifier, isDirectory: true).standardizedFileURL.path
            if isWithin(candidate, root: logsRoot) {
                return ApplicationPathAttribution(
                    evidence: .probableLogsPathMatch,
                    bundleIdentifier: bundleIdentifier,
                    groupIdentifier: nil
                )
            }
            let savedStateRoot = libraryRoot.appendingPathComponent("Saved Application State", isDirectory: true)
                .appendingPathComponent("\(bundleIdentifier).savedState", isDirectory: true)
                .standardizedFileURL.path
            if isWithin(candidate, root: savedStateRoot) {
                return ApplicationPathAttribution(
                    evidence: .probableSavedApplicationStatePathMatch,
                    bundleIdentifier: bundleIdentifier,
                    groupIdentifier: nil
                )
            }
        }

        return ApplicationPathAttribution(
            evidence: .userSelectedOnly,
            bundleIdentifier: bundleIdentifier,
            groupIdentifier: nil
        )
    }

    private init(evidence: Evidence, bundleIdentifier: String?, groupIdentifier: String?) {
        self.evidence = evidence
        self.bundleIdentifier = bundleIdentifier
        self.groupIdentifier = groupIdentifier
    }

    public static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255,
              value.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value)
                    || (65...90).contains($0.value)
                    || (97...122).contains($0.value)
                    || $0 == "-" || $0 == "."
              }) else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty }
    }

    private static func isWithin(_ candidate: String, root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root + "/")
    }
}

public struct ApplicationDataLocationCandidate: Equatable, Sendable, Identifiable {
    public enum Evidence: Equatable, Sendable {
        case probableAppContainer
        case validatedAppContainerIdentifier
        case probableNamedSupportDirectory
        case probableLogsDirectory
        case probableSavedApplicationState
        case declaredSharedGroupClaim
        case signatureCoveredSharedGroupClaim
    }

    public let path: String
    public let evidence: Evidence
    public let identifier: String

    public var id: String { path }

    public var title: String {
        switch evidence {
        case .probableAppContainer: "Probable per-app container path"
        case .validatedAppContainerIdentifier: "Signed identifier · conventional per-app container path"
        case .probableNamedSupportDirectory: "Possible app support or cache · name match"
        case .probableLogsDirectory: "Possible application logs · ID pattern"
        case .probableSavedApplicationState: "Possible saved state · ID pattern"
        case .declaredSharedGroupClaim: "Declared App Group path · shared"
        case .signatureCoveredSharedGroupClaim: "Signature-covered App Group path · shared"
        }
    }

    public var explanation: String {
        switch evidence {
        case .probableAppContainer:
            "This is the standard path pattern for the supplied bundle ID. Its presence, use, and exclusive ownership have not been checked."
        case .validatedAppContainerIdentifier:
            "The selected bundle's locally validated signature carries this identifier. This conventional path has not been checked for presence, origin, or exclusive use."
        case .probableNamedSupportDirectory:
            "The candidate directory name exactly matches the supplied bundle ID under Application Support or Caches. This is only a naming clue; presence, app ownership, and exclusive use have not been checked."
        case .probableLogsDirectory:
            "This conventional Logs directory path uses the supplied bundle ID as a hint. Its presence, origin, app ownership, and exclusive use have not been checked."
        case .probableSavedApplicationState:
            "This conventional saved-state path uses the supplied bundle ID as a hint. Its presence, origin, current use, and exclusive ownership have not been checked; it may contain user state."
        case .declaredSharedGroupClaim:
            "The selected bundle declares this App Group. The path is shared by design; signature validity and OS-granted access are not established."
        case .signatureCoveredSharedGroupClaim:
            "The selected bundle's locally valid signature covers this App Group claim. The path is shared by design; publisher trust and OS-granted access are not established."
        }
    }
}

public enum ApplicationDataLocationCandidates {
    /// Builds conventional paths from a supplied bounded bundle-ID hint.
    /// Signature and group evidence refine labels when available; this performs
    /// no filesystem lookup and grants no access.
    public static func suggestions(
        bundleIdentifier: String?, homeDirectoryPath: String,
        claimedGroupIdentifiers: [String] = [],
        signatureValidated: Bool = false, signedBundleIdentifier: String? = nil
    ) -> [ApplicationDataLocationCandidate] {
        guard let bundleIdentifier,
              ApplicationPathAttribution.isValidBundleIdentifier(bundleIdentifier)
        else { return [] }

        let libraryRoot = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .standardizedFileURL
        let validatedIdentity = signatureValidated && signedBundleIdentifier == bundleIdentifier
        var candidates = [ApplicationDataLocationCandidate(
            path: libraryRoot.appendingPathComponent("Containers", isDirectory: true)
                .appendingPathComponent(bundleIdentifier, isDirectory: true).standardizedFileURL.path,
            evidence: validatedIdentity ? .validatedAppContainerIdentifier : .probableAppContainer,
            identifier: bundleIdentifier
        )]

        for directory in ["Application Support", "Caches"] {
            candidates.append(ApplicationDataLocationCandidate(
                path: libraryRoot.appendingPathComponent(directory, isDirectory: true)
                    .appendingPathComponent(bundleIdentifier, isDirectory: true)
                    .standardizedFileURL.path,
                evidence: .probableNamedSupportDirectory,
                identifier: bundleIdentifier
            ))
        }

        candidates.append(ApplicationDataLocationCandidate(
            path: libraryRoot.appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent(bundleIdentifier, isDirectory: true).standardizedFileURL.path,
            evidence: .probableLogsDirectory,
            identifier: bundleIdentifier
        ))
        candidates.append(ApplicationDataLocationCandidate(
            path: libraryRoot.appendingPathComponent("Saved Application State", isDirectory: true)
                .appendingPathComponent("\(bundleIdentifier).savedState", isDirectory: true)
                .standardizedFileURL.path,
            evidence: .probableSavedApplicationState,
            identifier: bundleIdentifier
        ))

        for groupIdentifier in Set(claimedGroupIdentifiers.filter {
            ApplicationPathAttribution.isValidBundleIdentifier($0)
        }).sorted() {
            candidates.append(ApplicationDataLocationCandidate(
                path: libraryRoot.appendingPathComponent("Group Containers", isDirectory: true)
                    .appendingPathComponent(groupIdentifier, isDirectory: true).standardizedFileURL.path,
                evidence: validatedIdentity
                    ? .signatureCoveredSharedGroupClaim : .declaredSharedGroupClaim,
                identifier: groupIdentifier
            ))
        }
        return candidates
    }

    /// Returns only an exact normalized match for a generated suggestion. This
    /// lets UI workflows reject arbitrary caller paths before opening a picker
    /// or beginning a selected-root scan.
    public static func suggestion(
        matchingExactPath path: String,
        bundleIdentifier: String?,
        homeDirectoryPath: String
    ) -> ApplicationDataLocationCandidate? {
        let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        return suggestions(
            bundleIdentifier: bundleIdentifier,
            homeDirectoryPath: homeDirectoryPath
        ).first(where: { $0.path == normalizedPath })
    }
}
