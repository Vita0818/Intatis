import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation

/// The single-agent tool loop (ARCHITECTURE.md §3.9, §6.1). It only orchestrates:
/// build context → stream model → for each tool call run the permission pipeline
/// → execute → feed the observation back → repeat until the model stops calling
/// tools. Every state change is appended to the event log.
public struct AgentLoop: Sendable {
    private let log: EventLog
    private let provider: ToolCallingProvider
    private let registry: ToolRegistry
    private let engine: PermissionEngine
    private let responder: PermissionResponder
    private let agent: Agent
    private let context: ContextBuilder
    private let allowsShell: Bool
    private let shell: ShellRunner
    private let git: GitService
    private let messenger: AgentMessenger?
    private let agentManager: AgentManager?
    private let reasoningEffort: ReasoningEffort?
    private let includeUsage: Bool
    private let maxIterations: Int

    public init(log: EventLog,
                provider: ToolCallingProvider,
                registry: ToolRegistry,
                engine: PermissionEngine,
                responder: PermissionResponder,
                agent: Agent,
                context: ContextBuilder = ContextBuilder(),
                allowsShell: Bool,
                shell: ShellRunner = ProcessShellRunner(),
                git: GitService = ProcessGitService(),
                messenger: AgentMessenger? = nil,
                agentManager: AgentManager? = nil,
                reasoningEffort: ReasoningEffort? = nil,
                includeUsage: Bool = false,
                maxIterations: Int = 50) {
        self.log = log
        self.provider = provider
        self.registry = registry
        self.engine = engine
        self.responder = responder
        self.agent = agent
        self.context = context
        self.allowsShell = allowsShell
        self.shell = shell
        self.git = git
        self.messenger = messenger
        self.agentManager = agentManager
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage
        self.maxIterations = maxIterations
    }

    /// Runs the loop and returns the agent's final text answer (empty if it ran
    /// out of iterations). Discardable for fire-and-forget UI sends.
    @discardableResult
    public func send(_ userText: String, images: [ImageAttachment] = []) async throws -> String {
        let history = await priorHistory()
        try await log.append(.userMessage(UserMessagePayload(text: userText)))
        try await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .thinking)))

        var convo = context.initialMessages(history: history, userText: userText, userImages: images)
        let specs = context.toolSpecs(registry)
        let start = Date()
        var firstTokenAt: Date?
        var usage: Usage?

        do {
        for _ in 0..<maxIterations {
            var assistantText = ""
            var pendingToolCalls: [ToolCall] = []
            let assistantID = MessageID.new()

            let request = AgentRequest(model: agent.model, messages: convo, tools: specs,
                                       reasoningEffort: reasoningEffort, includeUsage: includeUsage)
            for try await chunk in provider.stream(request) {
                switch chunk {
                case .textDelta(let d):
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    assistantText += d
                    try await log.append(.messageDelta(
                        MessageDeltaPayload(messageId: assistantID, role: .agent, agent: agent.name, textDelta: d)))
                case .toolCalls(let calls):
                    pendingToolCalls = calls
                case .usage(let u):
                    usage = Usage(
                        promptTokens: (usage?.promptTokens ?? 0) + (u.promptTokens ?? 0),
                        completionTokens: (usage?.completionTokens ?? 0) + (u.completionTokens ?? 0),
                        totalTokens: (usage?.totalTokens ?? 0) + (u.totalTokens ?? 0))
                case .done:
                    break
                }
            }

            if !assistantText.isEmpty {
                try await log.append(.messageCompleted(
                    MessageCompletedPayload(messageId: assistantID, role: .agent, agent: agent.name, text: assistantText)))
            }

            if pendingToolCalls.isEmpty {
                await appendTurnStats(start: start, firstTokenAt: firstTokenAt, usage: usage)
                try await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .idle)))
                return assistantText  // final answer
            }

            convo.append(.assistant(toolCalls: pendingToolCalls, content: assistantText.isEmpty ? nil : assistantText))
            for toolCall in pendingToolCalls {
                let observation = await runTool(toolCall)
                convo.append(.tool(id: toolCall.id, content: observation))
            }
        }

        await appendTurnStats(start: start, firstTokenAt: firstTokenAt, usage: usage)
        try await log.append(.error(ErrorPayload(code: "max_iterations",
                                                  message: "agent exceeded max tool iterations")))
        try await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .idle)))
        return ""
        } catch {
            // Surface provider/stream/tool errors instead of failing silently.
            try? await log.append(.error(ErrorPayload(code: "agent", message: error.localizedDescription)))
            try? await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .idle)))
            return ""
        }
    }

    private func appendTurnStats(start: Date, firstTokenAt: Date?, usage: Usage?) async {
        let now = Date()
        try? await log.append(.turnStats(TurnStatsPayload(
            promptTokens: usage?.promptTokens,
            completionTokens: usage?.completionTokens,
            totalTokens: usage?.totalTokens,
            ttftMillis: firstTokenAt.map { Int($0.timeIntervalSince(start) * 1000) },
            totalMillis: Int(now.timeIntervalSince(start) * 1000),
            model: agent.model.rawValue)))
    }

    // MARK: - Tool execution with permission

    private func runTool(_ toolCall: ToolCall) async -> String {
        try? await log.append(.toolCall(ToolCallPayload(
            toolCallId: toolCall.id, agent: agent.name, name: toolCall.name, args: toolCall.arguments)))

        guard let tool = registry.tool(named: toolCall.name) else {
            let message = "unknown tool: \(toolCall.name)"
            try? await log.append(.toolResult(ToolResultPayload(toolCallId: toolCall.id, observation: message)))
            return message
        }

        let args = ToolArgs(raw: toolCall.arguments)
        let descriptor = type(of: tool).descriptor
        let callContext = ToolCallContext(
            toolName: descriptor.name,
            sideEffect: descriptor.sideEffect,
            touchedPaths: tool.touchedPaths(args),
            risksNetwork: tool.risksNetwork(args),
            rawArgs: toolCall.arguments)
        let permissionContext = PermissionContext(
            workspaceRoot: agent.workspaceRoot,
            profile: agent.profile,
            allowsShell: allowsShell,
            agent: agent.name)

        let outcome = await engine.decide(callContext, permissionContext)
        let finalDecision = await settle(outcome, descriptor: descriptor, toolCall: toolCall)

        guard finalDecision == .allow else {
            let message = "permission denied: \(outcome.reason)"
            try? await log.append(.toolResult(ToolResultPayload(toolCallId: toolCall.id, observation: message)))
            return message
        }

        do {
            let toolContext = ToolContext(workspaceRoot: agent.workspaceRoot, shell: shell, git: git, messenger: messenger, agentManager: agentManager)
            let observation = try await tool.execute(args, in: toolContext)
            if let diff = observation.diff, let files = observation.changedFiles {
                try? await log.append(.patchProposed(PatchProposedPayload(
                    patchId: IDGen.random(prefix: "patch"), agent: agent.name, files: files, diff: diff)))
            }
            try? await log.append(.toolResult(ToolResultPayload(
                toolCallId: toolCall.id, observation: observation.text, truncated: observation.truncated)))
            return observation.text
        } catch {
            let message = "tool error: \(error.localizedDescription)"
            try? await log.append(.toolResult(ToolResultPayload(toolCallId: toolCall.id, observation: message)))
            return message
        }
    }

    /// Emit the right audit events and, for `ask_user`, await the responder.
    private func settle(_ outcome: PermissionOutcome,
                        descriptor: ToolDescriptor,
                        toolCall: ToolCall) async -> PermissionDecision {
        switch outcome.decision {
        case .allow, .deny:
            try? await log.append(.permissionResolved(PermissionResolvedPayload(
                tool: descriptor.name, decision: outcome.decision, risk: outcome.risk, reason: outcome.reason)))
            return outcome.decision

        case .askUser:
            let requestID = RequestID.new()
            let request = PermissionRequestPayload(
                requestId: requestID, agent: agent.name, tool: descriptor.name,
                args: toolCall.arguments, risk: outcome.risk, reason: outcome.reason)
            try? await log.append(.permissionRequest(request))
            try? await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .blocked)))

            let userDecision = await responder.requestApproval(request)
            try? await log.append(.permissionResolved(PermissionResolvedPayload(
                requestId: requestID, tool: descriptor.name, decision: userDecision, risk: outcome.risk,
                reason: userDecision == .allow ? "user approved" : "user denied")))
            try? await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .tool)))
            return userDecision
        }
    }

    private func priorHistory() async -> [AgentMessage] {
        let projection = ConversationProjection.build(from: await log.replay())
        return projection.messages.compactMap { m in
            switch m.role {
            case .user:
                return .user(m.text)
            case .assistant, .agent:
                return m.isComplete ? .assistant(m.text) : nil
            case .system:
                return nil
            }
        }
    }
}
