// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "minutiae-engine",
    platforms: [.macOS("14.4")],
    dependencies: [
        // Pinned exact: 0.x API churn — bump deliberately (see CLAUDE.md).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.2")
    ],
    targets: [
        .executableTarget(
            name: "minutiae-engine",
            dependencies: ["EngineCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "EngineCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EngineCoreTests",
            dependencies: ["EngineCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
