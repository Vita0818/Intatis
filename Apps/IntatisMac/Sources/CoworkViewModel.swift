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
            let stream = await self.log.stream(from: 0)
            var projection = CodeProjection()
            for await envelope in stream {
                projection.apply(envelope)
                self.items = projection.items
                switch envelope.event {
                case .agentAttached(let p):
                    self.agents.append(CoworkAgentInfo(id: p.agent.rawValue, name: p.agent.rawValue,
                                                       workspace: p.path, model: p.model.rawValue, profile: p.profile))
                case .agentDetached(let p):
                    self.agents.removeAll { $0.id == p.agent.rawValue }
                default:
                    break
                }
            }
        }
    }

    func addAgent(name: String, workspace: URL) {
        guard let orchestrator else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let model = await self.registry.agentModel()
            await orchestrator.attach(Agent(name: AgentID(rawValue: name), workspaceRoot: workspace,
                                            model: model, profile: .reviewed, canCoordinate: true))
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
        pendingPermission = nil
        permissionContinuation?.resume(returning: decision)
        permissionContinuation = nil
    }
}
#endif
