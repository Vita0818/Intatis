import Foundation
import IntatisCore
import IntatisProtocol

/// A renderable item in a Code/Cowork thread — the fold of tool, permission, and
/// patch events (v0.2) plus messages. Pure and testable; SharedUI renders it.
public struct CodeItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case user, agent, toolCall, toolResult, patch, note, error, agentToAgent
    }
    public let id: String
    public var kind: Kind
    public var title: String
    public var body: String
    public var complete: Bool
    public var files: [String]

    public init(id: String, kind: Kind, title: String, body: String,
                complete: Bool = true, files: [String] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.complete = complete
        self.files = files
    }
}

/// Folds the event stream into `[CodeItem]`. `permission_request` is intentionally
/// not folded here — the pending request is surfaced separately as an actionable
/// card (the gate runs before execution).
public struct CodeProjection: Equatable, Sendable {
    public private(set) var items: [CodeItem] = []

    public init() {}

    public mutating func apply(_ envelope: Envelope) {
        switch envelope.event {
        case .userMessage(let p):
            items.append(CodeItem(id: freshID(), kind: .user, title: "You", body: p.text))

        case .messageDelta(let p):
            if let i = agentIndex(p.messageId.rawValue) {
                items[i].body += p.textDelta
            } else {
                items.append(CodeItem(id: p.messageId.rawValue, kind: .agent,
                                      title: p.agent?.rawValue ?? "Agent", body: p.textDelta, complete: false))
            }

        case .messageCompleted(let p):
            if let i = agentIndex(p.messageId.rawValue) {
                items[i].body = p.text
                items[i].complete = true
            } else {
                items.append(CodeItem(id: p.messageId.rawValue, kind: .agent,
                                      title: p.agent?.rawValue ?? "Agent", body: p.text))
            }

        case .toolCall(let p):
            items.append(CodeItem(id: p.toolCallId, kind: .toolCall, title: p.name, body: p.args))

        case .toolResult(let p):
            items.append(CodeItem(id: p.toolCallId + ":result", kind: .toolResult,
                                  title: "result", body: p.observation))

        case .patchProposed(let p):
            items.append(CodeItem(id: p.patchId, kind: .patch, title: "patch", body: p.diff, files: p.files))

        case .permissionResolved(let p):
            items.append(CodeItem(id: freshID(), kind: .note, title: "permission",
                                  body: "\(p.decision.rawValue): \(p.tool) — \(p.reason)"))

        case .error(let p):
            items.append(CodeItem(id: freshID(), kind: .error, title: "error", body: p.message))

        // v0.3 (Cowork)
        case .agentAttached(let p):
            items.append(CodeItem(id: freshID(), kind: .note, title: "agent",
                                  body: "+ @\(p.agent.rawValue) attached (\(p.path))"))

        case .agentDetached(let p):
            items.append(CodeItem(id: freshID(), kind: .note, title: "agent",
                                  body: "− @\(p.agent.rawValue) detached"))

        case .agentMessage(let p):
            items.append(CodeItem(id: p.messageId.rawValue, kind: .agent,
                                  title: p.agent.rawValue, body: p.content))

        case .agentToAgentMessage(let p):
            items.append(CodeItem(id: freshID(), kind: .agentToAgent,
                                  title: "\(p.from.rawValue) → \(p.to.rawValue)", body: p.content))

        case .permissionReview(let p):
            items.append(CodeItem(id: freshID(), kind: .note, title: "review",
                                  body: "reviewer(\(p.reviewerModel)): \(p.decision.rawValue) \(p.tool) — \(p.reason)"))

        case .artifactAdded(let p):
            items.append(CodeItem(id: p.artifactId.rawValue, kind: .note, title: "artifact",
                                  body: "📎 \(p.kind)" + (p.prompt.map { ": \($0)" } ?? "")))

        case .permissionRequest, .agentStatus, .artifactProgress, .turnStats:
            break
        }
    }

    public static func build(from envelopes: [Envelope]) -> CodeProjection {
        var p = CodeProjection()
        for e in envelopes { p.apply(e) }
        return p
    }

    private func agentIndex(_ id: String) -> Int? {
        items.firstIndex { $0.id == id && $0.kind == .agent }
    }

    private func freshID() -> String { IDGen.random(prefix: "item", length: 10) }
}
