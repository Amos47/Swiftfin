// swift-tools-version: 6.2

// Personal fork: Custom Home Rows logic without UI, shared by the iOS and tvOS apps and tested with `swift test`.

import PackageDescription

let package = Package(
    name: "HomeRowsCore",
    platforms: [
        .iOS(.v18),
        .tvOS(.v26),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "HomeRowsCore",
            targets: ["HomeRowsCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/jellyfin/jellyfin-sdk-swift.git", exact: "3.0.0"),
    ],
    targets: [
        .target(
            name: "HomeRowsCore",
            dependencies: [
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
            ]
        ),
        .testTarget(
            name: "HomeRowsCoreTests",
            dependencies: ["HomeRowsCore"]
        ),
    ]
)
