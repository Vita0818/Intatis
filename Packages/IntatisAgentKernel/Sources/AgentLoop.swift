import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation

/// Terminal failures produced by the agent loop itself, rather than by a
/// provider or tool. Callers can distinguish these from a successful (possibly
/// empty) final response without parsing an event-log message.
public enum AgentLoopError: Error, Sendable, Equatable, LocalizedError {
    case maxIterationsExceeded(limit: Int)
    case responseEndedWithoutCompletionMarker
    case completionExpectedToolCalls(finishReason: String)
    case incompleteFinishReason(String)
    case toolExecutionRequiresManualReconciliation(tool: String, executionID: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .maxIterationsExceeded(let limit):
            return "Agent exceeded the maximum of \(limit) tool iterations without reaching a final response."
        case .responseEndedWithoutCompletionMarker:
            return "Agent response ended without an explicit completion marker."
        case .completionExpectedToolCalls(let finishReason):
            return "Agent response finished with \(finishReason) but provided no tool calls."
        case .incompleteFinishReason(let finishReason):
            return "Agent response ended incompletely with finish reason \(finishReason)."
        case .toolExecutionRequiresManualReconciliation(let tool, let executionID, let reason):
            return "Tool \(tool) may have produced a side effect before it failed (execution \(executionID)); manual reconciliation is required before retrying. \(reason)"
        }
    }
}

/// Resolves the kernel-side permission wait exactly once. The approval request
/// runs in its own task so cancelling an AgentLoop never depends on a responder
/// cooperatively returning from its UI/network wait.
private final class PermissionApprovalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PermissionDecision, Error>?
    private var pendingResult: Result<PermissionDecision, Error>?
    private var approvalTask: Task<Void, Never>?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<PermissionDecision, Error>) {
        let result: Result<PermissionDecision, Error>?
        lock.lock()
        if let pendingResult {
            result = pendingResult
            self.pendingResult = nil
        } else {
            self.continuation = continuation
            result = nil
        }
        lock.unlock()
        if let result {
            continuation.resume(with: result)
        }
    }

    func setApprovalTask(_ task: Task<Void, Never>) {
        let shouldCancel: Bool
        lock.lock()
        if isResolved {
            shouldCancel = true
        } else {
            approvalTask = task
            shouldCancel = false
        }
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func resolve(_ result: Result<PermissionDecision, Error>) {
        let continuation: CheckedContinuation<PermissionDecision, Error>?
        let taskToCancel: Task<Void, Never>?
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        switch result {
        case .success:
            taskToCancel = nil
        case .failure:
            taskToCancel = approvalTask
        }
        approvalTask = nil
        lock.unlock()

        taskToCancel?.cancel()
        continuation?.resume(with: result)
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }
}

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
    private let capabilityLease: CapabilityLease?
    private let workspaceLease: WorkspaceLease?
    private let rootTaskID: TaskID?
    private let taskAttempt: Int?
    private let tokenBudgetMeter: AgentTokenBudgetMeter?

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
                maxIterations: Int = 50,
                capabilityLease: CapabilityLease? = nil,
                workspaceLease: WorkspaceLease? = nil,
                rootTaskID: TaskID? = nil,
                taskAttempt: Int? = nil,
                tokenBudgetMeter: AgentTokenBudgetMeter? = nil) {
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
        self.capabilityLease = capabilityLease
        self.workspaceLease = workspaceLease
        self.rootTaskID = rootTaskID
        self.taskAttempt = taskAttempt
        self.tokenBudgetMeter = tokenBudgetMeter
    }

    /// Runs the loop and returns the agent's explicitly completed final answer.
    /// Exhausting the iteration limit is a terminal error, not an empty success.
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
        var turnStatsAppended = false

        do {
        for _ in 0..<maxIterations {
            try Task.checkCancellation()
            var assistantText = ""
            var pendingToolCalls: [ToolCall] = []
            var responseUsage: Usage?
            var receivedCompletionMarker = false
            var finishReason: String?
            let assistantID = MessageID.new()

            var request = AgentRequest(model: agent.model, messages: convo, tools: specs,
                                       reasoningEffort: reasoningEffort, includeUsage: includeUsage)
            let estimatedInputTokens = Self.estimatedInputTokens(request: request)
            // Cowork always supplies its one session-lifetime meter, including
            // while enforcement is disabled. A disabled meter returns a
            // tracking-only reservation with no output ceiling, so enabling a
            // budget cannot overlook an old in-flight request. The reservation
            // stays bound to the same actor across live policy changes.
            var pendingBudgetReservation: AgentTokenBudgetReservation?
            if let tokenBudgetMeter {
                pendingBudgetReservation = try await tokenBudgetMeter.reserve(
                    estimatedInputTokens: estimatedInputTokens)
            } else {
                pendingBudgetReservation = nil
            }
            request.maxOutputTokens = pendingBudgetReservation?.maxOutputTokens
            do {
                for try await chunk in provider.stream(request) {
                    try Task.checkCancellation()
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
                    case .done(let reason):
                        receivedCompletionMarker = true
                        finishReason = reason ?? finishReason
                    }
                }
                // Cancellation can arrive after the provider has ended normally
                // but before accounting. Keep this check inside the reservation
                // lifecycle so that path cannot strand reserved capacity.
                try Task.checkCancellation()
                let summedReportedTokens = (responseUsage?.promptTokens ?? 0)
                    + (responseUsage?.completionTokens ?? 0)
                let reportedTokens = responseUsage?.totalTokens
                    ?? (summedReportedTokens > 0 ? summedReportedTokens : nil)
                let estimatedTokens = Self.estimatedTokens(
                    request: request,
                    assistantText: assistantText,
                    toolCalls: pendingToolCalls)
                let accountedUsage = reportedTokens == nil
                    ? Usage(totalTokens: estimatedTokens)
                    : responseUsage
                usage = Usage.adding(usage, accountedUsage)
                if let reservation = pendingBudgetReservation,
                   let tokenBudgetMeter {
                    // Take ownership before the actor hop. `settle` removes the
                    // reservation even when it reports an overrun, so a thrown
                    // exhaustion error must not trigger a second settlement.
                    pendingBudgetReservation = nil
                    try await tokenBudgetMeter.settle(
                        reservation,
                        reportedTokens: reportedTokens,
                        estimatedTokens: estimatedTokens)
                }
            } catch {
                if let reservation = pendingBudgetReservation,
                   let tokenBudgetMeter {
                    pendingBudgetReservation = nil
                    let partialEstimate = Self.estimatedTokens(
                        request: request,
                        assistantText: assistantText,
                        toolCalls: pendingToolCalls)
                    let summedReportedTokens = (responseUsage?.promptTokens ?? 0)
                        + (responseUsage?.completionTokens ?? 0)
                    let partialReportedTokens = responseUsage?.totalTokens
                        ?? (summedReportedTokens > 0 ? summedReportedTokens : nil)
                    usage = Usage.adding(
                        usage,
                        partialReportedTokens == nil
                            ? Usage(totalTokens: partialEstimate)
                            : responseUsage)
                    _ = try? await tokenBudgetMeter.settle(
                        reservation,
                        reportedTokens: partialReportedTokens,
                        estimatedTokens: partialEstimate)
                }
                throw error
            }

            guard receivedCompletionMarker else {
                throw AgentLoopError.responseEndedWithoutCompletionMarker
            }
            if pendingToolCalls.isEmpty,
               Self.finishReasonRequiresToolCalls(finishReason) {
                throw AgentLoopError.completionExpectedToolCalls(
                    finishReason: finishReason ?? "tool_calls")
            }
            if let finishReason,
               !Self.finishReasonIsSuccessful(finishReason) {
                throw AgentLoopError.incompleteFinishReason(finishReason)
            }

            if !assistantText.isEmpty {
                try await log.append(.messageCompleted(
                    MessageCompletedPayload(messageId: assistantID, role: .agent, agent: agent.name, text: assistantText)))
            }

            if pendingToolCalls.isEmpty {
                await appendTurnStats(start: start, firstTokenAt: firstTokenAt, usage: usage)
                turnStatsAppended = true
                try await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .idle)))
                return assistantText  // final answer
            }

            convo.append(.assistant(toolCalls: pendingToolCalls, content: assistantText.isEmpty ? nil : assistantText))
            let observations = try await runToolCalls(pendingToolCalls)
            for (toolCall, observation) in zip(pendingToolCalls, observations) {
                try Task.checkCancellation()
                convo.append(.tool(id: toolCall.id, content: observation))
            }
        }

        try Task.checkCancellation()
        await appendTurnStats(start: start, firstTokenAt: firstTokenAt, usage: usage)
        turnStatsAppended = true
        throw AgentLoopError.maxIterationsExceeded(limit: maxIterations)
        } catch {
            // AgentLoop owns the single terminal error event for failures that
            // occur after entering the loop. Callers should propagate/classify
            // the thrown error, not append a second copy of the same event.
            if !turnStatsAppended {
                await appendTurnStats(start: start, firstTokenAt: firstTokenAt, usage: usage)
            }
            try? await log.append(.error(Self.terminalErrorPayload(for: error)))
            try? await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .idle)))
            throw error
        }
    }

    private static func finishReasonRequiresToolCalls(_ finishReason: String?) -> Bool {
        guard let finishReason else { return false }
        switch finishReason.lowercased() {
        case "tool_calls", "function_call":
            return true
        default:
            return false
        }
    }

    private static func finishReasonIsSuccessful(_ finishReason: String) -> Bool {
        switch finishReason.lowercased() {
        case "stop", "end_turn", "completed", "complete", "tool_calls", "function_call":
            return true
        default:
            return false
        }
    }

    private static func terminalErrorPayload(for error: Error) -> ErrorPayload {
        if error is AgentExecutionBudgetError {
            return ErrorPayload(code: "token_budget_exhausted", message: error.localizedDescription)
        }
        guard let loopError = error as? AgentLoopError else {
            return RuntimeErrorPresentation.payload(for: error, fallbackCode: "agent")
        }
        let code: String
        switch loopError {
        case .maxIterationsExceeded:
            code = "max_iterations"
        case .responseEndedWithoutCompletionMarker:
            code = "incomplete_completion"
        case .completionExpectedToolCalls:
            code = "incomplete_tool_calls"
        case .incompleteFinishReason:
            code = "incomplete_response"
        case .toolExecutionRequiresManualReconciliation:
            code = "manual_reconciliation"
        }
        return ErrorPayload(code: code, message: loopError.localizedDescription)
    }

    private static func estimatedTokens(request: AgentRequest,
                                        assistantText: String,
                                        toolCalls: [ToolCall]) -> Int {
        let requestCharacters = request.messages.reduce(0) { partial, message in
            partial
                + (message.content?.count ?? 0)
                + (message.toolCalls?.reduce(0) { $0 + $1.name.count + $1.arguments.count } ?? 0)
        }
        let responseCharacters = assistantText.count
            + toolCalls.reduce(0) { $0 + $1.name.count + $1.arguments.count }
        return max(1, Int(ceil(Double(requestCharacters + responseCharacters) / 4.0)))
    }

    private static func estimatedInputTokens(request: AgentRequest) -> Int {
        let messageCharacters = request.messages.reduce(0) { partial, message in
            partial
                + (message.content?.count ?? 0)
                + (message.toolCalls?.reduce(0) { $0 + $1.name.count + $1.arguments.count } ?? 0)
        }
        let toolCharacters = request.tools.reduce(0) { partial, tool in
            partial + tool.name.count + tool.description.count + String(describing: tool.parameters).count
        }
        return max(1, Int(ceil(Double(messageCharacters + toolCharacters) / 4.0)))
    }

    private func workspaceLeaseFailure(descriptor: ToolDescriptor,
                                       touchedPaths: [String]) -> String? {
        guard let lease = workspaceLease else { return nil }
        guard let rootIdentity = lease.rootIdentity else {
            return "workspace lease has no stable root identity; reattach the workspace"
        }
        guard rootIdentity.matchesCurrentDirectory(rootPath: lease.rootPath) else {
            return "workspace root changed after the lease was granted; reattach the workspace"
        }
        let leaseRoot = URL(fileURLWithPath: lease.rootPath).standardizedFileURL
        let agentRoot = agent.workspaceRoot.standardizedFileURL
        guard leaseRoot.path == agentRoot.path else {
            return "workspace lease root does not match the agent workspace"
        }
        if lease.access == .readOnly, descriptor.sideEffect != .readOnly {
            return "workspace lease is read-only"
        }
        for path in touchedPaths {
            let resolved: URL
            do {
                resolved = try PathConfinement.resolve(path, within: leaseRoot)
            } catch {
                return "path is outside the workspace lease: \(path)"
            }
            let relative = Self.relativePath(resolved, root: leaseRoot)
            if lease.deniedPatterns.contains(where: { Self.path(relative, matches: $0) }) {
                return "path is denied by the workspace lease: \(relative)"
            }
            let allowed = lease.allowedPathRules.contains { rule in
                rule.pattern == "." || Self.path(relative, matches: rule.pattern)
            }
            if !allowed {
                return "path is outside the workspace lease allow-list: \(relative)"
            }
        }
        return nil
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != rootPath else { return "." }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func path(_ path: String, matches pattern: String) -> Bool {
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        let normalizedPattern = pattern.replacingOccurrences(of: "\\", with: "/")
        if !normalizedPattern.contains("/") {
            return normalizedPath.split(separator: "/").contains {
                glob(String($0), matches: normalizedPattern)
            }
        }
        return glob(normalizedPath, matches: normalizedPattern)
    }

    private static func glob(_ value: String, matches pattern: String) -> Bool {
        var expression = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterStars = pattern.index(after: next)
                    if afterStars < pattern.endIndex, pattern[afterStars] == "/" {
                        // `**/name` also matches `name` at the workspace root.
                        expression += "(?:.*/)?"
                        index = pattern.index(after: afterStars)
                    } else {
                        expression += ".*"
                        index = afterStars
                    }
                    continue
                }
                expression += "[^/]*"
            } else if character == "?" {
                expression += "[^/]"
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = pattern.index(after: index)
        }
        expression += "$"
        guard let regex = try? NSRegularExpression(pattern: expression) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
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

    private func runToolCalls(_ toolCalls: [ToolCall]) async throws -> [String] {
        let parallelCollaborationTools = Set(["ask_agent", "delegate_task"])
        guard toolCalls.count > 1,
              toolCalls.allSatisfy({ parallelCollaborationTools.contains($0.name) }) else {
            var results: [String] = []
            results.reserveCapacity(toolCalls.count)
            for toolCall in toolCalls {
                try Task.checkCancellation()
                results.append(try await runTool(toolCall))
            }
            return results
        }

        return try await withThrowingTaskGroup(of: (Int, String).self, returning: [String].self) { group in
            for (index, toolCall) in toolCalls.enumerated() {
                group.addTask {
                    (index, try await runTool(toolCall))
                }
            }
            var indexed: [(Int, String)] = []
            indexed.reserveCapacity(toolCalls.count)
            for try await result in group { indexed.append(result) }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func runTool(_ toolCall: ToolCall) async throws -> String {
        try Task.checkCancellation()
        try await log.append(.toolCall(ToolCallPayload(
            toolCallId: toolCall.id, agent: agent.name, name: toolCall.name, args: toolCall.arguments)))

        guard let tool = registry.tool(named: toolCall.name) else {
            let available = registry.descriptors().map(\.name).sorted().joined(separator: ", ")
            let message = available.isEmpty
                ? "unknown tool: \(toolCall.name)"
                : "unknown tool: \(toolCall.name). Available tools: \(available)"
            try await log.append(.toolResult(ToolResultPayload(toolCallId: toolCall.id, observation: message)))
            return message
        }

        let descriptor = type(of: tool).descriptor
        let normalizedArguments: String
        switch normalizeToolArguments(toolCall.arguments, descriptor: descriptor) {
        case .valid(let arguments):
            normalizedArguments = arguments
        case .invalid(let message):
            try await log.append(.toolResult(ToolResultPayload(toolCallId: toolCall.id, observation: message)))
            return message
        }

        let args = ToolArgs(raw: normalizedArguments)
        if let leaseFailure = workspaceLeaseFailure(
            descriptor: descriptor,
            touchedPaths: tool.touchedPaths(args)) {
            let message = "permission denied: \(leaseFailure)"
            try await log.append([
                .permissionResolved(PermissionResolvedPayload(
                    tool: descriptor.name,
                    decision: .deny,
                    risk: .high,
                    reason: leaseFailure)),
                .toolResult(ToolResultPayload(
                    toolCallId: toolCall.id,
                    observation: message)),
            ])
            return message
        }
        let callContext = ToolCallContext(
            toolName: descriptor.name,
            sideEffect: descriptor.sideEffect,
            touchedPaths: tool.touchedPaths(args),
            risksNetwork: tool.risksNetwork(args),
            rawArgs: normalizedArguments)
        let effectiveWorkspaceRoot = workspaceLease.map { URL(fileURLWithPath: $0.rootPath) }
            ?? agent.workspaceRoot
        let effectiveProfile: PermissionProfile = workspaceLease?.access == .readOnly
            ? .readOnly
            : agent.profile
        let permissionContext = PermissionContext(
            workspaceRoot: effectiveWorkspaceRoot,
            profile: effectiveProfile,
            allowsShell: allowsShell,
            agent: agent.name)

        let outcome = await engine.decide(callContext, permissionContext)
        try Task.checkCancellation()
        let executionID = IDGen.random(prefix: "tool-execution")
        let replayPolicy = ToolExecutionReplayPolicy.conservative(
            for: descriptor.sideEffect,
            tool: descriptor.name)
        let settled = try await settle(outcome,
                                       descriptor: descriptor,
                                       toolCall: ToolCall(id: toolCall.id,
                                                          name: toolCall.name,
                                                          arguments: normalizedArguments),
                                       callContext: callContext,
                                       executionID: executionID,
                                       replayPolicy: replayPolicy)
        try Task.checkCancellation()

        guard settled.decision == .allow else {
            let message = "permission denied: \(settled.reason)"
            try await log.append(.toolResult(ToolResultPayload(toolCallId: toolCall.id, observation: message)))
            return message
        }

        // Permission review can be arbitrarily slow. Revalidate the pinned
        // workspace identity after that await boundary so an approved action
        // cannot be redirected into a replacement directory at the same path.
        if let leaseFailure = workspaceLeaseFailure(
            descriptor: descriptor,
            touchedPaths: callContext.touchedPaths) {
            let message = "permission denied: \(leaseFailure)"
            try await log.append([
                .permissionResolved(PermissionResolvedPayload(
                    tool: descriptor.name,
                    decision: .deny,
                    risk: .high,
                    reason: leaseFailure)),
                .toolResult(ToolResultPayload(
                    toolCallId: toolCall.id,
                    observation: message)),
            ])
            return message
        }

        try Task.checkCancellation()
        try await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .tool)))
        let prepared = ToolExecutionPreparedPayload(
            executionID: executionID,
            taskID: context.taskContract?.id,
            attempt: taskAttempt,
            toolCallID: toolCall.id,
            agent: agent.name,
            tool: descriptor.name,
            sideEffect: descriptor.sideEffect,
            replayPolicy: replayPolicy)
        // This record is the durable boundary: if it cannot be written, the
        // executor is never invoked. An unresolved non-replayable record after
        // a crash forces reconciliation instead of blindly replaying the task.
        try await log.append(.toolExecutionPrepared(prepared))

        // The durable prepare append is another suspension point. Check once
        // more immediately before entering the executor. If the root changed,
        // settle the unused ticket explicitly; no side effect has run.
        if let leaseFailure = workspaceLeaseFailure(
            descriptor: descriptor,
            touchedPaths: callContext.touchedPaths) {
            let message = "permission denied: \(leaseFailure)"
            try await log.append([
                .permissionResolved(PermissionResolvedPayload(
                    tool: descriptor.name,
                    decision: .deny,
                    risk: .high,
                    reason: leaseFailure)),
                .toolResult(ToolResultPayload(
                    toolCallId: toolCall.id,
                    observation: message)),
                .toolExecutionSettled(ToolExecutionSettledPayload(
                    prepared: prepared,
                    outcome: .failed,
                    reason: leaseFailure)),
            ])
            return message
        }

        let toolContext = ToolContext(workspaceRoot: effectiveWorkspaceRoot,
                                      workspaceLease: workspaceLease,
                                      shell: shell,
                                      git: git,
                                      messenger: messenger,
                                      agentManager: agentManager,
                                      imageGenerator: imageGenerator)
        let observation: ToolObservation
        do {
            try Task.checkCancellation()
            observation = try await tool.execute(args, in: toolContext)
        } catch is CancellationError {
            let requiresReconciliation = replayPolicy == .requiresManualReconciliation
            let message = requiresReconciliation
                ? "tool cancelled; manual reconciliation required because the side effect may already have occurred"
                : "tool cancelled"
            var events: [Event] = [
                .toolResult(ToolResultPayload(toolCallId: toolCall.id, observation: message)),
            ]
            if !requiresReconciliation {
                events.append(.toolExecutionSettled(ToolExecutionSettledPayload(
                    prepared: prepared,
                    outcome: .cancelled,
                    reason: message)))
            }
            try await log.append(events)
            throw CancellationError()
        } catch {
            let underlying = RuntimeErrorPresentation.message(for: error)
            if replayPolicy == .requiresManualReconciliation {
                let message = "tool error: \(underlying); manual reconciliation required because the side effect may already have occurred"
                // Deliberately leave the execution ticket unresolved. A network,
                // process, or collaboration tool can commit its side effect and
                // still throw locally (for example after a timeout), so `failed`
                // is not proof that replay is safe.
                try await log.append(.toolResult(ToolResultPayload(
                    toolCallId: toolCall.id,
                    observation: message)))
                throw AgentLoopError.toolExecutionRequiresManualReconciliation(
                    tool: descriptor.name,
                    executionID: executionID,
                    reason: underlying)
            }
            let message = "tool error: \(underlying)"
            try await log.append([
                .toolResult(ToolResultPayload(toolCallId: toolCall.id, observation: message)),
                .toolExecutionSettled(ToolExecutionSettledPayload(
                    prepared: prepared,
                    outcome: .failed,
                    reason: message)),
            ])
            return message
        }

        var completionEvents: [Event] = []
        if let diff = observation.diff, let files = observation.changedFiles {
            completionEvents.append(.patchProposed(PatchProposedPayload(
                patchId: IDGen.random(prefix: "patch"), agent: agent.name, files: files, diff: diff)))
        }
        completionEvents.append(.toolResult(ToolResultPayload(
            toolCallId: toolCall.id,
            observation: observation.text,
            truncated: observation.truncated)))
        completionEvents.append(.toolExecutionSettled(ToolExecutionSettledPayload(
            prepared: prepared,
            outcome: .succeeded)))
        try await log.append(completionEvents)
        // Persist completed side effects before surfacing a concurrent cancel.
        try Task.checkCancellation()
        return observation.text
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
                        toolCall: ToolCall,
                        callContext: ToolCallContext,
                        executionID: String,
                        replayPolicy: ToolExecutionReplayPolicy) async throws -> SettledPermission {
        switch outcome.decision {
        case .allow, .deny:
            try await log.append(.permissionResolved(PermissionResolvedPayload(
                tool: descriptor.name, decision: outcome.decision, risk: outcome.risk, reason: outcome.reason)))
            return SettledPermission(decision: outcome.decision, reason: outcome.reason)

        case .askUser:
            let requestID = RequestID.new()
            let request = PermissionRequestPayload(
                requestId: requestID, agent: agent.name, tool: descriptor.name,
                args: toolCall.arguments, risk: outcome.risk, reason: outcome.reason,
                context: permissionRequestContext(
                    outcome: outcome,
                    callContext: callContext,
                    toolCall: toolCall,
                    executionID: executionID,
                    replayPolicy: replayPolicy))
            try await log.append([
                .permissionRequest(request),
                .agentStatus(AgentStatusPayload(agent: agent.name, state: .blocked)),
            ])

            let userDecision: PermissionDecision
            do {
                userDecision = try await awaitPermissionApproval(request)
                try Task.checkCancellation()
            } catch is CancellationError {
                try await log.append(.permissionResolved(PermissionResolvedPayload(
                    requestId: requestID,
                    tool: descriptor.name,
                    decision: .deny,
                    risk: outcome.risk,
                    reason: "permission request cancelled")))
                throw CancellationError()
            }
            let resolvedReason = userDecision == .allow
                ? "permission approved"
                : "permission denied: \(outcome.reason)"
            try await log.append([
                .permissionResolved(PermissionResolvedPayload(
                    requestId: requestID,
                    tool: descriptor.name,
                    decision: userDecision,
                    risk: outcome.risk,
                    reason: resolvedReason)),
                .agentStatus(AgentStatusPayload(agent: agent.name, state: .tool)),
            ])
            return SettledPermission(decision: userDecision, reason: resolvedReason)
        }
    }

    private func permissionRequestContext(outcome: PermissionOutcome,
                                          callContext: ToolCallContext,
                                          toolCall: ToolCall,
                                          executionID: String,
                                          replayPolicy: ToolExecutionReplayPolicy) -> PermissionRequestContext {
        let contract = context.taskContract
        var lineage: [TaskID] = []
        if let rootTaskID { lineage.append(rootTaskID) }
        if let parentTaskID = contract?.parentTaskID,
           !lineage.contains(parentTaskID) {
            lineage.append(parentTaskID)
        }
        if let taskID = contract?.id,
           !lineage.contains(taskID) {
            lineage.append(taskID)
        }
        var relatedAgents = contract?.relatedAgents ?? []
        for candidate in [contract?.issuer, contract?.assignee].compactMap({ $0 })
            where !relatedAgents.contains(candidate) {
            relatedAgents.append(candidate)
        }
        let gateDecision: PermissionReviewGateDecision
        switch outcome.decision {
        case .allow: gateDecision = .allow
        case .deny: gateDecision = .deny
        case .askUser: gateDecision = .ask
        }
        return PermissionRequestContext(
            taskID: contract?.id,
            rootTaskID: rootTaskID,
            parentTaskID: contract?.parentTaskID,
            attempt: taskAttempt,
            toolCallID: toolCall.id,
            normalizedArgs: toolCall.arguments,
            touchedPaths: callContext.touchedPaths,
            risksNetwork: callContext.risksNetwork,
            sideEffect: callContext.sideEffect,
            gate: PermissionReviewGateSnapshot(
                decision: gateDecision,
                risk: outcome.risk,
                reason: outcome.reason),
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease,
            taskContract: contract,
            causalContext: PermissionReviewCausalContext(
                userGoal: contract?.objective,
                issuer: contract?.issuer,
                assignee: contract?.assignee,
                taskLineage: lineage,
                relatedAgents: relatedAgents),
            executionID: executionID,
            replayPolicy: replayPolicy.rawValue)
    }

    private func awaitPermissionApproval(_ request: PermissionRequestPayload) async throws -> PermissionDecision {
        let gate = PermissionApprovalGate()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let approvalTask = Task {
                    let decision = await responder.requestApproval(request)
                    gate.resolve(.success(decision))
                }
                gate.setApprovalTask(approvalTask)
            }
        }, onCancel: {
            gate.cancel()
        })
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
