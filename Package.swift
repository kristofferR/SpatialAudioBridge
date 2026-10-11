// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpatialAudioBridge",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13)],
    products: [
        .library(name: "SpatialAudioBridge", targets: ["SpatialAudioBridge"]),
        .library(name: "SpatialAudioPlayback", targets: ["SpatialAudioPlayback"]),
        .executable(name: "apac-convert", targets: ["APACConvert"]),
    ],
    targets: [
        // Built by scripts/build-core.sh. Release tags download it instead; see scripts/release-core.sh.
        .binaryTarget(name: "SpatialAudioCore", url: "https://github.com/kristofferR/SpatialAudioBridge/releases/download/1.1.1/SpatialAudioCore.xcframework.zip", checksum: "2db8c6d15cea3550468a9c68d65c25f418264e1618215cc593879b4f80fc2064"),
        .target(name: "SpatialAudioBridge", dependencies: ["SpatialAudioCore"]),
        .target(name: "SpatialAudioPlayback", resources: [.copy("Resources/silent-atmos.mp4")]),
        .executableTarget(name: "APACConvert", dependencies: ["SpatialAudioBridge"]),
        .testTarget(name: "SpatialAudioBridgeTests", dependencies: ["SpatialAudioBridge"]),
        .testTarget(name: "SpatialAudioPlaybackTests", dependencies: ["SpatialAudioPlayback"]),
    ]
)
