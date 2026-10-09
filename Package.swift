// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpatialAudioBridge",
    platforms: [.macOS("26.0"), .tvOS("26.0")],
    products: [
        .library(name: "SpatialAudioBridge", targets: ["SpatialAudioBridge"]),
        .executable(name: "apac-convert", targets: ["APACConvert"]),
    ],
    targets: [
        .binaryTarget(name: "SpatialAudioCore", path: "BinaryArtifacts/SpatialAudioCore.xcframework"),
        .target(name: "SpatialAudioBridge", dependencies: ["SpatialAudioCore"]),
        .executableTarget(name: "APACConvert", dependencies: ["SpatialAudioBridge"]),
        .testTarget(name: "SpatialAudioBridgeTests", dependencies: ["SpatialAudioBridge"]),
    ]
)
