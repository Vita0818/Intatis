import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
@testable import IntatisCodexRuntime

private struct FixedSecretResolver: SecretResolver {
    let value: String

    func secret(for ref: KeychainRef) async throws -> String {
        value
    }
}

private struct FailingSecretResolver: SecretResolver {
    func secret(for ref: KeychainRef) async throws -> String {
        throw IntatisError.config("secret resolver was called")
    }
}

final class CodexRuntimeTests: XCTestCase {
    func testResponsesRouteUsesExplicitResponsesBaseAndRedactsCredential()
        async throws
    {
        let endpoint = ProviderEndpoint(
            id: "example",
            baseURL: URL(string: "https://unused.invalid/v1")!,
            responsesEndpoint: URL(
                string: "https://api.example.test/v2/responses?api-version=7")!,
            apiKeyRef: .environment("EXAMPLE_API_KEY"),
            wire: .openai,
            modelRequestOptions: [
                "example-model": [
                    "reasoningEffort": .string("high"),
                ],
            ])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: endpoint.id,
                        model: ModelID(rawValue: "example-model")))),
            resolver: FixedSecretResolver(value: "Bearer test-secret"))

        let route = try await registry.responsesRuntimeRoute()

        XCTAssertEqual(route.endpointID, "example")
        XCTAssertEqual(route.model.rawValue, "example-model")
        XCTAssertEqual(
            route.baseURL.absoluteString,
            "https://api.example.test/v2/")
        XCTAssertEqual(route.queryParameters, ["api-version": "7"])
        XCTAssertEqual(route.bearerToken, "test-secret")
        XCTAssertEqual(route.reasoningEffort, "high")
        XCTAssertFalse(String(describing: route).contains("test-secret"))
    }

    func testOpenRouterProviderObjectPassesThroughWithoutFieldEnumeration()
        async throws
    {
        let providerOptions: [String: JSONValue] = [
            "require_parameters": .bool(true),
            "allow_fallbacks": .bool(false),
            "order": .array([
                .string("openai"),
                .string("azure"),
            ]),
            "future_routing": .object([
                "mode": .string("provider-owned"),
            ]),
        ]
        let endpoint = ProviderEndpoint(
            id: "openrouter",
            baseURL: URL(string: "https://openrouter.example.test/api/v1")!,
            apiKeyRef: .environment("OPENROUTER_API_KEY"),
            wire: .openai,
            requestAdapter: .openRouter,
            modelRequestOptions: [
                "stealth/ox-alpha": [
                    "reasoningEffort": .string("max"),
                    "provider": .object(providerOptions),
                ],
            ])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(chat: ModelRef(
                    endpoint: endpoint.id,
                    model: ModelID(rawValue: "stealth/ox-alpha")))),
            resolver: FixedSecretResolver(value: "test-secret"))

        let route = try await registry.responsesRuntimeRoute()

        XCTAssertEqual(route.reasoningEffort, "max")
        XCTAssertEqual(route.providerOptions, providerOptions)

        let connectionID = InferenceConnectionID(rawValue: "openrouter")
        let catalog = try InferenceCatalogReconciler.reconcile(draft:
            InferenceCatalogDraft(
                connections: [InferenceConnectionDraft(
                    inferenceConnectionID: connectionID,
                    wire: .openai,
                    requestAdapter: .openRouter,
                    baseURL: endpoint.baseURL,
                    credentialRef: endpoint.apiKeyRef)],
                profiles: [InferenceProfileDraft(
                    inferenceProfileID: InferenceProfileID(
                        rawValue: "stealth-ox-alpha"),
                    inferenceConnectionID: connectionID,
                    modelID: ModelID(rawValue: "stealth/ox-alpha"),
                    modelBaseRequestOptions:
                        endpoint.requestOptions(for: ModelID(
                            rawValue: "stealth/ox-alpha")))]))
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let profileRef = try XCTUnwrap(catalog.currentProfileRefs.first)
        let binding = try snapshot.resolve(profileRef).binding
        let exactRegistry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(chat: ModelRef(
                    endpoint: endpoint.id,
                    model: ModelID(rawValue: "stealth/ox-alpha")))),
            resolver: FixedSecretResolver(value: "test-secret"),
            inferenceCatalogSnapshot: snapshot)

        let exactRoute = try await exactRegistry.responsesRuntimeRoute(
            for: binding)

        XCTAssertEqual(exactRoute.reasoningEffort, "max")
        XCTAssertEqual(exactRoute.providerOptions, providerOptions)
    }

    func testUnsupportedModelOptionsFailBeforeCredentialResolution()
        async throws
    {
        let endpoint = ProviderEndpoint(
            id: "example",
            baseURL: URL(string: "https://api.example.test/v1")!,
            apiKeyRef: .environment("EXAMPLE_API_KEY"),
            wire: .openai,
            modelRequestOptions: [
                "example-model": [
                    "temperature": .number(0.2),
                ],
            ])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(chat: ModelRef(
                    endpoint: endpoint.id,
                    model: ModelID(rawValue: "example-model")))),
            resolver: FailingSecretResolver())

        do {
            _ = try await registry.responsesRuntimeRoute()
            XCTFail("Unsupported options must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(
                "cannot project"))
            XCTAssertFalse(error.localizedDescription.contains(
                "secret resolver"))
        }
    }

    func testProviderPassthroughRejectsSecretMaterialBeforeCredentialResolution()
        async throws
    {
        let endpoint = ProviderEndpoint(
            id: "openrouter",
            baseURL: URL(string: "https://openrouter.example.test/api/v1")!,
            apiKeyRef: .environment("OPENROUTER_API_KEY"),
            wire: .openai,
            requestAdapter: .openRouter,
            modelRequestOptions: [
                "model": [
                    "provider": .object([
                        "authorization": .string(
                            "Bearer must-not-leak"),
                    ]),
                ],
            ])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(chat: ModelRef(
                    endpoint: endpoint.id,
                    model: ModelID(rawValue: "model")))),
            resolver: FailingSecretResolver())

        do {
            _ = try await registry.responsesRuntimeRoute()
            XCTFail("Secret-bearing provider options must fail closed")
        } catch {
            XCTAssertEqual(
                error as? InferenceCatalogError,
                .secretLikeRequestOptions)
            XCTAssertFalse(error.localizedDescription.contains(
                "must-not-leak"))
            XCTAssertFalse(error.localizedDescription.contains(
                "secret resolver"))
        }
    }

    func testResponsesRouteRejectsNonstandardCustomPath() async throws {
        let endpoint = ProviderEndpoint(
            id: "example",
            baseURL: URL(string: "https://api.example.test/v1")!,
            responsesEndpoint: URL(
                string: "https://api.example.test/custom-generation")!,
            apiKeyRef: .environment("EXAMPLE_API_KEY"),
            wire: .openai)
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: endpoint.id,
                        model: ModelID(rawValue: "example-model")))),
            resolver: FixedSecretResolver(value: "secret"))

        do {
            _ = try await registry.responsesRuntimeRoute()
            XCTFail("Expected an exact Responses URL validation failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("/responses"))
        }
    }

    func testThreadConfigurationKeepsProviderTokenOutOfToolEnvironment()
        async throws
    {
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "config-test"),
                mode: .code,
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                runtimeRootURL: URL(fileURLWithPath: "/tmp/runtime"),
                route: ResponsesRuntimeRoute(
                    endpointID: "example",
                    model: ModelID(rawValue: "example-model"),
                    baseURL: URL(string: "https://api.example.test/v1")!,
                    bearerToken: "must-not-enter-json",
                    providerOptions: [
                        "require_parameters": .bool(true),
                        "allow_fallbacks": .bool(false),
                        "order": .array([.string("openai")]),
                        "future_routing": .object([
                            "mode": .string("provider-owned"),
                        ]),
                    ])))

        let params = await session.threadLifecycleParameters()
        let data = try JSONEncoder().encode(JSONValue.object(params))
        let encoded = try XCTUnwrap(
            String(data: data, encoding: .utf8))

        XCTAssertTrue(encoded.contains("shell_environment_policy"))
        XCTAssertTrue(encoded.contains("\"shell_snapshot\":false"))
        XCTAssertTrue(encoded.contains("\"inherit\":\"core\""))
        XCTAssertTrue(encoded.contains(
            "\"ignore_default_excludes\":false"))
        XCTAssertTrue(encoded.contains("INTATIS_*"))
        XCTAssertTrue(encoded.contains("CODEX_HOME"))
        XCTAssertTrue(encoded.contains("intatis_responses_provider"))
        XCTAssertTrue(encoded.contains("require_parameters"))
        XCTAssertTrue(encoded.contains("allow_fallbacks"))
        XCTAssertTrue(encoded.contains("future_routing"))
        XCTAssertFalse(encoded.contains("x-intatis-openrouter"))
        XCTAssertFalse(encoded.contains("\"http_headers\""))
        XCTAssertFalse(encoded.contains("must-not-enter-json"))
    }

    func testRuntimeRecordRoundTripsOwnerOnly() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(rootURL: temporary)

        try storage.prepare()
        try storage.writeModelCatalog(
            modelID: "selected-model",
            baseInstructions: "test instructions")
        try storage.writeRecord(
            threadID: "thread-test",
            mode: .cowork,
            workspacePath: "/tmp/workspace")

        XCTAssertEqual(
            try storage.readRecord(),
            CodexRuntimeStorage.Record(
                schemaVersion: 2,
                runtimeVersion: CodexRuntimeExecutable.pinnedVersion,
                threadID: "thread-test",
                mode: .cowork,
                workspacePath: "/tmp/workspace",
                materialized: true))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: storage.recordURL.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
        let catalogData = try XCTUnwrap(
            DurableOwnerOnlyFile.read(from: storage.modelCatalogURL))
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalogData)
                as? [String: Any])
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["slug"] as? String, "selected-model")
        XCTAssertEqual(
            models.first?["auto_review_model_override"] as? String,
            "selected-model")
        XCTAssertFalse(String(data: catalogData, encoding: .utf8)?
            .contains("test-secret") == true)
    }

    func testUnsafeExistingRuntimeDirectoryIsRejectedWithoutChmodRepair()
        throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o755)])
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: temporary.path)

        XCTAssertThrowsError(
            try CodexRuntimeStorage(rootURL: temporary).prepare()
        ) { error in
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .unsafeRuntimeStorage)
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: temporary.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o755)
    }

    func testRuntimeProcessLeaseIsSingleWriterAndRecoverable() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(rootURL: temporary)
        try storage.prepare()

        let first = try CodexRuntimeProcessLease(
            url: storage.processLockURL)
        XCTAssertThrowsError(
            try CodexRuntimeProcessLease(url: storage.processLockURL)
        ) { error in
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .runtimeAlreadyActive)
        }
        first.release()
        let replacement = try CodexRuntimeProcessLease(
            url: storage.processLockURL)
        replacement.release()
    }

    func testPersistedShellSnapshotDirectoryFailsClosedWithoutDeletion()
        throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(rootURL: temporary)
        try storage.prepare()
        let snapshots = storage.homeURL.appendingPathComponent(
            "shell_snapshots",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: snapshots,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])

        XCTAssertThrowsError(
            try storage.rejectPersistedShellSnapshots()
        ) { error in
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .shellSnapshotStoragePresent)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: snapshots.path))
    }

    func testModelCatalogRejectsControlCharacters() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(rootURL: temporary)
        try storage.prepare()

        XCTAssertThrowsError(try storage.writeModelCatalog(
            modelID: "unsafe\nmodel",
            baseInstructions: "test")) { error in
                XCTAssertEqual(
                    error as? CodexRuntimeError,
                    .malformedProtocol(
                        "the selected Responses model id is invalid"))
            }
    }

    func testVersionVerifierRequiresPinnedRuntime() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        try Data("#!/bin/sh\necho 'codex-cli 9.9.9'\n".utf8)
            .write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        XCTAssertThrowsError(
            try CodexRuntimeExecutable.verifiedVersion(at: executable)
        ) { error in
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .incompatibleRuntime(
                    expected: "0.145.0-intatis.2",
                    actual: "9.9.9"))
        }
    }

    func testVersionVerifierTimeoutForceStopsTermIgnoringExecutable()
        throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        try Data("#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n".utf8)
            .write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let started = Date()
        XCTAssertThrowsError(try CodexRuntimeExecutable.verifiedVersion(
            at: executable,
            expectedVersion: "0.145.0-intatis.2",
            timeoutSeconds: 0.1)) { error in
                XCTAssertEqual(
                    error as? CodexRuntimeError,
                    .requestTimedOut("codex --version"))
            }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testExplicitExecutableOverrideDoesNotFallThroughToInstalledRuntime()
        throws
    {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(
            try CodexRuntimeExecutable.locate(
                override: missing,
                environment: ProcessInfo.processInfo.environment)
        ) { error in
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .executableUnavailable)
        }
    }

    func testApprovalRequestIDRejectsUnsafeNumericValues() {
        XCTAssertNil(CodexRuntimeRequestID(
            wireValue: .number(Double.greatestFiniteMagnitude)))
        XCTAssertNil(CodexRuntimeRequestID(
            wireValue: .number(1.5)))
        XCTAssertEqual(
            CodexRuntimeRequestID(wireValue: .number(42))?.description,
            "42")
    }

    func testInstalledPinnedAppServerStartsIsolatedThread() async throws {
        let executable: URL
        do {
            executable = try CodexRuntimeExecutable.locate()
            _ = try CodexRuntimeExecutable.verifiedVersion(at: executable)
        } catch {
            throw XCTSkip(
                "Pinned Codex Runtime is not installed for the integration handshake")
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "code-test"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "offline-test",
                    model: ModelID(rawValue: "offline-test-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "offline-placeholder"),
                approvalReviewer: .automatic,
                executableOverride: executable))

        let identity = try await session.start()
        XCTAssertFalse(identity.threadID.isEmpty)
        XCTAssertEqual(identity.runtimeVersion, "0.145.0-intatis.2")
        XCTAssertEqual(identity.mode, .code)
        XCTAssertNil(try DurableOwnerOnlyFile.read(
            from: runtimeRoot.appendingPathComponent("runtime.json")))
        await session.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            runtimeRoot
                .appendingPathComponent("codex-home", isDirectory: true)
                .appendingPathComponent("shell_snapshots", isDirectory: true)
                .path))
        try assertBytesAreAbsent(
            Data("offline-placeholder".utf8),
            below: runtimeRoot)
    }

    func testAppServerTurnStreamsOfficialLifecycle() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.2'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-fake","turns":[],"createdAt":0,"updatedAt":0,"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"turn":{"id":"turn-fake","items":[],"status":"inProgress"}}}'
            echo '{"method":"turn/started","params":{"threadId":"thread-fake","turn":{"id":"turn-fake","items":[],"status":"inProgress"}}}'
            echo '{"method":"item/agentMessage/delta","params":{"threadId":"thread-fake","turnId":"turn-fake","itemId":"message-fake","delta":"hello "}}'
            echo '{"method":"item/agentMessage/delta","params":{"threadId":"thread-fake","turnId":"turn-fake","itemId":"message-fake","delta":"world"}}'
            echo '{"method":"item/completed","params":{"threadId":"thread-fake","turnId":"turn-fake","completedAtMs":1,"item":{"id":"message-fake","type":"agentMessage","text":"hello world","phase":"final_answer"}}}'
            echo '{"method":"turn/completed","params":{"threadId":"thread-fake","turn":{"id":"turn-fake","items":[],"status":"completed"}}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "code-fake"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable))
        let stream = await session.events()
        let eventTask = Task { () -> [CodexRuntimeEvent] in
            var received: [CodexRuntimeEvent] = []
            for await event in stream {
                received.append(event)
                if case .turnCompleted = event { break }
            }
            return received
        }

        _ = try await session.start()
        let result = try await session.runTurn(text: "test")
        let received = await eventTask.value
        await session.shutdown()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.turnID, "turn-fake")
        let recordData = try XCTUnwrap(DurableOwnerOnlyFile.read(
            from: temporary
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("runtime.json")))
        XCTAssertEqual(
            try JSONDecoder().decode(
                CodexRuntimeStorage.Record.self,
                from: recordData).schemaVersion,
            2)
        XCTAssertTrue(received.contains(.assistantDelta(
            itemID: "message-fake",
            text: "hello ")))
        XCTAssertTrue(received.contains(.assistantCompleted(
            itemID: "message-fake",
            text: "hello world")))
        XCTAssertTrue(received.contains(.turnCompleted(result)))
    }

    func testShutdownWaitsForProcessExitBeforeReleasingSessionLease()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let retirementMarker = URL(
            fileURLWithPath: executable.path + ".retired")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.2'
          exit 0
        fi
        trap '' TERM
        trap 'sleep 0.35; : > "$0.retired"' EXIT
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-drain"}}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "shutdown-drain-test"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable))

        _ = try await session.start()
        let started = Date()
        await session.shutdown()

        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(started),
            0.25)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: retirementMarker.path))
        let storage = CodexRuntimeStorage(rootURL: runtimeRoot)
        let replacement = try CodexRuntimeProcessLease(
            url: storage.processLockURL)
        replacement.release()
    }

    func testLegacySessionWithoutThreadMappingFailsInsteadOfStartingEmptyThread()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.2'
          exit 0
        fi
        if IFS= read -r line; then
          echo '{"id":1,"result":{"userAgent":"fake"}}'
        fi
        while IFS= read -r line; do :; done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "legacy-test"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                allowsThreadCreation: false))

        do {
            _ = try await session.start()
            XCTFail("Legacy history must not acquire an empty Codex thread")
        } catch {
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .threadMigrationRequired)
        }
        await session.shutdown()
    }

    func testServerInitiatedCommandApprovalRoundTripsDecision()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.2'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-approval"}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"turn":{"id":"turn-approval","items":[],"status":"inProgress"}}}'
            echo '{"method":"item/commandExecution/requestApproval","id":99,"params":{"threadId":"thread-approval","turnId":"turn-approval","itemId":"command-approval","reason":"run the requested check","startedAtMs":1,"command":"true","cwd":"/tmp","commandActions":[]}}'
          elif [ "$count" = "4" ]; then
            case "$line" in
              *'"decision":"accept"'*)
                echo '{"method":"serverRequest/resolved","params":{"threadId":"thread-approval","requestId":99}}'
                echo '{"method":"turn/completed","params":{"threadId":"thread-approval","turn":{"id":"turn-approval","items":[],"status":"completed"}}}'
                ;;
              *) exit 2 ;;
            esac
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "approval-test"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable))
        let stream = await session.events()
        let approvalTask = Task { () throws
            -> CodexRuntimeApprovalRequest in
            for await event in stream {
                if case .approvalRequested(let request) = event {
                    try await session.resolveApproval(
                        requestID: request.requestID,
                        decision: .accept)
                    return request
                }
            }
            throw CodexRuntimeError.requestNotPending
        }

        _ = try await session.start()
        let result = try await session.runTurn(text: "check")
        let approval = try await approvalTask.value
        await session.shutdown()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(approval.kind, .command)
        XCTAssertEqual(approval.itemID, "command-approval")
    }

    private func assertBytesAreAbsent(
        _ needle: Data,
        below root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []) else { return }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            XCTAssertNil(
                data.range(of: needle),
                "Sensitive bytes persisted in \(url.lastPathComponent)",
                file: file,
                line: line)
        }
    }
}
