#if canImport(SwiftUI)
import SwiftUI
import Combine
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel
import IntatisCowork
import IntatisSharedUI

/// Drives a Cowork session: owns the `Orchestrator`, folds the shared event log
/// into items + an agent roster, parses `@mention` routing, and serves as the
/// `PermissionResponder` for whichever agent is currently acting.
@MainActor
final class CoworkViewModel: ObservableObject, PermissionResponder {
    @Published private(set) var items: [CodeItem] = []
    @Published private(set) var agents: [CoworkAgentInfo] = []
    @Published var input: String = ""
    @Published private(set) var isWorking = false
    @Published var pendingPermission: PermissionRequestPayload?

    private let log: EventLog
    private let registry: ProviderRegistry
    private var orchestrator: Orchestrator?
    private var subscription: Task<Void, Never>?
    private var permissionContinuation: CheckedContinuation<PermissionDecision, Never>?

    init(log: EventLog, registry: ProviderRegistry) {
        self.log = log
        self.registry = registry
    }

    func start() {
        guard orchestrator == nil else { return }
        let reg = registry
        orchestrator = Orchestrator(log: log, allowsShell: PlatformProfile.current.allowsShell, responder: self) { _ in
            try await reg.defaultAgentProvider()
        }
        subscription = Task { @MainActor [weak self] in
            guard let self else { return }
            let replayed = await self.log.replay()
            var projection = CodeProjection.build(from: replayed)
            var permissions = PermissionProjection.build(from: replayed, markNeedsRerun: true)
            self.items = projection.items
            self.pendingPermission = permissions.latest?.request
            for envelope in replayed {
                self.applyRosterEvent(envelope.event)
            }
            let stream = await self.log.stream(from: (replayed.last?.seq ?? -1) + 1)
            for await envelope in stream {
                projection.apply(envelope)
                permissions.apply(envelope)
                self.items = projection.items
                self.pendingPermission = permissions.latest?.request
                self.applyRosterEvent(envelope.event)
            }
        }
    }

    private func applyRosterEvent(_ event: Event) {
        switch event {
        case .agentAttached(let p):
            agents.removeAll { $0.id == p.agent.rawValue }
            agents.append(CoworkAgentInfo(id: p.agent.rawValue, name: p.agent.rawValue,
                                          workspace: p.path, model: p.model.rawValue, profile: p.profile))
        case .agentSpawned(let p):
            agents.removeAll { $0.id == p.agent.rawValue }
            agents.append(CoworkAgentInfo(id: p.agent.rawValue, name: p.agent.rawValue,
                                          workspace: p.path, model: p.model.rawValue, profile: "reviewed"))
        case .agentDetached(let p):
            agents.removeAll { $0.id == p.agent.rawValue }
        default:
            break
        }
    }

    func addAgent(name: String, workspace: URL) {
        guard let orchestrator else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let model = await self.registry.agentModel()
            await orchestrator.attach(Agent(name: AgentID(rawValue: name), workspaceRoot: workspace,
                                            model: model, profile: .reviewed,
                                            coordinationDepth: Agent.defaultCoordinationDepth))
        }
    }

    func send() {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !isWorking, let orchestrator else { return }
        var text = raw
        var to: AgentID?
        if raw.hasPrefix("@") {
            let parts = raw.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if let nameSub = parts.first {
                to = AgentID(rawValue: String(nameSub))
                text = parts.count > 1 ? String(parts[1]) : ""
            }
        }
        input = ""
        isWorking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await orchestrator.send(text, to: to)
            self.isWorking = false
        }
    }

    // MARK: PermissionResponder

    nonisolated func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await withCheckedContinuation { (continuation: CheckedContinuation<PermissionDecision, Never>) in
            Task { @MainActor in
                self.pendingPermission = request
                self.permissionContinuation = continuation
            }
        }
    }

    func resolvePermission(_ decision: PermissionDecision) {
        guard let continuation = permissionContinuation else {
            guard let request = pendingPermission else { return }
            pendingPermission = nil
            Task { [log] in
                try? await log.append(.permissionResolved(PermissionResolvedPayload(
                    requestId: request.requestId,
                    tool: request.tool,
                    decision: .deny,
                    risk: request.risk,
                    reason: "permission request expired; rerun the task")))
            }
            return
        }
        pendingPermission = nil
        continuation.resume(returning: decision)
        permissionContinuation = nil
    }
}
#endif
