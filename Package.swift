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
        .binaryTarget(name: "SpatialAudioCore", url: "https://github.com/kristofferR/SpatialAudioBridge/releases/download/1.1.0/SpatialAudioCore.xcframework.zip", checksum: "f774051150266db76a443553d0f13b33f58c2dcd3a36ff90d1e1c28de1968050"),
        .target(name: "SpatialAudioBridge", dependencies: ["SpatialAudioCore"]),
        .target(name: "SpatialAudioPlayback", resources: [.copy("Resources/silent-atmos.mp4")]),
        .executableTarget(name: "APACConvert", dependencies: ["SpatialAudioBridge"]),
        .testTarget(name: "SpatialAudioBridgeTests", dependencies: ["SpatialAudioBridge"]),
        .testTarget(name: "SpatialAudioPlaybackTests", dependencies: ["SpatialAudioPlayback"]),
    ]
)
