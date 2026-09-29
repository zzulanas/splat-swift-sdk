// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SplatKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "SplatKit",
            targets: ["SplatKit"]
        ),
    ],
    targets: [
        .target(
            name: "SplatKit",
            path: "Sources/SplatKit"
        ),
        .testTarget(
            name: "SplatKitTests",
            dependencies: ["SplatKit"],
            path: "Tests/SplatKitTests"
        ),
    ]
)
