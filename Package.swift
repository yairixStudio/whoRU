// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "whoRU",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .library(name: "WhoRUCore", targets: ["WhoRUCore"]),
        .executable(name: "whoru", targets: ["whoru"]),
        .executable(name: "whoru-cli", targets: ["whoru-cli"]),
    ],
    targets: [
        // Platform-agnostic core: models, parsing, scoring, analyst, store, settings.
        // Imports Foundation only. Builds on macOS, Linux and Windows.
        .target(
            name: "WhoRUCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // macOS implementation of the platform protocols: dialog watcher,
        // process inspection, evidence checks, and the SwiftUI/AppKit UI.
        .target(
            name: "WhoRUMac",
            dependencies: ["WhoRUCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // The menu-bar app.
        .executableTarget(
            name: "whoru",
            dependencies: ["WhoRUCore", "WhoRUMac"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Command-line front end. Uses the same pipeline without a GUI.
        .executableTarget(
            name: "whoru-cli",
            dependencies: [
                "WhoRUCore",
                .target(name: "WhoRUMac", condition: .when(platforms: [.macOS])),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "WhoRUCoreTests",
            dependencies: ["WhoRUCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WhoRUMacTests",
            dependencies: ["WhoRUMac"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
