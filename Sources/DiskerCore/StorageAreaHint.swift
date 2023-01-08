import Foundation

public enum StorageAreaHint: String, CaseIterable, Sendable {
    case gitMetadata
    case swiftPackageBuild
    case xcodeDerivedData
    case javascriptDependencies
    case pythonEnvironment
    case pythonBytecode

    public var title: String {
        switch self {
        case .gitMetadata: "Git metadata"
        case .swiftPackageBuild: "Swift build products"
        case .xcodeDerivedData: "Xcode derived data"
        case .javascriptDependencies: "JavaScript dependencies"
        case .pythonEnvironment: "Python environment"
        case .pythonBytecode: "Python bytecode cache"
        }
    }

    public var symbolName: String {
        switch self {
        case .gitMetadata: "chevron.left.forwardslash.chevron.right"
        case .swiftPackageBuild, .xcodeDerivedData: "hammer"
        case .javascriptDependencies: "shippingbox"
        case .pythonEnvironment, .pythonBytecode: "curlybraces"
        }
    }

    /// This is a name-based clue for an explicitly scanned directory, not
    /// evidence of ownership, active use, or safe removal.
    public static func matching(relativePath: String) -> StorageAreaHint? {
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".git": return .gitMetadata
            case ".build": return .swiftPackageBuild
            case "DerivedData": return .xcodeDerivedData
            case "node_modules": return .javascriptDependencies
            case ".venv", "venv": return .pythonEnvironment
            case "__pycache__": return .pythonBytecode
            default: continue
            }
        }
        return nil
    }
}
