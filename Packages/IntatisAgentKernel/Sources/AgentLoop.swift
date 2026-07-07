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
    private let imageGenerator: ImageGenerationToolService?
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
                imageGenerator: ImageGenerationToolService? = nil,
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
        self.imageGenerator = imageGenerator
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage
        self.maxIterations = maxIterations
    }

    /// Runs the loop and returns the agent's final text answer (empty if it ran
    /// out of iterations). Discardable for fire-and-forget UI sends.
    @discardableResult
    public func send(_ userText: String,
                     images: [ImageAttachment] = [],
                     userMessage: UserMessagePayload? = nil) async throws -> String {
        let history = await projectedHistory()
        try await log.append(.userMessage(userMessage ?? UserMessagePayload(text: userText)))
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
            var responseUsage: Usage?
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
                    responseUsage = Usage.merging(responseUsage, with: u)
                case .done:
                    break
                }
            }
            usage = Usage.adding(usage, responseUsage)

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
            try? await log.append(.error(RuntimeErrorPresentation.payload(for: error, fallbackCode: "agent")))
            try? await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .idle)))
            throw error
        }
    }

    private func appendTurnStats(start: Date, firstTokenAt: Date?, usage: Usage?) async {
        let now = Date()
        try? await log.append(.turnStats(TurnStatsPayload(
            promptTokens: usage?.promptTokens,
            cachedPromptTokens: usage?.cachedPromptTokens,
            completionTokens: usage?.completionTokens,
            totalTokens: usage?.totalTokens,
            contextWindowTokens: usage?.contextWindowTokens,
            ttftMillis: firstTokenAt.map { Int($0.timeIntervalSince(start) * 1000) },
            totalMillis: Int(now.timeIntervalSince(start) * 1000),
            model: agent.model.rawValue)))
    }

    // MARK: - Tool execution with permission

    private func runTool(_ toolCall: ToolCall) async -> String {
        try? await log.append(.toolCall(ToolCallPayload(
            toolCallId: toolCall.id, agent: agent.name, name: toolCall.name, args: toolCall.arguments)))

        guard let tool = registry.tool(named: toolCall.name) else {
            let available = registry.descriptors().map(\.name).sorted().joined(separator: ", ")
            let message = available.isEmpty
                ? "unknown tool: \(toolCall.name)"
                : "unknown tool: \(toolCall.name). Available tools: \(available)"
            try? await log.append(.toolResult(ToolResultPayload(toolCallId: toolCall.id, observation: message)))
            return message
        }

        let descriptor = type(of: tool).descriptor
        let normalizedArguments: String
        switch normalizeToolArguments(toolCall.arguments, descriptor: descriptor) {
        case .valid(let arguments):
            normalizedArguments = arguments
        case .invalid(let message):
            try? await log.append(.toolResult(ToolResultPayload(toolCallId: toolCall.id, observation: message)))
            return message
        }

        let args = ToolArgs(raw: normalizedArguments)
        let callContext = ToolCallContext(
            toolName: descriptor.name,
            sideEffect: descriptor.sideEffect,
            touchedPaths: tool.touchedPaths(args),
            risksNetwork: tool.risksNetwork(args),
            rawArgs: normalizedArguments)
        let permissionContext = PermissionContext(
            workspaceRoot: agent.workspaceRoot,
            profile: agent.profile,
            allowsShell: allowsShell,
            agent: agent.name)

        let outcome = await engine.decide(callContext, permissionContext)
        let settled = await settle(outcome,
                                   descriptor: descriptor,
                                   toolCall: ToolCall(id: toolCall.id,
                                                      name: toolCall.name,
                                                      arguments: normalizedArguments))

        guard settled.decision == .allow else {
            let message = "permission denied: \(settled.reason)"
            try? await log.append(.toolResult(ToolResultPayload(toolCallId: toolCall.id, observation: message)))
            return message
        }

        do {
            try? await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .tool)))
            let toolContext = ToolContext(workspaceRoot: agent.workspaceRoot,
                                          shell: shell,
                                          git: git,
                                          messenger: messenger,
                                          agentManager: agentManager,
                                          imageGenerator: imageGenerator)
            let observation = try await tool.execute(args, in: toolContext)
            if let diff = observation.diff, let files = observation.changedFiles {
                try? await log.append(.patchProposed(PatchProposedPayload(
                    patchId: IDGen.random(prefix: "patch"), agent: agent.name, files: files, diff: diff)))
            }
            try? await log.append(.toolResult(ToolResultPayload(
                toolCallId: toolCall.id, observation: observation.text, truncated: observation.truncated)))
            return observation.text
        } catch {
            let message = "tool error: \(RuntimeErrorPresentation.message(for: error))"
            try? await log.append(.toolResult(ToolResultPayload(toolCallId: toolCall.id, observation: message)))
            return message
        }
    }

    private enum ToolArgumentNormalization {
        case valid(String)
        case invalid(String)
    }

    private func normalizeToolArguments(_ raw: String, descriptor: ToolDescriptor) -> ToolArgumentNormalization {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowsEmptyObject = requiredArguments(in: descriptor).isEmpty

        guard !trimmed.isEmpty else {
            if allowsEmptyObject {
                return .valid("{}")
            }
            return .invalid("invalid tool input: arguments for \(descriptor.name) must be a JSON object matching the tool schema; received empty arguments.")
        }

        guard let data = trimmed.data(using: .utf8) else {
            return .invalid("invalid tool input: arguments for \(descriptor.name) are not valid UTF-8.")
        }

        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            switch value {
            case .object(let object):
                if let message = validateToolArgumentObject(object, descriptor: descriptor) {
                    return .invalid(message)
                }
                return .valid(trimmed)
            case .null where allowsEmptyObject:
                return .valid("{}")
            default:
                return .invalid("invalid tool input: arguments for \(descriptor.name) must be a JSON object matching the tool schema.")
            }
        } catch {
            return .invalid("invalid tool input: arguments for \(descriptor.name) must be valid JSON. \(RuntimeErrorPresentation.message(for: error))")
        }
    }

    private func validateToolArgumentObject(_ object: [String: JSONValue], descriptor: ToolDescriptor) -> String? {
        let required = Set(requiredArguments(in: descriptor))
        let missing = required
            .filter { object[$0] == nil }
            .sorted()
        if !missing.isEmpty {
            let fields = missing.joined(separator: ", ")
            return "invalid tool input: arguments for \(descriptor.name) are missing required field(s): \(fields)."
        }

        if rejectsAdditionalProperties(in: descriptor) {
            let allowed = Set(propertyNames(in: descriptor))
            let unknown = object.keys
                .filter { !allowed.contains($0) }
                .sorted()
            if !unknown.isEmpty {
                let fields = unknown.joined(separator: ", ")
                let allowedText = allowed.isEmpty
                    ? "no fields"
                    : allowed.sorted().joined(separator: ", ")
                return "invalid tool input: arguments for \(descriptor.name) contain unknown field(s): \(fields). Allowed fields: \(allowedText)."
            }
        }

        for (name, value) in object.sorted(by: { $0.key < $1.key }) {
            guard let propertySchema = propertySchema(named: name, in: descriptor),
                  let expected = propertyType(in: propertySchema) else { continue }
            if value == .null, !required.contains(name) { continue }
            if !matches(value, expectedType: expected) {
                return "invalid tool input: argument \(name) for \(descriptor.name) must be \(expected)."
            }
            if let message = numericConstraintViolation(value, schema: propertySchema, name: name, descriptor: descriptor) {
                return message
            }
            if let message = stringConstraintViolation(value, schema: propertySchema, name: name, descriptor: descriptor) {
                return message
            }
        }
        return nil
    }

    private func requiredArguments(in descriptor: ToolDescriptor) -> [String] {
        guard case .object(let schema) = descriptor.parameters,
              case .array(let required)? = schema["required"] else {
            return []
        }
        return required.compactMap { value in
            guard case .string(let name) = value else { return nil }
            return name
        }
    }

    private func propertyNames(in descriptor: ToolDescriptor) -> [String] {
        guard case .object(let schema) = descriptor.parameters,
              case .object(let properties)? = schema["properties"] else {
            return []
        }
        return Array(properties.keys)
    }

    private func rejectsAdditionalProperties(in descriptor: ToolDescriptor) -> Bool {
        guard case .object(let schema) = descriptor.parameters,
              case .bool(let value)? = schema["additionalProperties"] else {
            return false
        }
        return value == false
    }

    private func propertySchema(named name: String, in descriptor: ToolDescriptor) -> [String: JSONValue]? {
        guard case .object(let schema) = descriptor.parameters,
              case .object(let properties)? = schema["properties"],
              case .object(let propertySchema)? = properties[name] else {
            return nil
        }
        return propertySchema
    }

    private func propertyType(in propertySchema: [String: JSONValue]) -> String? {
        guard case .string(let type)? = propertySchema["type"] else { return nil }
        return type
    }

    private func numericConstraintViolation(_ value: JSONValue,
                                            schema: [String: JSONValue],
                                            name: String,
                                            descriptor: ToolDescriptor) -> String? {
        guard case .number(let number) = value else { return nil }
        if case .number(let minimum)? = schema["minimum"], number < minimum {
            return "invalid tool input: argument \(name) for \(descriptor.name) must be >= \(formatJSONNumber(minimum))."
        }
        if case .number(let maximum)? = schema["maximum"], number > maximum {
            return "invalid tool input: argument \(name) for \(descriptor.name) must be <= \(formatJSONNumber(maximum))."
        }
        return nil
    }

    private func stringConstraintViolation(_ value: JSONValue,
                                           schema: [String: JSONValue],
                                           name: String,
                                           descriptor: ToolDescriptor) -> String? {
        guard case .string(let string) = value else { return nil }
        if let minLength = integerSchemaValue("minLength", in: schema), string.count < minLength {
            return "invalid tool input: argument \(name) for \(descriptor.name) must have at least \(formatCharacterCount(minLength))."
        }
        if let maxLength = integerSchemaValue("maxLength", in: schema), string.count > maxLength {
            return "invalid tool input: argument \(name) for \(descriptor.name) must have at most \(formatCharacterCount(maxLength))."
        }
        return nil
    }

    private func integerSchemaValue(_ key: String, in schema: [String: JSONValue]) -> Int? {
        guard case .number(let number)? = schema[key],
              number.rounded(.towardZero) == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            return nil
        }
        return Int(number)
    }

    private func formatJSONNumber(_ value: Double) -> String {
        if value.rounded(.towardZero) == value,
           value >= Double(Int.min),
           value <= Double(Int.max) {
            return String(Int(value))
        }
        return String(value)
    }

    private func formatCharacterCount(_ count: Int) -> String {
        count == 1 ? "1 character" : "\(count) characters"
    }

    private func matches(_ value: JSONValue, expectedType: String) -> Bool {
        switch expectedType {
        case "string":
            if case .string = value { return true }
            return false
        case "integer":
            guard case .number(let number) = value else { return false }
            return number.rounded(.towardZero) == number
        case "number":
            if case .number = value { return true }
            return false
        case "boolean":
            if case .bool = value { return true }
            return false
        case "array":
            if case .array = value { return true }
            return false
        case "object":
            if case .object = value { return true }
            return false
        default:
            return true
        }
    }

    private struct SettledPermission: Sendable {
        var decision: PermissionDecision
        var reason: String
    }

    /// Emit the right audit events and, for `ask_user`, await the responder.
    private func settle(_ outcome: PermissionOutcome,
                        descriptor: ToolDescriptor,
                        toolCall: ToolCall) async -> SettledPermission {
        switch outcome.decision {
        case .allow, .deny:
            try? await log.append(.permissionResolved(PermissionResolvedPayload(
                tool: descriptor.name, decision: outcome.decision, risk: outcome.risk, reason: outcome.reason)))
            return SettledPermission(decision: outcome.decision, reason: outcome.reason)

        case .askUser:
            let requestID = RequestID.new()
            let request = PermissionRequestPayload(
                requestId: requestID, agent: agent.name, tool: descriptor.name,
                args: toolCall.arguments, risk: outcome.risk, reason: outcome.reason)
            try? await log.append(.permissionRequest(request))
            try? await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .blocked)))

            let userDecision = await responder.requestApproval(request)
            let resolvedReason = userDecision == .allow
                ? "user approved"
                : "user denied: \(outcome.reason)"
            try? await log.append(.permissionResolved(PermissionResolvedPayload(
                requestId: requestID, tool: descriptor.name, decision: userDecision, risk: outcome.risk,
                reason: resolvedReason)))
            try? await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .tool)))
            return SettledPermission(decision: userDecision, reason: resolvedReason)
        }
    }

    private func projectedHistory() async -> [AgentMessage] {
        guard context.contextBundle == nil else {
            return []
        }
        return await priorHistory()
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
