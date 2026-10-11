// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpatialAudioBridge",
    platforms: [.macOS("26.0"), .tvOS("26.0")],
    products: [
        .library(name: "SpatialAudioBridge", targets: ["SpatialAudioBridge"]),
        .library(name: "SpatialAudioPlayback", targets: ["SpatialAudioPlayback"]),
        .executable(name: "apac-convert", targets: ["APACConvert"]),
    ],
    targets: [
        // Built by scripts/build-core.sh. Release tags download it instead; see scripts/release-core.sh.
        .binaryTarget(name: "SpatialAudioCore", url: "https://github.com/kristofferR/SpatialAudioBridge/releases/download/1.0.0/SpatialAudioCore.xcframework.zip", checksum: "988ff080ba049f273ab0d3a3561423cf47ead836e93c0c28f04b0842fe5b77eb"),
        .target(name: "SpatialAudioBridge", dependencies: ["SpatialAudioCore"]),
        .target(name: "SpatialAudioPlayback", resources: [.copy("Resources/silent-atmos.mp4")]),
        .executableTarget(name: "APACConvert", dependencies: ["SpatialAudioBridge"]),
        .testTarget(name: "SpatialAudioBridgeTests", dependencies: ["SpatialAudioBridge"]),
        .testTarget(name: "SpatialAudioPlaybackTests", dependencies: ["SpatialAudioPlayback"]),
    ]
)
