import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel

/// Coordinates multiple agents over one shared event log (ARCHITECTURE.md §7).
/// Routes `@mentioned` user messages to the right agent, and mediates every
/// agent-to-agent exchange through the Message Bus. An `actor`, so concurrent /
/// reentrant agent runs serialize safely.
public actor Orchestrator {
    private let log: EventLog
    private var registry: AgentRegistry
    private let bus: MessageBus
    private let engine: PermissionEngine
    private let allowsShell: Bool
    private let responder: PermissionResponder
    private let providerFor: @Sendable (Agent) async throws -> ToolCallingProvider

    public init(log: EventLog,
                mediator: Mediator = Mediator(),
                engine: PermissionEngine = PermissionEngine(),
                allowsShell: Bool,
                responder: PermissionResponder,
                providerFor: @escaping @Sendable (Agent) async throws -> ToolCallingProvider) {
        self.log = log
        self.registry = AgentRegistry()
        self.bus = MessageBus(log: log, mediator: mediator)
        self.engine = engine
        self.allowsShell = allowsShell
        self.responder = responder
        self.providerFor = providerFor
    }

    public func attach(_ agent: Agent) async {
        registry.add(agent)
        try? await log.append(.agentAttached(AgentAttachedPayload(
            agent: agent.name, path: agent.workspaceRoot.path, model: agent.model, profile: agent.profile.rawValue)))
    }

    public func detach(_ name: AgentID) async {
        registry.remove(name)
        try? await log.append(.agentDetached(AgentDetachedPayload(agent: name)))
    }

    public func agentNames() -> [AgentID] { registry.names }

    /// Route a user message to the `@mentioned` agent, or the first attached agent.
    public func send(_ text: String, to: AgentID? = nil) async {
        let target = to.flatMap { registry.agent($0) } ?? registry.all().first
        guard let agent = target else {
            try? await log.append(.error(ErrorPayload(code: "no_agent", message: "no agent attached")))
            return
        }
        try? await log.append(.userMessage(UserMessagePayload(text: text, to: agent.name)))
        _ = try? await run(agent, input: text)
    }

    /// Called by `BusMessenger` when `from` asks the agent named `toName`.
    func ask(from: AgentID, to toName: String, question: String) async -> String {
        let to = AgentID(rawValue: toName)
        guard let toAgent = registry.agent(to) else { return "no such agent: \(toName)" }
        guard let forwardedQuestion = await bus.deliver(from: from, to: to, content: question) else {
            return "your message was blocked by the mediator"
        }
        let answer = (try? await run(toAgent, input: forwardedQuestion)) ?? ""
        guard let forwardedAnswer = await bus.deliver(from: to, to: from, content: answer) else {
            return "the reply was blocked by the mediator"
        }
        return forwardedAnswer
    }

    private func run(_ agent: Agent, input: String) async throws -> String {
        let provider = try await providerFor(agent)
        let messenger = BusMessenger(from: agent.name, orchestrator: self)
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: ToolRegistry.standard().adding([AskAgentTool()]),
            engine: engine,
            responder: responder,
            agent: agent,
            allowsShell: allowsShell,
            messenger: messenger
        )
        return try await loop.send(input)
    }
}

/// Per-agent messenger handed to each agent's loop; binds `from` and routes
/// through the orchestrator (and thus the mediated bus).
struct BusMessenger: AgentMessenger {
    let from: AgentID
    let orchestrator: Orchestrator

    func ask(to agent: String, question: String) async -> String {
        await orchestrator.ask(from: from, to: agent, question: question)
    }
}
