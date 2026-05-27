// swift-tools-version: 6.0

// SPDX-License-Identifier: Apache-2.0

// Copyright 2026 XCSteward Contributors



import PackageDescription

let package = Package(
    name: "XCSteward",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "XCStewardKit", targets: ["XCStewardKit"]),
        .executable(name: "xcsteward", targets: ["xcsteward"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite"
        ),
        .target(
            name: "XCStewardKit",
            dependencies: ["CSQLite"]
        ),
        .executableTarget(
            name: "xcsteward",
            dependencies: ["XCStewardKit"]
        ),
        .testTarget(
            name: "XCStewardKitTests",
            dependencies: ["XCStewardKit"]
        ),
    ]
)
