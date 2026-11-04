// swift-tools-version: 6.2

// Personal fork: video player logic without UI (skip buttons, hold-to-speed, playback decisions), used by the iOS app
// and tested with `swift test`.

import PackageDescription

let package = Package(
    name: "PlayerCore",
    platforms: [
        .iOS(.v18),
        .tvOS(.v26),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "PlayerCore",
            targets: ["PlayerCore"]
        ),
    ],
    targets: [
        .target(name: "PlayerCore"),
        .testTarget(
            name: "PlayerCoreTests",
            dependencies: ["PlayerCore"]
        ),
    ]
)
