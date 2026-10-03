// swift-tools-version: 6.0

import PackageDescription

// Compiles Splat3D's documented call sites in Swift 6 language mode, from
// the main actor, the way a SwiftUI app writes them. CI builds it; nothing
// runs. If it stops compiling, app code written from the README breaks too.
let package = Package(
    name: "ConcurrencyCheck",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    dependencies: [
        // Named explicitly: a path package's identity is otherwise its
        // directory name, which differs between checkouts.
        .package(name: "Splat3D", path: "../.."),
    ],
    targets: [
        .target(
            name: "ConcurrencyCheck",
            dependencies: [.product(name: "Splat3D", package: "Splat3D")]
        ),
    ]
)
