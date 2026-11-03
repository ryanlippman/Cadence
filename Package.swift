// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Cadence",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Cadence", targets: ["Cadence"]),
        .executable(name: "cadence-render", targets: ["cadence-render"]),
    ],
    targets: [
        .target(
            name: "CadenceCore",
            resources: [.copy("Resources/Samples")]
        ),
        .executableTarget(name: "Cadence", dependencies: ["CadenceCore"]),
        .executableTarget(name: "cadence-render", dependencies: ["CadenceCore"]),
        .executableTarget(name: "cadence-analyze", dependencies: ["CadenceCore"]),
        .testTarget(name: "CadenceCoreTests", dependencies: ["CadenceCore"]),
    ]
)
