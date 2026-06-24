// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CodexKit",
    platforms: [
        .macOS("15.5"),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
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
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "CodexKit",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
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
    ]
)
