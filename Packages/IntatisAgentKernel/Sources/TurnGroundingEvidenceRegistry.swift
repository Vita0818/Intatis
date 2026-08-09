import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
import IntatisProtocol
import IntatisTools

/// Request-local authority for model-visible knowledge citations. The
/// registry is deliberately recreated for every AgentLoop turn: durable tool
/// history is context, never authority for a new citation.
struct TurnGroundingEvidenceRegistry: Sendable {
    struct Binding: Equatable, Sendable {
        let evidenceID: String
        let knowledgeBase: String
        let knowledgeBaseRevision: String
        let retrievalSnapshot: String
        let retrievalSnapshotRevision: String
        let textSHA256: String
        let evidenceURI: String
    }

    enum ValidationError: Error, Equatable, Sendable, LocalizedError {
        case malformedSearchResult(String)
        case malformedCitation
        case unknownCitation(String)

        var errorDescription: String? {
            switch self {
            case .malformedSearchResult(let reason):
                return "search_knowledge returned an invalid grounding result: \(reason)"
            case .malformedCitation:
                return "The final answer contains a malformed evidence citation."
            case .unknownCitation(let evidenceID):
                return "The final answer cites evidence that was not returned successfully in this turn: \(evidenceID)"
            }
        }
    }

    private(set) var bindings: [String: Binding] = [:]

    mutating func record(toolName: String,
                         observation: ToolObservation) throws {
        guard toolName == "search_knowledge",
              observation.structuredResult?.isError == false,
              let value = observation.structuredResult?.structuredContent else {
            return
        }
        guard case .object(let root) = value,
              root.string("status") == "ok" else {
            return
        }
        guard let knowledgeBase = root.string("knowledge_base"),
              let knowledgeBaseRevision = root.digest("knowledge_base_revision"),
              let retrievalSnapshot = root.string("retrieval_snapshot"),
              let retrievalSnapshotRevision = root.digest("retrieval_snapshot_revision"),
              case .array(let evidence)? = root["evidence"],
              !evidence.isEmpty else {
            throw ValidationError.malformedSearchResult("required snapshot identity or evidence is missing")
        }

        var result: [String: Binding] = [:]
        for (offset, item) in evidence.enumerated() {
            guard case .object(let object) = item,
                  let evidenceID = object.string("evidence_id"),
                  evidenceID.range(
                    of: #"^ev_[A-Za-z0-9._-]{1,128}$"#,
                    options: .regularExpression) != nil,
                  object.integer("rank") == offset + 1,
                  let text = object.string("text"),
                  let textSHA256 = object.digest("text_sha256"),
                  textSHA256 == Self.sha256(Data(text.utf8)),
                  let evidenceURI = object.string("evidence_uri"),
                  evidenceURI.hasPrefix(
                    "knowledge://\(knowledgeBase)/\(retrievalSnapshot)/"),
                  case .array(let sourceIDs)? = object["source_ids"],
                  !sourceIDs.isEmpty,
                  sourceIDs.allSatisfy({ $0.nonEmptyString != nil }),
                  result[evidenceID] == nil,
                  bindings[evidenceID] == nil else {
                throw ValidationError.malformedSearchResult("evidence ordering, digest, URI, source binding, or identity is invalid")
            }
            result[evidenceID] = Binding(
                evidenceID: evidenceID,
                knowledgeBase: knowledgeBase,
                knowledgeBaseRevision: knowledgeBaseRevision,
                retrievalSnapshot: retrievalSnapshot,
                retrievalSnapshotRevision: retrievalSnapshotRevision,
                textSHA256: textSHA256,
                evidenceURI: evidenceURI)
        }
        bindings.merge(result) { _, _ in
            preconditionFailure("duplicate evidence ID was checked above")
        }
    }

    func validateCitations(in text: String) throws {
        let marker = "[[evidence:"
        guard text.contains(marker) else { return }
        let pattern = #"\[\[evidence:(ev_[A-Za-z0-9._-]{1,128})\]\]"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        guard !matches.isEmpty else {
            throw ValidationError.malformedCitation
        }

        var covered = IndexSet()
        for match in matches {
            covered.insert(integersIn: match.range.location..<(match.range.location + match.range.length))
            guard let idRange = Range(match.range(at: 1), in: text) else {
                throw ValidationError.malformedCitation
            }
            let evidenceID = String(text[idRange])
            guard bindings[evidenceID] != nil else {
                throw ValidationError.unknownCitation(evidenceID)
            }
        }

        let utf16 = Array(text.utf16)
        var searchStart = 0
        let markerUnits = Array(marker.utf16)
        while searchStart + markerUnits.count <= utf16.count {
            guard let offset = Self.firstOccurrence(
                of: markerUnits,
                in: utf16,
                startingAt: searchStart) else { break }
            guard covered.contains(offset) else {
                throw ValidationError.malformedCitation
            }
            searchStart = offset + markerUnits.count
        }
    }

    private static func firstOccurrence(of needle: [UInt16],
                                        in haystack: [UInt16],
                                        startingAt start: Int) -> Int? {
        guard !needle.isEmpty, start >= 0, start <= haystack.count else { return nil }
        guard needle.count <= haystack.count else { return nil }
        let upper = haystack.count - needle.count
        guard start <= upper else { return nil }
        for index in start...upper where Array(haystack[index..<(index + needle.count)]) == needle {
            return index
        }
        return nil
    }

    private static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        self[key]?.nonEmptyString
    }

    func integer(_ key: String) -> Int? {
        guard case .number(let value)? = self[key],
              value.isFinite,
              value.rounded() == value else { return nil }
        return Int(value)
    }

    func digest(_ key: String) -> String? {
        guard let value = string(key),
              value.range(
                of: #"^sha256:[0-9a-f]{64}$"#,
                options: .regularExpression) != nil else { return nil }
        return value
    }
}

private extension JSONValue {
    var nonEmptyString: String? {
        guard case .string(let value) = self,
              !value.isEmpty else { return nil }
        return value
    }
}
