// swift-tools-version: 6.2

import PackageDescription

let concurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "Flow42",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Flow42Core", targets: ["Flow42Core"]),
        .executable(name: "flow42", targets: ["flow42"]),
        .executable(name: "Flow42Menu", targets: ["Flow42Menu"]),
    ],
    dependencies: [
        .package(url: "https://github.com/steipete/AXorcist.git", from: "0.1.0"),
        // Yams: read-only YAML for `flow42 view` (parses the agent-authored
        // flow.yaml). Swift never parses YAML during recording — only emits
        // meta.yaml via Flow42Core/Common/YAMLEmit. So Yams lives in the
        // CLI target, not in Flow42Core.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "Flow42Core",
            dependencies: [
                .product(name: "AXorcist", package: "AXorcist"),
            ],
            path: "Sources/Flow42Core",
            resources: [
                .copy("Resources/prompts"),
                .copy("Resources/skills"),
            ],
            swiftSettings: concurrencySettings,
            linkerSettings: [.linkedFramework("ScreenCaptureKit")]
        ),
        .executableTarget(
            name: "flow42",
            dependencies: [
                "Flow42Core",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/flow42",
            swiftSettings: concurrencySettings
        ),
        .executableTarget(
            name: "Flow42Menu",
            dependencies: ["Flow42Core"],
            path: "Sources/Flow42Menu",
            swiftSettings: concurrencySettings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "Flow42CoreTests",
            dependencies: ["Flow42Core"],
            path: "Tests/Flow42CoreTests",
            swiftSettings: concurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
