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

        case .agentAttachRequested(let p):
            items.append(CodeItem(id: freshID(), kind: .note, title: "agent attach requested",
                                  body: "@\(p.agent.rawValue): \(p.path)"))

        case .agentDetached(let p):
            items.append(CodeItem(id: freshID(), kind: .note, title: "agent",
                                  body: "− @\(p.agent.rawValue) detached"))

        case .agentSpawnRequested(let p):
            items.append(CodeItem(id: freshID(), kind: .note, title: "agent spawn requested",
                                  body: "@\(p.agent.rawValue): \(p.path)"))

        case .agentSpawned(let p):
            items.append(CodeItem(id: freshID(), kind: .note, title: "agent spawned",
                                  body: "@\(p.agent.rawValue): \(p.path)"))

        case .agentMessage(let p):
            let title = p.from.flatMap { from in p.to.map { "\(from.rawValue) -> \($0.rawValue)" } }
                ?? p.agent.rawValue
            items.append(CodeItem(id: p.messageId.rawValue, kind: .agent,
                                  title: title, body: p.content))

        case .agentToAgentMessage(let p):
            items.append(CodeItem(id: freshID(), kind: .agentToAgent,
                                  title: "\(p.from.rawValue) → \(p.to.rawValue)", body: p.content))

        case .informationRequested(let p):
            items.append(CodeItem(id: p.requestID.rawValue, kind: .agentToAgent,
                                  title: "info \(p.from.rawValue) -> \(p.to.rawValue)", body: p.question))

        case .informationReplied(let p):
            items.append(CodeItem(id: p.replyID.rawValue, kind: .agentToAgent,
                                  title: "reply \(p.from.rawValue) -> \(p.to.rawValue)", body: p.content))

        case .delegationRequested(let p):
            items.append(CodeItem(id: p.requestID.rawValue, kind: .note, title: "delegation requested",
                                  body: "\(p.requester.rawValue): \(p.objective) — \(p.reason)"))

        case .delegationApproved(let p):
            items.append(CodeItem(id: freshID(), kind: .note, title: "delegation approved",
                                  body: "@\(p.contract.assignee.rawValue): \(p.contract.objective)"))

        case .delegationRejected(let p):
            items.append(CodeItem(id: freshID(), kind: .error, title: "delegation rejected",
                                  body: "\(p.objective) — \(p.reason)"))

        case .taskDelegated(let p):
            items.append(CodeItem(id: p.contract.id.rawValue + ":delegated", kind: .note, title: "task delegated",
                                  body: "@\(p.assignee.rawValue): \(p.contract.objective)"))

        case .workspaceLeaseRequested(let p):
            items.append(CodeItem(id: freshID(), kind: .note, title: "workspace lease requested",
                                  body: "\(p.access.rawValue): \(p.rootPath)"))

        case .workspaceLeaseGranted(let p):
            items.append(CodeItem(id: p.lease.id.rawValue, kind: .note, title: "workspace lease",
                                  body: "\(p.lease.access.rawValue): \(p.lease.rootPath)"))

        case .workspaceLeaseDenied(let p):
            items.append(CodeItem(id: freshID(), kind: .error, title: "workspace lease denied",
                                  body: "\(p.rootPath) — \(p.reason)"))

        case .capabilityLeaseCreated(let p):
            items.append(CodeItem(id: p.lease.id.rawValue, kind: .note, title: "capability lease",
                                  body: p.lease.tools.map(\.rawValue).sorted().joined(separator: ", ")))

        case .capabilityLeaseRevoked(let p):
            items.append(CodeItem(id: p.leaseID.rawValue + ":revoked", kind: .note, title: "capability lease revoked",
                                  body: p.reason))

        case .permissionReview(let p):
            items.append(CodeItem(id: freshID(), kind: .note, title: "review",
                                  body: "reviewer(\(p.reviewerModel)): \(p.decision.rawValue) \(p.tool) — \(p.reason)"))

        case .taskCreated(let p):
            items.append(CodeItem(id: p.contract.id.rawValue, kind: .note, title: "task",
                                  body: "created \(p.contract.roleHint): \(p.contract.objective)"))

        case .taskAssigned(let p):
            items.append(CodeItem(id: p.contract.id.rawValue + ":assigned", kind: .note, title: "task",
                                  body: "assigned @\(p.contract.assignee.rawValue): \(p.contract.expectedDeliverable)"))

        case .taskQueued(let p):
            items.append(CodeItem(id: p.contract.id.rawValue + ":queued", kind: .note, title: "task",
                                  body: "queued @\(p.assignee.rawValue): \(p.contract.objective)"))

        case .taskStarted(let p):
            items.append(CodeItem(id: p.taskID.rawValue + ":started", kind: .note, title: "task",
                                  body: "started @\(p.agent.rawValue)"))

        case .taskCompleted(let p):
            items.append(CodeItem(id: p.taskID.rawValue + ":completed", kind: .agent,
                                  title: p.agent.rawValue, body: p.result))

        case .taskFailed(let p):
            items.append(CodeItem(id: p.taskID.rawValue + ":failed", kind: .error,
                                  title: p.agent.rawValue, body: p.error))

        case .taskRejected(let p):
            items.append(CodeItem(id: p.contract?.id.rawValue ?? freshID(), kind: .error,
                                  title: "task rejected", body: "\(p.objective) — \(p.reason)"))

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

public enum PendingPermissionState: String, Equatable, Sendable {
    case active
    case needsRerun = "needs_rerun"
}

public struct PendingPermission: Identifiable, Equatable, Sendable {
    public var id: RequestID { request.requestId }
    public var request: PermissionRequestPayload
    public var state: PendingPermissionState
    public var requestedSeq: Int

    public init(request: PermissionRequestPayload,
                state: PendingPermissionState = .active,
                requestedSeq: Int) {
        self.request = request
        self.state = state
        self.requestedSeq = requestedSeq
    }
}

/// Folds permission request/resolution events into recoverable pending state.
/// A replayed pending request may no longer have a live async tool continuation;
/// callers can mark it `needs_rerun` while still showing it in the UI.
public struct PermissionProjection: Equatable, Sendable {
    public private(set) var pending: [PendingPermission] = []

    public init() {}

    public mutating func apply(_ envelope: Envelope) {
        switch envelope.event {
        case .permissionRequest(let request):
            upsert(PendingPermission(request: request, requestedSeq: envelope.seq))
        case .permissionResolved(let resolved):
            guard let requestID = resolved.requestId else { return }
            pending.removeAll { $0.request.requestId == requestID }
        default:
            break
        }
    }

    public mutating func markNeedsRerun() {
        pending = pending.map {
            var item = $0
            item.state = .needsRerun
            item.request.reason += " (needs rerun)"
            return item
        }
    }

    public var latest: PendingPermission? {
        pending.sorted { $0.requestedSeq < $1.requestedSeq }.last
    }

    public static func build(from envelopes: [Envelope], markNeedsRerun: Bool = false) -> PermissionProjection {
        var p = PermissionProjection()
        for e in envelopes { p.apply(e) }
        if markNeedsRerun { p.markNeedsRerun() }
        return p
    }

    private mutating func upsert(_ item: PendingPermission) {
        pending.removeAll { $0.request.requestId == item.request.requestId }
        pending.append(item)
    }
}
