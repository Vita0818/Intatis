import XCTest
@testable import IntatisKnowledge
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

final class KnowledgeRetrievalQualityTests: XCTestCase {
    private struct Corpus: Decodable {
        struct Document: Decodable { let id: String; let text: String }
        struct Query: Decodable { let text: String; let relevant: [String] }
        let schema: String
        let documents: [Document]
        let queries: [Query]
    }

    #if canImport(NaturalLanguage)
    func testAppleEnglishHybridRouteMeetsFrozenCorpusGate() async throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schema, "intatis-knowledge-eval-corpus/1")
        let provider: AppleNaturalLanguageSentenceEmbeddingProvider
        do {
            provider = try AppleNaturalLanguageSentenceEmbeddingProvider(
                language: .english,
                revision: 1,
                requiredDimensions: 512,
                maximumInputUnits: 512)
        } catch {
            return XCTFail("Required universal macOS embedding route unavailable: \(error)")
        }

        let documentVectors = try await provider.embedDocuments(
            corpus.documents.map(\.text))
        let dense = try KnowledgeDenseIndex(file: KnowledgeDenseIndexFile(
            dimensions: 512,
            vectors: zip(corpus.documents, documentVectors).map {
                KnowledgeDenseVectorRecord(chunkID: $0.0.id, values: $0.1)
            }))
        let lexical = try KnowledgeBM25Index(file: KnowledgeLexicalIndexFile(
            tokenizer: KnowledgeTextTokenizer.identity,
            documents: corpus.documents.map { document in
                let tokens = KnowledgeTextTokenizer.tokens(document.text)
                var terms: [String: Int] = [:]
                for token in tokens { terms[token, default: 0] += 1 }
                return KnowledgeLexicalDocumentRecord(
                    chunkID: document.id,
                    length: tokens.count,
                    terms: terms)
            }))

        var recallAtFive = 0
        var reciprocalRank = 0.0
        for query in corpus.queries {
            let vector = try await provider.embedQuery(query.text)
            let denseRanking = try dense.search(query: vector, limit: 10)
            let lexicalRanking = lexical.search(query: query.text, limit: 10)
            let ranking = KnowledgeRRF.fuse(
                [denseRanking, lexicalRanking],
                limit: 10).map(\.chunkID)
            if !Set(ranking.prefix(5)).isDisjoint(with: query.relevant) {
                recallAtFive += 1
            }
            if let index = ranking.firstIndex(where: { query.relevant.contains($0) }) {
                reciprocalRank += 1.0 / Double(index + 1)
            }
        }
        let recall = Double(recallAtFive) / Double(corpus.queries.count)
        let mrr = reciprocalRank / Double(corpus.queries.count)
        XCTAssertGreaterThanOrEqual(recall, 0.85, "Recall@5 regression: \(recall)")
        XCTAssertGreaterThanOrEqual(mrr, 0.60, "MRR regression: \(mrr)")
    }
    #endif

    private func loadCorpus() throws -> Corpus {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "retrieval-corpus",
            withExtension: "json"))
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }
}
