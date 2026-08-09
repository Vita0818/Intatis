import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisKnowledge

final class KnowledgeSnapshotStoreTests: XCTestCase {
    func testAtomicPointerSwitchKeepsOldReaderPinnedUntilDrainThenGC() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }

        let first = try fixture.publish(snapshotID: "snap_first", expectedRevision: nil)
        XCTAssertEqual(first.revision, 1)
        let oldReader = try fixture.store.acquireCurrentReaderLease()
        XCTAssertEqual(oldReader.pointer.currentSnapshot, "snap_first")

        let second = try fixture.publish(snapshotID: "snap_second", expectedRevision: 1)
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(fixture.store.loadCurrentPointer(), second)
        XCTAssertNoThrow(try oldReader.verifyStable())

        let newReader = try fixture.store.acquireCurrentReaderLease()
        XCTAssertEqual(newReader.pointer.currentSnapshot, "snap_second")
        newReader.release()

        let writer = try fixture.store.acquireWriterLease()
        var policy = KnowledgeSnapshotGarbageCollectionPolicy(
            minimumRetainedAge: 0,
            retainNewestNonCurrent: 0,
            maximumRemovals: 10,
            abandonedStagingAge: nil)
        var result = try writer.garbageCollect(policy: policy)
        XCTAssertEqual(result.removedSnapshotIDs, [])
        XCTAssertEqual(result.skippedActiveReaderSnapshotIDs, ["snap_first"])

        oldReader.release()
        policy.maximumRemovals = 1
        result = try writer.garbageCollect(policy: policy)
        XCTAssertEqual(result.removedSnapshotIDs, ["snap_first"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.snapshotRoot("snap_second").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.snapshotRoot("snap_first").path))
        writer.release()
    }

    func testCurrentProtectedAndRetainedSnapshotsCannotBeGarbageCollected() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(snapshotID: "snap_a", expectedRevision: nil)
        _ = try fixture.publish(snapshotID: "snap_b", expectedRevision: 1)
        _ = try fixture.publish(snapshotID: "snap_c", expectedRevision: 2)

        let writer = try fixture.store.acquireWriterLease()
        let result = try writer.garbageCollect(
            policy: KnowledgeSnapshotGarbageCollectionPolicy(
                minimumRetainedAge: 0,
                retainNewestNonCurrent: 1,
                maximumRemovals: 10,
                abandonedStagingAge: nil),
            protectedSnapshotIDs: ["snap_a"])
        writer.release()

        XCTAssertEqual(result.skippedCurrentSnapshotIDs, ["snap_c"])
        XCTAssertEqual(result.skippedProtectedSnapshotIDs, ["snap_a"])
        XCTAssertEqual(result.skippedRetentionSnapshotIDs, ["snap_b"])
        XCTAssertEqual(result.removedSnapshotIDs, [])
    }

    func testWriterLeaseIsExclusiveAndCanReadPointerWithoutRelocking() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(snapshotID: "snap_one", expectedRevision: nil)

        let writer = try fixture.store.acquireWriterLease()
        XCTAssertEqual(try writer.currentPointer()?.currentSnapshot, "snap_one")
        XCTAssertNil(try fixture.store.tryAcquireWriterLease())
        writer.release()
        XCTAssertNotNil(try fixture.store.tryAcquireWriterLease())
    }

    func testUnsafePointerSnapshotNameFailsClosedWithoutPathResolution() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        let pointer = fixture.store.root.appendingPathComponent(
            ".intatis-rag-store.json")
        let bytes = Data(
            """
            {"schema":"intatis-rag-store/1","store_id":"kb_fixture","revision":1,"current_snapshot":"../outside","current_snapshot_revision":"\(SnapshotStoreFixture.digest(9))"}
            """.utf8)
        try DurableOwnerOnlyFile.writeAtomically(bytes, to: pointer)

        XCTAssertThrowsError(try fixture.store.loadCurrentPointer()) { error in
            XCTAssertEqual(
                (error as? KnowledgeDomainError)?.failure.code,
                .profileInvalid)
        }
    }

    func testMountHandleIsScopeBoundAndInvalidatedForNewAdmissionAfterPublish() async throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(snapshotID: "snap_initial", expectedRevision: nil)
        let registry = KnowledgeMountRegistry(
            policy: KnowledgeValidationPolicy(evaluationDate: "2026-08-09T00:00:00Z"),
            validate: { root, _, _, _ in
                try SnapshotStoreFixture.validatedSnapshot(
                    root: root,
                    storeID: "kb_fixture",
                    snapshotID: root.lastPathComponent)
            })
        let authority = fixture.authority()
        let mounted = try await registry.mount(
            store: fixture.store,
            authority: authority)
        XCTAssertTrue(KnowledgeBaseHandle(rawValue: mounted.knowledgeBaseHandle) != nil)

        let access = try await registry.checkout(
            handle: mounted.handle,
            authority: authority)
        XCTAssertEqual(access.binding.snapshotID, "snap_initial")

        var wrong = fixture.authority()
        while wrong == authority { wrong = fixture.authority() }
        do {
            _ = try await registry.checkout(
                handle: mounted.handle,
                authority: wrong)
            XCTFail("Expected exact host-scope denial")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .accessDenied)
        }

        _ = try fixture.publish(snapshotID: "snap_replacement", expectedRevision: 1)
        XCTAssertNoThrow(try access.verifyStable())
        do {
            _ = try await registry.checkout(
                handle: mounted.handle,
                authority: authority)
            XCTFail("Expected replaced handle to reject new admission")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .revisionChanged)
            XCTAssertTrue(error.failure.retryable)
        }
        let admittingAfterReplacement = await registry.isAdmitting(mounted.handle)
        XCTAssertFalse(admittingAfterReplacement)
        await access.close()
    }

    func testUrgentRevocationSignalsCancellationAndWaitsForReaderDrain() async throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(snapshotID: "snap_sensitive", expectedRevision: nil)
        let registry = KnowledgeMountRegistry(
            policy: KnowledgeValidationPolicy(evaluationDate: "2026-08-09T00:00:00Z"),
            validate: { root, _, _, _ in
                try SnapshotStoreFixture.validatedSnapshot(
                    root: root,
                    storeID: "kb_fixture",
                    snapshotID: root.lastPathComponent)
            })
        let authority = fixture.authority()
        let mounted = try await registry.mount(store: fixture.store, authority: authority)
        let cancellation = CancellationProbe()
        let access = try await registry.checkout(
            handle: mounted.handle,
            authority: authority,
            cancellation: {
                Task { await cancellation.mark() }
            })

        async let drained = registry.revokeStoreAndDrain(
            storeID: mounted.storeID,
            timeoutNanoseconds: 1_000_000_000)
        for _ in 0..<100 {
            if await cancellation.wasMarked() { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let cancellationWasMarked = await cancellation.wasMarked()
        let stillAdmitting = await registry.isAdmitting(mounted.handle)
        XCTAssertTrue(cancellationWasMarked)
        XCTAssertFalse(stillAdmitting)
        await access.close()
        let didDrain = await drained
        let activeCount = await registry.activeAccessCount(for: mounted.handle)
        XCTAssertTrue(didDrain)
        XCTAssertEqual(activeCount, 0)
    }
}

private actor CancellationProbe {
    private var marked = false

    func mark() { marked = true }
    func wasMarked() -> Bool { marked }
}

private final class SnapshotStoreFixture {
    let workspaceRoot: URL
    let workspaceLease: WorkspaceLease
    let store: KnowledgeSnapshotStore

    private init(workspaceRoot: URL,
                 workspaceLease: WorkspaceLease,
                 store: KnowledgeSnapshotStore) {
        self.workspaceRoot = workspaceRoot
        self.workspaceLease = workspaceLease
        self.store = store
    }

    static func make() throws -> SnapshotStoreFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "intatis-knowledge-store-tests-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let lease = WorkspaceLease(rootPath: root.path, access: .readWrite)
        let store = try KnowledgeSnapshotStore(
            root: root.appendingPathComponent("knowledge", isDirectory: true),
            workspaceLease: lease,
            coordinationRoot: root.appendingPathComponent("host-locks", isDirectory: true),
            createIfMissing: true)
        return SnapshotStoreFixture(
            workspaceRoot: root,
            workspaceLease: lease,
            store: store)
    }

    func publish(snapshotID: String,
                 expectedRevision: Int?) throws -> KnowledgeStorePointer {
        let writer = try store.acquireWriterLease()
        defer { writer.release() }
        let staging = try writer.createStagingSnapshot(snapshotID: snapshotID)
        let data = Data("snapshot \(snapshotID)".utf8)
        try data.write(to: staging.root.appendingPathComponent("index.md"))
        let validated = try Self.validatedSnapshot(
            root: staging.root,
            storeID: "kb_fixture",
            snapshotID: snapshotID)
        return try writer.publishValidatedStaging(
            staging,
            validatedSnapshot: validated,
            expectedPointerRevision: expectedRevision)
    }

    func authority() -> KnowledgeMountAuthority {
        KnowledgeMountAuthority(
            sessionID: .new(),
            agentID: .new(),
            taskID: nil,
            capabilityLeaseID: .new(),
            workspaceLeaseID: workspaceLease.id,
            workspaceRootIdentity: workspaceLease.rootIdentity!)
    }

    func snapshotRoot(_ id: String) -> URL {
        store.root
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: workspaceRoot)
    }

    static func validatedSnapshot(root: URL,
                                  storeID: String,
                                  snapshotID: String) throws
        -> KnowledgeValidatedSnapshot {
        guard let rootIdentity = WorkspaceRootIdentity.capture(rootPath: root.path) else {
            throw KnowledgeDomainError(.unsafeStorage, "Fixture root identity is unavailable.")
        }
        let bundleRevision = digest(1)
        let chunkDigest = digest(2)
        let componentRevision = digest(3)
        let snapshotRevision = digest(snapshotID == "snap_initial" ? 4 : 5)
        let backend = KnowledgeBackendIdentity(
            identity: KnowledgeContract.exactKNNBackendIdentity,
            formatVersion: KnowledgeContract.exactKNNFormatVersion,
            runtimeVersion: KnowledgeContract.exactKNNRuntimeVersion)
        let embedding = KnowledgeEmbeddingModelIdentity(
            identity: "org.vita.intatis.fixture-embedding",
            revision: "1",
            tokenizerRevision: "1",
            runtimeBindingKind: .local,
            runtimeBindingDigest: digest(6),
            dimensions: 1,
            pooling: "sentence",
            maxInputTokens: 32)
        let dense = KnowledgeEmbeddingIndexProfile(
            id: "dense_fixture",
            componentRevision: componentRevision,
            indexPath: ".intatis-rag/dense/exact-knn.json",
            backend: backend,
            model: embedding,
            chunkManifestDigest: chunkDigest,
            vectorCount: 0,
            indexDigest: digest(7))
        let profile = KnowledgeProfile(
            schema: KnowledgeContract.profileSchema,
            profile: KnowledgeContract.profileIdentity,
            profileVersion: KnowledgeContract.profileVersion,
            okf: .init(
                version: KnowledgeContract.okfVersion,
                specCommit: KnowledgeContract.okfSpecCommit),
            bundle: .init(
                id: storeID,
                revision: bundleRevision,
                createdAt: "2026-08-09T00:00:00Z"),
            normalization: .init(
                textEncoding: "utf-8",
                lineEndings: "lf",
                unicode: "nfc",
                version: KnowledgeContract.textNormalizationVersion),
            chunking: .init(
                manifest: ".intatis-rag/chunks.jsonl",
                algorithm: KnowledgeContract.deterministicChunkerIdentity,
                version: KnowledgeContract.deterministicChunkerVersion,
                parametersDigest: digest(8),
                manifestDigest: chunkDigest),
            embeddingIndexes: [dense],
            lexicalIndexes: [],
            retrieval: .init(
                dense: "required",
                lexical: "disabled",
                fusion: "rrf",
                reranker: .init(mode: .disabled, model: nil),
                evidenceContract: KnowledgeContract.evidenceContract),
            retrievalSnapshot: .init(
                id: snapshotID,
                revision: snapshotRevision,
                bundleRevision: bundleRevision,
                chunkManifestDigest: chunkDigest,
                dense: .init(id: dense.id, componentRevision: componentRevision),
                lexical: nil,
                retrievalPolicyDigest: digest(9),
                rerankerBindingDigest: digest(10)),
            integrity: .init(
                algorithm: "sha256",
                inventory: ".intatis-rag/checksums.json"))
        let report = KnowledgeValidationReport(
            profile: profile,
            chunks: [],
            diagnostics: [])
        return KnowledgeValidatedSnapshot(
            root: root,
            rootIdentity: rootIdentity,
            profile: profile,
            concepts: [:],
            chunks: [],
            denseFile: KnowledgeDenseIndexFile(dimensions: 1, vectors: []),
            lexicalFile: nil,
            checksums: KnowledgeChecksums(files: []),
            report: report)
    }

    static func digest(_ byte: Int) -> String {
        "sha256:" + String(repeating: String(format: "%02x", byte & 0xff), count: 32)
    }
}
