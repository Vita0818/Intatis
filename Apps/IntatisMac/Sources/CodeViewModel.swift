#if canImport(SwiftUI)
import SwiftUI
import Combine
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel

/// Drives a single-workspace Code session: subscribes to the event log, folds it
/// into `CodeItem`s, runs the `AgentLoop`, and acts as the `PermissionResponder`
/// (bridging `ask_user` to the on-screen permission card).
@MainActor
final class CodeViewModel: ObservableObject, PermissionResponder {
    @Published private(set) var items: [CodeItem] = []
    @Published var input: String = ""
    @Published private(set) var isWorking = false
    @Published private(set) var agentState: String = "idle"
    @Published var pendingPermission: PermissionRequestPayload?

    let workspaceName: String

    private let workspaceRoot: URL
    private let log: EventLog
    private let registry: ProviderRegistry
    private var subscription: Task<Void, Never>?
    private var permissionContinuation: CheckedContinuation<PermissionDecision, Never>?

    init(workspaceRoot: URL, log: EventLog, registry: ProviderRegistry) {
        self.workspaceRoot = workspaceRoot
        self.workspaceName = workspaceRoot.lastPathComponent
        self.log = log
        self.registry = registry
    }

    func start() {
        guard subscription == nil else { return }
        subscription = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.log.stream(from: 0)
            var projection = CodeProjection()
            for await envelope in stream {
                projection.apply(envelope)
                self.items = projection.items
                if case .agentStatus(let p) = envelope.event { self.agentState = p.state.rawValue }
            }
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        input = ""
        isWorking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let provider = try await self.registry.defaultAgentProvider()
                let model = await self.registry.agentModel()
                let agent = Agent(name: AgentID(rawValue: "Coder"),
                                  workspaceRoot: self.workspaceRoot,
                                  model: model,
                                  profile: .reviewed)
                let loop = AgentLoop(
                    log: self.log,
                    provider: provider,
                    registry: .standard(),
                    engine: PermissionEngine(),
                    responder: self,
                    agent: agent,
                    allowsShell: PlatformProfile.current.allowsShell
                )
                try await loop.send(text)
            } catch {
                try? await self.log.append(.error(ErrorPayload(code: "agent", message: error.localizedDescription)))
            }
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
