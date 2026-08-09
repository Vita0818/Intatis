import XCTest
@testable import IntatisKnowledge

final class KnowledgeContractTests: XCTestCase {
    func testEveryFrozenSchemaLoads() throws {
        let validator = KnowledgeJSONSchemaValidator()
        for schema in KnowledgeJSONSchemaValidator.Schema.allCases {
            guard case .object = try validator.schemaValue(schema) else {
                return XCTFail("\(schema.rawValue) is not an object schema")
            }
        }
    }

    func testStoreSchemaRejectsAdditionalPropertiesAndEscapingSnapshot() throws {
        let validator = KnowledgeJSONSchemaValidator()
        let valid = #"{"schema":"intatis-rag-store/1","store_id":"kb_demo","revision":1,"current_snapshot":"snap_one","current_snapshot_revision":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
        XCTAssertNoThrow(try validator.validate(
            data: Data(valid.utf8),
            against: .store))

        let extra = valid.dropLast() + #", "path":"/private/secret"}"#
        XCTAssertThrowsError(try validator.validate(
            data: Data(extra.utf8),
            against: .store))
        let escape = valid.replacingOccurrences(
            of: "snap_one",
            with: "../snap_one")
        XCTAssertThrowsError(try validator.validate(
            data: Data(escape.utf8),
            against: .store))
    }

    func testEvidenceConditionalBranchesAreStrict() throws {
        let validator = KnowledgeJSONSchemaValidator()
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let exact = """
        {
          "evidence_id":"ev_one",
          "rank":1,
          "text":"grounded",
          "text_sha256":"\(digest)",
          "evidence_uri":"knowledge://kb_demo/snap_one/ev_one",
          "concept_id":"concepts/one",
          "concept_revision":"\(digest)",
          "evidence_class":"exact_concept_slice",
          "concept_locator":{"kind":"utf8-byte-range","start":1,"end":2},
          "source_ids":["source-one"],
          "status":"stable",
          "stale":false
        }
        """
        XCTAssertNoThrow(try validator.validate(
            data: Data(exact.utf8),
            against: .evidence))
        let forged = exact.replacingOccurrences(
            of: #""status":"stable""#,
            with: #""producer":{"identity":"model","version":"1","at":"2026-08-09T00:00:00Z"},"status":"stable""#)
        XCTAssertThrowsError(try validator.validate(
            data: Data(forged.utf8),
            against: .evidence))
    }

    func testOKFReaderAcceptsV02AndLegacyCitations() throws {
        let reader = OKFReader()
        let modern = """
        ---
        type: Policy
        title: Refunds
        sources:
          - id: refund-policy
            resource: https://example.invalid/refund
        verified: { by: human:reviewer, at: 2026-08-09T00:00:00Z }
        ---

        # Rule
        Refunds require a receipt.
        """
        let concept = try reader.readConcept(
            data: Data(modern.utf8),
            relativePath: "concepts/refund.md")
        XCTAssertEqual(concept.conceptID, "concepts/refund")
        XCTAssertEqual(concept.sources.map(\.id), ["refund-policy"])
        XCTAssertEqual(concept.trustTier, "human-reviewed")

        let legacy = """
        ---
        type: Note
        timestamp: '2026-08-01T00:00:00Z'
        ---

        # Facts
        A legacy fact.

        # Citations
        - https://example.invalid/legacy
        """
        let old = try reader.readConcept(
            data: Data(legacy.utf8),
            relativePath: "concepts/legacy.md")
        XCTAssertEqual(old.legacyTimestamp, "2026-08-01T00:00:00Z")
        XCTAssertEqual(old.sources.count, 1)
        XCTAssertTrue(old.sources[0].id?.hasPrefix("legacy-") == true)
    }

    func testOKFReaderRejectsAliasAndCustomTagSafetyHazards() {
        let reader = OKFReader()
        let alias = """
        ---
        type: &kind Policy
        title: *kind
        ---
        body
        """
        XCTAssertThrowsError(try reader.readConcept(
            data: Data(alias.utf8),
            relativePath: "concepts/alias.md"))
        let tag = """
        ---
        type: !exec Policy
        ---
        body
        """
        XCTAssertThrowsError(try reader.readConcept(
            data: Data(tag.utf8),
            relativePath: "concepts/tag.md"))
    }

    func testTokenizerSupportsChineseAndCodeIdentifiers() {
        let tokens = KnowledgeTextTokenizer.tokens(
            "权限链 PathConfinement.isWithin embed_query")
        XCTAssertTrue(tokens.contains("权"))
        XCTAssertTrue(tokens.contains("权限"))
        XCTAssertTrue(tokens.contains("pathconfinement"))
        XCTAssertTrue(tokens.contains("embed_query"))
    }
}

