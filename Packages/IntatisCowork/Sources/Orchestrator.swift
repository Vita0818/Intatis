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
    private let reasoningEffort: ReasoningEffort?
    private let includeUsage: Bool
    private let maxSteps: Int
    private let providerFor: @Sendable (Agent) async throws -> ToolCallingProvider

    public init(log: EventLog,
                mediator: Mediator = Mediator(),
                engine: PermissionEngine = PermissionEngine(),
                allowsShell: Bool,
                responder: PermissionResponder,
                reasoningEffort: ReasoningEffort? = nil,
                includeUsage: Bool = false,
                maxSteps: Int = 50,
                providerFor: @escaping @Sendable (Agent) async throws -> ToolCallingProvider) {
        self.log = log
        self.registry = AgentRegistry()
        self.bus = MessageBus(log: log, mediator: mediator)
        self.engine = engine
        self.allowsShell = allowsShell
        self.responder = responder
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage
        self.maxSteps = maxSteps
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
    public func agentList() -> [Agent] { registry.all() }

    /// Route a user message to the `@mentioned` agent, or the first attached agent.
    public func send(_ text: String, to: AgentID? = nil, images: [ImageAttachment] = []) async {
        let target = to.flatMap { registry.agent($0) } ?? registry.all().first
        guard let agent = target else {
            try? await log.append(.error(ErrorPayload(code: "no_agent", message: "no agent attached")))
            return
        }
        // AgentLoop appends the user message itself — don't double-log it here.
        _ = try? await run(agent, input: text, images: images)
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

    // MARK: - Coordinator tools (a lead agent spawns / lists / removes sub-agents)

    /// Create and attach a new sub-agent bound to `path`. Returns a status line
    /// the calling (coordinator) agent can read back.
    func spawnFromTool(name: String, path: String, model: String) async -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "error: an agent name is required" }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return "error: not a folder: \(url.path)"
        }
        let id = AgentID(rawValue: trimmed)
        if registry.agent(id) != nil { return "error: an agent named @\(trimmed) already exists" }
        await attach(Agent(name: id, workspaceRoot: url,
                           model: ModelID(rawValue: model), profile: .reviewed))
        return "spawned @\(trimmed) · model \(model) · \(url.path)"
    }

    /// One line per active agent, for the coordinator to read.
    func listForTool() -> String {
        let all = registry.all()
        guard !all.isEmpty else { return "(no agents)" }
        return all.map { "@\($0.name.rawValue) · \($0.model.rawValue) · \($0.workspaceRoot.path)" }
            .joined(separator: "\n")
    }

    /// Detach a sub-agent. `@main` is protected so the user always keeps a coordinator.
    func removeFromTool(name: String) async -> String {
        let id = AgentID(rawValue: name)
        guard registry.agent(id) != nil else { return "error: no agent named @\(name)" }
        if name == "main" { return "error: cannot remove @main" }
        await detach(id)
        return "removed @\(name)"
    }

    private func run(_ agent: Agent, input: String, images: [ImageAttachment] = []) async throws -> String {
        let provider = try await providerFor(agent)
        let messenger = BusMessenger(from: agent.name, orchestrator: self)
        let manager = OrchestratorManager(orchestrator: self, defaultModel: agent.model.rawValue)
        // Only coordinators get the team-building tools. Tool-spawned workers get
        // the standard toolset, so they do the task and report back instead of
        // recursively spawning their own sub-teams.
        let toolRegistry = agent.canCoordinate
            ? ToolRegistry.standard().adding([AskAgentTool(), SpawnAgentTool(), ListAgentsTool(), RemoveAgentTool()])
            : ToolRegistry.standard()
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: toolRegistry,
            engine: engine,
            responder: responder,
            agent: agent,
            allowsShell: allowsShell,
            messenger: messenger,
            agentManager: manager,
            reasoningEffort: reasoningEffort,
            includeUsage: includeUsage,
            maxIterations: maxSteps
        )
        return try await loop.send(input, images: images)
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

/// Coordinator seam handed to each agent's loop; routes lifecycle calls through
/// the orchestrator actor (and thus its registry + event log). `defaultModel` is
/// the spawning agent's model, used when the tool call omits one.
struct OrchestratorManager: AgentManager {
    let orchestrator: Orchestrator
    let defaultModel: String

    func spawnAgent(name: String, path: String, model: String?) async -> String {
        await orchestrator.spawnFromTool(name: name, path: path, model: model ?? defaultModel)
    }
    func listAgents() async -> String { await orchestrator.listForTool() }
    func removeAgent(name: String) async -> String { await orchestrator.removeFromTool(name: name) }
}
