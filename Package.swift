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
        .binaryTarget(name: "SpatialAudioCore", url: "https://github.com/kristofferR/SpatialAudioBridge/releases/download/1.6.1/SpatialAudioCore.xcframework.zip", checksum: "f42b019317fd8f641e96440332d1e094c9abf9f594bc36a47e479816c9c4e0fe"),
        .target(name: "SpatialAudioBridge", dependencies: ["SpatialAudioCore"],
                resources: [.copy("Resources/ThirdPartyNotices.txt")]),
        .target(name: "SpatialAudioPlayback", resources: [.copy("Resources/silent-atmos.mp4")]),
        .executableTarget(name: "APACConvert", dependencies: ["SpatialAudioBridge"]),
        .testTarget(name: "SpatialAudioBridgeTests", dependencies: ["SpatialAudioBridge"]),
        .testTarget(name: "SpatialAudioPlaybackTests", dependencies: ["SpatialAudioPlayback"]),
    ]
)
