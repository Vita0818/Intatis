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
        .macOS("26.0"),
        .iOS("26.0"),
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
        .library(name: "IntatisCowork", targets: ["IntatisCowork"]),
        .library(name: "IntatisMultimodal", targets: ["IntatisMultimodal"]),
        .library(name: "IntatisSharedUI", targets: ["IntatisSharedUI"]),
        // The CLI IS a SwiftPM executable (no Xcode needed): `swift run intatis chat`.
        .executable(name: "intatis", targets: ["IntatisCLI"]),
        // The GUI apps (IntatisMac, IntatisiOS) are Xcode App targets, not SPM
        // products — SwiftPM cannot build a .app bundle, and iOS apps cannot be
        // built from SPM at all. See project.yml (XcodeGen) + README.
    ],
    dependencies: [
        // Audited in-tree thin derivative of Microsoft SwiftStreamingMarkdown
        // v0.6.0. Provenance and local patches live beside the vendored source.
        .package(path: "Vendor/SwiftStreamingMarkdown"),
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
            name: "IntatisPTYLauncher",
            path: "Packages/IntatisPTYLauncher",
            publicHeadersPath: "include"
        ),
        .target(
            name: "IntatisTools",
            dependencies: ["IntatisCore", "IntatisProtocol", "IntatisPTYLauncher"],
            path: "Packages/IntatisTools/Sources"
        ),
        .target(
            name: "IntatisPermission",
            // Providers added in v0.3 for the model-backed reviewer (layer B).
            dependencies: ["IntatisCore", "IntatisProtocol", "IntatisProviders"],
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
        // v0.3 — Cowork: multi-agent orchestration over a mediated message bus.
        .target(
            name: "IntatisCowork",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisProviders", "IntatisTools",
                "IntatisPermission", "IntatisConversation", "IntatisAgentKernel",
            ],
            path: "Packages/IntatisCowork/Sources"
        ),
        // v0.4 — Multimodal: image/video generation + transcription → artifacts.
        .target(
            name: "IntatisMultimodal",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisArtifacts", "IntatisConversation",
            ],
            path: "Packages/IntatisMultimodal/Sources"
        ),
        .target(
            name: "IntatisSharedUI",
            // Providers is needed because ChatViewModel drives ProviderRegistry.
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisConversation", "IntatisArtifacts",
                .product(
                    name: "SwiftStreamingMarkdown",
                    package: "SwiftStreamingMarkdown",
                    condition: .when(platforms: [.macOS, .iOS])
                ),
            ],
            path: "Packages/IntatisSharedUI/Sources"
        ),
        // v0.6 — CLI: Swift-native `intatis` command (chat + code agent), talks to
        // any OpenAI-compatible endpoint via env vars.
        .executableTarget(
            name: "IntatisCLI",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisProviders", "IntatisConversation",
                "IntatisTools", "IntatisPermission", "IntatisAgentKernel", "IntatisCowork",
            ],
            path: "Apps/intatis-cli/Sources"
        ),
        // GUI app targets (IntatisMac macOS app, IntatisiOS iOS app) are defined in
        // the Xcode project generated from project.yml — they link these library
        // products. The iOS app intentionally links only the subset.

        // MARK: Test targets (none depend on app targets; SharedUI tests run headlessly on macOS)
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
            dependencies: ["IntatisPermission", "IntatisCore", "IntatisProtocol", "IntatisProviders"],
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
        .testTarget(
            name: "IntatisCoworkTests",
            dependencies: [
                "IntatisCowork", "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisTools", "IntatisPermission", "IntatisConversation", "IntatisAgentKernel",
            ],
            path: "Packages/IntatisCowork/Tests"
        ),
        .testTarget(
            name: "IntatisMultimodalTests",
            dependencies: [
                "IntatisMultimodal", "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisArtifacts", "IntatisConversation",
            ],
            path: "Packages/IntatisMultimodal/Tests"
        ),
        .testTarget(
            name: "IntatisSharedUITests",
            dependencies: ["IntatisSharedUI"],
            path: "Packages/IntatisSharedUI/Tests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
