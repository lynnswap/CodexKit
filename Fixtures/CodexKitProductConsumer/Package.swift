// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CodexKitProductConsumer",
    platforms: [
        .macOS("15.4"),
    ],
    products: [
        .executable(
            name: "CodexKitProductConsumer",
            targets: ["CodexKitProductConsumer"]
        ),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "CodexKitProductConsumer",
            dependencies: [
                .product(name: "CodexAppServerKit", package: "CodexKit"),
                .product(name: "CodexAppServerKitTesting", package: "CodexKit"),
                .product(name: "CodexDataKit", package: "CodexKit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ]
)
