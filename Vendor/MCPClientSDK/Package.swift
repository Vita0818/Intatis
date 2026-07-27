// swift-tools-version:6.1
import PackageDescription

// Client-only, source-pinned derivative of the official MCP Swift SDK.
// Upstream identity and the intentionally excluded server surface are recorded
// in UPSTREAM.md and PATCHES.md.
let package = Package(
    name: "MCPClientSDK",
    platforms: [
        .macOS("13.0"),
        .macCatalyst("16.0"),
        .iOS("16.0"),
        .watchOS("9.0"),
        .tvOS("16.0"),
        .visionOS("1.0"),
    ],
    products: [
        .library(name: "MCP", targets: ["MCP"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-system.git",
            revision: "c8a44d836fe7913603e246acab7c528c2e780168"
        ),
        .package(
            url: "https://github.com/apple/swift-log.git",
            revision: "96a2f8a0fa41e9e09af4585e2724c4e825410b91"
        ),
        .package(
            url: "https://github.com/mattt/eventsource.git",
            revision: "e83f076811f32757305b8bf69ac92d05626ffdd7"
        ),
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            exact: "4.5.1"
        ),
    ],
    targets: [
        .target(
            name: "MCP",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Logging", package: "swift-log"),
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                ),
                .product(
                    name: "EventSource",
                    package: "eventsource",
                    condition: .when(
                        platforms: [
                            .macOS, .iOS, .tvOS, .visionOS, .watchOS, .macCatalyst,
                        ]
                    )
                ),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
    ]
)
