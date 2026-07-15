import Foundation

/// A deterministic, host-side classification used only to decide whether a
/// normal Cowork turn may expose explicit Goal-creation intent to the runtime.
///
/// This is deliberately narrower than general natural-language understanding:
/// a request must both ask to create/set something as a Goal and explicitly
/// describe that Goal as persistent/ongoing. Merely mentioning a goal, stating
/// a complex objective, or asking to create an ordinary one-shot goal remains a
/// normal user turn.
public enum ExplicitGoalIntentClassification: Equatable, Sendable {
    case ordinaryTurn
    case createPersistentGoal

    public var isExplicit: Bool {
        self == .createPersistentGoal
    }
}

public enum ExplicitGoalIntentClassifier {
    public static func classify(_ rawInput: String) -> ExplicitGoalIntentClassification {
        let input = normalized(rawInput)
        guard !input.isEmpty else { return .ordinaryTurn }

        if englishPatterns.contains(where: { input.matches(regularExpression: $0) })
            || chinesePatterns.contains(where: { input.matches(regularExpression: $0) }) {
            return .createPersistentGoal
        }
        return .ordinaryTurn
    }

    private static let englishRequestPrefix =
        #"(?:(?:please|kindly)\s+|(?:can|could|would|will)\s+you\s+(?:please\s+)?|i\s+(?:want|need)\s+you\s+to\s+|i(?:'|’)d\s+like\s+you\s+to\s+)?"#
    private static let englishPersistence =
        #"(?:ongoing|persistent|continuous|continuing|durable|long[- ]term|long[- ]running)"#

    private static var englishPatterns: [String] {
        [
            #"^\#(englishRequestPrefix)(?:set|mark|record|register|create|keep|treat)\s+.+\s+as\s+(?:(?:an?|the|my)\s+)?\#(englishPersistence)\s+goal[.!?]?$"#,
            #"^\#(englishRequestPrefix)(?:make|turn)\s+.+\s+(?:into\s+)?(?:(?:an?|the|my)\s+)?\#(englishPersistence)\s+goal[.!?]?$"#,
            #"^\#(englishRequestPrefix)(?:create|establish|start)\s+(?:(?:an?|the|my)\s+)?\#(englishPersistence)\s+goal(?:\s*[:\-]\s*|\s+(?:to|for)\s+).+[.!?]?$"#,
        ]
    }

    private static let chineseRequestPrefix =
        #"(?:(?:请|请你|麻烦|麻烦你|我想让你|我希望你|能否|可以请你)\s*)?"#
    private static let chinesePersistence =
        #"(?:持续(?:性)?|长期|持久|连续(?:性)?|可延续)"#

    private static var chinesePatterns: [String] {
        [
            #"^\#(chineseRequestPrefix)(?:把|将)\s*.+\s*(?:设成|设为|设置成|设置为|定义为|标记为|登记为|作为|创建为)\s*(?:(?:一个|我的|该)\s*)?\#(chinesePersistence)\s*(?:目标|goal)[。！？!?]?$"#,
            #"^\#(chineseRequestPrefix)(?:创建|建立|新增|开启)\s*(?:(?:一个|我的|该)\s*)?\#(chinesePersistence)\s*目标\s*(?:[:：—-]\s*|(?:来|以|用于|用来|以便)\s*).+[。！？!?]?$"#,
        ]
    }

    private static func normalized(_ input: String) -> String {
        input
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private extension String {
    func matches(regularExpression pattern: String) -> Bool {
        range(of: pattern, options: [.regularExpression]) != nil
    }
}
