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
        .binaryTarget(name: "SpatialAudioCore", url: "https://github.com/kristofferR/SpatialAudioBridge/releases/download/2.0.1/SpatialAudioCore.xcframework.zip", checksum: "f55febe310fd3d5ed3afe6d7cc977b67c2cf4a6d08affeaf1a8c4720f22ada5d"),
        .target(name: "SpatialAudioBridge", dependencies: ["SpatialAudioCore"],
                resources: [.copy("Resources/ThirdPartyNotices.txt")]),
        .target(name: "SpatialAudioPlayback", resources: [.copy("Resources/silent-atmos.mp4")]),
        .executableTarget(name: "APACConvert", dependencies: ["SpatialAudioBridge"]),
        .testTarget(name: "SpatialAudioBridgeTests", dependencies: ["SpatialAudioBridge"]),
        .testTarget(name: "SpatialAudioPlaybackTests", dependencies: ["SpatialAudioPlayback"]),
    ]
)
