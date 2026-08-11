import Foundation
import IntatisCore
import IntatisKnowledge
import IntatisProtocol
import IntatisProviders
import IntatisTools
import XCTest
@testable import IntatisCLI

final class CLIProviderAdapterTests: XCTestCase {
    func testOpenRouterKnowledgeRoleModelsStayOutOfInferenceProfiles()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-cli-openrouter-knowledge-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let file = directory.appendingPathComponent("intatis.json")
        let object: [String: Any] = [
            "model": "OpenRouter/chat-model",
            "embedding_model": "OpenRouter/google/gemini-embedding-2",
            "reranker_model": "OpenRouter/cohere/rerank-4-pro",
            "provider": [
                "OpenRouter": [
                    "npm": "@ai-sdk/openai-compatible",
                    "options": [
                        "baseURL": "https://openrouter.ai/api/v1",
                        "apiKey": "{env:OPENROUTER_API_KEY}",
                    ],
                    "models": [
                        "chat-model": ["name": "Chat"],
                        "google/gemini-embedding-2": [
                            "name": "Gemini Embedding 2",
                            "provider": [
                                "npm": "@openrouter/ai-sdk-provider",
                            ],
                            "options": ["dimensions": 1_536],
                        ],
                        "cohere/rerank-4-pro": [
                            "name": "Cohere Rerank 4 Pro",
                            "provider": [
                                "npm": "@openrouter/ai-sdk-provider",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)

        let config = try CLIConfig.load(
            configurationFileURL: file,
            environment: [:])
        XCTAssertNil(cliKnowledgeToolsConfigurationNotice(config: config))
        let endpoint = try XCTUnwrap(config.providerConfig().endpoints.first)
        XCTAssertEqual(
            endpoint.requestAdapter(for: ModelID(
                rawValue: "google/gemini-embedding-2")),
            .openRouter)
        XCTAssertEqual(
            endpoint.requestAdapter(for: ModelID(
                rawValue: "cohere/rerank-4-pro")),
            .openRouter)
        let profiles = try await CLIInferenceProfiles.load(
            config: config,
            fileURL: directory.appendingPathComponent("catalog.json"))
        XCTAssertEqual(profiles.options.map(\.modelID.rawValue), ["chat-model"])
    }

    func testKnowledgeRoleOnlyRoutesComposeStrictToolsWithoutResolvingSecrets()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-cli-knowledge-models-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let file = directory.appendingPathComponent("intatis.json")
        let object: [String: Any] = [
            "model": "chat/chat-model",
            "embedding_model": "embedding/BAAI/bge-m3",
            "reranker_model": "reranker/BAAI/bge-reranker-v2-m3",
            "provider": [
                "chat": [
                    "options": [
                        "baseURL": "https://chat.example.invalid/v1",
                        "apiKey": "{env:INTATIS_TEST_CHAT_KEY}",
                    ],
                    "models": ["chat-model": ["name": "Chat"]],
                ],
                "embedding": [
                    "npm": "intatis:siliconflow-v1",
                    "options": [
                        "baseURL": "https://embedding.example.invalid/v1",
                        "apiKey": "{env:INTATIS_TEST_EMBEDDING_KEY}",
                    ],
                    "models": [String: Any](),
                ],
                "reranker": [
                    "npm": "intatis:cohere-v2",
                    "options": [
                        "baseURL": "https://reranker.example.invalid/v2",
                        "apiKey": "{env:INTATIS_TEST_RERANKER_KEY}",
                    ],
                    "models": [String: Any](),
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)

        let config = try CLIConfig.load(
            configurationFileURL: file,
            environment: [:])
        XCTAssertNil(cliKnowledgeToolsConfigurationNotice(config: config))
        let providerConfig = config.providerConfig()
        XCTAssertNotNil(providerConfig.models.embedding)
        XCTAssertNotNil(providerConfig.models.reranker)
        XCTAssertEqual(config.providerRoutes.count, 3)

        let registry = ProviderRegistry(
            config: providerConfig,
            resolver: CLIExactSecretResolver(config: config))
        let augmenter = try XCTUnwrap(makeCLIKnowledgeToolAugmenter(
            config: config,
            registry: registry))
        let capability = CapabilityLease(
            tools: augmenter.additionalCapabilities)
        let workspace = WorkspaceLease(
            rootPath: directory.path,
            access: .readWrite,
            deniedPatterns: [])
        let lease = try await augmenter.augment(
            HostToolRegistryAugmentationInput(
                sessionID: SessionID(rawValue: "cli-knowledge-test"),
                agentID: AgentID(rawValue: "cli"),
                taskID: nil,
                capabilityLease: capability,
                workspaceLease: workspace,
                baseRegistry: ToolRegistry(
                    registrations: [],
                    registryVersion: "cli-base/1")))
        XCTAssertNotNil(lease.registry.registration(named: "build_knowledge"))
        XCTAssertNotNil(lease.registry.registration(named: "search_knowledge"))
        let drained = await lease.close()
        XCTAssertTrue(drained)
    }

    func testKnowledgeRolesRejectImplicitSelectedProviderFallback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-cli-invalid-knowledge-route-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("intatis.json")
        let object: [String: Any] = [
            "model": "chat/chat-model",
            "embedding_model": "BAAI/bge-m3",
            "reranker_model": "chat/reranker-model",
            "provider": [
                "chat": [
                    "options": [
                        "baseURL": "https://chat.example.invalid/v1",
                    ],
                    "models": ["chat-model": ["name": "Chat"]],
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)

        XCTAssertThrowsError(try CLIConfig.load(
            configurationFileURL: file,
            environment: [:])) { error in
            XCTAssertTrue(error.localizedDescription.contains(
                "embedding_model must use the canonical provider/model shape"))
        }
    }

    func testUnsupportedRerankerAdapterIsNotAdvertisedAsReady() throws {
        let baseURL = try XCTUnwrap(URL(
            string: "https://knowledge.example.invalid/v1"))
        let route = CLIProviderRoute(
            id: "knowledge",
            displayName: "Knowledge",
            baseURL: baseURL,
            chatEndpoint: nil,
            wire: .openai,
            requestAdapter: .openAICompatible,
            credentialRef: .environment("KNOWLEDGE_TEST_KEY"),
            inlineSecret: nil,
            models: [
                CLIProviderModel(
                    id: "chat-model",
                    displayName: "Chat"),
            ])
        let config = CLIConfig(
            baseURL: baseURL,
            apiKey: "unused-test-value",
            model: "chat-model",
            wire: .openai,
            reasoningEffort: nil,
            mode: .code,
            includeUsage: false,
            maxSteps: 1,
            providerRoutes: [route],
            selectedProviderID: route.id,
            embeddingModel: CLIProviderModelSelection(
                providerID: route.id,
                modelID: "BAAI/bge-m3"),
            rerankerModel: CLIProviderModelSelection(
                providerID: route.id,
                modelID: "BAAI/bge-reranker-v2-m3"))
        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config))

        let notice = try XCTUnwrap(
            cliKnowledgeToolsConfigurationNotice(config: config))
        XCTAssertTrue(notice.contains("explicit intatis:siliconflow-v1"))
        XCTAssertNil(makeCLIKnowledgeToolAugmenter(
            config: config,
            registry: registry))
    }

    func testCLIExternalKnowledgeCreationTouchesOnlyExactLeaf() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-cli-exact-knowledge-root-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])

        let exact = parent.appendingPathComponent(
            "store",
            isDirectory: true)
        let created = try prepareCLIKnowledgeDirectory(
            exact,
            operation: .build)
        XCTAssertEqual(
            created.path,
            exact.resolvingSymlinksInPath().standardizedFileURL.path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: exact.path,
            isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let missingParent = parent.appendingPathComponent(
            "missing",
            isDirectory: true)
        let nested = missingParent.appendingPathComponent(
            "store",
            isDirectory: true)
        XCTAssertThrowsError(try prepareCLIKnowledgeDirectory(
            nested,
            operation: .build))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: missingParent.path))
    }

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
        XCTAssertNil(config.providerConfig().models.embedding)
        XCTAssertNil(config.providerConfig().models.reranker)
        XCTAssertTrue(try XCTUnwrap(
            cliKnowledgeToolsConfigurationNotice(config: config))
            .contains("embedding_model and reranker_model"))
        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config))
        XCTAssertNil(makeCLIKnowledgeToolAugmenter(
            config: config,
            registry: registry))
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
