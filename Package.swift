// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexModelLens",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "CodexModelLens", targets: ["CodexModelLens"]),
        .executable(name: "model-lens", targets: ["ModelLensCLI"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ModelLensCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "CodexModelLens", dependencies: ["ModelLensCore"]),
        .executableTarget(name: "ModelLensCLI", dependencies: ["ModelLensCore"]),
        .testTarget(name: "ModelLensCoreTests", dependencies: ["ModelLensCore", "CSQLite"])
    ]
)
