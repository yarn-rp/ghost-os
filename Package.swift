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
        .executable(name: "Flow42App", targets: ["Flow42App"]),
    ],
    dependencies: [
        .package(url: "https://github.com/steipete/AXorcist.git", from: "0.1.0"),
        // Yams: read-only YAML for parsing the agent-authored flow.yaml.
        // Swift never parses YAML during recording — only emits meta.yaml via
        // Flow42Core/Common/YAMLEmit. Yams lives in Flow42Core because both
        // the flow42 CLI (`play current`, `view`) and Flow42Menu (the
        // floating window) need to read flow.yaml.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        // MarkdownUI: SwiftUI Markdown renderer with theming, full
        // block-level support (lists, code blocks, headers,
        // blockquotes, tables). Used by Flow42ChatView to render
        // agent messages — flow-creator + the autonomous runner
        // both speak Markdown, and we want it to look like Markdown
        // not raw text. macOS 12+, MIT.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
    ],
    targets: [
        .target(
            name: "Flow42Core",
            dependencies: [
                .product(name: "AXorcist", package: "AXorcist"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/Flow42Core",
            resources: [
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
            dependencies: [
                "Flow42Core",
                .product(name: "Yams", package: "Yams"),
            ],
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
        .executableTarget(
            name: "Flow42App",
            dependencies: [
                "Flow42Core",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/Flow42App",
            swiftSettings: concurrencySettings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreServices"),
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
