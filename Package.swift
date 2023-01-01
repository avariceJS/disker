// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Disker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Disker", targets: ["DiskerApp"]),
        .executable(name: "DiskerCoreChecks", targets: ["DiskerCoreChecks"]),
        .library(name: "DiskerCore", targets: ["DiskerCore"]),
    ],
    targets: [
        .target(name: "DiskerCore"),
        .executableTarget(name: "DiskerApp", dependencies: ["DiskerCore"]),
        .executableTarget(name: "DiskerCoreChecks", dependencies: ["DiskerCore"], path: "Tests/DiskerCoreChecks"),
    ]
)
