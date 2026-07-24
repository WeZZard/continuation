// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Continuations",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "Continuations", targets: ["Continuations"]),
        .library(name: "ContinuationsKit", targets: ["ContinuationsKit"]),
    ],
    targets: [
        .target(
            name: "ContinuationsKit",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "Continuations",
            dependencies: ["ContinuationsKit"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "ContinuationsKitTests",
            dependencies: ["ContinuationsKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
