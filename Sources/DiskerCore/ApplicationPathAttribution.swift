import Foundation
import Security

public struct ApplicationBundleIdentity: Equatable, Sendable {
    public let bundleIdentifier: String
    /// Embedded App Groups entitlement claims. Security's signing-information
    /// lookup does not validate the signature; consumers must label this claim.
    public let claimedGroupIdentifiers: [String]

    public init(bundleIdentifier: String, claimedGroupIdentifiers: [String] = []) {
        self.bundleIdentifier = bundleIdentifier
        self.claimedGroupIdentifiers = claimedGroupIdentifiers
    }
}

public enum ApplicationBundleMetadata {
    /// Reads the declared bundle ID and embedded App Groups claim only from the
    /// app the user selected. This is separate from file-tree size scanning.
    public static func identity(fromSelectedBundleAt url: URL) -> ApplicationBundleIdentity? {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { return nil }

        var claimedGroups: [String] = []
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
        }

        return ApplicationBundleIdentity(
            bundleIdentifier: bundleIdentifier,
            claimedGroupIdentifiers: claimedGroups
        )
    }

    private static func validGroupIdentifiers(_ value: Any?) -> [String] {
        guard let identifiers = value as? [String] else { return [] }
        return Array(Set(identifiers.filter(isValidIdentifier))).sorted()
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
        /// The selected bundle's embedded entitlement claims this shared group.
        /// Signature validity and membership are not verified.
        case declaredSharedGroupContainerClaim
        /// The exact selected bundle ID matches macOS's per-app container path.
        /// Code-signing identity and exclusive use have not been checked.
        case probableContainerPathMatch
        /// The user selected this relationship, but Disker found no known path evidence.
        case userSelectedOnly
    }

    public let evidence: Evidence
    public let bundleIdentifier: String?
    public let groupIdentifier: String?

    public var title: String {
        switch evidence {
        case .declaredSharedGroupContainerClaim: "Declared shared App Group path"
        case .probableContainerPathMatch: "Probable app container path"
        case .userSelectedOnly: "User-selected association"
        }
    }

    public var explanation: String {
        switch evidence {
        case .declaredSharedGroupContainerClaim:
            "The selected app's embedded App Groups claim names this exact path. Disker has not validated the signature or access, and this container is shared with other group members."
        case .probableContainerPathMatch:
            "This path matches the selected app's CFBundleIdentifier under ~/Library/Containers. Disker has not verified the app's signing identity or exclusive use of the data."
        case .userSelectedOnly:
            "You selected this folder for the app. Disker found no verified ownership relationship; the folder may be shared or unrelated."
        }
    }

    public static func classify(
        bundleIdentifier: String?, associatedFolderPath: String,
        homeDirectoryPath: String, claimedGroupIdentifiers: [String] = []
    ) -> ApplicationPathAttribution {
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
                    evidence: .declaredSharedGroupContainerClaim,
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
                    evidence: .probableContainerPathMatch,
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

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
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

    private static func isWithin(_ candidate: String, root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root + "/")
    }
}
