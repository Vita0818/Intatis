import Foundation
import IntatisCore
import IntatisProviders
import XCTest
@testable import IntatisCLI

final class CLIProviderAdapterTests: XCTestCase {
    func testModernConfigRoutesDedicatedImageModelWithoutSelectingItForChat()
        throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "intatis-cli-image-model-\(UUID().uuidString)",
                isDirectory: true)
        defer {
            try? FileManager.default.removeItem(
                at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            "intatis.json")
        let object: [String: Any] = [
            "model": "chat/chat-model",
            "image_model": "images/gpt-image-1",
            "provider": [
                "chat": [
                    "options": [
                        "baseURL": "https://chat.example.invalid/v1",
                        "apiKey": "{env:INTATIS_TEST_CHAT_KEY}",
                    ],
                    "models": [
                        "chat-model": ["name": "Chat Model"],
                    ],
                ],
                "images": [
                    "options": [
                        "baseURL": "https://images.example.invalid/v1",
                        "apiKey": "{env:INTATIS_TEST_IMAGE_KEY}",
                    ],
                    // The role-specific image model is intentionally absent
                    // from the inference model menu.
                    "models": [String: Any](),
                ],
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)

        let config = try CLIConfig.load(
            configurationFileURL: file,
            environment: [:])
        let providerConfig = config.providerConfig()
        let imageRoute = try XCTUnwrap(
            config.providerRoutes.first { $0.id == "images" })

        XCTAssertEqual(config.model, "chat-model")
        XCTAssertEqual(
            providerConfig.models.imageGen,
            ModelRef(
                endpoint: CLIInferenceRouteIdentity.endpointID(route: imageRoute),
                model: ModelID(rawValue: "gpt-image-1")))
        XCTAssertFalse(
            imageRoute.models.contains { $0.id == "gpt-image-1" })
    }

    func testModernConfigWithoutImageModelHasNoHiddenFallback()
        throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "intatis-cli-no-image-model-\(UUID().uuidString)",
                isDirectory: true)
        defer {
            try? FileManager.default.removeItem(
                at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            "intatis.json")
        let object: [String: Any] = [
            "model": "test/chat-model",
            "provider": [
                "test": [
                    "options": [
                        "baseURL": "https://example.invalid/v1",
                        "apiKey": "{env:INTATIS_TEST_API_KEY}",
                    ],
                    "models": [
                        "chat-model": ["name": "Chat Model"],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)

        let config = try CLIConfig.load(
            configurationFileURL: file,
            environment: [:])

        XCTAssertNil(config.providerConfig().models.imageGen)
    }

    func testModernConfigPreservesProviderAndModelNPMAdapters()
        throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "intatis-cli-provider-adapter-\(UUID().uuidString)",
                isDirectory: true)
        defer {
            try? FileManager.default.removeItem(
                at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            "intatis.json")
        let object: [String: Any] = [
            "model": "gateway/compatible/model",
            "provider": [
                "gateway": [
                    "npm":
                        "@ai-sdk/openai-compatible",
                    "options": [
                        "baseURL":
                            "https://example.invalid/v1",
                        "apiKey":
                            "{env:INTATIS_TEST_API_KEY}",
                    ],
                    "models": [
                        "compatible/model": [
                            "name":
                                "Compatible",
                            "options": [
                                "reasoningEffort":
                                    "low",
                                "provider": [
                                    "only": [
                                        "base",
                                    ],
                                    "require_parameters":
                                        false,
                                ],
                            ],
                            "variants": [
                                "strict": [
                                    "reasoningEffort":
                                        "high",
                                    "provider": [
                                        "only": [
                                            "deepseek",
                                        ],
                                        "allow_fallbacks":
                                            false,
                                        "require_parameters":
                                            true,
                                    ],
                                ],
                            ],
                        ],
                        "openrouter/model": [
                            "name":
                                "OpenRouter",
                            "provider": [
                                "npm":
                                    "@openrouter/ai-sdk-provider",
                            ],
                            "options": [
                                "reasoning": [
                                    "effort": "high",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)

        let config = try CLIConfig.load(
            configurationFileURL: file,
            environment: [
                "INTATIS_REASONING":
                    "high",
            ])
        let route = try XCTUnwrap(
            config.providerRoutes.first)
        XCTAssertEqual(
            route.requestAdapter,
            .openAICompatible)
        XCTAssertNil(
            route.models.first {
                $0.id == "compatible/model"
            }?.requestAdapterOverride)
        XCTAssertEqual(
            route.models.first {
                $0.id == "openrouter/model"
            }?.requestAdapterOverride,
            .openRouter)

        let endpoint = try XCTUnwrap(
            config.providerConfig().endpoints.first)
        XCTAssertEqual(
            endpoint.requestAdapter,
            .openAICompatible)
        XCTAssertEqual(
            endpoint.requestAdapter(
                for: .init(
                    rawValue: "openrouter/model")),
            .openRouter)
        XCTAssertEqual(
            endpoint.requestOptions(
                for: .init(
                    rawValue: "compatible/model"))[
                    "provider"],
            .object([
                "only": .array([
                    .string("deepseek"),
                ]),
                "require_parameters":
                    .bool(true),
                "allow_fallbacks":
                    .bool(false),
            ]))
    }

    func testMissingProviderNPMUsesOpenCodeCompatibleDefault()
        throws {
        XCTAssertEqual(
            ProviderRequestAdapter
                .configuredProvider(nil),
            .openAICompatible)
        XCTAssertEqual(
            ProviderRequestAdapter
                .configuredProvider("").rawValue,
            "")
        XCTAssertEqual(
            ProviderRequestAdapter
                .configuredModelOverride("  ")?
                .rawValue,
            "  ")
    }
}
