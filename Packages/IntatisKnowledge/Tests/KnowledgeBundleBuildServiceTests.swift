import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisTools
@testable import IntatisKnowledge

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class KnowledgeBundleBuildServiceTests: XCTestCase {
    func testPublishesCompleteSnapshotAndReusesUnchangedEmbeddings() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let provider = CountingBuildEmbeddingProvider()
        let service = try KnowledgeBundleBuildService(
            embeddingProvider: provider,
            now: { Date(timeIntervalSince1970: 1_786_233_600) })

        let first = try await service.buildAndPublish(fixture.request())
        XCTAssertEqual(first.storeRevision, 1)
        XCTAssertEqual(first.vectorCount, first.chunkCount)
        XCTAssertEqual(first.embeddedVectorCount, first.chunkCount)
        XCTAssertEqual(first.reusedVectorCount, 0)
        XCTAssertGreaterThan(first.embeddingRequestTextCount, 0)
        let firstRequestCount = await provider.requestTextCount()
        XCTAssertEqual(firstRequestCount, first.embeddingRequestTextCount)

        let store = try KnowledgeSnapshotStore(
            root: fixture.store,
            workspaceLease: fixture.workspaceLease)
        let oldReader = try store.acquireCurrentReaderLease()
        defer { oldReader.release() }
        XCTAssertEqual(oldReader.pointer.currentSnapshot, first.snapshotID)

        let second = try await service.buildAndPublish(
            fixture.request(expectedStoreID: first.storeID))
        XCTAssertEqual(second.storeID, first.storeID)
        XCTAssertEqual(second.storeRevision, 2)
        XCTAssertNotEqual(second.snapshotID, first.snapshotID)
        XCTAssertEqual(second.reusedVectorCount, second.chunkCount)
        XCTAssertEqual(second.embeddedVectorCount, 0)
        XCTAssertEqual(second.embeddingRequestTextCount, 0)
        let secondRequestCount = await provider.requestTextCount()
        XCTAssertEqual(secondRequestCount, firstRequestCount)

        let current = try store.loadCurrentPointer()
        XCTAssertEqual(current.currentSnapshot, second.snapshotID)
        XCTAssertEqual(current.currentSnapshotRevision, second.snapshotRevision)
        XCTAssertNoThrow(try oldReader.verifyStable())
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldReader.snapshotRoot.path))

        let secondRoot = fixture.store
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(second.snapshotID, isDirectory: true)
        let validated = try KnowledgeValidator().validateSnapshot(
            at: secondRoot,
            mode: .mount,
            policy: KnowledgeValidationPolicy(
                evaluationDate: "2026-08-09T00:00:00Z",
                trustedVerificationActors: ["human:test"]),
            workspaceLease: fixture.workspaceLease)
        XCTAssertEqual(validated.profile.bundle.revision, second.bundleRevision)
        XCTAssertEqual(validated.denseFile.vectors.count, second.vectorCount)
        XCTAssertEqual(validated.lexicalFile?.documents.count, second.chunkCount)
    }

    func testRejectsAdmissionWithoutDeterministicPermissionSnapshot() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let provider = CountingBuildEmbeddingProvider()
        let service = try KnowledgeBundleBuildService(embeddingProvider: provider)
        let invalid = fixture.request(
            authorization: fixture.authorization(deterministicGate: nil))

        do {
            _ = try await service.buildAndPublish(invalid)
            XCTFail("unreviewed build admission unexpectedly succeeded")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .accessDenied)
        }
        let requestCount = await provider.requestTextCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.store
                .appendingPathComponent(".intatis-rag-store.json").path))
    }

    func testBudgetFailureAbortsStagingWithoutActivatingPartialSnapshot() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let provider = CountingBuildEmbeddingProvider()
        let service = try KnowledgeBundleBuildService(embeddingProvider: provider)
        var budget = KnowledgeBuildBudget()
        budget.maximumDraftBytes = 1

        do {
            _ = try await service.buildAndPublish(fixture.request(), budget: budget)
            XCTFail("over-budget build unexpectedly succeeded")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .searchBudgetExceeded)
        }
        let requestCount = await provider.requestTextCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.store
                .appendingPathComponent(".intatis-rag-store.json").path))
        let staging = fixture.store
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(".staging", isDirectory: true)
        if FileManager.default.fileExists(atPath: staging.path) {
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: staging.path),
                [])
        }
    }

    func testEmbeddingCancellationIsTypedAndDoesNotPublish() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanup() }
        let service = try KnowledgeBundleBuildService(
            embeddingProvider: CancellingBuildEmbeddingProvider())
        do {
            _ = try await service.buildAndPublish(fixture.request())
            XCTFail("cancelled embedding unexpectedly published")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .searchCancelled)
            XCTAssertFalse(error.failure.retryable)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.store
                .appendingPathComponent(".intatis-rag-store.json").path))
    }
}

private actor CountingBuildEmbeddingProvider: KnowledgeEmbeddingProvider {
    nonisolated let modelIdentity = testBuildEmbeddingIdentity
    private var embeddedTextCount = 0

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        embeddedTextCount += texts.count
        return texts.map { text in
            let discriminator = Float((Data(text.utf8).count % 7) + 1)
            return [discriminator, 2, 3, 4]
        }
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        [1, 2, 3, 4]
    }

    func requestTextCount() -> Int { embeddedTextCount }
}

private struct CancellingBuildEmbeddingProvider: KnowledgeEmbeddingProvider {
    let modelIdentity = testBuildEmbeddingIdentity

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        throw CancellationError()
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        throw CancellationError()
    }
}

private let testBuildEmbeddingIdentity = KnowledgeEmbeddingModelIdentity(
    identity: "org.vita.intatis.tests.embedding",
    revision: "sha256:" + String(repeating: "1", count: 64),
    tokenizerRevision: "sha256:" + String(repeating: "2", count: 64),
    runtimeBindingKind: .local,
    runtimeBindingDigest: KnowledgeDigest.sha256("test-build-embedding-runtime/1"),
    dimensions: 4,
    pooling: "test",
    maxInputTokens: 512)

private final class BuildFixture {
    let root: URL
    let draft: URL
    let store: URL
    let workspaceLease: WorkspaceLease

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "intatis-knowledge-build-tests-\(UUID().uuidString)",
            isDirectory: true)
        draft = root.appendingPathComponent("draft", isDirectory: true)
        store = root.appendingPathComponent("store", isDirectory: true)
        try Self.createDirectory(root)
        try Self.createDirectory(draft)
        try Self.createDirectory(store)
        try Self.createDirectory(draft.appendingPathComponent("concepts", isDirectory: true))
        try Self.createDirectory(draft.appendingPathComponent("references", isDirectory: true))
        try Self.write(
            """
            ---
            type: Index
            okf_version: "0.2"
            ---

            # Test knowledge
            """,
            to: draft.appendingPathComponent("index.md"))
        try Self.write(
            """
            ---
            type: Policy
            title: Durable knowledge publication
            sources:
              - id: source-one
                resource: ../references/source.txt
            verified:
              by: human:test
              at: "2026-08-09T00:00:00Z"
            status: stable
            ---

            # Publication rule

            A validated knowledge snapshot is published atomically, and an active reader keeps using its exact immutable revision.

            # Incremental rule

            An unchanged canonical chunk may reuse vector bytes only when the complete embedding and chunking compatibility identity is equal.
            """,
            to: draft.appendingPathComponent("concepts/publication.md"))
        try Self.write(
            "The source fixture is immutable for this build test.\n",
            to: draft.appendingPathComponent("references/source.txt"))
        workspaceLease = WorkspaceLease(
            rootPath: root.path,
            access: .readWrite,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: [])
    }

    func request(expectedStoreID: String? = nil,
                 authorization explicit: ResolvedToolAuthorization? = nil)
        -> KnowledgeBundleBuildRequest {
        KnowledgeBundleBuildRequest(
            draftRoot: draft,
            storeRoot: store,
            expectedStoreID: expectedStoreID,
            workspaceLease: workspaceLease,
            authorization: explicit ?? authorization(),
            trustedVerificationActors: ["human:test"])
    }

    func authorization(
        deterministicGate: PermissionReviewGateSnapshot? = PermissionReviewGateSnapshot(
            decision: .ask,
            risk: .medium,
            reason: "test-reviewed-write",
            policyVersion: "test/1")
    ) -> ResolvedToolAuthorization {
        let intent = PermissionIntent(
            action: "build_knowledge",
            resources: [
                PermissionResource(
                    kind: .workspacePath,
                    value: PathConfinement.relativePath(of: store, root: root),
                    access: .readWrite),
            ],
            dataEffects: [.read, .mutate],
            risks: [.workspaceMutation],
            replayPolicy: .requiresManualReconciliation)
        return ResolvedToolAuthorization(
            authorizationID: "test-build-authorization",
            registryVersion: "test-registry/1",
            concreteToolID: "test-registry/1/build_knowledge",
            descriptorFingerprint: "test-descriptor",
            toolName: "build_knowledge",
            canonicalAction: "build_knowledge",
            canonicalPermission: "build_knowledge",
            requiredCapabilities: [.buildKnowledge],
            membership: .granted,
            capabilityLeaseID: CapabilityLeaseID.new(),
            capabilityTaskID: nil,
            workspaceLeaseID: workspaceLease.id,
            workspaceAccess: .readWrite,
            workspaceRootIdentity: workspaceLease.rootIdentity,
            normalizedArgumentsDigest: "test-arguments",
            normalizedArgumentsCharacterCount: 0,
            intent: intent,
            sideEffect: .write,
            risksNetwork: false,
            replayPolicy: .requiresManualReconciliation,
            deterministicGate: deterministicGate,
            workspaceID: workspaceLease.workspaceID,
            workspaceTaskID: workspaceLease.taskID,
            workspaceRootPath: workspaceLease.rootPath,
            workspaceLeaseFingerprint: ToolRegistry.authorizationFingerprint(workspaceLease))
    }

    func cleanup() {
        Self.makeWritable(root)
        try? FileManager.default.removeItem(at: root)
    }

    private static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        _ = chmod(url.path, 0o700)
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        _ = chmod(url.path, 0o600)
    }

    private static func makeWritable(_ root: URL) {
        _ = chmod(root.path, 0o700)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []) else { return }
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                _ = chmod(url.path, isDirectory.boolValue ? 0o700 : 0o600)
            }
        }
    }
}
