import Foundation

public enum StorageAreaHint: String, CaseIterable, Sendable {
    case swiftPackageBuild
    case xcodeDerivedData
    case javascriptDependencies
    case npmData
    case pnpmStore
    case yarnData
    case pythonEnvironment
    case pythonBytecode
    case gradleData
    case mavenData
    case cargoData
    case buildOutputCandidate
    case cocoaPodsDependencies
    case carthageDependencies
    case simulatorData
    case dockerData
    case modelDataDirectory
    case datasetDirectory
    case databaseDataDirectory
    case trainingArtifactDirectory
    case logDirectory
    case xcodeArchives
    case xcodeArchiveBundle
    case debugSymbols
    case webBuildOutput
    case webBuildCache
    case testCoverageOutput

    public var title: String {
        switch self {
        case .swiftPackageBuild: "Swift build products"
        case .xcodeDerivedData: "Xcode derived data"
        case .javascriptDependencies: "JavaScript dependencies"
        case .npmData: "npm data · name match"
        case .pnpmStore: "pnpm package store · name match"
        case .yarnData: "Yarn data · name match"
        case .pythonEnvironment: "Python environment"
        case .pythonBytecode: "Python bytecode cache"
        case .gradleData: "Gradle data · name match"
        case .mavenData: "Maven data · name match"
        case .cargoData: "Cargo data · name match"
        case .buildOutputCandidate: "Build output candidate · name match"
        case .cocoaPodsDependencies: "CocoaPods dependencies · name match"
        case .carthageDependencies: "Carthage dependencies · name match"
        case .simulatorData: "Simulator data · name match"
        case .dockerData: "Docker data · name match"
        case .modelDataDirectory: "Model, weight, embedding, or checkpoint data · name pattern"
        case .datasetDirectory: "Dataset directory · name match"
        case .databaseDataDirectory: "Database or vector-store data · name match"
        case .trainingArtifactDirectory: "Training artifacts · name match"
        case .logDirectory: "Log directory · name match"
        case .xcodeArchives: "Xcode archives directory · name match"
        case .xcodeArchiveBundle: "Xcode archive bundle · name match"
        case .debugSymbols: "Debug symbols · name match"
        case .webBuildOutput: "Web build output · name match"
        case .webBuildCache: "Web build cache · name match"
        case .testCoverageOutput: "Test coverage output · name match"
        }
    }

    public var symbolName: String {
        switch self {
        case .swiftPackageBuild, .xcodeDerivedData: "hammer"
        case .javascriptDependencies, .npmData, .pnpmStore, .yarnData: "shippingbox"
        case .pythonEnvironment, .pythonBytecode: "curlybraces"
        case .gradleData, .mavenData, .cargoData, .buildOutputCandidate: "hammer"
        case .cocoaPodsDependencies, .carthageDependencies: "shippingbox"
        case .simulatorData, .dockerData, .modelDataDirectory, .datasetDirectory, .databaseDataDirectory,
             .trainingArtifactDirectory, .xcodeArchives, .xcodeArchiveBundle: "externaldrive"
        case .logDirectory: "doc.text"
        case .debugSymbols: "hammer"
        case .webBuildOutput, .testCoverageOutput: "hammer"
        case .webBuildCache: "shippingbox"
        }
    }

    /// This is a name-based clue for an explicitly scanned directory, not
    /// evidence of ownership, active use, or safe removal.
    public static func matching(relativePath: String) -> StorageAreaHint? {
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".build": return .swiftPackageBuild
            case "DerivedData": return .xcodeDerivedData
            case "node_modules": return .javascriptDependencies
            case ".npm": return .npmData
            case ".pnpm-store": return .pnpmStore
            case ".yarn": return .yarnData
            case ".venv", "venv": return .pythonEnvironment
            case "__pycache__": return .pythonBytecode
            case ".gradle": return .gradleData
            case ".m2": return .mavenData
            case ".cargo": return .cargoData
            case "target": return .buildOutputCandidate
            case "Pods": return .cocoaPodsDependencies
            case "Carthage": return .carthageDependencies
            case "CoreSimulator": return .simulatorData
            case "Docker": return .dockerData
            case "models", "checkpoints", "checkpoint", "weights", "model_weights", "model-weights",
                 "embedding", "embeddings", "model-cache", "model_cache", "huggingface":
                return .modelDataDirectory
            case let component where component.hasPrefix("models--"): return .modelDataDirectory
            case "datasets", "dataset": return .datasetDirectory
            case "database", "databases", "db", "sqlite", "chroma", "chroma_db", "lancedb",
                 "qdrant", "weaviate", "milvus", "postgres", "mongodb":
                return .databaseDataDirectory
            case "artifacts", "training-artifacts", "training_artifacts", "runs":
                return .trainingArtifactDirectory
            case "logs": return .logDirectory
            case "Archives": return .xcodeArchives
            case let component where component.hasSuffix(".xcarchive"): return .xcodeArchiveBundle
            case "dSYMs": return .debugSymbols
            case let component where component.hasSuffix(".dSYM"): return .debugSymbols
            case "dist", "build", "out", ".next", ".nuxt": return .webBuildOutput
            case ".turbo": return .webBuildCache
            case "coverage": return .testCoverageOutput
            default: continue
            }
        }
        return nil
    }

    /// Returns a hint only when the directory's own final component is a
    /// recognized name. Unlike `matching(relativePath:)`, ancestors do not
    /// cause every descendant to become an independent candidate.
    public static func matchingDirectory(relativePath: String) -> StorageAreaHint? {
        guard let component = relativePath.split(separator: "/", omittingEmptySubsequences: true).last else {
            return nil
        }
        return matching(relativePath: String(component))
    }
}
