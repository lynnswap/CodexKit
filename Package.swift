// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CodexKit",
    platforms: [
        .macOS("15.4"),
    ],
    products: [
        .library(
            name: "CodexKit",
            targets: ["CodexKit"]
        ),
        .library(
            name: "CodexAppServerKit",
            targets: ["CodexAppServerKit"]
        ),
        .library(
            name: "CodexAppServerKitTesting",
            targets: ["CodexAppServerKitTesting"]
        ),
        .library(
            name: "CodexDataKit",
            targets: ["CodexDataKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "CodexKit",
            dependencies: [
                "CodexAppServerKit",
                "CodexDataKit",
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ],
        ),
        .target(
            name: "CodexAppServerKit",
            exclude: ["README.md"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .target(
            name: "CodexAppServerKitTesting",
            dependencies: [
                "CodexAppServerKit",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .target(
            name: "CodexDataKit",
            dependencies: [
                "CodexAppServerKit",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ],
            exclude: ["README.md"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ],
        ),
        .testTarget(
            name: "CodexKitTests",
            dependencies: ["CodexKit"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "CodexAppServerKitTests",
            dependencies: [
                "CodexAppServerKit",
                "CodexAppServerKitTesting",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .testTarget(
            name: "CodexDataKitTests",
            dependencies: [
                "CodexDataKit",
                "CodexAppServerKitTesting",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ],
        ),
    ]
)
