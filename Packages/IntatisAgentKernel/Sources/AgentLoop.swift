import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation

public typealias ToolAuthorizationRevalidator = @Sendable (
    ResolvedToolAuthorization
) async -> String?

/// Host preflight performed after schema validation but before the immutable
/// authorization snapshot is created. Cowork uses it to turn symbolic targets
/// such as delegate_task(to:auto) into concrete resources for review without
/// mutating the roster, leases, scheduler, or event log.
public struct ToolAuthorizationPreparationRequest: Sendable {
    public let authorizationID: String
    public let toolName: String
    public let normalizedArguments: String
    public let baseIntent: PermissionIntent
    public let invocation: ToolAuthorizationInvocationContext

    public init(authorizationID: String,
                toolName: String,
                normalizedArguments: String,
                baseIntent: PermissionIntent,
                invocation: ToolAuthorizationInvocationContext) {
        self.authorizationID = authorizationID
        self.toolName = toolName
        self.normalizedArguments = normalizedArguments
        self.baseIntent = baseIntent
        self.invocation = invocation
    }
}

/// Host-resolved authorization facts produced before the immutable registry
/// snapshot is created. `targetAgentInferenceBinding` is deliberately a
/// structured protocol value rather than free-form metadata so the exact
/// route/profile revision survives review and durable execution tickets.
public struct ToolAuthorizationPreparation: Sendable {
    public var intent: PermissionIntent
    public var targetAgentInferenceBinding: AgentInferenceBinding?

    public init(intent: PermissionIntent,
                targetAgentInferenceBinding: AgentInferenceBinding? = nil) {
        self.intent = intent
        self.targetAgentInferenceBinding = targetAgentInferenceBinding
    }
}

public typealias ToolAuthorizationPreparer = @Sendable (
    ToolAuthorizationPreparationRequest
) async throws -> ToolAuthorizationPreparation

/// Terminal failures produced by the agent loop itself, rather than by a
/// provider or tool. Callers can distinguish these from a successful (possibly
/// empty) final response without parsing an event-log message.
public enum AgentLoopError: Error, Sendable, Equatable, LocalizedError {
    case maxIterationsExceeded(limit: Int)
    case responseEndedWithoutCompletionMarker
    case completionExpectedToolCalls(finishReason: String)
    case incompleteFinishReason(String)
    case toolExecutionRequiresManualReconciliation(tool: String, executionID: String, reason: String)
    case repeatedDeniedToolCall(tool: String)
    case unresolvedDeniedSideEffects([String])

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
        case .repeatedDeniedToolCall(let tool):
            return "Agent repeatedly retried the identical denied tool call \(tool); the task was stopped to protect the automatic permission reviewer."
        case .unresolvedDeniedSideEffects(let actions):
            return "Agent invocation cannot complete because required side effects remain denied or failed: \(actions.joined(separator: "; "))."
        }
    }
}

/// A typed, non-failure terminal used when a user explicitly cancels from a
/// permission prompt. It is distinct from a call-scoped decline and from an
/// arbitrary provider/runtime `CancellationError`.
public struct AgentTurnInterruptedError: Error, Sendable, Equatable, LocalizedError {
    public let reason: String
    public let failureSource: ExecutionFailureSource

    public init(reason: String,
                failureSource: ExecutionFailureSource = .userCancelled) {
        self.reason = reason
        self.failureSource = failureSource
    }

    public var errorDescription: String? { reason }
}

private struct ModelHistoryRecordingScope: Sendable {
    var turnID: TurnID
    var taskID: TaskID
    var submissionID: SubmissionID
    var taskAttempt: Int
}

/// Per-AgentLoop circuit breaker. One exact retry is answered from the cached
/// denial without spending another reviewer call; a further identical retry is
/// a terminal coordination failure instead of an unbounded model/reviewer loop.
private actor ToolDenialCircuitBreaker {
    private var deniedAttempts: [String: Int] = [:]

    func noteRepeatedAttempt(signature: String) -> Int? {
        guard let previous = deniedAttempts[signature] else { return nil }
        let next = previous + 1
        deniedAttempts[signature] = next
        return next
    }

    func recordDenial(signature: String) {
        if deniedAttempts[signature] == nil {
            deniedAttempts[signature] = 1
        }
    }
}

/// Host-derived completion evidence for Cowork. A model cannot turn a denied
/// mutating/network/exec action into a successful invocation merely by ending
/// its response. A later successful execution against the same capability and
/// resources clears the outstanding denial.
private actor SideEffectEvidenceLedger {
    private struct Key: Hashable {
        var authority: String
        var resources: [String]
    }

    private var unresolved: [Key: String] = [:]

    /// Rebuilds completion evidence from the append-only log for the current
    /// Cowork task. This closes the crash window between a durable permission
    /// decision and a durable successful tool settlement: a restarted
    /// invocation cannot simply claim completion while an earlier required
    /// side effect for the same task still lacks host-derived success evidence.
    func restore(from envelopes: [Envelope],
                 taskID: TaskID,
                 throughAttempt: Int?) {
        for envelope in envelopes {
            switch envelope.event {
            case .permissionRequest(let payload):
                guard let context = payload.context,
                      let authorization = context.authorization,
                      Self.belongsToCurrentTask(
                        authorization: authorization,
                        taskID: taskID,
                        throughAttempt: throughAttempt)
                else { continue }
                recordDenied(
                    tool: payload.tool,
                    intent: context.intent ?? authorization.intent,
                    authorization: authorization)

            case .permissionReviewRequested(let payload):
                guard let authorization = payload.task.authorization,
                      Self.belongsToCurrentTask(
                        authorization: authorization,
                        taskID: taskID,
                        throughAttempt: throughAttempt)
                else { continue }
                recordDenied(
                    tool: payload.task.tool,
                    intent: payload.task.intent ?? authorization.intent,
                    authorization: authorization)

            case .permissionReviewSettled(let payload):
                guard let authorization = payload.authorization,
                      Self.belongsToCurrentTask(
                        authorization: authorization,
                        taskID: taskID,
                        throughAttempt: throughAttempt)
                else { continue }
                recordDenied(
                    tool: payload.tool,
                    intent: authorization.intent,
                    authorization: authorization)

            case .permissionResolved(let payload):
                guard let authorization = payload.authorization,
                      Self.belongsToCurrentTask(
                        authorization: authorization,
                        taskID: taskID,
                        throughAttempt: throughAttempt)
                else { continue }
                recordDenied(
                    tool: payload.tool,
                    intent: payload.intent ?? authorization.intent,
                    authorization: authorization)

            case .toolExecutionPrepared(let payload):
                guard Self.belongsToCurrentTask(
                    payloadTaskID: payload.taskID,
                    payloadAttempt: payload.attempt,
                    authorization: payload.authorization,
                    taskID: taskID,
                    throughAttempt: throughAttempt),
                    let intent = payload.intent ?? payload.authorization?.intent
                else { continue }
                recordDenied(
                    tool: payload.tool,
                    intent: intent,
                    authorization: payload.authorization)

            case .toolExecutionSettled(let payload):
                guard Self.belongsToCurrentTask(
                    payloadTaskID: payload.taskID,
                    payloadAttempt: payload.attempt,
                    authorization: payload.authorization,
                    taskID: taskID,
                    throughAttempt: throughAttempt),
                    let intent = payload.intent ?? payload.authorization?.intent
                else { continue }
                if payload.outcome == .succeeded,
                   let authorization = payload.authorization {
                    recordSucceeded(intent: intent, authorization: authorization)
                } else {
                    recordDenied(
                        tool: payload.tool,
                        intent: intent,
                        authorization: payload.authorization)
                }

            default:
                continue
            }
        }
    }

    func recordDenied(tool: String,
                      intent: PermissionIntent,
                      authorization: ResolvedToolAuthorization?) {
        guard Self.requiresExecutionEvidence(intent) else { return }
        let key = Self.key(intent: intent, authorization: authorization)
        unresolved[key] = Self.description(tool: tool, intent: intent)
    }

    func recordSucceeded(intent: PermissionIntent,
                         authorization: ResolvedToolAuthorization) {
        guard Self.requiresExecutionEvidence(intent) else { return }
        let succeededKey = Self.key(
            intent: intent,
            authorization: authorization)
        unresolved.removeValue(forKey: succeededKey)
        // A malformed mutating call may not expose a usable resource yet. A
        // later successful action in the same canonical permission family is
        // the strongest host-derived remediation available for that wildcard.
        unresolved.removeValue(forKey: Key(
            authority: succeededKey.authority,
            resources: []))
    }

    func unresolvedDescriptions() -> [String] {
        unresolved.values.sorted()
    }

    private static func requiresExecutionEvidence(_ intent: PermissionIntent) -> Bool {
        !intent.controlEffects.isEmpty || intent.dataEffects.contains { effect in
            effect != .none && effect != .read
        }
    }

    private static func key(intent: PermissionIntent,
                            authorization: ResolvedToolAuthorization?) -> Key {
        let capabilities = authorization?.requiredCapabilities.map(\.rawValue).sorted() ?? []
        let semanticAction: String
        if let canonicalPermission = authorization?.canonicalPermission {
            semanticAction = canonicalPermission
        } else if authorization?.requiredCapabilities.contains(.applyPatch) == true
            || intent.action == "filesystem.write"
            || intent.action == "filesystem.patch" {
            semanticAction = "filesystem.edit"
        } else {
            semanticAction = intent.action
        }
        let authority = capabilities.isEmpty
            ? "action:\(semanticAction)"
            : "capabilities:\(capabilities.joined(separator: ","))|action:\(semanticAction)"
        let resources = intent.resources.map { resource in
            "\(resource.kind.rawValue):\(resource.value):\(resource.access?.rawValue ?? "")"
        }.sorted()
        return Key(authority: authority, resources: resources)
    }

    private static func belongsToCurrentTask(
        authorization: ResolvedToolAuthorization,
        taskID: TaskID,
        throughAttempt: Int?
    ) -> Bool {
        belongsToCurrentTask(
            payloadTaskID: authorization.taskID,
            payloadAttempt: authorization.attempt,
            authorization: authorization,
            taskID: taskID,
            throughAttempt: throughAttempt)
    }

    private static func belongsToCurrentTask(
        payloadTaskID: TaskID?,
        payloadAttempt: Int?,
        authorization: ResolvedToolAuthorization?,
        taskID: TaskID,
        throughAttempt: Int?
    ) -> Bool {
        guard (payloadTaskID ?? authorization?.taskID) == taskID else { return false }
        guard let throughAttempt else { return true }
        guard let eventAttempt = payloadAttempt ?? authorization?.attempt else { return true }
        return eventAttempt <= throughAttempt
    }

    private static func description(tool: String, intent: PermissionIntent) -> String {
        let resources = intent.resources.map(\.value).sorted().joined(separator: ", ")
        return resources.isEmpty
            ? "\(tool) (\(intent.action))"
            : "\(tool) (\(intent.action)) on \(resources)"
    }
}

/// Resolves the kernel-side permission wait exactly once. The approval request
/// runs in its own task so cancelling an AgentLoop never depends on a responder
/// cooperatively returning from its UI/network wait.
private final class PermissionApprovalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PermissionApprovalResolution, Error>?
    private var pendingResult: Result<PermissionApprovalResolution, Error>?
    private var approvalTask: Task<Void, Never>?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<PermissionApprovalResolution, Error>) {
        let result: Result<PermissionApprovalResolution, Error>?
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

    func resolve(_ result: Result<PermissionApprovalResolution, Error>) {
        let continuation: CheckedContinuation<PermissionApprovalResolution, Error>?
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
    private let terminal: (any TerminalSessionManaging)?
    private let git: GitService
    private let messenger: AgentMessenger?
    private let agentManager: AgentManager?
    private let workTaskManager: WorkTaskManager?
    private let goalManager: GoalManager?
    private let imageGenerator: ImageGenerationToolService?
    private let sessionNaming: SessionNamingService?
    private let reasoningEffort: ReasoningEffort?
    private let includeUsage: Bool
    private let maxIterations: Int
    private let capabilityLease: CapabilityLease?
    private let workspaceLease: WorkspaceLease?
    private let rootTaskID: TaskID?
    private let taskAttempt: Int?
    private let executionScope: AgentExecutionScope?
    private let tokenBudgetMeter: AgentTokenBudgetMeter?
    private let authorizationPreparer: ToolAuthorizationPreparer?
    private let authorizationRevalidator: ToolAuthorizationRevalidator?

    public init(log: EventLog,
                provider: ToolCallingProvider,
                registry: ToolRegistry,
                engine: PermissionEngine,
                responder: PermissionResponder,
                agent: Agent,
                context: ContextBuilder = ContextBuilder(),
                allowsShell: Bool,
                shell: ShellRunner = ProcessShellRunner(),
                terminal: (any TerminalSessionManaging)? = nil,
                git: GitService = ProcessGitService(),
                messenger: AgentMessenger? = nil,
                agentManager: AgentManager? = nil,
                workTaskManager: WorkTaskManager? = nil,
                goalManager: GoalManager? = nil,
                imageGenerator: ImageGenerationToolService? = nil,
                sessionNaming: SessionNamingService? = nil,
                reasoningEffort: ReasoningEffort? = nil,
                includeUsage: Bool = false,
                maxIterations: Int = 50,
                capabilityLease: CapabilityLease? = nil,
                workspaceLease: WorkspaceLease? = nil,
                rootTaskID: TaskID? = nil,
                taskAttempt: Int? = nil,
                executionScope: AgentExecutionScope? = nil,
                tokenBudgetMeter: AgentTokenBudgetMeter? = nil,
                authorizationPreparer: ToolAuthorizationPreparer? = nil,
                authorizationRevalidator: ToolAuthorizationRevalidator? = nil) {
        self.log = log
        self.provider = provider
        self.registry = registry
        self.engine = engine
        self.responder = responder
        self.agent = agent
        self.context = context
        self.allowsShell = allowsShell
        self.shell = shell
        self.terminal = terminal
        self.git = git
        self.messenger = messenger
        self.agentManager = agentManager
        self.workTaskManager = workTaskManager
        self.goalManager = goalManager
        self.imageGenerator = imageGenerator
        self.sessionNaming = sessionNaming
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage
        self.maxIterations = maxIterations
        self.capabilityLease = capabilityLease
        self.workspaceLease = workspaceLease
        self.rootTaskID = rootTaskID
        self.taskAttempt = taskAttempt
        self.executionScope = executionScope
        self.tokenBudgetMeter = tokenBudgetMeter
        self.authorizationPreparer = authorizationPreparer
        self.authorizationRevalidator = authorizationRevalidator
    }

    /// Runs the loop and returns the agent's explicitly completed final answer.
    /// Exhausting the iteration limit is a terminal error, not an empty success.
    @discardableResult
    public func send(_ userText: String,
                     images: [ImageAttachment] = [],
                     userMessage: UserMessagePayload? = nil,
                     recordUserMessage: Bool = true,
                     submissionID: SubmissionID? = nil) async throws -> String {
        let turnID = TurnID.new()
        let effectiveSubmissionID = submissionID ?? userMessage?.submissionID
        let start = Date()
        var firstTokenAt: Date?
        var usage: Usage?
        var turnStatsAppended = false

        do {
        var recoveredCoworkEvents: [Envelope]?
        if context.runtimeEnvironment.mode == .cowork,
           context.taskContract?.id != nil {
            // A missing/corrupt/unknown event must not be confused with a
            // shorter model history. Verify a complete sequence-zero snapshot
            // before this run adds any new events or asks a provider to
            // continue the task.
            let replay = try await log.replayForProjectionChecked()
            guard replay.hasCompleteKnownHistory else {
                throw EventLogError.unsupportedEventTypes
            }
            recoveredCoworkEvents = replay.envelopes
        } else {
            recoveredCoworkEvents = nil
        }
        var acceptedCurrentUserMessage = userMessage
        if recordUserMessage {
            var durableUserMessage = userMessage ?? UserMessagePayload(text: userText)
            if durableUserMessage.submissionID == nil {
                durableUserMessage.submissionID = effectiveSubmissionID
            }
            let appended = try await log.append(.userMessage(durableUserMessage))
            recoveredCoworkEvents?.append(appended)
            acceptedCurrentUserMessage = durableUserMessage
        }
        let history = try await projectedHistory(
            recoveredEvents: recoveredCoworkEvents,
            excludingCurrentAndLaterSubmissionsFrom: effectiveSubmissionID)
        let modelHistoryScope = try modelHistoryRecordingScope(
            turnID: turnID,
            effectiveSubmissionID: effectiveSubmissionID)
        if let modelHistoryScope {
            guard let recoveredCoworkEvents else {
                throw AgentModelHistoryProjectionError.missingAcceptedSubmission(
                    modelHistoryScope.submissionID)
            }
            acceptedCurrentUserMessage = try Self.acceptedUserMessage(
                for: modelHistoryScope.submissionID,
                agentID: agent.name,
                expectedText: userText,
                preferredPayload: acceptedCurrentUserMessage,
                events: recoveredCoworkEvents)
            try await log.append(.modelHistoryItem(.message(
                itemID: "model-history-user:\(turnID.rawValue)",
                turnID: turnID,
                agent: agent.name,
                taskID: modelHistoryScope.taskID,
                submissionID: modelHistoryScope.submissionID,
                taskAttempt: modelHistoryScope.taskAttempt,
                role: .user,
                content: userText,
                attachmentIDs: acceptedCurrentUserMessage?.attachments)))
        }
        try await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .thinking)))

        var convo = context.initialMessages(history: history, userText: userText, userImages: images)
        let specs = context.toolSpecs(registry)
        let denialCircuitBreaker = ToolDenialCircuitBreaker()
        let sideEffectEvidence = SideEffectEvidenceLedger()
        var usedToolCallIDs = Set<String>()
        var syntheticToolCallOrdinal = 0
        if context.runtimeEnvironment.mode == .cowork,
           let taskID = context.taskContract?.id,
           let recoveredCoworkEvents {
            await sideEffectEvidence.restore(
                from: recoveredCoworkEvents,
                taskID: taskID,
                throughAttempt: taskAttempt)
        }

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
                            MessageDeltaPayload(
                                messageId: assistantID,
                                role: .agent,
                                agent: agent.name,
                                textDelta: d,
                                submissionID: effectiveSubmissionID)))
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
            pendingToolCalls = Self.uniquedToolCalls(
                pendingToolCalls,
                usedCallIDs: &usedToolCallIDs,
                syntheticOrdinal: &syntheticToolCallOrdinal)
            if pendingToolCalls.isEmpty,
               Self.finishReasonRequiresToolCalls(finishReason) {
                throw AgentLoopError.completionExpectedToolCalls(
                    finishReason: finishReason ?? "tool_calls")
            }
            if let finishReason,
               !Self.finishReasonIsSuccessful(finishReason) {
                throw AgentLoopError.incompleteFinishReason(finishReason)
            }

            var completedResponseEvents: [Event] = []
            if !assistantText.isEmpty {
                try Task.checkCancellation()
                completedResponseEvents.append(.messageCompleted(
                    MessageCompletedPayload(
                        messageId: assistantID,
                        role: .agent,
                        agent: agent.name,
                        text: assistantText,
                        submissionID: effectiveSubmissionID)))
            }
            if let modelHistoryScope {
                if pendingToolCalls.isEmpty {
                    completedResponseEvents.append(.modelHistoryItem(.message(
                        itemID: "model-history-assistant:\(assistantID.rawValue)",
                        turnID: modelHistoryScope.turnID,
                        agent: agent.name,
                        taskID: modelHistoryScope.taskID,
                        submissionID: modelHistoryScope.submissionID,
                        taskAttempt: modelHistoryScope.taskAttempt,
                        role: .assistant,
                        content: assistantText)))
                } else {
                    completedResponseEvents.append(
                        .modelHistoryItem(.functionCallBatch(
                            itemID: "model-history-assistant:\(assistantID.rawValue)",
                            turnID: modelHistoryScope.turnID,
                            agent: agent.name,
                            taskID: modelHistoryScope.taskID,
                            submissionID: modelHistoryScope.submissionID,
                            taskAttempt: modelHistoryScope.taskAttempt,
                            content: assistantText.isEmpty ? nil : assistantText,
                            calls: try modelHistoryFunctionCalls(
                                pendingToolCalls))))
                }
            }
            if !completedResponseEvents.isEmpty {
                try Task.checkCancellation()
                try await log.append(completedResponseEvents)
            }

            if pendingToolCalls.isEmpty,
               context.runtimeEnvironment.mode == .cowork {
                let unresolved = await sideEffectEvidence.unresolvedDescriptions()
                if !unresolved.isEmpty {
                    throw AgentLoopError.unresolvedDeniedSideEffects(unresolved)
                }
            }

            if pendingToolCalls.isEmpty {
                await appendTurnStats(start: start, firstTokenAt: firstTokenAt, usage: usage)
                turnStatsAppended = true
                try await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .idle)))
                try Task.checkCancellation()
                try await log.append(.turnOutcome(TurnOutcomePayload(
                    turnID: turnID,
                    outcome: .completed,
                    submissionID: effectiveSubmissionID,
                    taskID: context.taskContract?.id,
                    agentID: agent.name)))
                return assistantText  // final answer
            }

            convo.append(.assistant(toolCalls: pendingToolCalls, content: assistantText.isEmpty ? nil : assistantText))
            let observations = try await runToolCalls(
                pendingToolCalls,
                turnID: turnID,
                denialCircuitBreaker: denialCircuitBreaker,
                sideEffectEvidence: sideEffectEvidence,
                modelHistoryScope: modelHistoryScope)
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
            let interruption = Self.turnInterruption(for: error)
            if interruption == nil {
                try? await log.append(.error(Self.terminalErrorPayload(
                    for: error,
                    submissionID: effectiveSubmissionID)))
            }
            try? await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .idle)))
            try? await log.append(.turnOutcome(TurnOutcomePayload(
                turnID: turnID,
                outcome: interruption == nil ? .failed : .interrupted,
                failureSource: interruption?.failureSource ?? .runtimeFailed,
                reason: Self.boundedTurnReason(error.localizedDescription),
                submissionID: effectiveSubmissionID,
                taskID: context.taskContract?.id,
                agentID: agent.name)))
            throw error
        }
    }

    private func modelHistoryRecordingScope(
        turnID: TurnID,
        effectiveSubmissionID: SubmissionID?
    ) throws -> ModelHistoryRecordingScope? {
        guard context.conversationHistoryPolicy == .coworkMainThread else {
            return nil
        }
        guard context.runtimeEnvironment.mode == .cowork,
              let contract = context.taskContract,
              contract.kind == .root,
              contract.issuer == nil,
              contract.assignee == agent.name,
              let submissionID = contract.submissionID,
              effectiveSubmissionID == submissionID else {
            throw AgentModelHistoryProjectionError.invalidItem(
                "model-history-user:\(turnID.rawValue)",
                "Cowork main-thread recording lacks one exact root task/submission/agent binding")
        }
        let attempt = taskAttempt ?? 1
        guard attempt >= 1 else {
            throw AgentModelHistoryProjectionError.invalidItem(
                "model-history-user:\(turnID.rawValue)",
                "taskAttempt must be one-based")
        }
        return ModelHistoryRecordingScope(
            turnID: turnID,
            taskID: contract.id,
            submissionID: submissionID,
            taskAttempt: attempt)
    }

    private static func acceptedUserMessage(
        for submissionID: SubmissionID,
        agentID: AgentID,
        expectedText: String,
        preferredPayload: UserMessagePayload?,
        events: [Envelope]
    ) throws -> UserMessagePayload {
        let candidates = events.compactMap { envelope -> UserMessagePayload? in
            guard case .userMessage(let payload) = envelope.event,
                  payload.submissionID == submissionID else {
                return nil
            }
            return payload
        }
        guard let durable = candidates.first else {
            throw AgentModelHistoryProjectionError.missingAcceptedSubmission(
                submissionID)
        }
        guard candidates.dropFirst().allSatisfy({ $0 == durable }),
              preferredPayload.map({ $0 == durable }) ?? true else {
            throw AgentModelHistoryProjectionError.conflictingAcceptedSubmission(
                submissionID)
        }
        guard durable.text == expectedText,
              durable.to == nil || durable.to == agentID else {
            throw AgentModelHistoryProjectionError.invalidItem(
                "model-history-user:\(submissionID.rawValue)",
                "provider input does not exactly match the accepted submission")
        }
        return durable
    }

    private static func turnInterruption(
        for error: Error
    ) -> (failureSource: ExecutionFailureSource, reason: String)? {
        if let interrupted = error as? AgentTurnInterruptedError {
            return (interrupted.failureSource, interrupted.reason)
        }
        if IntatisCancellation.isCurrentTaskCancellation(error) {
            return (.turnCancelled, "Turn cancelled")
        }
        return nil
    }

    private static func boundedTurnReason(_ reason: String) -> String {
        PermissionReviewTextSanitizer.sanitizeDiagnostic(
            reason,
            maxCharacters: 500).text
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

    private static func terminalErrorPayload(
        for error: Error,
        submissionID: SubmissionID? = nil
    ) -> ErrorPayload {
        if IntatisCancellation.isCancellationSignal(error) {
            return ErrorPayload(
                code: "runtime_failed",
                message: "The provider or runtime ended with an unexpected cancellation signal.",
                submissionID: submissionID)
        }
        if error is AgentExecutionBudgetError {
            return ErrorPayload(
                code: "token_budget_exhausted",
                message: error.localizedDescription,
                submissionID: submissionID)
        }
        guard let loopError = error as? AgentLoopError else {
            var payload = RuntimeErrorPresentation.payload(for: error, fallbackCode: "agent")
            payload.submissionID = submissionID
            return payload
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
        case .repeatedDeniedToolCall:
            code = "repeated_denied_tool_call"
        case .unresolvedDeniedSideEffects:
            code = "unresolved_denied_side_effects"
        }
        return ErrorPayload(
            code: code,
            message: loopError.localizedDescription,
            submissionID: submissionID)
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

    private func workspaceLeaseFailure(intent: PermissionIntent,
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
        if lease.access == .readOnly, !intent.isReadOnlyWorkspaceCompatible {
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
            model: agent.model.rawValue,
            goalID: executionScope?.goalID ?? context.taskContract?.goalID,
            continuationRunID: executionScope?.continuationRunID ?? context.taskContract?.continuationRunID,
            workTaskID: executionScope?.workTaskID ?? context.taskContract?.workTaskID,
            invocationTaskID: executionScope?.invocationTaskID ?? rootTaskID ?? context.taskContract?.id,
            agentID: executionScope?.agentID ?? agent.name,
            agentInferenceBinding: context.taskContract?.agentInferenceBinding
                ?? agent.agentInferenceBinding)))
    }

    // MARK: - Tool execution with permission

    private func runToolCalls(_ toolCalls: [ToolCall],
                              turnID: TurnID,
                              denialCircuitBreaker: ToolDenialCircuitBreaker,
                              sideEffectEvidence: SideEffectEvidenceLedger,
                              modelHistoryScope: ModelHistoryRecordingScope?) async throws -> [String] {
        let parallelCollaborationTools = Set(["ask_agent", "delegate_task"])
        guard toolCalls.count > 1,
              toolCalls.allSatisfy({ parallelCollaborationTools.contains($0.name) }) else {
            var results: [String] = []
            results.reserveCapacity(toolCalls.count)
            for toolCall in toolCalls {
                try Task.checkCancellation()
                let observation = try await runTool(
                    toolCall,
                    turnID: turnID,
                    denialCircuitBreaker: denialCircuitBreaker,
                    sideEffectEvidence: sideEffectEvidence,
                    modelHistoryScope: modelHistoryScope)
                results.append(observation)
            }
            return results
        }

        return try await withThrowingTaskGroup(of: (Int, String).self, returning: [String].self) { group in
            for (index, toolCall) in toolCalls.enumerated() {
                group.addTask {
                    let observation = try await runTool(
                        toolCall,
                        turnID: turnID,
                        denialCircuitBreaker: denialCircuitBreaker,
                        sideEffectEvidence: sideEffectEvidence,
                        modelHistoryScope: modelHistoryScope)
                    return (index, observation)
                }
            }
            var indexed: [(Int, String)] = []
            indexed.reserveCapacity(toolCalls.count)
            for try await result in group { indexed.append(result) }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func appendingModelHistoryToolOutput(
        to events: [Event],
        toolCall: ToolCall,
        observation: String,
        scope: ModelHistoryRecordingScope?
    ) -> [Event] {
        guard let scope else { return events }
        let sanitized = PermissionReviewTextSanitizer.sanitize(
            observation,
            maxCharacters: 65_536)
        return events + [.modelHistoryItem(.functionCallOutput(
            itemID: "model-history-output:\(scope.turnID.rawValue):\(toolCall.id)",
            turnID: scope.turnID,
            agent: agent.name,
            taskID: scope.taskID,
            submissionID: scope.submissionID,
            taskAttempt: scope.taskAttempt,
            callID: toolCall.id,
            output: sanitized.text))]
    }

    private func appendToolCompletion(
        _ events: [Event],
        toolCall: ToolCall,
        observation: String,
        modelHistoryScope: ModelHistoryRecordingScope?
    ) async throws {
        try await log.append(appendingModelHistoryToolOutput(
            to: events,
            toolCall: toolCall,
            observation: observation,
            scope: modelHistoryScope))
    }

    private func runTool(_ toolCall: ToolCall,
                         turnID: TurnID,
                         denialCircuitBreaker: ToolDenialCircuitBreaker,
                         sideEffectEvidence: SideEffectEvidenceLedger,
                         modelHistoryScope: ModelHistoryRecordingScope?) async throws -> String {
        try Task.checkCancellation()

        guard let tool = registry.tool(named: toolCall.name) else {
            let safeUnknownToolName = PermissionReviewTextSanitizer.sanitizeDiagnostic(
                toolCall.name,
                maxCharacters: 128).text
            try await appendDurableToolCall(
                toolCall,
                canonicalName: safeUnknownToolName,
                validatedArguments: nil,
                forceRedaction: true)
            let denialSignature = "unknown\u{001F}\(toolCall.name)\u{001F}\(toolCall.arguments.trimmingCharacters(in: .whitespacesAndNewlines))"
            if let repeatedAttempt = await denialCircuitBreaker.noteRepeatedAttempt(
                signature: denialSignature),
               repeatedAttempt >= 3 {
                throw AgentLoopError.repeatedDeniedToolCall(tool: toolCall.name)
            }
            let available = registry.descriptors().map(\.name).sorted().joined(separator: ", ")
            let message = available.isEmpty
                ? "unknown tool: \(safeUnknownToolName)"
                : "unknown tool: \(safeUnknownToolName). Available tools: \(available)"
            try await appendToolCompletion(
                [.toolResult(ToolResultPayload(
                    toolCallId: toolCall.id,
                    observation: message,
                    outcome: .failed,
                    failureSource: .runtimeFailed,
                    turnID: turnID))],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            return message
        }

        let descriptor = type(of: tool).descriptor
        let effectiveWorkspaceRoot = workspaceLease.map { URL(fileURLWithPath: $0.rootPath) }
            ?? agent.workspaceRoot
        let normalizedArguments: String
        switch normalizeToolArguments(toolCall.arguments, descriptor: descriptor) {
        case .valid(let arguments):
            normalizedArguments = arguments
            try await appendDurableToolCall(
                toolCall,
                canonicalName: descriptor.name,
                validatedArguments: arguments,
                forceRedaction: Self.redactsDurableArguments(for: descriptor.name))
        case .invalid(let message):
            try await appendDurableToolCall(
                toolCall,
                canonicalName: descriptor.name,
                validatedArguments: nil,
                forceRedaction: true)
            let denialSignature = "invalid\u{001F}\(descriptor.name)\u{001F}\(toolCall.arguments.trimmingCharacters(in: .whitespacesAndNewlines))"
            if let repeatedAttempt = await denialCircuitBreaker.noteRepeatedAttempt(
                signature: denialSignature),
               repeatedAttempt >= 3 {
                throw AgentLoopError.repeatedDeniedToolCall(tool: descriptor.name)
            }
            try await appendToolCompletion(
                [.toolResult(ToolResultPayload(
                    toolCallId: toolCall.id,
                    observation: message,
                    outcome: .failed,
                    failureSource: .runtimeFailed,
                    turnID: turnID))],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: invalidInputIntent(
                    tool: tool,
                    descriptor: descriptor,
                    rawArguments: toolCall.arguments,
                    workspaceRoot: effectiveWorkspaceRoot),
                authorization: nil)
            return message
        }

        let args = ToolArgs(raw: normalizedArguments)
        let touchedPaths = tool.touchedPaths(args)
        let baseIntent = tool.permissionIntent(args, workspaceRoot: effectiveWorkspaceRoot)
        let risksNetwork = tool.risksNetwork(args)
        if descriptor.name == "rename_session",
           Self.sessionRenameContainsSecret(normalizedArguments) {
            let reason = "the proposed session name appears to contain a secret"
            let message = Self.permissionDeniedMessage(reason)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        turnID: turnID,
                        toolCallID: toolCall.id,
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: reason,
                        intent: baseIntent,
                        source: .deterministicPolicy,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(
                signature: descriptor.name + "\u{001F}" + normalizedArguments)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: baseIntent,
                authorization: nil)
            return message
        }
        let sessionID = await log.sessionID
        let authorizationInvocation = ToolAuthorizationInvocationContext(
            sessionID: sessionID,
            agent: agent.name,
            taskID: context.taskContract?.id,
            rootTaskID: rootTaskID,
            parentTaskID: context.taskContract?.parentTaskID,
            attempt: taskAttempt,
            toolCallID: toolCall.id,
            taskObjective: context.taskContract.map {
                String($0.objective.prefix(1_200))
            })
        let denialSignature = descriptor.name + "\u{001F}" + normalizedArguments
        if let repeatedAttempt = await denialCircuitBreaker.noteRepeatedAttempt(
            signature: denialSignature) {
            let reason = "identical tool call was already denied in this agent run"
            let message = Self.permissionDeniedMessage(reason)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .medium,
                        reason: reason,
                        intent: baseIntent,
                        source: .deterministicPolicy,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            if repeatedAttempt >= 3 {
                throw AgentLoopError.repeatedDeniedToolCall(tool: descriptor.name)
            }
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: baseIntent,
                authorization: nil)
            return message
        }

        let authorizationID = IDGen.random(prefix: "tool-authorization")
        let preparation: ToolAuthorizationPreparation
        do {
            if let authorizationPreparer {
                preparation = try await authorizationPreparer(
                    ToolAuthorizationPreparationRequest(
                        authorizationID: authorizationID,
                        toolName: descriptor.name,
                        normalizedArguments: normalizedArguments,
                        baseIntent: baseIntent,
                        invocation: authorizationInvocation))
            } else {
                preparation = ToolAuthorizationPreparation(intent: baseIntent)
            }
        } catch {
            let reason = "authorization preflight failed: \(error.localizedDescription)"
            let message = Self.permissionDeniedMessage(reason)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: reason,
                        intent: baseIntent,
                        source: .authorizationRevalidation,
                        failureKind: .authorizationSnapshotInvalid,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: baseIntent,
                authorization: nil)
            return message
        }
        let intent = preparation.intent

        var authorization: ResolvedToolAuthorization
        do {
            authorization = try registry.resolveAuthorization(
                toolName: descriptor.name,
                intent: intent,
                risksNetwork: risksNetwork,
                normalizedArguments: normalizedArguments,
                authorizationID: authorizationID,
                invocation: authorizationInvocation,
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease,
                targetAgentInferenceBinding: preparation.targetAgentInferenceBinding)
        } catch {
            let reason = error.localizedDescription
            let message = Self.permissionDeniedMessage(reason)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: reason,
                        intent: intent,
                        source: .authorizationRevalidation,
                        failureKind: .authorizationSnapshotInvalid,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(
                signature: descriptor.name + "\u{001F}" + normalizedArguments)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: intent,
                authorization: nil)
            return message
        }
        if let leaseFailure = workspaceLeaseFailure(
            intent: intent,
            touchedPaths: touchedPaths) {
            let message = Self.permissionDeniedMessage(leaseFailure)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: leaseFailure,
                        intent: intent,
                        authorization: authorization,
                        source: .deterministicPolicy,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: intent,
                authorization: authorization)
            return message
        }
        let callContext = ToolCallContext(
            toolName: descriptor.name,
            sideEffect: descriptor.sideEffect,
            touchedPaths: touchedPaths,
            risksNetwork: risksNetwork,
            rawArgs: normalizedArguments,
            intent: intent)
        let effectiveProfile: PermissionProfile = workspaceLease?.access == .readOnly
            ? .readOnly
            : agent.profile
        let permissionContext = PermissionContext(
            workspaceRoot: effectiveWorkspaceRoot,
            profile: effectiveProfile,
            allowsShell: allowsShell,
            agent: agent.name)

        let engineDecision = await engine.decideDetailed(callContext, permissionContext)
        let outcome = engineDecision.outcome
        authorization = authorization.withDeterministicGate(
            Self.gateSnapshot(engineDecision.gate))
        if outcome.decision != .deny,
           let authorizationFailure = await authorizationRevalidationFailure(
            authorization,
            toolName: descriptor.name,
            normalizedArguments: normalizedArguments,
            intent: intent,
            risksNetwork: risksNetwork,
            invocation: authorizationInvocation
           ) {
            let message = Self.permissionDeniedMessage(authorizationFailure)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: authorizationFailure,
                        intent: intent,
                        authorization: authorization,
                        source: .authorizationRevalidation,
                        failureKind: .authorizationSnapshotInvalid,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: intent,
                authorization: authorization)
            return message
        }
        try Task.checkCancellation()
        let executionID = IDGen.random(prefix: "tool-execution")
        let replayPolicy = intent.replayPolicy
        let settled = try await settle(outcome,
                                       descriptor: descriptor,
                                       toolCall: ToolCall(id: toolCall.id,
                                                          name: toolCall.name,
                                                          arguments: normalizedArguments),
                                       turnID: turnID,
                                       callContext: callContext,
                                       authorization: authorization,
                                       executionID: executionID,
                                       replayPolicy: replayPolicy)
        try Task.checkCancellation()

        guard settled.decision == .allow else {
            let message = Self.permissionDeniedMessage(settled.reason)
            try await appendToolCompletion(
                [.toolResult(ToolResultPayload(
                    toolCallId: toolCall.id,
                    observation: message,
                    outcome: .denied,
                    failureSource: settled.failureSource ?? .policyDenied,
                    turnID: turnID,
                    permissionRequestID: settled.requestID))],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: intent,
                authorization: authorization)
            return message
        }

        if let authorizationFailure = await authorizationRevalidationFailure(
            authorization,
            toolName: descriptor.name,
            normalizedArguments: normalizedArguments,
            intent: intent,
            risksNetwork: risksNetwork,
            invocation: authorizationInvocation
        ) {
            let message = Self.permissionDeniedMessage(authorizationFailure)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: authorizationFailure,
                        intent: intent,
                        authorization: authorization,
                        source: .authorizationRevalidation,
                        failureKind: .authorizationSnapshotInvalid,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: intent,
                authorization: authorization)
            return message
        }

        // Permission review can be arbitrarily slow. Revalidate the pinned
        // workspace identity after that await boundary so an approved action
        // cannot be redirected into a replacement directory at the same path.
        if let leaseFailure = workspaceLeaseFailure(
            intent: intent,
            touchedPaths: callContext.touchedPaths) {
            let message = Self.permissionDeniedMessage(leaseFailure)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: leaseFailure,
                        intent: intent,
                        authorization: authorization,
                        source: .authorizationRevalidation,
                        failureKind: .authorizationSnapshotInvalid,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: intent,
                authorization: authorization)
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
            intent: intent,
            authorization: authorization,
            replayPolicy: replayPolicy)
        // This record is the durable boundary: if it cannot be written, the
        // executor is never invoked. An unresolved non-replayable record after
        // a crash forces reconciliation instead of blindly replaying the task.
        try await log.append(.toolExecutionPrepared(prepared))

        if let authorizationFailure = await authorizationRevalidationFailure(
            authorization,
            toolName: descriptor.name,
            normalizedArguments: normalizedArguments,
            intent: intent,
            risksNetwork: risksNetwork,
            invocation: authorizationInvocation
        ) {
            let message = Self.permissionDeniedMessage(authorizationFailure)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: authorizationFailure,
                        intent: intent,
                        authorization: authorization,
                        source: .authorizationRevalidation,
                        failureKind: .authorizationSnapshotInvalid,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                    .toolExecutionSettled(ToolExecutionSettledPayload(
                        prepared: prepared,
                        outcome: .denied,
                        effectDisposition: .notStarted,
                        reason: authorizationFailure)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: intent,
                authorization: authorization)
            return message
        }

        // The durable prepare append is another suspension point. Check once
        // more immediately before entering the executor. If the root changed,
        // settle the unused ticket explicitly; no side effect has run.
        if let leaseFailure = workspaceLeaseFailure(
            intent: intent,
            touchedPaths: callContext.touchedPaths) {
            let message = Self.permissionDeniedMessage(leaseFailure)
            try await appendToolCompletion(
                [
                    .permissionResolved(PermissionResolvedPayload(
                        tool: descriptor.name,
                        decision: .deny,
                        risk: .high,
                        reason: leaseFailure,
                        intent: intent,
                        authorization: authorization,
                        source: .authorizationRevalidation,
                        failureKind: .authorizationSnapshotInvalid,
                        failureSource: .policyDenied)),
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .policyDenied,
                        turnID: turnID)),
                    .toolExecutionSettled(ToolExecutionSettledPayload(
                        prepared: prepared,
                        outcome: .denied,
                        effectDisposition: .notStarted,
                        reason: leaseFailure)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: intent,
                authorization: authorization)
            return message
        }

        let toolContext = ToolContext(workspaceRoot: effectiveWorkspaceRoot,
                                      workspaceLease: workspaceLease,
                                      shell: shell,
                                      terminal: terminal,
                                      git: git,
                                      messenger: messenger,
                                      agentManager: agentManager,
                                      workTaskManager: workTaskManager,
                                      goalManager: goalManager,
                                      imageGenerator: imageGenerator,
                                      sessionNaming: sessionNaming,
                                      executionID: executionID,
                                      authorization: authorization)
        let observation: ToolObservation
        do {
            try Task.checkCancellation()
        } catch is CancellationError {
            let message = "tool cancelled before execution started"
            try await appendToolCompletion(
                [
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .failed,
                        failureSource: .turnCancelled,
                        turnID: turnID)),
                    .toolExecutionSettled(ToolExecutionSettledPayload(
                        prepared: prepared,
                        outcome: .cancelled,
                        effectDisposition: .notStarted,
                        reason: message)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: intent,
                authorization: authorization)
            throw CancellationError()
        }
        do {
            observation = try await tool.execute(args, in: toolContext)
        } catch is CancellationError {
            let message = replayPolicy == .requiresManualReconciliation
                ? "tool cancelled; manual reconciliation required because the side effect may already have occurred"
                : "tool cancelled after execution started; execution outcome is unresolved"
            // The executor boundary has been crossed. Even a cancellation from
            // a nominally replayable tool is not proof that its work stopped,
            // so leave the durable ticket unresolved.
            try await appendToolCompletion(
                [.toolResult(ToolResultPayload(
                    toolCallId: toolCall.id,
                    observation: message,
                    outcome: .failed,
                    failureSource: .turnCancelled,
                    turnID: turnID))],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            throw CancellationError()
        } catch let denial as WorkspaceSandboxDeniedError {
            let underlying = RuntimeErrorPresentation.message(for: denial)
            let message = "sandbox denied tool execution: \(underlying)"
            // The managed runner emits this type only for an attributable
            // wrapper-startup denial, before the target executable is entered.
            // That is a durable no-effect fact, but it is not a reason to
            // retry the command or widen its sandbox authority.
            try await appendToolCompletion(
                [
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .denied,
                        failureSource: .sandboxDenied,
                        turnID: turnID)),
                    .toolExecutionSettled(ToolExecutionSettledPayload(
                        prepared: prepared,
                        outcome: .denied,
                        effectDisposition: .notStarted,
                        reason: message)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: intent,
                authorization: authorization)
            await denialCircuitBreaker.recordDenial(signature: denialSignature)
            return message
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            let message = "tool error: \(rejection.message)"
            try await appendToolCompletion(
                [
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .failed,
                        failureSource: .runtimeFailed,
                        turnID: turnID)),
                    .toolExecutionSettled(ToolExecutionSettledPayload(
                        prepared: prepared,
                        outcome: .failed,
                        effectDisposition: .notStarted,
                        reason: message)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: intent,
                authorization: authorization)
            return message
        } catch {
            let underlying = RuntimeErrorPresentation.message(for: error)
            if replayPolicy == .requiresManualReconciliation {
                let message = "tool error: \(underlying); manual reconciliation required because the side effect may already have occurred"
                // Deliberately leave the execution ticket unresolved. A network,
                // process, or collaboration tool can commit its side effect and
                // still throw locally (for example after a timeout), so `failed`
                // is not proof that replay is safe.
                try await appendToolCompletion(
                    [.toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .failed,
                        failureSource: .runtimeFailed,
                        turnID: turnID))],
                    toolCall: toolCall,
                    observation: message,
                    modelHistoryScope: modelHistoryScope)
                throw AgentLoopError.toolExecutionRequiresManualReconciliation(
                    tool: descriptor.name,
                    executionID: executionID,
                    reason: underlying)
            }
            let message = "tool error: \(underlying)"
            try await appendToolCompletion(
                [
                    .toolResult(ToolResultPayload(
                        toolCallId: toolCall.id,
                        observation: message,
                        outcome: .failed,
                        failureSource: .runtimeFailed,
                        turnID: turnID)),
                    .toolExecutionSettled(ToolExecutionSettledPayload(
                        prepared: prepared,
                        outcome: .failed,
                        reason: message)),
                ],
                toolCall: toolCall,
                observation: message,
                modelHistoryScope: modelHistoryScope)
            await sideEffectEvidence.recordDenied(
                tool: descriptor.name,
                intent: intent,
                authorization: authorization)
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
            truncated: observation.truncated,
            outcome: .succeeded,
            turnID: turnID)))
        completionEvents.append(.toolExecutionSettled(ToolExecutionSettledPayload(
            prepared: prepared,
            outcome: .succeeded,
            effectDisposition: .committed)))
        try await appendToolCompletion(
            completionEvents,
            toolCall: toolCall,
            observation: observation.text,
            modelHistoryScope: modelHistoryScope)
        await sideEffectEvidence.recordSucceeded(
            intent: intent,
            authorization: authorization)
        // Persist completed side effects before surfacing a concurrent cancel.
        try Task.checkCancellation()
        return observation.text
    }

    /// Provider call IDs are opaque correlation keys, but some compatible
    /// endpoints omit them and the wire adapter historically falls back to
    /// `call_0` for each response. Keep a provider-supplied ID when it is unique
    /// within this AgentLoop turn; otherwise rewrite both the assistant call and
    /// its later tool output to one deterministic turn-local ID.
    private static func uniquedToolCalls(
        _ calls: [ToolCall],
        usedCallIDs: inout Set<String>,
        syntheticOrdinal: inout Int
    ) -> [ToolCall] {
        calls.map { call in
            if !call.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               usedCallIDs.insert(call.id).inserted {
                return call
            }

            var candidate: String
            repeat {
                candidate = "call_intatis_\(syntheticOrdinal)"
                syntheticOrdinal += 1
            } while !usedCallIDs.insert(candidate).inserted
            return ToolCall(
                id: candidate,
                name: call.name,
                arguments: call.arguments)
        }
    }

    /// Builds the durable provider-history form before any tool in the
    /// assistant batch executes. The live request keeps the provider's exact
    /// arguments; restart history keeps exact canonical JSON only when it is
    /// schema-valid, bounded, and contains no scrubbed secret material.
    private func modelHistoryFunctionCalls(
        _ toolCalls: [ToolCall]
    ) throws -> [ModelHistoryFunctionCall] {
        var seenCallIDs = Set<String>()
        var result: [ModelHistoryFunctionCall] = []
        result.reserveCapacity(toolCalls.count)

        for call in toolCalls {
            let trimmedCallID = call.id.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !trimmedCallID.isEmpty,
                  seenCallIDs.insert(call.id).inserted else {
                throw AgentModelHistoryProjectionError.ambiguousCallID(
                    call.id)
            }

            guard let tool = registry.tool(named: call.name) else {
                let sanitizedName = PermissionReviewTextSanitizer
                    .sanitizeDiagnostic(call.name, maxCharacters: 128)
                    .text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(ModelHistoryFunctionCall(
                    callID: call.id,
                    name: sanitizedName.isEmpty ? "unknown_tool" : sanitizedName,
                    arguments: #"{"_intatis":"arguments_redacted"}"#,
                    argumentsRedacted: true))
                continue
            }

            let descriptor = type(of: tool).descriptor
            let durableArguments: String
            let argumentsRedacted: Bool
            switch normalizeToolArguments(
                call.arguments,
                descriptor: descriptor)
            {
            case .valid(let canonical)
                where !Self.redactsDurableArguments(
                    for: descriptor.name):
                let sanitized = PermissionReviewTextSanitizer.sanitize(
                    canonical,
                    maxCharacters: 8_192)
                if sanitized.redacted || sanitized.truncated {
                    durableArguments = #"{"_intatis":"arguments_redacted"}"#
                    argumentsRedacted = true
                } else {
                    durableArguments = canonical
                    argumentsRedacted = false
                }
            case .valid, .invalid:
                durableArguments = #"{"_intatis":"arguments_redacted"}"#
                argumentsRedacted = true
            }
            result.append(ModelHistoryFunctionCall(
                callID: call.id,
                name: descriptor.name,
                arguments: durableArguments,
                argumentsRedacted: argumentsRedacted))
        }
        return result
    }

    /// Durable tool-call events are an audit/display surface, not a raw model
    /// argument store. Unknown or schema-invalid calls are never persisted
    /// verbatim. Inference-control calls are also fully redacted because even
    /// a valid string field could otherwise smuggle an endpoint, header,
    /// credential, or provider-native option into EventLog before the
    /// authorization layer rejects it. Other validated tools retain a bounded,
    /// secret-scrubbed display value while their exact identity is carried by
    /// the additive digest and character count.
    private func appendDurableToolCall(
        _ toolCall: ToolCall,
        canonicalName: String,
        validatedArguments: String?,
        forceRedaction: Bool
    ) async throws {
        let rawArguments = toolCall.arguments
        let displayArguments: String
        let redacted: Bool
        let durableDigest: String?
        if forceRedaction || validatedArguments == nil {
            displayArguments = #"{"_intatis":"arguments_redacted"}"#
            redacted = true
            // Never turn rejected/inference-control secret material into an
            // offline verifier. A plain digest of low-entropy endpoints,
            // headers, or credentials is still sensitive.
            durableDigest = nil
        } else {
            let sanitized = PermissionReviewTextSanitizer.sanitize(
                validatedArguments!,
                maxCharacters: 8_192)
            displayArguments = sanitized.text
            redacted = sanitized.redacted || sanitized.truncated
            durableDigest = redacted
                ? nil
                : ToolRegistry.authorizationDigest(validatedArguments!)
        }
        try await log.append(.toolCall(ToolCallPayload(
            toolCallId: toolCall.id,
            agent: agent.name,
            name: canonicalName,
            args: displayArguments,
            argsDigest: durableDigest,
            argsCharacterCount: rawArguments.count,
            argsRedacted: redacted)))
    }

    private static func redactsDurableArguments(for toolName: String) -> Bool {
        toolName == "spawn_agent"
            || toolName == "rename_session"
            || toolName == "write_stdin"
    }

    private static func sessionRenameContainsSecret(_ normalizedArguments: String) -> Bool {
        struct Arguments: Decodable { var name: String }
        guard let data = normalizedArguments.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(Arguments.self, from: data) else {
            return false
        }
        return SecretScanner.containsSecret(arguments.name)
    }

    private enum ToolArgumentNormalization {
        case valid(String)
        case invalid(String)
    }

    private func invalidInputIntent(tool: any Tool,
                                    descriptor: ToolDescriptor,
                                    rawArguments: String,
                                    workspaceRoot: URL) -> PermissionIntent {
        let args = ToolArgs(raw: rawArguments)
        var intent = tool.permissionIntent(args, workspaceRoot: workspaceRoot)
        guard intent.resources.isEmpty else { return intent }

        var paths = tool.touchedPaths(args)
        if paths.isEmpty,
           let data = rawArguments.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .object(let object) = decoded,
           case .string(let path)? = object["path"],
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            paths = [path]
        }
        if !paths.isEmpty {
            let access: WorkspaceAccess = descriptor.sideEffect == .readOnly
                ? .readOnly
                : .readWrite
            intent.resources = paths.map {
                PermissionResource(kind: .workspacePath, value: $0, access: access)
            }
        }
        return intent
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
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard let canonical = try? encoder.encode(JSONValue.object(object)) else {
                    return .invalid("invalid tool input: arguments for \(descriptor.name) could not be normalized.")
                }
                return .valid(String(decoding: canonical, as: UTF8.self))
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
        var requestID: RequestID? = nil
        var failureSource: ExecutionFailureSource? = nil
    }

    private func authorizationRevalidationFailure(
        _ authorization: ResolvedToolAuthorization,
        toolName: String,
        normalizedArguments: String,
        intent: PermissionIntent,
        risksNetwork: Bool,
        invocation: ToolAuthorizationInvocationContext
    ) async -> String? {
        do {
            try registry.validateAuthorizationSnapshot(
                authorization,
                toolName: toolName,
                normalizedArguments: normalizedArguments,
                intent: intent,
                risksNetwork: risksNetwork,
                invocation: invocation,
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease)
        } catch {
            return error.localizedDescription
        }
        return await authorizationRevalidator?(authorization)
    }

    /// Permission reasons are stored without presentation text. Defensively
    /// normalize custom responders and injected revalidators at the final
    /// ToolResult boundary so the UI never shows repeated denial prefixes.
    private static func permissionDeniedMessage(_ rawReason: String) -> String {
        var reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "permission denied:"
        while reason.lowercased().hasPrefix(prefix) {
            reason = String(reason.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return reason.isEmpty ? "permission denied" : "permission denied: \(reason)"
    }

    private static func gateSnapshot(_ result: GateResult) -> PermissionReviewGateSnapshot {
        switch result {
        case .deny(let reason, let risk):
            return PermissionReviewGateSnapshot(
                decision: .deny, risk: risk, reason: reason,
                policyVersion: "intatis.deterministic-policy.v1")
        case .ask(let reason, let risk):
            return PermissionReviewGateSnapshot(
                decision: .ask, risk: risk, reason: reason,
                policyVersion: "intatis.deterministic-policy.v1")
        case .allow(let reason, let risk):
            return PermissionReviewGateSnapshot(
                decision: .allow, risk: risk, reason: reason,
                policyVersion: "intatis.deterministic-policy.v1")
        case .pass(let reason, let risk):
            return PermissionReviewGateSnapshot(
                decision: .pass, risk: risk, reason: reason,
                policyVersion: "intatis.deterministic-policy.v1")
        }
    }

    /// Emit the right audit events and, for `ask_user`, await the responder.
    private func settle(_ outcome: PermissionOutcome,
                        descriptor: ToolDescriptor,
                        toolCall: ToolCall,
                        turnID: TurnID,
                        callContext: ToolCallContext,
                        authorization: ResolvedToolAuthorization,
                        executionID: String,
                        replayPolicy: ToolExecutionReplayPolicy) async throws -> SettledPermission {
        switch outcome.decision {
        case .allow, .deny:
            try await log.append(.permissionResolved(PermissionResolvedPayload(
                turnID: turnID,
                toolCallID: toolCall.id,
                tool: descriptor.name,
                decision: outcome.decision,
                risk: outcome.risk,
                reason: outcome.reason,
                intent: callContext.intent,
                authorization: authorization,
                source: .deterministicPolicy,
                failureSource: outcome.decision == .deny ? .policyDenied : nil)))
            return SettledPermission(
                decision: outcome.decision,
                reason: outcome.reason,
                failureSource: outcome.decision == .deny ? .policyDenied : nil)

        case .askUser:
            let requestID = RequestID.new()
            let boundedArguments = "digest=\(authorization.normalizedArgumentsDigest); characters=\(authorization.normalizedArgumentsCharacterCount)"
            let request = PermissionRequestPayload(
                requestId: requestID, agent: agent.name, tool: descriptor.name,
                args: context.runtimeEnvironment.mode == .cowork
                    || Self.redactsDurableArguments(for: descriptor.name)
                    ? boundedArguments
                    : toolCall.arguments,
                risk: outcome.risk, reason: outcome.reason,
                context: permissionRequestContext(
                    outcome: outcome,
                    callContext: callContext,
                    toolCall: toolCall,
                    turnID: turnID,
                    authorization: authorization,
                    executionID: executionID,
                    replayPolicy: replayPolicy),
                approvalMode: responder.approvalMode)
            try await log.append([
                .permissionRequest(request),
                .agentStatus(AgentStatusPayload(agent: agent.name, state: .blocked)),
            ])

            let resolution: PermissionApprovalResolution
            do {
                resolution = try await awaitPermissionApproval(request)
                try Task.checkCancellation()
            } catch is CancellationError {
                let cancelled = PermissionResolvedPayload(
                    requestId: requestID,
                    turnID: turnID,
                    toolCallID: toolCall.id,
                    tool: descriptor.name,
                    decision: .deny,
                    risk: outcome.risk,
                    reason: "permission request cancelled",
                    intent: callContext.intent,
                    authorization: authorization,
                    source: .callerCancellation,
                    reviewStatus: .cancelled,
                    failureKind: .callerCancelled,
                    failureSource: .turnCancelled)
                do {
                    _ = try await log.settlePermissionRequest(cancelled)
                } catch EventLogError.conflictingPermissionSettlement {
                    // Another terminal response may have won immediately
                    // before cancellation. Authorization delivery remains
                    // fenced by the thrown cancellation below.
                }
                throw CancellationError()
            }
            let userDecision: PermissionDecision = resolution.decision == .allow ? .allow : .deny
            let suppliedReason = resolution.reason?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedReason: String
            if let suppliedReason, !suppliedReason.isEmpty {
                resolvedReason = suppliedReason
            } else {
                resolvedReason = userDecision == .allow
                    ? "permission approved"
                    : outcome.reason
            }
            let failureSource = Self.permissionFailureSource(
                resolution,
                effectiveDecision: userDecision)
            let durableResolution = PermissionResolvedPayload(
                requestId: requestID,
                turnID: turnID,
                toolCallID: toolCall.id,
                tool: descriptor.name,
                decision: userDecision,
                risk: resolution.risk ?? outcome.risk,
                reason: resolvedReason,
                intent: callContext.intent,
                authorization: authorization,
                source: resolution.source,
                reviewTaskID: resolution.reviewTaskID,
                reviewStatus: resolution.reviewStatus,
                failureKind: resolution.failureKind,
                failureSource: failureSource,
                action: resolution.action)
            let settlement = try await log.settlePermissionRequest(durableResolution)
            if resolution.effectiveAction == .cancelTurn {
                throw AgentTurnInterruptedError(
                    reason: resolvedReason,
                    failureSource: failureSource ?? .userCancelled)
            }
            try await log.append(.agentStatus(AgentStatusPayload(agent: agent.name, state: .tool)))
            return SettledPermission(
                decision: settlement.resolution.decision,
                reason: settlement.resolution.reason,
                requestID: requestID,
                failureSource: settlement.resolution.failureSource)
        }
    }

    private static func permissionFailureSource(
        _ resolution: PermissionApprovalResolution,
        effectiveDecision: PermissionDecision
    ) -> ExecutionFailureSource? {
        if let failureSource = resolution.failureSource { return failureSource }
        if resolution.effectiveAction == .cancelTurn { return .userCancelled }
        if resolution.failureKind == .reviewerTimedOut { return .reviewerTimedOut }
        if resolution.failureKind != nil { return .reviewerFailed }
        guard effectiveDecision == .deny else { return nil }
        switch resolution.source {
        case .user:
            return .userDenied
        case .callerCancellation:
            return .userCancelled
        case .automaticReviewerFailure:
            return .reviewerFailed
        case .automaticReviewer, .deterministicPolicy, .authorizationRevalidation:
            return .policyDenied
        }
    }

    private func permissionRequestContext(outcome: PermissionOutcome,
                                          callContext: ToolCallContext,
                                          toolCall: ToolCall,
                                          turnID: TurnID,
                                          authorization: ResolvedToolAuthorization,
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
        let gateSnapshot: PermissionReviewGateSnapshot
        if let resolvedGate = authorization.deterministicGate {
            gateSnapshot = resolvedGate
        } else {
            let gateDecision: PermissionReviewGateDecision
            switch outcome.decision {
            case .allow: gateDecision = .allow
            case .deny: gateDecision = .deny
            case .askUser: gateDecision = .ask
            }
            gateSnapshot = PermissionReviewGateSnapshot(
                decision: gateDecision,
                risk: outcome.risk,
                reason: outcome.reason,
                policyVersion: "intatis.deterministic-policy.v1")
        }
        return PermissionRequestContext(
            turnID: turnID,
            taskID: contract?.id,
            rootTaskID: rootTaskID,
            parentTaskID: contract?.parentTaskID,
            attempt: taskAttempt,
            toolCallID: toolCall.id,
            normalizedArgs: "digest=\(authorization.normalizedArgumentsDigest); characters=\(authorization.normalizedArgumentsCharacterCount)",
            touchedPaths: callContext.touchedPaths,
            risksNetwork: callContext.risksNetwork,
            sideEffect: callContext.sideEffect,
            intent: callContext.intent,
            gate: gateSnapshot,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease,
            taskContract: contract,
            causalContext: PermissionReviewCausalContext(
                userGoal: contract?.objective,
                issuer: contract?.issuer,
                assignee: contract?.assignee,
                taskLineage: lineage,
                relatedAgents: relatedAgents),
            authorization: authorization,
            executionID: executionID,
            replayPolicy: replayPolicy.rawValue)
    }

    private func awaitPermissionApproval(_ request: PermissionRequestPayload) async throws -> PermissionApprovalResolution {
        let gate = PermissionApprovalGate()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let approvalTask = Task {
                    let resolution = await responder.requestResolution(request)
                    gate.resolve(.success(resolution))
                }
                gate.setApprovalTask(approvalTask)
            }
        }, onCancel: {
            gate.cancel()
        })
    }

    private func projectedHistory(
        recoveredEvents: [Envelope]? = nil,
        excludingCurrentAndLaterSubmissionsFrom submissionID: SubmissionID? = nil
    ) async throws -> [AgentMessage] {
        switch context.conversationHistoryPolicy {
        case .taskScoped:
            return []
        case .coworkMainThread:
            guard context.runtimeEnvironment.mode == .cowork,
                  context.contextBundle != nil,
                  let currentTask = context.taskContract else {
                return []
            }
            let events: [Envelope]
            if let recoveredEvents {
                events = recoveredEvents
            } else {
                let replay = try await log.replayForProjectionChecked()
                guard replay.hasCompleteKnownHistory else {
                    throw EventLogError.unsupportedEventTypes
                }
                events = replay.envelopes
            }
            return try AgentModelHistoryProjector().project(
                agentID: agent.name,
                currentTask: currentTask,
                events: events)
        case .conversation:
            return await priorHistory(
                recoveredEvents: recoveredEvents,
                excludingCurrentAndLaterSubmissionsFrom: submissionID)
        }
    }

    private func priorHistory(
        recoveredEvents: [Envelope]? = nil,
        excludingCurrentAndLaterSubmissionsFrom submissionID: SubmissionID? = nil
    ) async -> [AgentMessage] {
        // Cowork already performed a strict replay at the start of `send`.
        // Reuse that verified snapshot so a safety-sensitive run never falls
        // back to the compatibility replay that skips malformed records.
        let events: [Envelope]
        if let recoveredEvents {
            events = recoveredEvents
        } else {
            events = await log.replay()
        }
        let projectedEvents = Self.historyEvents(
            events,
            excludingCurrentAndLaterSubmissionsFrom: submissionID)
        let projection = ConversationProjection.build(from: projectedEvents)
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

    /// A submitted intent is durable before it reaches AgentLoop. While an
    /// earlier turn runs, later intents may already be present in EventLog.
    /// Build model history by logical submission order instead of raw append
    /// order: exclude the current/later user turns and their correlated model
    /// output, while retaining a prior turn's response even when that response
    /// was appended after a later intent was accepted.
    private static func historyEvents(
        _ events: [Envelope],
        excludingCurrentAndLaterSubmissionsFrom submissionID: SubmissionID?
    ) -> [Envelope] {
        guard let submissionID,
              let currentAcceptedSeq = events.first(where: { envelope in
                  guard case .userMessage(let payload) = envelope.event else { return false }
                  return payload.submissionID == submissionID
              })?.seq else {
            return events
        }

        var acceptedSequenceBySubmission: [SubmissionID: Int] = [:]
        for envelope in events {
            guard case .userMessage(let payload) = envelope.event,
                  let id = payload.submissionID,
                  acceptedSequenceBySubmission[id] == nil else { continue }
            acceptedSequenceBySubmission[id] = envelope.seq
        }

        return events.filter { envelope in
            let correlatedSubmissionID: SubmissionID?
            switch envelope.event {
            case .userMessage(let payload):
                correlatedSubmissionID = payload.submissionID
            case .messageDelta(let payload):
                correlatedSubmissionID = payload.submissionID
            case .messageCompleted(let payload):
                correlatedSubmissionID = payload.submissionID
            case .error(let payload):
                correlatedSubmissionID = payload.submissionID
            default:
                correlatedSubmissionID = nil
            }
            guard let correlatedSubmissionID,
                  let acceptedSeq = acceptedSequenceBySubmission[correlatedSubmissionID] else {
                return true
            }
            return acceptedSeq < currentAcceptedSeq
        }
    }
}
