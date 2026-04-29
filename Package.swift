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
    ],
    dependencies: [
        .package(url: "https://github.com/steipete/AXorcist.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "Flow42Core",
            dependencies: [
                .product(name: "AXorcist", package: "AXorcist"),
            ],
            path: "Sources/Flow42Core",
            swiftSettings: concurrencySettings,
            linkerSettings: [.linkedFramework("ScreenCaptureKit")]
        ),
        .executableTarget(
            name: "flow42",
            dependencies: ["Flow42Core"],
            path: "Sources/flow42",
            swiftSettings: concurrencySettings
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
