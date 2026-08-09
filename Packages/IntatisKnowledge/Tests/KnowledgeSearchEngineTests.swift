import Foundation
import XCTest
import IntatisProtocol
@testable import IntatisKnowledge

final class KnowledgeSearchEngineTests: XCTestCase {
    func testHybridRRFPromotesDenseAndLexicalAgreement() async throws {
        let fixture = try SearchFixture.make()
        defer { fixture.remove() }
        let reader = try fixture.reader()

        let result = try await reader.search(
            knowledgeBase: "kb_fixture",
            query: "refund",
            limit: 2)

        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.evidence?.first?.conceptID, "concepts/refund")
        XCTAssertEqual(result.evidence?.first?.rank, 1)
        XCTAssertEqual(result.evidence?.first?.text, "Refunds are available for 30 days.")
        XCTAssertEqual(result.evidence?.first?.trust, "unverified")
        XCTAssertEqual(result.evidence?.first?.status, "stable")
        XCTAssertEqual(result.evidence?.first?.stale, false)
        XCTAssertEqual(
            result.evidence?.first?.evidenceURI.hasPrefix(
                "knowledge://kb_fixture/snap_fixture/ev_"),
            true)
        XCTAssertEqual(result.rerankApplied, false)
        XCTAssertEqual(result.truncated, false)
    }

    func testPolicyFiltersBeforeTopKAndCannotBeWidenedByQuery() async throws {
        let fixture = try SearchFixture.make(
            entries: [
                .init(
                    id: "concepts/draft",
                    text: "Refund secret draft instructions.",
                    status: "draft",
                    source: "draft-source",
                    vector: [1, 0]),
                .init(
                    id: "concepts/stable",
                    text: "Refund policy is stable.",
                    status: "stable",
                    source: "stable-source",
                    vector: [0.8, 0.6]),
            ])
        defer { fixture.remove() }
        let reader = try fixture.reader(policy: KnowledgeSearchPolicy(
            denseCandidateLimit: 1,
            lexicalCandidateLimit: 1,
            evaluationDate: SearchFixture.evaluationDate))

        let result = try await reader.search(
            knowledgeBase: "kb_fixture",
            query: "refund",
            limit: 1)

        XCTAssertEqual(result.evidence?.map(\.conceptID), ["concepts/stable"])
    }

    func testTieOrderingAndEvidenceIDsAreDeterministic() async throws {
        let fixture = try SearchFixture.make(entries: [
            .init(
                id: "concepts/b",
                text: "Neutral beta evidence.",
                status: "stable",
                source: "source-b",
                vector: [1, 0]),
            .init(
                id: "concepts/a",
                text: "Neutral alpha evidence.",
                status: "stable",
                source: "source-a",
                vector: [1, 0]),
        ])
        defer { fixture.remove() }
        let reader = try fixture.reader(policy: KnowledgeSearchPolicy(
            lexicalCandidateLimit: 0,
            minimumDenseSimilarity: -1,
            evaluationDate: SearchFixture.evaluationDate))

        let first = try await reader.search(
            knowledgeBase: "kb_fixture",
            query: "unmatched",
            limit: 2)
        let second = try await reader.search(
            knowledgeBase: "kb_fixture",
            query: "unmatched",
            limit: 2)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.evidence?.map(\.conceptID), [
            "concepts/a", "concepts/b",
        ])
        XCTAssertTrue(first.evidence?.allSatisfy {
            $0.evidenceID.range(
                of: #"^ev_[0-9a-f]{64}$"#,
                options: .regularExpression) != nil
        } ?? false)
    }

    func testFirstEvidenceThatCannotFitReturnsTypedBudgetFailure() async throws {
        let fixture = try SearchFixture.make(entries: [
            .init(
                id: "concepts/oversized",
                text: "This evidence cannot fit.",
                status: "stable",
                source: "source",
                vector: [1, 0]),
        ])
        defer { fixture.remove() }
        var budget = KnowledgeResultBudget()
        budget.maximumEvidenceCharacters = 4
        let reader = try fixture.reader(policy: KnowledgeSearchPolicy(
            lexicalCandidateLimit: 0,
            evaluationDate: SearchFixture.evaluationDate,
            resultBudget: budget))

        do {
            _ = try await reader.search(
                knowledgeBase: "kb_fixture",
                query: "anything",
                limit: 1)
            XCTFail("Expected a hard packing budget failure")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .searchBudgetExceeded)
            XCTAssertFalse(error.failure.retryable)
        }
    }

    func testSnapshotRootReplacementFailsClosed() async throws {
        let fixture = try SearchFixture.make()
        let reader = try fixture.reader()
        fixture.remove()
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: true)
        defer { fixture.remove() }

        do {
            _ = try await reader.search(
                knowledgeBase: "kb_fixture",
                query: "refund",
                limit: 1)
            XCTFail("Expected snapshot identity replacement to be rejected")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .revisionChanged)
            XCTAssertTrue(error.failure.retryable)
        }
    }

    func testInvalidHandleAndBlankQueryAreTypedInputFailures() async throws {
        let fixture = try SearchFixture.make()
        defer { fixture.remove() }
        let reader = try fixture.reader()

        for (handle, query) in [
            ("/private/path", "refund"),
            ("kb_fixture", "   \n"),
        ] {
            do {
                _ = try await reader.search(
                    knowledgeBase: handle,
                    query: query,
                    limit: 1)
                XCTFail("Expected invalid input to fail")
            } catch let error as KnowledgeDomainError {
                XCTAssertEqual(error.failure.code, .toolInputInvalid)
            }
        }
    }

    func testExactEmbeddingCosineRouteReranksAndBindsIdentity() async throws {
        let fixture = try SearchFixture.make(
            entries: [
                .init(
                    id: "concepts/lexical",
                    text: "Refund lexical match.",
                    status: "stable",
                    source: "lexical-source",
                    vector: [0.8, 0.6],
                    rerankVector: [0, 1]),
                .init(
                    id: "concepts/semantic",
                    text: "Semantic candidate.",
                    status: "stable",
                    source: "semantic-source",
                    vector: [1, 0],
                    rerankVector: [1, 0]),
            ],
            rerankerMode: .optional,
            provideReranker: true)
        defer { fixture.remove() }
        let reader = try fixture.reader()

        let result = try await reader.search(
            knowledgeBase: "kb_fixture",
            query: "refund",
            limit: 2)

        XCTAssertEqual(result.rerankApplied, true)
        XCTAssertEqual(result.evidence?.map(\.conceptID), [
            "concepts/semantic", "concepts/lexical",
        ])
        let expected = fixture.snapshot.profile.retrieval.reranker.model
        XCTAssertNotNil(expected)
        XCTAssertEqual(
            expected?.scoreSemantics,
            "cosine_similarity_descending")
        XCTAssertTrue(KnowledgeDigest.isValid(expected?.templateDigest ?? ""))
        XCTAssertTrue(KnowledgeDigest.isValid(
            expected?.runtimeBindingDigest ?? ""))
    }

    func testOptionalMissingRerankerIsExplicitlyNotApplied() async throws {
        let fixture = try SearchFixture.make(
            rerankerMode: .optional,
            provideReranker: false)
        defer { fixture.remove() }
        let reader = try fixture.reader()

        let result = try await reader.search(
            knowledgeBase: "kb_fixture",
            query: "refund",
            limit: 2)

        XCTAssertEqual(result.rerankApplied, false)
        XCTAssertEqual(result.evidence?.first?.conceptID, "concepts/refund")
    }

    func testRequiredMissingRerankerFailsWithoutFallback() throws {
        let fixture = try SearchFixture.make(
            rerankerMode: .required,
            provideReranker: false)
        defer { fixture.remove() }

        XCTAssertThrowsError(try fixture.reader()) { error in
            XCTAssertEqual(
                (error as? KnowledgeDomainError)?.failure.code,
                .rerankUnavailable)
        }
    }
}

private struct MockEmbeddingProvider: KnowledgeEmbeddingProvider {
    let modelIdentity: KnowledgeEmbeddingModelIdentity
    let queryVector: [Float]
    let documentVectors: [String: [Float]]

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        texts.map { documentVectors[$0] ?? queryVector }
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        queryVector
    }
}

private struct SearchFixture {
    struct Entry {
        let id: String
        let text: String
        let status: String
        let source: String
        let vector: [Float]
        let rerankVector: [Float]

        init(id: String,
             text: String,
             status: String,
             source: String,
             vector: [Float],
             rerankVector: [Float]? = nil) {
            self.id = id
            self.text = text
            self.status = status
            self.source = source
            self.vector = vector
            self.rerankVector = rerankVector ?? vector
        }
    }

    static let evaluationDate = "2026-08-09T00:00:00Z"

    let root: URL
    let snapshot: KnowledgeValidatedSnapshot
    let embeddingRegistry: KnowledgeEmbeddingRuntimeRegistry
    let rerankerRegistry: KnowledgeRerankerRuntimeRegistry?

    static func make(entries: [Entry] = [
        Entry(
            id: "concepts/refund",
            text: "Refunds are available for 30 days.",
            status: "stable",
            source: "refund-policy",
            vector: [0.8, 0.6]),
        Entry(
            id: "concepts/semantic-only",
            text: "A semantically nearby but lexically different passage.",
            status: "stable",
            source: "semantic-source",
            vector: [1, 0]),
    ],
    rerankerMode: KnowledgeRerankerProfile.Mode = .disabled,
    provideReranker: Bool = false) throws -> SearchFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        guard let rootIdentity = WorkspaceRootIdentity.capture(rootPath: root.path) else {
            throw KnowledgeDomainError(.unsafeStorage, "Test root identity is unavailable.")
        }

        let model = KnowledgeEmbeddingModelIdentity(
            identity: "test.embedding",
            revision: "test-revision-1",
            tokenizerRevision: "test-tokenizer-1",
            runtimeBindingKind: .local,
            runtimeBindingDigest: KnowledgeDigest.sha256("test-runtime-binding"),
            dimensions: 2,
            pooling: "test",
            maxInputTokens: 32)
        let denseBackend = KnowledgeBackendIdentity(
            identity: KnowledgeContract.exactKNNBackendIdentity,
            formatVersion: KnowledgeContract.exactKNNFormatVersion,
            runtimeVersion: KnowledgeContract.exactKNNRuntimeVersion)
        let lexicalBackend = KnowledgeBackendIdentity(
            identity: KnowledgeContract.lexicalBackendIdentity,
            formatVersion: KnowledgeContract.lexicalFormatVersion,
            runtimeVersion: KnowledgeContract.lexicalRuntimeVersion)

        var concepts: [String: OKFConcept] = [:]
        var chunks: [KnowledgeChunk] = []
        var vectors: [KnowledgeDenseVectorRecord] = []
        var documents: [KnowledgeLexicalDocumentRecord] = []
        for (offset, entry) in entries.enumerated() {
            let source = OKFSource(
                id: entry.source,
                resource: "reference://\(entry.source)",
                title: nil,
                author: nil,
                usageCount: nil,
                lastModified: nil)
            let revision = KnowledgeDigest.sha256(entry.text)
            let concept = OKFConcept(
                conceptID: entry.id,
                relativePath: "\(entry.id).md",
                normalizedText: entry.text,
                body: entry.text,
                bodyUTF8Start: 0,
                revision: revision,
                type: "knowledge",
                title: nil,
                description: nil,
                sources: [source],
                verifications: [],
                status: entry.status,
                staleAfter: nil,
                generatedAt: nil,
                legacyTimestamp: nil,
                frontmatter: [:])
            concepts[entry.id] = concept
            let chunkID = String(format: "chk_%03d", offset)
            chunks.append(KnowledgeChunk(
                chunkID: chunkID,
                conceptID: entry.id,
                conceptRevision: revision,
                evidenceClass: .exactConceptSlice,
                text: entry.text,
                textSha256: KnowledgeDigest.sha256(entry.text),
                conceptLocator: KnowledgeConceptLocator(
                    start: 0,
                    end: Data(entry.text.utf8).count),
                sourceIDs: [entry.source],
                producer: KnowledgeProducer(
                    identity: KnowledgeContract.deterministicChunkerIdentity,
                    version: KnowledgeContract.deterministicChunkerVersion,
                    at: evaluationDate)))
            vectors.append(KnowledgeDenseVectorRecord(
                chunkID: chunkID,
                values: try KnowledgeVectorMath.normalized(entry.vector)))
            let tokens = KnowledgeTextTokenizer.tokens(entry.text)
            documents.append(KnowledgeLexicalDocumentRecord(
                chunkID: chunkID,
                length: tokens.count,
                terms: Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +)))
        }

        let manifestDigest = KnowledgeDigest.sha256("fixture-manifest")
        let denseProfile = KnowledgeEmbeddingIndexProfile(
            id: "dense_fixture",
            componentRevision: KnowledgeDigest.sha256("dense-component"),
            indexPath: ".intatis-rag/dense/fixture.json",
            backend: denseBackend,
            model: model,
            chunkManifestDigest: manifestDigest,
            vectorCount: vectors.count,
            indexDigest: KnowledgeDigest.sha256("dense-index"))
        let lexicalProfile = KnowledgeLexicalIndexProfile(
            id: "lexical_fixture",
            componentRevision: KnowledgeDigest.sha256("lexical-component"),
            indexPath: ".intatis-rag/lexical/fixture.json",
            backend: lexicalBackend,
            tokenizer: KnowledgeTextTokenizer.identity,
            languagePolicy: "multilingual-code",
            chunkManifestDigest: manifestDigest,
            documentCount: documents.count,
            indexDigest: KnowledgeDigest.sha256("lexical-index"))
        let embeddingProvider = MockEmbeddingProvider(
            modelIdentity: model,
            queryVector: [1, 0],
            documentVectors: Dictionary(
                uniqueKeysWithValues: try entries.map {
                    ($0.text, try KnowledgeVectorMath.normalized($0.rerankVector))
                }))
        let localReranker = try KnowledgeEmbeddingCosineRerankerProvider(
            embeddingProvider: embeddingProvider)
        let reranker = KnowledgeRerankerProfile(
            mode: rerankerMode,
            model: rerankerMode == .disabled
                ? nil
                : localReranker.modelIdentity)
        let profile = KnowledgeProfile(
            schema: KnowledgeContract.profileSchema,
            profile: KnowledgeContract.profileIdentity,
            profileVersion: KnowledgeContract.profileVersion,
            okf: KnowledgeProfile.OKF(
                version: KnowledgeContract.okfVersion,
                specCommit: KnowledgeContract.okfSpecCommit),
            bundle: KnowledgeProfile.Bundle(
                id: "kb_fixture_bundle",
                revision: KnowledgeDigest.sha256("fixture-bundle"),
                createdAt: evaluationDate),
            normalization: KnowledgeProfile.Normalization(
                textEncoding: "UTF-8",
                lineEndings: "LF",
                unicode: "NFC",
                version: KnowledgeContract.textNormalizationVersion),
            chunking: KnowledgeProfile.Chunking(
                manifest: ".intatis-rag/chunks.jsonl",
                algorithm: KnowledgeContract.deterministicChunkerIdentity,
                version: KnowledgeContract.deterministicChunkerVersion,
                parametersDigest: KnowledgeDigest.sha256("chunk-parameters"),
                manifestDigest: manifestDigest),
            embeddingIndexes: [denseProfile],
            lexicalIndexes: [lexicalProfile],
            retrieval: KnowledgeProfile.Retrieval(
                dense: "required",
                lexical: "required",
                fusion: "rrf/1",
                reranker: reranker,
                evidenceContract: KnowledgeContract.evidenceContract),
            retrievalSnapshot: KnowledgeProfile.RetrievalSnapshot(
                id: "snap_fixture",
                revision: KnowledgeDigest.sha256("retrieval-snapshot"),
                bundleRevision: KnowledgeDigest.sha256("fixture-bundle"),
                chunkManifestDigest: manifestDigest,
                dense: KnowledgeComponentReference(
                    id: denseProfile.id,
                    componentRevision: denseProfile.componentRevision),
                lexical: KnowledgeComponentReference(
                    id: lexicalProfile.id,
                    componentRevision: lexicalProfile.componentRevision),
                retrievalPolicyDigest: KnowledgeDigest.sha256("retrieval-policy"),
                rerankerBindingDigest: KnowledgeDigest.sha256("reranker-binding")),
            integrity: KnowledgeProfile.Integrity(
                algorithm: "sha256",
                inventory: ".intatis-rag/checksums.json"))
        let report = KnowledgeValidationReport(
            profile: profile,
            chunks: chunks,
            diagnostics: [])
        let snapshot = KnowledgeValidatedSnapshot(
            root: root,
            rootIdentity: rootIdentity,
            profile: profile,
            concepts: concepts,
            chunks: chunks,
            denseFile: KnowledgeDenseIndexFile(dimensions: 2, vectors: vectors),
            lexicalFile: KnowledgeLexicalIndexFile(
                tokenizer: KnowledgeTextTokenizer.identity,
                documents: documents),
            checksums: KnowledgeChecksums(files: []),
            report: report)
        return SearchFixture(
            root: root,
            snapshot: snapshot,
            embeddingRegistry: try KnowledgeEmbeddingRuntimeRegistry([
                embeddingProvider,
            ]),
            rerankerRegistry: provideReranker
                ? try KnowledgeRerankerRuntimeRegistry([localReranker])
                : nil)
    }

    func reader(policy: KnowledgeSearchPolicy? = nil) throws -> KnowledgeSnapshotSearchReader {
        try KnowledgeSnapshotSearchReader(
            snapshot: snapshot,
            embeddingRegistry: embeddingRegistry,
            rerankerRegistry: rerankerRegistry,
            policy: policy ?? KnowledgeSearchPolicy(
                evaluationDate: Self.evaluationDate))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
