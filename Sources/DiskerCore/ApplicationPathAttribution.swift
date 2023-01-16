import Foundation

public enum ApplicationBundleMetadata {
    /// Reads only the declared bundle identifier from an app the user selected
    /// in the application-bundle picker. This is separate from tree scanning.
    public static func identifier(fromSelectedBundleAt url: URL) -> String? {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}

public struct ApplicationPathAttribution: Equatable, Sendable {
    public enum Evidence: Equatable, Sendable {
        /// The exact selected bundle ID matches macOS's per-app container path.
        /// Code-signing identity and exclusive use have not been checked.
        case probableContainerPathMatch
        /// The user selected this relationship, but Disker found no known path evidence.
        case userSelectedOnly
    }

    public let evidence: Evidence
    public let bundleIdentifier: String?

    public var title: String {
        switch evidence {
        case .probableContainerPathMatch: "Probable app container path"
        case .userSelectedOnly: "User-selected association"
        }
    }

    public var explanation: String {
        switch evidence {
        case .probableContainerPathMatch:
            "This path matches the selected app's CFBundleIdentifier under ~/Library/Containers. Disker has not verified the app's signing identity or exclusive use of the data."
        case .userSelectedOnly:
            "You selected this folder for the app. Disker found no verified ownership relationship; the folder may be shared or unrelated."
        }
    }

    public static func classify(
        bundleIdentifier: String?, associatedFolderPath: String,
        homeDirectoryPath: String
    ) -> ApplicationPathAttribution {
        guard let bundleIdentifier,
              isValidBundleIdentifier(bundleIdentifier) else {
            return ApplicationPathAttribution(evidence: .userSelectedOnly, bundleIdentifier: nil)
        }

        let containerRoot = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .standardizedFileURL.path
        let candidate = URL(fileURLWithPath: associatedFolderPath).standardizedFileURL.path
        let isContainerOrDescendant = candidate == containerRoot
            || candidate.hasPrefix(containerRoot + "/")

        return ApplicationPathAttribution(
            evidence: isContainerOrDescendant ? .probableContainerPathMatch : .userSelectedOnly,
            bundleIdentifier: bundleIdentifier
        )
    }

    private init(evidence: Evidence, bundleIdentifier: String?) {
        self.evidence = evidence
        self.bundleIdentifier = bundleIdentifier
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
}
