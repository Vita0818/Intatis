// swift-tools-version:5.9
import PackageDescription

// Intatis v0.1 — single root manifest.
// One target per module; target dependencies enforce the acyclic DAG from
// ARCHITECTURE.md §2.1. The conceptual `Packages/<Name>` split maps 1:1 to
// these targets and can be promoted to standalone SwiftPM packages later.
//
// Buildable/testable today: Core / Protocol / Providers / Artifacts / Conversation
// (pure Swift, no Apple-only frameworks). SharedUI + IntatisMac use SwiftUI/AppKit,
// guarded with `#if canImport(SwiftUI)` so the package still builds on Linux.

let package = Package(
    name: "Intatis",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "IntatisCore", targets: ["IntatisCore"]),
        .library(name: "IntatisProtocol", targets: ["IntatisProtocol"]),
        .library(name: "IntatisProviders", targets: ["IntatisProviders"]),
        .library(name: "IntatisArtifacts", targets: ["IntatisArtifacts"]),
        .library(name: "IntatisConversation", targets: ["IntatisConversation"]),
        .library(name: "IntatisTools", targets: ["IntatisTools"]),
        .library(name: "IntatisPermission", targets: ["IntatisPermission"]),
        .library(name: "IntatisAgentKernel", targets: ["IntatisAgentKernel"]),
        .library(name: "IntatisSharedUI", targets: ["IntatisSharedUI"]),
        .executable(name: "IntatisMac", targets: ["IntatisMac"]),
    ],
    targets: [
        // MARK: Library targets (module == target)
        .target(
            name: "IntatisCore",
            path: "Packages/IntatisCore/Sources"
        ),
        .target(
            name: "IntatisProtocol",
            dependencies: ["IntatisCore"],
            path: "Packages/IntatisProtocol/Sources"
        ),
        .target(
            name: "IntatisProviders",
            dependencies: ["IntatisCore", "IntatisProtocol"],
            path: "Packages/IntatisProviders/Sources"
        ),
        .target(
            name: "IntatisArtifacts",
            dependencies: ["IntatisCore", "IntatisProtocol"],
            path: "Packages/IntatisArtifacts/Sources"
        ),
        .target(
            name: "IntatisConversation",
            // ChatLoop drives a ChatProvider, so Conversation depends on Providers
            // (still tool-free — see ARCHITECTURE.md §3.4 / §4: iOS links this, not the kernel).
            dependencies: ["IntatisCore", "IntatisProtocol", "IntatisProviders", "IntatisArtifacts"],
            path: "Packages/IntatisConversation/Sources"
        ),
        // v0.2 — Code: tools, deterministic permission gate, single-agent kernel.
        .target(
            name: "IntatisTools",
            dependencies: ["IntatisCore", "IntatisProtocol"],
            path: "Packages/IntatisTools/Sources"
        ),
        .target(
            name: "IntatisPermission",
            dependencies: ["IntatisCore", "IntatisProtocol"],
            path: "Packages/IntatisPermission/Sources"
        ),
        .target(
            name: "IntatisAgentKernel",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisTools", "IntatisPermission", "IntatisConversation", "IntatisArtifacts",
            ],
            path: "Packages/IntatisAgentKernel/Sources"
        ),
        .target(
            name: "IntatisSharedUI",
            // Providers is needed because ChatViewModel drives ProviderRegistry.
            dependencies: ["IntatisCore", "IntatisProtocol", "IntatisProviders", "IntatisConversation", "IntatisArtifacts"],
            path: "Packages/IntatisSharedUI/Sources"
        ),
        .executableTarget(
            name: "IntatisMac",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisConversation", "IntatisArtifacts", "IntatisSharedUI",
                "IntatisTools", "IntatisPermission", "IntatisAgentKernel",
            ],
            path: "Apps/IntatisMac/Sources"
        ),

        // MARK: Test targets (none depend on UI/app targets, so `swift test` is headless)
        .testTarget(
            name: "IntatisCoreTests",
            dependencies: ["IntatisCore"],
            path: "Packages/IntatisCore/Tests"
        ),
        .testTarget(
            name: "IntatisProtocolTests",
            dependencies: ["IntatisProtocol", "IntatisCore"],
            path: "Packages/IntatisProtocol/Tests"
        ),
        .testTarget(
            name: "IntatisProvidersTests",
            dependencies: ["IntatisProviders", "IntatisCore", "IntatisProtocol"],
            path: "Packages/IntatisProviders/Tests"
        ),
        .testTarget(
            name: "IntatisArtifactsTests",
            dependencies: ["IntatisArtifacts", "IntatisCore"],
            path: "Packages/IntatisArtifacts/Tests"
        ),
        .testTarget(
            name: "IntatisConversationTests",
            dependencies: ["IntatisConversation", "IntatisCore", "IntatisProtocol", "IntatisProviders"],
            path: "Packages/IntatisConversation/Tests"
        ),
        .testTarget(
            name: "IntatisToolsTests",
            dependencies: ["IntatisTools", "IntatisCore"],
            path: "Packages/IntatisTools/Tests"
        ),
        .testTarget(
            name: "IntatisPermissionTests",
            dependencies: ["IntatisPermission", "IntatisCore", "IntatisProtocol"],
            path: "Packages/IntatisPermission/Tests"
        ),
        .testTarget(
            name: "IntatisAgentKernelTests",
            dependencies: [
                "IntatisAgentKernel", "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisTools", "IntatisPermission", "IntatisConversation",
            ],
            path: "Packages/IntatisAgentKernel/Tests"
        ),
    ]
)
