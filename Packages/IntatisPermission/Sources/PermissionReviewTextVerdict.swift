import Foundation
import IntatisProtocol

/// A minimal model-authored permission verdict. Risk remains a host policy
/// fact and is intentionally absent from this value.
public struct PermissionReviewTextVerdict: Equatable, Sendable {
    public let decision: PermissionDecision
    public let reason: String

    public init(decision: PermissionDecision, reason: String) {
        self.decision = decision
        self.reason = reason
    }
}

/// Parses the shared permission-review text protocol. Provider completion and
/// finish-reason validation belong to the transport-owning caller, not this
/// pure text parser.
public enum PermissionReviewTextVerdictParser {
    public static let maximumReasonCharacterCount = 240

    public static func parse(_ text: String) -> PermissionReviewTextVerdict? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        while let last = lines.last, last.allSatisfy(\.isWhitespace) {
            lines.removeLast()
        }

        guard let marker = lines.last,
              let parsedDecision = decision(forExactASCIIMarker: marker) else {
            return nil
        }

        let markerCount = lines.reduce(into: 0) { count, line in
            if decision(forExactASCIIMarker: line) != nil {
                count += 1
            }
        }
        guard markerCount == 1 else { return nil }

        let reason = lines.dropLast()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty,
              reason.count <= maximumReasonCharacterCount,
              !containsCodeFence(reason),
              !containsJSONPayload(reason) else {
            return nil
        }

        return PermissionReviewTextVerdict(decision: parsedDecision, reason: reason)
    }

    private static func decision(forExactASCIIMarker line: String) -> PermissionDecision? {
        let bytes = Array(line.utf8)
        if equalsASCIICaseInsensitive(bytes, Array("ALLOW".utf8)) {
            return .allow
        }
        if equalsASCIICaseInsensitive(bytes, Array("DENY".utf8)) {
            return .deny
        }
        return nil
    }

    private static func equalsASCIICaseInsensitive(_ candidate: [UInt8], _ expected: [UInt8]) -> Bool {
        guard candidate.count == expected.count else { return false }
        return zip(candidate, expected).allSatisfy { byte, expectedByte in
            let uppercased: UInt8
            switch byte {
            case 97 ... 122:
                uppercased = byte - 32
            default:
                uppercased = byte
            }
            return uppercased == expectedByte
        }
    }

    private static func containsCodeFence(_ reason: String) -> Bool {
        reason.contains("```") || reason.contains("~~~")
    }

    private static func containsJSONPayload(_ reason: String) -> Bool {
        for (opening, closing) in [("{", "}"), ("[", "]")] {
            guard let start = reason.firstIndex(of: Character(opening)),
                  let end = reason.lastIndex(of: Character(closing)),
                  start < end,
                  let data = String(reason[start ... end]).data(using: .utf8) else {
                continue
            }
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                return true
            }
        }
        return false
    }
}
