import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
import IntatisAgentKernel

public enum OrchestratorSendResult: Equatable, Sendable {
    case sent
    case failed(String)

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

public enum AutomaticPermissionReviewResult: Equatable, Sendable {
    case enabled(AgentID)
    case alreadyEnabled(AgentID)
    case failed(String)
}

public enum AutomaticPermissionReviewDisableResult: Equatable, Sendable {
    case disabled(AgentID)
    case alreadyDisabled
    case failed(String)
}

public struct CoworkExecutionPolicy: Equatable, Sendable {
    public var maxConcurrentTasks: Int
    public var taskTimeoutSeconds: Double
    public var maxAttempts: Int
    public var tokenBudget: Int?

    public init(maxConcurrentTasks: Int = 4,
                taskTimeoutSeconds: Double = 300,
                maxAttempts: Int = 3,
                tokenBudget: Int? = nil) {
        self.maxConcurrentTasks = max(1, maxConcurrentTasks)
        self.taskTimeoutSeconds = max(0.01, taskTimeoutSeconds)
        self.maxAttempts = max(1, maxAttempts)
        self.tokenBudget = tokenBudget.flatMap { $0 > 0 ? $0 : nil }
    }

    public static let `default` = CoworkExecutionPolicy()
}

public enum CoworkTaskExecutionError: Error, Equatable, Sendable, LocalizedError {
    case timedOut(seconds: Double)
    case tokenBudgetExhausted(limit: Int)
    case cancelled(String)
    case invalidLease(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            let rendered = seconds.rounded() == seconds
                ? String(Int(seconds))
                : String(format: "%.2f", seconds)
            return "Task timed out after \(rendered) seconds."
        case .tokenBudgetExhausted(let limit):
            return "Cowork token budget of \(limit) tokens is exhausted."
        case .cancelled(let reason):
            return "Task cancelled: \(reason)"
        case .invalidLease(let reason):
            return "Task lease is invalid: \(reason)"
        }
    }
}

private enum ScheduledReplyFormat: Sendable {
    case answer
    case taskReport
}

private enum CommunicationOperation: Equatable, Sendable {
    case send
    case requestInformation
    case reply
}

private struct RootInvocationContext: Sendable {
    var images: [ImageAttachment]
    var userMessage: UserMessagePayload?
}

private struct AgentRunResult: Sendable {
    var output: String
    var presentedMessageIDs: [MessageID]
}

private struct TaskLeaseRenewal: Sendable {
    var contract: TaskContract
    var capabilityLease: CapabilityLease?
    var workspaceLease: WorkspaceLease?
}

private enum RetryAdmissionResult: Sendable {
    case admitted(TaskID)
    case rejected(String)
}

private final class CoworkTimeoutGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var resolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let result: Result<Value, Error>?
        lock.lock()
        if let pendingResult {
            result = pendingResult
            self.pendingResult = nil
        } else {
            self.continuation = continuation
            result = nil
        }
        lock.unlock()
        if let result { continuation.resume(with: result) }
    }

    func setTasks(_ tasks: [Task<Void, Never>]) {
        let shouldCancel: Bool
        lock.lock()
        if resolved {
            shouldCancel = true
        } else {
            self.tasks = tasks
            shouldCancel = false
        }
        lock.unlock()
        if shouldCancel { tasks.forEach { $0.cancel() } }
    }

    func resolve(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>?
        let tasks: [Task<Void, Never>]
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pendingResult = result }
        tasks = self.tasks
        self.tasks.removeAll()
        lock.unlock()

        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

private func withTaskTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let boundedSeconds = max(0.001, seconds)
    let gate = CoworkTimeoutGate<T>()
    return try await withTaskCancellationHandler(operation: {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            // Detached tasks must not inherit the Orchestrator actor executor:
            // a provider is allowed to block synchronously while constructing
            // its stream, and that must not starve the independent watchdog.
            let operationTask = Task.detached(priority: nil) {
                do {
                    gate.resolve(.success(try await operation()))
                } catch {
                    gate.resolve(.failure(error))
                }
            }
            let timeoutTask = Task.detached(priority: nil) {
                do {
                    let nanos = UInt64(
                        min(boundedSeconds, Double(UInt64.max) / 1_000_000_000)
                            * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanos)
                    gate.resolve(.failure(CoworkTaskExecutionError.timedOut(
                        seconds: boundedSeconds)))
                } catch is CancellationError {
                    // The operation won the race or the caller was cancelled.
                } catch {
                    gate.resolve(.failure(error))
                }
            }
            gate.setTasks([operationTask, timeoutTask])
        }
    }, onCancel: {
        gate.resolve(.failure(CancellationError()))
    })
}

/// Coordinates multiple agents over one shared event log (ARCHITECTURE.md §7).
/// Routes `@mentioned` user messages to the right agent, and mediates every
/// agent-to-agent exchange through the Message Bus. An `actor`, so concurrent /
/// reentrant agent runs serialize safely.
public actor Orchestrator {
    public static let mainAgentID = AgentID(rawValue: "main")
    public static let automaticPermissionReviewerID = AgentID(rawValue: "permission-reviewer")

    private let log: EventLog
    /// Retained for the runtime lifetime. The public runtime initializer
    /// requires this lease so a second process cannot schedule the same session.
    private let writerLease: EventLogWriterLease?
    private var registry: AgentRegistry
    private let bus: MessageBus
    private let engine: PermissionEngine
    private let allowsShell: Bool
    private let responder: PermissionResponder
    private var automaticPermissionResponder: AgentPermissionResponder?
    private var automaticPermissionReviewerAgentID: AgentID?
    private var automaticPermissionReviewDisabling: Bool
    private var automaticPermissionReviewRecoveryFailure: String?
    private var capabilityLeases: [CapabilityLeaseID: CapabilityLease]
    private var workspaceLeases: [WorkspaceLeaseID: WorkspaceLease]
    private var capabilityLeaseHistory: [CapabilityLeaseID: CapabilityLease]
    private var workspaceLeaseHistory: [WorkspaceLeaseID: WorkspaceLease]
    private var defaultCapabilityLeaseIDs: [AgentID: CapabilityLeaseID]
    private var defaultWorkspaceLeaseIDs: [AgentID: WorkspaceLeaseID]
    private var scheduler: AgentScheduler
    private var taskGraph: TaskGraph
    private var scheduledReplyTargets: [TaskID: AgentID]
    private var scheduledReplyFormats: [TaskID: ScheduledReplyFormat]
    private var scheduledReplyResults: [TaskID: String]
    private var spawnedAgentOwners: [AgentID: AgentID]
    private var executionPolicy: CoworkExecutionPolicy
    private var runningExecutions: [TaskID: Task<Void, Never>]
    private var resultWaiters: [TaskID: [CheckedContinuation<String?, Never>]]
    private var idleWaiters: [CheckedContinuation<Void, Never>]
    private var rootInvocations: [TaskID: RootInvocationContext]
    private var cancellationReasons: [TaskID: String]
    private var restoredPendingTaskIDs: Set<TaskID>
    private var consumedTokenCount: Int
    /// One actor for the full Cowork session lifetime. Its optional limit is
    /// reconfigured in place; it is never swapped when policy changes.
    private let tokenBudgetMeter: AgentTokenBudgetMeter
    private var schedulerSuspensionTokens: Set<UUID>
    private var schedulerResumeRequested: Bool
    private var schedulerSuspended: Bool { !schedulerSuspensionTokens.isEmpty }
    private let reasoningEffort: ReasoningEffort?
    private let includeUsage: Bool
    private let maxSteps: Int
    private let providerFor: @Sendable (Agent) async throws -> ToolCallingProvider
    private let imageGeneratorFor: @Sendable (Agent) async -> ImageGenerationToolService?
    private var messageConsumptionAppender: (@Sendable (AgentMessageConsumedPayload) async throws -> Void)?
    private var taskLifecycleEventAppender: (@Sendable (Event) async throws -> Void)?
    private var terminalPersistenceFailures: [TaskID: String]
    private var terminalCommitTaskIDs: Set<TaskID>
    private var taskStartGate: (@Sendable (TaskID) async -> Void)?
    private var cancelAllBeforeResumeHook: (@Sendable () async -> Void)?
    private var admissionEventAppender: (@Sendable (Event) async throws -> Void)?
    private var admissionEventsAppender: (@Sendable ([Event]) async throws -> Void)?
    private var admissionLocked: Bool
    private var admissionWaiters: [CheckedContinuation<Void, Never>]
    private var executionPolicyUpdateLocked: Bool
    private var executionPolicyUpdateWaiters: [CheckedContinuation<Void, Never>]
    private var executionPolicyUpdateInProgress: Bool

    /// The only shipping-runtime constructor. It atomically acquires and retains
    /// the process-level EventLog writer lease before any scheduler exists.
    public static func runtime(
        log: EventLog,
        mediator: Mediator = Mediator(),
        engine: PermissionEngine = PermissionEngine(),
        allowsShell: Bool,
        responder: PermissionResponder,
        reasoningEffort: ReasoningEffort? = nil,
        includeUsage: Bool = false,
        maxSteps: Int = 50,
        executionPolicy: CoworkExecutionPolicy = .default,
        taskGraphPolicy: TaskGraphPolicy = .default,
        imageGeneratorFor: @escaping @Sendable (Agent) async -> ImageGenerationToolService? = { _ in nil },
        providerFor: @escaping @Sendable (Agent) async throws -> ToolCallingProvider
    ) throws -> Orchestrator {
        let writerLease = try log.acquireWriterLease()
        return Orchestrator(
            log: log,
            mediator: mediator,
            engine: engine,
            allowsShell: allowsShell,
            responder: responder,
            reasoningEffort: reasoningEffort,
            includeUsage: includeUsage,
            maxSteps: maxSteps,
            executionPolicy: executionPolicy,
            taskGraphPolicy: taskGraphPolicy,
            imageGeneratorFor: imageGeneratorFor,
            writerLease: writerLease,
            providerFor: providerFor)
    }

    /// Internal unlocked constructor for isolated `@testable` unit tests.
    /// Other package targets cannot bypass the process-level session writer
    /// lease; shipping callers must use `runtime`.
    init(log: EventLog,
                mediator: Mediator = Mediator(),
                engine: PermissionEngine = PermissionEngine(),
                allowsShell: Bool,
                responder: PermissionResponder,
                reasoningEffort: ReasoningEffort? = nil,
                includeUsage: Bool = false,
                maxSteps: Int = 50,
                executionPolicy: CoworkExecutionPolicy = .default,
                taskGraphPolicy: TaskGraphPolicy = .default,
                imageGeneratorFor: @escaping @Sendable (Agent) async -> ImageGenerationToolService? = { _ in nil },
                writerLease: EventLogWriterLease? = nil,
                providerFor: @escaping @Sendable (Agent) async throws -> ToolCallingProvider) {
        self.log = log
        self.writerLease = writerLease
        self.registry = AgentRegistry()
        self.bus = MessageBus(log: log, mediator: mediator)
        self.engine = engine
        self.allowsShell = allowsShell
        self.responder = responder
        self.automaticPermissionResponder = nil
        self.automaticPermissionReviewerAgentID = nil
        self.automaticPermissionReviewDisabling = false
        self.automaticPermissionReviewRecoveryFailure = nil
        self.capabilityLeases = [:]
        self.workspaceLeases = [:]
        self.capabilityLeaseHistory = [:]
        self.workspaceLeaseHistory = [:]
        self.defaultCapabilityLeaseIDs = [:]
        self.defaultWorkspaceLeaseIDs = [:]
        self.scheduler = AgentScheduler()
        self.taskGraph = TaskGraph(policy: taskGraphPolicy)
        self.scheduledReplyTargets = [:]
        self.scheduledReplyFormats = [:]
        self.scheduledReplyResults = [:]
        self.spawnedAgentOwners = [:]
        self.executionPolicy = executionPolicy
        self.runningExecutions = [:]
        self.resultWaiters = [:]
        self.idleWaiters = []
        self.rootInvocations = [:]
        self.cancellationReasons = [:]
        self.restoredPendingTaskIDs = []
        self.consumedTokenCount = 0
        self.tokenBudgetMeter = AgentTokenBudgetMeter(limit: executionPolicy.tokenBudget)
        self.schedulerSuspensionTokens = []
        self.schedulerResumeRequested = false
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage || executionPolicy.tokenBudget != nil
        self.maxSteps = maxSteps
        self.providerFor = providerFor
        self.imageGeneratorFor = imageGeneratorFor
        self.messageConsumptionAppender = nil
        self.taskLifecycleEventAppender = nil
        self.terminalPersistenceFailures = [:]
        self.terminalCommitTaskIDs = []
        self.taskStartGate = nil
        self.cancelAllBeforeResumeHook = nil
        self.admissionEventAppender = nil
        self.admissionEventsAppender = nil
        self.admissionLocked = false
        self.admissionWaiters = []
        self.executionPolicyUpdateLocked = false
        self.executionPolicyUpdateWaiters = []
        self.executionPolicyUpdateInProgress = false
    }

    @discardableResult
    public func attach(_ agent: Agent,
                       admissionIssuer: AgentID? = nil,
                       causalParentTaskID: TaskID? = nil) async -> Bool {
        let id = agent.name
        if let validationError = Self.agentNameValidationError(id.rawValue) {
            try? await log.append(.error(ErrorPayload(
                code: "invalid_agent_name",
                message: validationError)))
            return false
        }
        guard id != Self.automaticPermissionReviewerID else {
            try? await log.append(.error(ErrorPayload(
                code: "reserved_agent",
                message: "@\(id.rawValue) is reserved for automatic permission review")))
            return false
        }
        guard registry.agent(id) == nil else {
            try? await log.append(.error(ErrorPayload(code: "agent_exists",
                                                       message: "agent @\(id.rawValue) already exists")))
            return false
        }

        let assessment = assessWorkspaceAttach(agent.workspaceRoot)
        var proposedAgent = agent
        if let canonical = assessment.canonical {
            proposedAgent.workspaceRoot = canonical
        }
        // Freeze the exact leases before review. The same values are embedded in
        // the durable review task and committed after allow; regenerating them
        // after review would create an admission TOCTOU boundary.
        let proposedLeases = prepareDefaultLeases(for: proposedAgent)
        let requestID = RequestID.new()
        let admissionTaskID = TaskID.new()
        let admissionRootTaskID = causalParentTaskID.flatMap {
            taskGraph.node($0)?.rootTaskID
        } ?? causalParentTaskID ?? admissionTaskID
        let admissionAttempt = 1
        let assessedPath = proposedAgent.workspaceRoot.path
        let canCoordinate = proposedAgent.coordinationDepth > 0
        let admissionRole = canCoordinate ? "coordinator" : "worker"
        let admissionContract = TaskContract(
            id: admissionTaskID,
            kind: .agentAdmission,
            issuer: admissionIssuer,
            assignee: proposedAgent.name,
            parentTaskID: causalParentTaskID,
            objective: "Attach @\(proposedAgent.name.rawValue) to \(assessedPath) as a \(admissionRole).",
            roleHint: "agent workspace admission",
            expectedDeliverable: "Durably attach the agent with exactly the reviewed workspace and capability leases.",
            workspaceID: proposedLeases.workspace.workspaceID,
            workspaceLeaseID: proposedLeases.workspace.id,
            capabilityLeaseID: proposedLeases.capability.id,
            relatedAgents: admissionIssuer.map { [$0] } ?? [],
            relatedTasks: causalParentTaskID.map { [$0] } ?? [],
            constraints: [
                "coordinationDepth=\(proposedAgent.coordinationDepth)",
                "canCoordinate=\(canCoordinate)",
                "persistentDefaultLeases=true",
            ],
            replyMode: TaskReplyMode.none,
            maxAttempts: 1)
        var admissionLineage = [admissionRootTaskID]
        if let causalParentTaskID, !admissionLineage.contains(causalParentTaskID) {
            admissionLineage.append(causalParentTaskID)
        }
        if !admissionLineage.contains(admissionTaskID) {
            admissionLineage.append(admissionTaskID)
        }
        let normalizedAttachArgs = attachArgs(
            agent: proposedAgent,
            canonicalPath: assessedPath,
            admissionTaskID: admissionTaskID,
            capabilityLease: proposedLeases.capability,
            workspaceLease: proposedLeases.workspace)
        let request = PermissionRequestPayload(
            requestId: requestID,
            agent: proposedAgent.name,
            tool: "agent.attach",
            args: normalizedAttachArgs,
            risk: assessment.risk,
            reason: assessment.reason,
            context: PermissionRequestContext(
                taskID: admissionTaskID,
                rootTaskID: admissionRootTaskID,
                parentTaskID: causalParentTaskID,
                attempt: admissionAttempt,
                toolCallID: "agent-attach:\(requestID.rawValue)",
                normalizedArgs: normalizedAttachArgs,
                touchedPaths: [assessedPath],
                risksNetwork: false,
                sideEffect: .write,
                gate: PermissionReviewGateSnapshot(
                    decision: assessment.canAskUser ? .ask : .deny,
                    risk: assessment.risk,
                    reason: assessment.reason),
                capabilityLease: proposedLeases.capability,
                workspaceLease: proposedLeases.workspace,
                taskContract: admissionContract,
                causalContext: PermissionReviewCausalContext(
                    userGoal: admissionContract.objective,
                    issuer: admissionIssuer,
                    assignee: proposedAgent.name,
                    taskLineage: admissionLineage,
                    relatedAgents: admissionContract.relatedAgents),
                executionID: "agent-admission:\(admissionTaskID.rawValue)",
                replayPolicy: "admission_once"))
        let agentMetadata = taskMetadata(
            contract: admissionContract,
            rootTaskID: admissionRootTaskID,
            parentTaskID: causalParentTaskID,
            sender: admissionIssuer,
            recipient: proposedAgent.name,
            scope: .agent,
            visibility: .global)
        let workspaceMetadata = taskMetadata(
            contract: admissionContract,
            rootTaskID: admissionRootTaskID,
            parentTaskID: causalParentTaskID,
            sender: admissionIssuer,
            recipient: proposedAgent.name,
            scope: .workspace,
            visibility: .global)
        let capabilityMetadata = taskMetadata(
            contract: admissionContract,
            rootTaskID: admissionRootTaskID,
            parentTaskID: causalParentTaskID,
            sender: admissionIssuer,
            recipient: proposedAgent.name,
            scope: .capability,
            visibility: .global)
        do {
            try await appendAdmissionEvent(.agentAttachRequested(AgentAttachRequestedPayload(
                agent: proposedAgent.name,
                path: assessedPath,
                model: proposedAgent.model,
                profile: proposedAgent.profile.rawValue,
                metadata: agentMetadata)))
            try await appendAdmissionEvent(.workspaceLeaseRequested(WorkspaceLeaseRequestedPayload(
                agent: proposedAgent.name,
                rootPath: assessedPath,
                access: proposedLeases.workspace.access,
                reason: assessment.reason,
                metadata: workspaceMetadata)))
            try await appendAdmissionEvent(.permissionRequest(request))
        } catch {
            try? await log.append(.error(ErrorPayload(
                code: "agent_attach_request_persistence_failed",
                message: error.localizedDescription)))
            return false
        }

        guard assessment.canAskUser else {
            try? await log.append(.permissionResolved(PermissionResolvedPayload(
                requestId: requestID, tool: "agent.attach", decision: .deny,
                risk: assessment.risk, reason: assessment.reason)))
            try? await log.append(.workspaceLeaseDenied(WorkspaceLeaseDeniedPayload(
                agent: proposedAgent.name,
                rootPath: assessedPath,
                reason: assessment.reason,
                metadata: workspaceMetadata)))
            return false
        }

        let decision = await activePermissionResponder().requestApproval(request)
        guard decision == .allow else {
            try? await log.append(.permissionResolved(PermissionResolvedPayload(
                requestId: requestID, tool: "agent.attach", decision: .deny,
                risk: assessment.risk, reason: "permission denied workspace attach")))
            try? await log.append(.workspaceLeaseDenied(WorkspaceLeaseDeniedPayload(
                agent: proposedAgent.name,
                rootPath: assessedPath,
                reason: "permission denied workspace attach",
                metadata: workspaceMetadata)))
            return false
        }
        await acquireAdmissionLock()
        guard registry.agent(id) == nil else {
            try? await log.append(.permissionResolved(PermissionResolvedPayload(
                requestId: requestID, tool: "agent.attach", decision: .deny,
                risk: .medium, reason: "agent already exists")))
            releaseAdmissionLock()
            return false
        }
        let reviewedWorkspace = proposedLeases.workspace
        guard let reviewedIdentity = reviewedWorkspace.rootIdentity,
              reviewedIdentity.matchesCurrentDirectory(rootPath: reviewedWorkspace.rootPath) else {
            let reason = "workspace root identity changed during permission review"
            do {
                try await appendAdmissionEvents([
                    .permissionResolved(PermissionResolvedPayload(
                        requestId: requestID,
                        tool: "agent.attach",
                        decision: .deny,
                        risk: .high,
                        reason: reason)),
                    .workspaceLeaseDenied(WorkspaceLeaseDeniedPayload(
                        agent: proposedAgent.name,
                        rootPath: assessedPath,
                        reason: reason,
                        metadata: workspaceMetadata)),
                ])
            } catch {
                try? await log.append(.error(ErrorPayload(
                    code: "agent_attach_identity_denial_persistence_failed",
                    message: error.localizedDescription)))
            }
            releaseAdmissionLock()
            return false
        }
        do {
            try await appendAdmissionEvent(.permissionResolved(PermissionResolvedPayload(
                requestId: requestID, tool: "agent.attach", decision: .allow,
                risk: assessment.risk, reason: "permission approved workspace attach")))
            try await appendAdmissionEvent(.workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                agent: proposedAgent.name,
                lease: proposedLeases.workspace,
                metadata: workspaceMetadata)))
            try await appendAdmissionEvent(.capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: proposedAgent.name,
                lease: proposedLeases.capability,
                metadata: capabilityMetadata)))
            try await appendAdmissionEvent(.agentAttached(AgentAttachedPayload(
                agent: proposedAgent.name, path: proposedAgent.workspaceRoot.path, model: proposedAgent.model,
                profile: proposedAgent.profile.rawValue,
                metadata: agentMetadata)))
        } catch {
            try? await log.append(.error(ErrorPayload(
                code: "agent_attach_admission_persistence_failed",
                message: error.localizedDescription)))
            releaseAdmissionLock()
            return false
        }
        registry.add(proposedAgent)
        commitDefaultLeases(proposedLeases, for: proposedAgent.name)
        releaseAdmissionLock()
        await enqueuePendingMailboxWakeIfNeeded(for: proposedAgent.name)
        return true
    }

    @discardableResult
    public func detach(_ name: AgentID, reason: String = "agent detached") async -> Bool {
        guard name != Self.mainAgentID else {
            try? await log.append(.error(ErrorPayload(code: "reserved_agent", message: "@main cannot be detached")))
            return false
        }
        guard name != Self.automaticPermissionReviewerID else {
            try? await log.append(.error(ErrorPayload(
                code: "reserved_agent",
                message: "@\(Self.automaticPermissionReviewerID.rawValue) is controlled by automatic review settings")))
            return false
        }
        guard registry.agent(name) != nil else { return false }
        guard !taskGraph.nodes.values.contains(where: {
            ($0.assignee == name || $0.issuer == name) && Self.isActiveTaskStatus($0.status)
        }) else {
            try? await log.append(.error(ErrorPayload(
                code: "agent_busy",
                message: "@\(name.rawValue) has active tasks; cancel them before detach")))
            return false
        }
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        // Re-check after waiting for another admission mutation.
        guard registry.agent(name) != nil,
              !taskGraph.nodes.values.contains(where: {
                  ($0.assignee == name || $0.issuer == name) && Self.isActiveTaskStatus($0.status)
              }) else { return false }

        let capabilityLeaseID = defaultCapabilityLeaseIDs[name]
        let workspaceLeaseID = defaultWorkspaceLeaseIDs[name]
        var events: [Event] = []
        if let capabilityLeaseID {
            events.append(.capabilityLeaseRevoked(CapabilityLeaseRevokedPayload(
                agent: name,
                leaseID: capabilityLeaseID,
                reason: reason,
                metadata: CoworkEventMetadata(
                    agentID: name,
                    capabilityLeaseID: capabilityLeaseID,
                    scope: .capability))))
        }
        if let workspaceLeaseID {
            events.append(.workspaceLeaseRevoked(WorkspaceLeaseRevokedPayload(
                agent: name,
                leaseID: workspaceLeaseID,
                reason: reason,
                metadata: CoworkEventMetadata(
                    agentID: name,
                    workspaceLeaseID: workspaceLeaseID,
                    scope: .workspace))))
        }
        events.append(.agentDetached(AgentDetachedPayload(
            agent: name,
            reason: reason,
            metadata: CoworkEventMetadata(agentID: name, scope: .agent))))
        do {
            try await appendAdmissionEvents(events)
        } catch {
            try? await log.append(.error(ErrorPayload(
                code: "agent_detach_persistence_failed",
                message: "@\(name.rawValue): \(error.localizedDescription)")))
            return false
        }

        // Runtime state changes only after the complete revoke+detach batch is
        // durable. A failed write therefore cannot resurrect an agent on replay.
        registry.remove(name)
        spawnedAgentOwners.removeValue(forKey: name)
        if let capabilityLeaseID {
            defaultCapabilityLeaseIDs.removeValue(forKey: name)
            capabilityLeases.removeValue(forKey: capabilityLeaseID)
        }
        if let workspaceLeaseID {
            defaultWorkspaceLeaseIDs.removeValue(forKey: name)
            workspaceLeases.removeValue(forKey: workspaceLeaseID)
        }
        return true
    }

    public func agentNames() -> [AgentID] { registry.names }
    public func agentList() -> [Agent] { registry.all() }
    public func automaticPermissionReviewEnabled() -> Bool {
        automaticPermissionResponder != nil && !automaticPermissionReviewDisabling
    }
    public func automaticPermissionReviewHealth() async -> PermissionReviewControlPlaneHealth? {
        guard let automaticPermissionResponder else { return nil }
        return await automaticPermissionResponder.health()
    }
    func capabilityLeaseList() -> [CapabilityLease] { Array(capabilityLeases.values) }
    func workspaceLeaseList() -> [WorkspaceLease] { Array(workspaceLeases.values) }
    func capabilityLease(id: CapabilityLeaseID) -> CapabilityLease? { capabilityLeases[id] }
    func workspaceLease(id: WorkspaceLeaseID) -> WorkspaceLease? { workspaceLeases[id] }
    func queuedTasks() -> [ScheduledTask] { scheduler.queuedTasks() }
    func executionRecord(taskID: TaskID) -> ExecutionRecord? { scheduler.record(for: taskID) }
    func mailbox(for agent: AgentID) -> AgentMailbox { scheduler.mailbox(for: agent) }
    func taskGraphSnapshot() -> TaskGraph { taskGraph }
    func taskGraphNode(_ taskID: TaskID) -> TaskNode? { taskGraph.node(taskID) }

    func setMessageConsumptionAppender(
        _ appender: (@Sendable (AgentMessageConsumedPayload) async throws -> Void)?
    ) {
        messageConsumptionAppender = appender
    }

    func setTaskLifecycleEventAppender(_ appender: (@Sendable (Event) async throws -> Void)?) {
        taskLifecycleEventAppender = appender
    }

    func setCancelAllBeforeResumeHook(_ hook: (@Sendable () async -> Void)?) {
        cancelAllBeforeResumeHook = hook
    }

    func terminalPersistenceFailure(taskID: TaskID) -> String? {
        terminalPersistenceFailures[taskID]
    }

    func setTaskStartGate(_ gate: (@Sendable (TaskID) async -> Void)?) {
        taskStartGate = gate
    }

    func setAdmissionEventAppender(_ appender: (@Sendable (Event) async throws -> Void)?) {
        admissionEventAppender = appender
    }

    /// Batch seam for tests that need to fail a multi-event admission
    /// transaction. The closure must provide all-or-nothing semantics, just as
    /// `EventLog.append(_:)` does in production.
    func setAdmissionEventsAppender(_ appender: (@Sendable ([Event]) async throws -> Void)?) {
        admissionEventsAppender = appender
    }

    @discardableResult
    public func enableAutomaticPermissionReview(model: ModelID,
                                                 workspaceRoot: URL,
                                                 name: AgentID = Orchestrator.automaticPermissionReviewerID,
                                                 policy: PermissionReviewControlPlanePolicy = PermissionReviewControlPlanePolicy()) async -> AutomaticPermissionReviewResult {
        guard automaticPermissionResponder == nil else {
            return .alreadyEnabled(automaticPermissionReviewerAgentID ?? name)
        }
        if let automaticPermissionReviewRecoveryFailure {
            return .failed(automaticPermissionReviewRecoveryFailure)
        }
        guard name == Self.automaticPermissionReviewerID else {
            return .failed("automatic permission reviewer must use @\(Self.automaticPermissionReviewerID.rawValue)")
        }
        guard registry.agent(name) == nil else {
            return .failed("@\(name.rawValue) already exists; the automatic reviewer identity is reserved")
        }

        let assessment = assessWorkspaceAttach(workspaceRoot)
        guard assessment.canAskUser, let canonical = assessment.canonical else {
            return .failed(assessment.reason)
        }

        let reviewer = Agent(
            name: name,
            workspaceRoot: canonical,
            model: model,
            profile: .readOnly,
            coordinationDepth: 0)

        let provider: ToolCallingProvider
        do {
            provider = try await providerFor(reviewer)
        } catch {
            return .failed(error.localizedDescription)
        }

        let workspaceLease = WorkspaceLease(rootPath: reviewer.workspaceRoot.path, access: .readOnly)
        let capabilityLease = CapabilityLease(
            tools: [],
            communication: .none,
            delegation: .none,
            expiresAtTaskCompletion: false)

        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        if let automaticPermissionReviewRecoveryFailure {
            return .failed(automaticPermissionReviewRecoveryFailure)
        }
        guard automaticPermissionResponder == nil, registry.agent(name) == nil else {
            return .failed("@\(name.rawValue) was attached while automatic review was being enabled")
        }
        do {
            try await appendAdmissionEvents([
                .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                    agent: reviewer.name,
                    lease: workspaceLease,
                    metadata: CoworkEventMetadata(
                        agentID: reviewer.name,
                        workspaceID: workspaceLease.workspaceID,
                        workspaceLeaseID: workspaceLease.id,
                        scope: .workspace))),
                .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                    agent: reviewer.name,
                    lease: capabilityLease,
                    metadata: CoworkEventMetadata(
                        agentID: reviewer.name,
                        capabilityLeaseID: capabilityLease.id,
                        scope: .capability))),
                .agentAttached(AgentAttachedPayload(
                    agent: reviewer.name,
                    path: reviewer.workspaceRoot.path,
                    model: reviewer.model,
                    profile: reviewer.profile.rawValue,
                    metadata: CoworkEventMetadata(agentID: reviewer.name, scope: .agent))),
            ])
        } catch {
            return .failed("automatic permission reviewer admission could not be persisted: \(error.localizedDescription)")
        }
        registry.add(reviewer)
        workspaceLeases[workspaceLease.id] = workspaceLease
        capabilityLeases[capabilityLease.id] = capabilityLease
        defaultWorkspaceLeaseIDs[reviewer.name] = workspaceLease.id
        defaultCapabilityLeaseIDs[reviewer.name] = capabilityLease.id
        automaticPermissionReviewerAgentID = reviewer.name
        automaticPermissionResponder = AgentPermissionResponder(
            log: log,
            reviewerAgent: reviewer,
            provider: provider,
            fallback: responder,
            policy: policy)
        return .enabled(reviewer.name)
    }

    @discardableResult
    public func disableAutomaticPermissionReview() async -> AutomaticPermissionReviewDisableResult {
        guard automaticPermissionReviewerAgentID != nil else {
            return .alreadyDisabled
        }
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        guard let reviewerID = automaticPermissionReviewerAgentID else {
            return .alreadyDisabled
        }
        guard !automaticPermissionReviewDisabling else {
            return .failed("automatic permission review disable is already in progress")
        }
        automaticPermissionReviewDisabling = true
        defer { automaticPermissionReviewDisabling = false }
        let responderToShutdown = automaticPermissionResponder
        await responderToShutdown?.quiesce(
            reason: "automatic permission review disabled")
        let capabilityLeaseID = defaultCapabilityLeaseIDs[reviewerID]
        let workspaceLeaseID = defaultWorkspaceLeaseIDs[reviewerID]
        var events: [Event] = []
        if let capabilityLeaseID {
            events.append(.capabilityLeaseRevoked(CapabilityLeaseRevokedPayload(
                agent: reviewerID,
                leaseID: capabilityLeaseID,
                reason: "automatic permission review disabled",
                metadata: CoworkEventMetadata(
                    agentID: reviewerID,
                    capabilityLeaseID: capabilityLeaseID,
                    scope: .capability))))
        }
        if let workspaceLeaseID {
            events.append(.workspaceLeaseRevoked(WorkspaceLeaseRevokedPayload(
                agent: reviewerID,
                leaseID: workspaceLeaseID,
                reason: "automatic permission review disabled",
                metadata: CoworkEventMetadata(
                    agentID: reviewerID,
                    workspaceLeaseID: workspaceLeaseID,
                    scope: .workspace))))
        }
        events.append(.agentDetached(AgentDetachedPayload(
            agent: reviewerID,
            reason: "automatic permission review disabled",
            metadata: CoworkEventMetadata(agentID: reviewerID, scope: .agent))))
        do {
            try await appendAdmissionEvents(events)
        } catch {
            await responderToShutdown?.resumeAfterFailedQuiesce()
            let message = "automatic permission review remains enabled because its detach audit could not be persisted: \(error.localizedDescription)"
            try? await log.append(.error(ErrorPayload(
                code: "automatic_review_disable_persistence_failed",
                message: message)))
            return .failed(message)
        }

        automaticPermissionResponder = nil
        automaticPermissionReviewerAgentID = nil
        registry.remove(reviewerID)
        if let capabilityLeaseID {
            defaultCapabilityLeaseIDs.removeValue(forKey: reviewerID)
            capabilityLeases.removeValue(forKey: capabilityLeaseID)
        }
        if let workspaceLeaseID {
            defaultWorkspaceLeaseIDs.removeValue(forKey: reviewerID)
            workspaceLeases.removeValue(forKey: workspaceLeaseID)
        }
        // Quiescence above is the authorization barrier; only the atomically
        // durable detach makes it irreversible.
        await responderToShutdown?.finalizeShutdown()
        return .disabled(reviewerID)
    }

    public func restore(from _: CoworkProjection) async {
        let schedulerSuspension = suspendScheduler()
        terminalPersistenceFailures.removeAll()
        terminalCommitTaskIDs.removeAll()
        automaticPermissionReviewRecoveryFailure = nil
        var events = await log.replay()
        var projection = CoworkProjection.build(from: events)
        let staleReviewerCapabilityLeaseIDs = projection.capabilityLeaseAgents
            .compactMap { $0.value == Self.automaticPermissionReviewerID ? $0.key : nil }
            .sorted { $0.rawValue < $1.rawValue }
        let staleReviewerWorkspaceLeaseIDs = projection.workspaceLeaseAgents
            .compactMap { $0.value == Self.automaticPermissionReviewerID ? $0.key : nil }
            .sorted { $0.rawValue < $1.rawValue }
        if projection.agentRoster[Self.automaticPermissionReviewerID] != nil
            || !staleReviewerCapabilityLeaseIDs.isEmpty
            || !staleReviewerWorkspaceLeaseIDs.isEmpty {
            var cleanupEvents: [Event] = staleReviewerCapabilityLeaseIDs.map { leaseID in
                .capabilityLeaseRevoked(CapabilityLeaseRevokedPayload(
                    agent: Self.automaticPermissionReviewerID,
                    leaseID: leaseID,
                    reason: "stale automatic permission reviewer recovered",
                    metadata: CoworkEventMetadata(
                        agentID: Self.automaticPermissionReviewerID,
                        capabilityLeaseID: leaseID,
                        scope: .capability)))
            }
            cleanupEvents.append(contentsOf: staleReviewerWorkspaceLeaseIDs.map { leaseID in
                .workspaceLeaseRevoked(WorkspaceLeaseRevokedPayload(
                    agent: Self.automaticPermissionReviewerID,
                    leaseID: leaseID,
                    reason: "stale automatic permission reviewer recovered",
                    metadata: CoworkEventMetadata(
                        agentID: Self.automaticPermissionReviewerID,
                        workspaceLeaseID: leaseID,
                        scope: .workspace)))
            })
            cleanupEvents.append(.agentDetached(AgentDetachedPayload(
                agent: Self.automaticPermissionReviewerID,
                reason: "stale automatic permission reviewer recovered",
                metadata: CoworkEventMetadata(
                    agentID: Self.automaticPermissionReviewerID,
                    scope: .agent))))
            do {
                try await appendAdmissionEvents(cleanupEvents)
                events = await log.replay()
                projection = CoworkProjection.build(from: events)
            } catch {
                let message = "stale automatic permission reviewer cleanup could not be persisted: \(error.localizedDescription)"
                automaticPermissionReviewRecoveryFailure = message
                try? await log.append(.error(ErrorPayload(
                    code: "automatic_review_restore_cleanup_failed",
                    message: message)))
            }
        }
        var durableCapabilityGrants: [CapabilityLeaseID: CapabilityLease] = [:]
        var durableWorkspaceGrants: [WorkspaceLeaseID: WorkspaceLease] = [:]
        capabilityLeaseHistory = [:]
        workspaceLeaseHistory = [:]
        for envelope in events {
            switch envelope.event {
            case .capabilityLeaseCreated(let payload):
                durableCapabilityGrants[payload.lease.id] = payload.lease
            case .capabilityLeaseRevoked(let payload):
                if let lease = durableCapabilityGrants[payload.leaseID],
                   lease.expiresAtTaskCompletion {
                    capabilityLeaseHistory[payload.leaseID] = lease
                }
            case .workspaceLeaseGranted(let payload):
                durableWorkspaceGrants[payload.lease.id] = payload.lease
            case .workspaceLeaseRevoked(let payload):
                if let lease = durableWorkspaceGrants[payload.leaseID],
                   lease.expiresAtTaskCompletion {
                    workspaceLeaseHistory[payload.leaseID] = lease
                }
            default:
                break
            }
        }
        let referencedCapabilityLeaseIDs: Set<CapabilityLeaseID> = Set(projection.tasks.values.compactMap {
            guard $0.contract?.kind != .root else { return nil }
            return $0.contract?.capabilityLeaseID
        })
        let referencedWorkspaceLeaseIDs: Set<WorkspaceLeaseID> = Set(projection.tasks.values.compactMap {
            guard $0.contract?.kind != .root else { return nil }
            return $0.contract?.workspaceLeaseID
        })
        let activeCapabilityLeaseIDs: Set<CapabilityLeaseID> = Set(
            projection.activeTasks.compactMap { $0.contract?.capabilityLeaseID })
        let activeWorkspaceLeaseIDs: Set<WorkspaceLeaseID> = Set(
            projection.activeTasks.compactMap { $0.contract?.workspaceLeaseID })
        let restorableAgentIDs = Set(projection.agentRoster.keys).subtracting([Self.automaticPermissionReviewerID])

        capabilityLeases = projection.capabilityLeases.filter { id, lease in
            if activeCapabilityLeaseIDs.contains(id) { return true }
            guard lease.taskID == nil,
                  !referencedCapabilityLeaseIDs.contains(id),
                  let agentID = projection.capabilityLeaseAgents[id] else { return false }
            return restorableAgentIDs.contains(agentID)
        }
        for (id, lease) in capabilityLeases where lease.taskID == nil && lease.expiresAtTaskCompletion {
            var durableDefault = lease
            durableDefault.expiresAtTaskCompletion = false
            capabilityLeases[id] = durableDefault
        }
        workspaceLeases = projection.workspaceLeases.filter { id, lease in
            if activeWorkspaceLeaseIDs.contains(id) { return true }
            guard lease.taskID == nil,
                  !referencedWorkspaceLeaseIDs.contains(id),
                  let agentID = projection.workspaceLeaseAgents[id] else { return false }
            return restorableAgentIDs.contains(agentID)
        }

        for payload in projection.agentRoster.values {
            guard payload.agent != Self.automaticPermissionReviewerID else { continue }
            let profile = PermissionProfile(rawValue: payload.profile) ?? .reviewed
            let agentLeaseIDs: [CapabilityLeaseID] = projection.capabilityLeaseAgents.compactMap { entry in
                entry.value == payload.agent ? entry.key : nil
            }
            let candidateDefaultLeases: [CapabilityLease] = agentLeaseIDs.compactMap { leaseID in
                projection.capabilityLeases[leaseID]
            }
            let defaultLease = candidateDefaultLeases
                .filter { lease in
                    lease.taskID == nil && !referencedCapabilityLeaseIDs.contains(lease.id)
                }
                .sorted { lhs, rhs in lhs.id.rawValue < rhs.id.rawValue }
                .first
            registry.add(Agent(
                name: payload.agent,
                workspaceRoot: URL(fileURLWithPath: payload.path),
                model: payload.model,
                profile: profile,
                coordinationDepth: payload.agent == Self.mainAgentID || defaultLease.map(Self.canCoordinate) == true
                    ? Agent.defaultCoordinationDepth
                    : 0))
        }

        defaultWorkspaceLeaseIDs = deterministicDefaultWorkspaceLeases(
            projection: projection,
            taskLeaseIDs: referencedWorkspaceLeaseIDs)
        defaultCapabilityLeaseIDs = deterministicDefaultCapabilityLeases(
            projection: projection,
            taskLeaseIDs: referencedCapabilityLeaseIDs)
        for agent in registry.all() where defaultCapabilityLeaseIDs[agent.name] == nil
            || defaultWorkspaceLeaseIDs[agent.name] == nil {
            let leases = prepareDefaultLeases(for: agent)
            do {
                try await appendAdmissionEvent(.workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                    agent: agent.name,
                    lease: leases.workspace,
                    metadata: CoworkEventMetadata(
                        agentID: agent.name,
                        workspaceID: leases.workspace.workspaceID,
                        workspaceLeaseID: leases.workspace.id,
                        scope: .workspace))))
                try await appendAdmissionEvent(.capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                    agent: agent.name,
                    lease: leases.capability,
                    metadata: CoworkEventMetadata(
                        agentID: agent.name,
                        capabilityLeaseID: leases.capability.id,
                        scope: .capability))))
                commitDefaultLeases(leases, for: agent.name)
            } catch {
                try? await log.append(.error(ErrorPayload(
                    code: "restore_default_lease_persistence_failed",
                    message: "@\(agent.name.rawValue): \(error.localizedDescription)")))
            }
        }
        spawnedAgentOwners = projection.agentOwners.filter { registry.agent($0.key) != nil }

        var nodes: [TaskID: TaskNode] = [:]
        for view in projection.tasks.values {
            guard let contract = view.contract else { continue }
            let recoveredStatus: TaskStatus = view.status == .running ? .queued : view.status
            nodes[view.id] = TaskNode(
                id: view.id,
                contract: contract,
                status: recoveredStatus,
                rootTaskID: view.rootTaskID ?? contract.parentTaskID ?? contract.id,
                parentTaskID: view.parentTaskID ?? contract.parentTaskID,
                issuer: view.issuer ?? contract.issuer,
                assignee: view.assignee ?? contract.assignee,
                createdAt: .distantPast)
        }
        let edges = nodes.values.compactMap { node -> TaskEdge? in
            guard let parent = node.parentTaskID else { return nil }
            return TaskEdge(
                fromTaskID: parent,
                toTaskID: node.id,
                issuer: node.issuer,
                assignee: node.assignee,
                kind: .delegates)
        }
        taskGraph = TaskGraph(nodes: nodes, edges: edges, policy: taskGraph.policy)

        var queued: [ScheduledTask] = []
        var known: [TaskID: ScheduledTask] = [:]
        var records: [TaskID: ExecutionRecord] = [:]
        var recoveredMailboxes: [AgentID: AgentMailbox] = [:]
        var recoveryFailures: [(ScheduledTask, String)] = []
        let startedNonReplayable = projection.startedNonReplayableToolExecutions

        for view in projection.tasks.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            guard let contract = view.contract else { continue }
            let rootTaskID = view.rootTaskID ?? nodes[view.id]?.rootTaskID ?? contract.id
            let visited = taskGraph.causalAgentChain(to: view.id)
            let previousAttempt = max(1, view.attempt)
            let maxAttempts = contract.maxAttempts ?? executionPolicy.maxAttempts
            let exhaustedRunningAttempt = view.status == .running && previousAttempt >= maxAttempts
            let interruptedSideEffects = startedNonReplayable.filter { execution in
                guard execution.prepared.taskID == view.id else { return false }
                return execution.prepared.attempt == nil
                    || execution.prepared.attempt == previousAttempt
            }
            let requiresManualReconciliation = view.status == .running
                && !interruptedSideEffects.isEmpty
            let attempt = view.status == .running
                && !exhaustedRunningAttempt
                && !requiresManualReconciliation
                ? previousAttempt + 1
                : previousAttempt
            let scheduled = ScheduledTask(
                contract: contract,
                input: contract.objective,
                rootTaskID: rootTaskID,
                parentTaskID: view.parentTaskID ?? contract.parentTaskID,
                issuer: view.issuer ?? contract.issuer,
                assignee: view.assignee ?? contract.assignee,
                causalParentID: view.parentTaskID ?? contract.parentTaskID,
                hopCount: max(0, visited.count - 1),
                visitedAgents: visited,
                attempt: attempt)
            known[view.id] = scheduled

            let restoredStatus = view.status == .running ? TaskStatus.queued : view.status
            if view.status == .created || view.status == .assigned {
                recoveryFailures.append((
                    scheduled,
                    "task admission was interrupted before it reached the durable queue"))
            } else if requiresManualReconciliation {
                let details = interruptedSideEffects
                    .map(Self.executionReconciliationDetail)
                    .sorted()
                    .joined(separator: ", ")
                recoveryFailures.append((
                    scheduled,
                    "manual reconciliation required before replaying non-replayable side effects: \(details)"))
            } else if exhaustedRunningAttempt {
                recoveryFailures.append((scheduled, "task exceeded retry attempts during crash recovery"))
            } else if restoredStatus == .queued {
                queued.append(scheduled)
                restoredPendingTaskIDs.insert(view.id)
            }
            records[view.id] = ExecutionRecord(
                taskID: view.id,
                assignee: scheduled.assignee,
                status: restoredStatus,
                result: view.result,
                error: view.error,
                rootTaskID: rootTaskID,
                parentTaskID: scheduled.parentTaskID,
                hopCount: scheduled.hopCount,
                visitedAgents: visited,
                attempt: attempt)

            if let replyMode = contract.replyMode,
               replyMode != TaskReplyMode.none,
               let issuer = contract.issuer {
                scheduledReplyTargets[view.id] = issuer
                scheduledReplyFormats[view.id] = replyMode == .answer ? .answer : .taskReport
            }
        }
        taskGraph = TaskGraph(nodes: nodes, edges: edges, policy: taskGraph.policy)

        for (agent, mailboxView) in projection.mailboxes {
            let details = pendingMessageDetails(
                for: agent,
                pendingIDs: Set(mailboxView.pendingMessages),
                events: events)
            recoveredMailboxes[agent] = AgentMailbox(
                pendingMessages: mailboxView.pendingMessages,
                pendingTasks: mailboxView.pendingTasks,
                completedResults: [],
                pendingMessageDetails: details)
        }
        var durableQueued = queued.filter { projection.tasks[$0.contract.id]?.status != .running }
        for task in queued where projection.tasks[task.contract.id]?.status == .running {
            do {
                try await appendAdmissionEvent(.taskQueued(TaskQueuedPayload(
                    contract: task.contract,
                    rootTaskID: task.rootTaskID,
                    parentTaskID: task.parentTaskID,
                    issuer: task.issuer,
                    assignee: task.assignee,
                    causalParentID: task.causalParentID,
                    hopCount: task.hopCount,
                    visitedAgents: task.visitedAgents,
                    attempt: task.attempt,
                    reason: "requeued after interrupted execution",
                    metadata: taskMetadata(
                        contract: task.contract,
                        rootTaskID: task.rootTaskID,
                        parentTaskID: task.parentTaskID,
                        sender: task.issuer,
                        recipient: task.assignee))))
                durableQueued.append(task)
            } catch {
                restoredPendingTaskIDs.remove(task.contract.id)
                recoveryFailures.append((
                    task,
                    "interrupted task could not be durably requeued: \(error.localizedDescription)"))
            }
        }
        scheduler = AgentScheduler(snapshot: AgentSchedulerSnapshot(
            queuedTasks: durableQueued,
            claimedTasks: [],
            knownTasks: known,
            records: records,
            mailboxes: recoveredMailboxes))

        await refreshConsumedTokenCount()
        await tokenBudgetMeter.reconfigure(
            tokenBudget: executionPolicy.tokenBudget,
            durableConsumed: consumedTokenCount)
        for (task, message) in recoveryFailures {
            let metadata = taskMetadata(
                contract: task.contract,
                rootTaskID: task.rootTaskID,
                parentTaskID: task.parentTaskID,
                sender: task.issuer,
                recipient: task.assignee)
            let report = Self.makeTaskReport(
                task: task,
                status: .failed,
                error: message,
                attempt: task.attempt)
            do {
                try await appendTaskLifecycleEvent(.taskFailed(TaskFailedPayload(
                    taskID: task.contract.id,
                    agent: task.assignee,
                    error: message,
                    report: report,
                    attempt: task.attempt,
                    metadata: metadata)))
            } catch {
                terminalPersistenceFailures[task.contract.id] =
                    "Task recovery failure could not be persisted: \(error.localizedDescription)"
                continue
            }
            scheduler.recordFailed(task: task, error: message)
            if var node = nodes[task.contract.id] {
                node.status = .failed
                nodes[task.contract.id] = node
            }
            await revokeTaskLeases(contract: task.contract, reason: "recovery attempts exhausted")
        }
        taskGraph = TaskGraph(nodes: nodes, edges: edges, policy: taskGraph.policy)
        for agentID in recoveredMailboxes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            await enqueuePendingMailboxWakeIfNeeded(for: agentID)
        }
        resumeScheduler(suspension: schedulerSuspension, ensureRunning: false)
    }

    /// Route a user message to the explicit target, or to the first attached agent
    /// only when the caller did not specify a target.
    @discardableResult
    public func send(_ text: String,
                     to: AgentID? = nil,
                     images: [ImageAttachment] = [],
                     userMessage: UserMessagePayload? = nil) async -> OrchestratorSendResult {
        let agent: Agent
        if let to {
            guard to != Self.automaticPermissionReviewerID else {
                let message = "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review."
                try? await log.append(.error(ErrorPayload(code: "reserved_agent", message: message)))
                return .failed(message)
            }
            guard let explicitTarget = registry.agent(to) else {
                try? await log.append(.error(ErrorPayload(
                    code: "no_such_agent",
                    message: "no attached agent named @\(to.rawValue)")))
                return .failed("No attached agent named @\(to.rawValue).")
            }
            agent = explicitTarget
        } else {
            let defaultTarget = registry.agent(Self.mainAgentID)
                ?? registry.all().first(where: { $0.name != Self.automaticPermissionReviewerID })
            guard let defaultTarget else {
                try? await log.append(.error(ErrorPayload(code: "no_agent", message: "no agent attached")))
                return .failed("No agent attached.")
            }
            agent = defaultTarget
        }
        guard let rootTaskID = await createRootTask(
            assignee: agent.name,
            objective: text,
            roleHint: "root task coordinator",
            expectedDeliverable: "Coordinate assigned subtasks and synthesize the result."),
              let rootNode = taskGraph.node(rootTaskID) else {
            return .failed("Could not create the root task.")
        }

        let scheduled = ScheduledTask(
            contract: rootNode.contract,
            input: text,
            rootTaskID: rootTaskID,
            parentTaskID: nil,
            issuer: nil,
            assignee: agent.name,
            causalParentID: nil,
            hopCount: 0,
            visitedAgents: [agent.name],
            attempt: 1)
        await acquireAdmissionLock()
        var preflightScheduler = scheduler
        guard preflightScheduler.enqueue(scheduled, mode: .newTask).accepted,
              taskGraph.node(rootTaskID)?.status == .assigned else {
            releaseAdmissionLock()
            return .failed("Root task was already queued.")
        }
        do {
            try await appendAdmissionEvent(.taskQueued(TaskQueuedPayload(
                contract: rootNode.contract,
                rootTaskID: rootTaskID,
                parentTaskID: nil,
                issuer: nil,
                assignee: agent.name,
                causalParentID: nil,
                hopCount: 0,
                visitedAgents: [agent.name],
                attempt: 1,
                reason: "user task admitted",
                metadata: taskMetadata(
                    contract: rootNode.contract,
                    rootTaskID: rootTaskID,
                    recipient: agent.name))))
        } catch {
            let message = "Root task queue could not be persisted: \(error.localizedDescription)"
            let report = Self.makeTaskReport(
                task: scheduled,
                status: .cancelled,
                error: message,
                attempt: scheduled.attempt)
            do {
                try await appendTaskLifecycleEvent(.taskCancelled(TaskCancelledPayload(
                    taskID: rootTaskID,
                    agent: agent.name,
                    reason: message,
                    report: report,
                    attempt: scheduled.attempt,
                    metadata: taskMetadata(
                        contract: rootNode.contract,
                        rootTaskID: rootTaskID,
                        recipient: agent.name))))
                _ = taskGraph.updateStatus(taskID: rootTaskID, status: .cancelled)
            } catch {
                terminalPersistenceFailures[rootTaskID] =
                    "Root task admission failure could not be persisted: \(error.localizedDescription)"
            }
            releaseAdmissionLock()
            return .failed(message)
        }
        guard scheduler.enqueue(scheduled, mode: .newTask).accepted else {
            releaseAdmissionLock()
            return .failed("Root task scheduler commit failed after durable admission.")
        }
        rootInvocations[rootTaskID] = RootInvocationContext(images: images, userMessage: userMessage)
        _ = taskGraph.updateStatus(taskID: rootTaskID, status: .queued)
        releaseAdmissionLock()
        ensureSchedulerRunning()
        _ = await awaitSchedulerResult(rootTaskID)
        if let failure = terminalPersistenceFailures[rootTaskID] {
            return .failed(failure)
        }
        guard let record = scheduler.record(for: rootTaskID) else {
            return .failed("Root task ended without an execution record.")
        }
        switch record.status {
        case .completed:
            return .sent
        case .failed, .cancelled:
            return .failed(record.error ?? "Root task \(record.status.rawValue).")
        case .created, .assigned, .queued, .running:
            return .failed("Root task did not reach a terminal state.")
        }
    }

    @discardableResult
    public func retry(_ task: CoworkTaskView) async -> OrchestratorSendResult {
        let admittedTaskID: TaskID
        switch await admitRetry(taskID: task.id, reason: "explicit retry") {
        case .admitted(let taskID):
            admittedTaskID = taskID
        case .rejected(let message):
            return .failed(message)
        }
        ensureSchedulerRunning()
        _ = await awaitSchedulerResult(admittedTaskID)
        if let failure = terminalPersistenceFailures[admittedTaskID] {
            return .failed(failure)
        }
        guard let record = scheduler.record(for: admittedTaskID) else {
            return .failed("Retry ended without an execution record.")
        }
        switch record.status {
        case .completed:
            return .sent
        case .failed, .cancelled:
            return .failed(record.error ?? "Task \(record.status.rawValue).")
        case .created, .assigned, .queued, .running:
            return .failed("Retried task did not reach a terminal state.")
        }
    }

    private func admitRetry(taskID: TaskID, reason: String) async -> RetryAdmissionResult {
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        guard let currentRecord = scheduler.record(for: taskID),
              currentRecord.status == .failed || currentRecord.status == .cancelled else {
            return .rejected("Only failed or cancelled tasks can be retried.")
        }
        guard let currentTask = scheduler.knownTask(taskID: taskID) else {
            return .rejected("This task cannot be retried because its scheduler state is missing.")
        }
        let assignee = currentTask.assignee
        guard assignee != Self.automaticPermissionReviewerID else {
            return .rejected("@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review.")
        }
        guard registry.agent(assignee) != nil else {
            return .rejected("No attached agent named @\(assignee.rawValue).")
        }
        let maxAttempts = currentTask.contract.maxAttempts ?? executionPolicy.maxAttempts
        guard let currentAttempt = currentRecord.attempt,
              currentAttempt >= 1,
              currentAttempt < Int.max else {
            return .rejected("Task has an invalid current attempt \(String(describing: currentRecord.attempt)).")
        }
        if let reconciliationFailure = await retryReconciliationFailure(
            taskID: taskID,
            attempt: currentAttempt
        ) {
            return .rejected(reconciliationFailure)
        }
        let nextAttempt = currentAttempt + 1
        guard nextAttempt <= maxAttempts else {
            return .rejected("Task reached its maximum of \(maxAttempts) attempts.")
        }

        let renewal: TaskLeaseRenewal
        do {
            renewal = try await prepareTaskLeaseRenewal(currentTask.contract, assignee: assignee)
        } catch {
            return .rejected(error.localizedDescription)
        }
        let contract = renewal.contract
        let scheduled = ScheduledTask(
            contract: contract,
            input: currentTask.input,
            rootTaskID: currentTask.rootTaskID,
            parentTaskID: currentTask.parentTaskID,
            issuer: currentTask.issuer,
            assignee: assignee,
            causalParentID: currentTask.causalParentID,
            hopCount: currentTask.hopCount,
            visitedAgents: currentTask.visitedAgents,
            attempt: nextAttempt)
        var preflightScheduler = scheduler
        guard preflightScheduler.enqueue(scheduled, mode: .retry).accepted else {
            return .rejected("Task is already queued/running or is not retryable.")
        }
        var preflightGraph = taskGraph
        guard preflightGraph.replaceContract(contract),
              preflightGraph.updateStatus(taskID: contract.id, status: .queued, isRetry: true) else {
            return .rejected("Task state no longer permits retry.")
        }
        do {
            try await appendAdmissionEvent(.taskQueued(TaskQueuedPayload(
                contract: contract,
                rootTaskID: scheduled.rootTaskID,
                parentTaskID: scheduled.parentTaskID,
                issuer: scheduled.issuer,
                assignee: scheduled.assignee,
                causalParentID: scheduled.causalParentID,
                hopCount: scheduled.hopCount,
                visitedAgents: scheduled.visitedAgents,
                attempt: nextAttempt,
                reason: reason,
                metadata: taskMetadata(
                    contract: contract,
                    rootTaskID: scheduled.rootTaskID,
                    parentTaskID: scheduled.parentTaskID,
                    sender: scheduled.issuer,
                    recipient: scheduled.assignee))))
        } catch {
            return .rejected("Retry admission could not be persisted: \(error.localizedDescription)")
        }
        commitTaskLeaseRenewal(renewal)
        guard taskGraph.replaceContract(contract),
              scheduler.enqueue(scheduled, mode: .retry).accepted,
              taskGraph.updateStatus(taskID: contract.id, status: .queued, isRetry: true) else {
            return .rejected("Retry admission could not be committed after persistence.")
        }
        return .admitted(contract.id)
    }

    private func retryReconciliationFailure(taskID: TaskID, attempt: Int) async -> String? {
        let projection = CoworkProjection.build(from: await log.replay())
        let nonReplayable = projection.startedNonReplayableToolExecutions(
            taskID: taskID,
            attempt: attempt)
        guard !nonReplayable.isEmpty else { return nil }
        let details = nonReplayable
            .map(Self.executionReconciliationDetail)
            .sorted()
            .joined(separator: ", ")
        return "manual reconciliation required before replaying non-replayable side effects: \(details)"
    }

    private static func executionReconciliationDetail(_ execution: CoworkToolExecutionView) -> String {
        let state: String
        if let settled = execution.settled {
            switch settled.outcome {
            case .succeeded:
                state = "side effect already succeeded"
            case .failed:
                state = "executor reported failure after starting"
            case .cancelled:
                state = "executor was cancelled after starting"
            case .denied:
                state = "execution outcome is denied but the executor boundary was already prepared"
            }
        } else {
            state = "outcome unknown"
        }
        return "\(execution.prepared.tool) [\(execution.prepared.executionID); \(state)]"
    }

    @discardableResult
    public func cancel(taskID: TaskID, reason: String = "cancelled by user") async -> Bool {
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "cancelled by user"
        if let queued = scheduler.queuedTask(taskID: taskID) {
            return await cancelBeforeExecution(queued, reason: normalizedReason, wasClaimed: false)
        }
        if let claimed = scheduler.claimedTask(taskID: taskID),
           scheduler.record(for: taskID)?.status == .queued {
            return await cancelBeforeExecution(claimed, reason: normalizedReason, wasClaimed: true)
        }

        guard scheduler.record(for: taskID)?.status == .running else { return false }
        cancellationReasons[taskID] = normalizedReason
        runningExecutions[taskID]?.cancel()
        return true
    }

    private func cancelBeforeExecution(_ task: ScheduledTask,
                                       reason: String,
                                       wasClaimed: Bool) async -> Bool {
        let taskID = task.contract.id
        guard !terminalCommitTaskIDs.contains(taskID) else { return false }
        terminalCommitTaskIDs.insert(taskID)
        defer {
            terminalCommitTaskIDs.remove(taskID)
            ensureSchedulerRunning()
            notifyIdleIfNeeded()
        }

        let metadata = taskMetadata(
            contract: task.contract,
            rootTaskID: task.rootTaskID,
            parentTaskID: task.parentTaskID,
            sender: task.issuer,
            recipient: task.assignee)
        let report = Self.makeTaskReport(
            task: task,
            status: .cancelled,
            error: reason,
            attempt: task.attempt)
        do {
            try await appendTaskLifecycleEvent(.taskCancelled(TaskCancelledPayload(
                taskID: taskID,
                agent: task.assignee,
                reason: reason,
                report: report,
                attempt: task.attempt,
                metadata: metadata)))
        } catch {
            if wasClaimed {
                _ = scheduler.requeueClaimedTask(taskID: taskID)
            }
            try? await log.append(.error(ErrorPayload(
                code: "terminal_persistence_failed",
                message: "Could not persist cancellation for task \(taskID.rawValue): \(error.localizedDescription)")))
            return false
        }

        if wasClaimed {
            runningExecutions[taskID]?.cancel()
            scheduler.recordCancelled(task: task, reason: reason)
        } else {
            guard scheduler.cancelQueuedTask(taskID: taskID, reason: reason) != nil else {
                return false
            }
        }
        _ = taskGraph.updateStatus(taskID: taskID, status: .cancelled)
        await storeScheduledReply(task: task, result: nil, report: report, error: reason)
        await revokeTaskLeases(contract: task.contract, reason: "task cancelled")
        await refreshConsumedTokenCount()
        rootInvocations.removeValue(forKey: taskID)
        completeResultWaiters(taskID)
        return true
    }

    public func cancelAll(reason: String = "cowork session stopped") async {
        let schedulerSuspension = suspendScheduler()
        await automaticPermissionResponder?.shutdown(reason: reason)
        let queuedIDs = scheduler.queuedTasks().map { $0.contract.id }
        let runningIDs = Array(runningExecutions.keys)
        for taskID in queuedIDs {
            _ = await cancel(taskID: taskID, reason: reason)
        }
        for taskID in runningIDs {
            _ = await cancel(taskID: taskID, reason: reason)
        }
        let executions = runningIDs.compactMap { runningExecutions[$0] }
        for execution in executions { await execution.value }
        if let cancelAllBeforeResumeHook {
            await cancelAllBeforeResumeHook()
        }
        resumeScheduler(suspension: schedulerSuspension, ensureRunning: false)
        notifyIdleIfNeeded()
    }

    public func resumePendingTasks() {
        if schedulerSuspended {
            schedulerResumeRequested = true
        } else {
            ensureSchedulerRunning()
        }
    }

    public func updateExecutionPolicy(_ policy: CoworkExecutionPolicy) async {
        await acquireExecutionPolicyUpdateLock()
        defer { releaseExecutionPolicyUpdateLock() }

        guard policy.tokenBudget != executionPolicy.tokenBudget else {
            executionPolicy = policy
            ensureSchedulerRunning()
            return
        }

        // Pause new scheduler admission while publishing policy + limit, but do
        // not rely on draining runningExecutions for correctness. The outer
        // timeout wrapper may already have finished while its detached,
        // non-cooperative AgentLoop still owns a reservation. Because every run
        // holds this session's one meter actor, reconfiguration can preserve that
        // reservation without waiting for the old operation to cooperate.
        let schedulerSuspension = suspendScheduler()
        executionPolicyUpdateInProgress = true
        await refreshConsumedTokenCount()
        await tokenBudgetMeter.reconfigure(
            tokenBudget: policy.tokenBudget,
            durableConsumed: consumedTokenCount)
        executionPolicy = policy
        executionPolicyUpdateInProgress = false
        resumeScheduler(suspension: schedulerSuspension, ensureRunning: true)
    }

    /// Called by `BusMessenger` when `from` asks the agent named `toName`.
    func ask(from: AgentID, to toName: String, question: String, parentTaskID: TaskID? = nil) async -> String {
        let queued = await enqueueAsk(from: from, to: toName, question: question, parentTaskID: parentTaskID)
        guard let taskID = queued.taskID else { return queued.message }
        return await awaitSchedulerResult(taskID) ?? queued.message
    }

    func enqueueAsk(from: AgentID, to toName: String, question: String, parentTaskID: TaskID?) async -> (taskID: TaskID?, message: String) {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != from else {
            try? await log.append(.error(ErrorPayload(code: "agent_self_call",
                                                       message: "agent cannot ask itself")))
            return (nil, "error: agent cannot ask itself")
        }
        guard to != Self.automaticPermissionReviewerID else {
            return (nil, "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review")
        }
        guard registry.agent(to) != nil else { return (nil, "no such agent: \(toName)") }
        let queued = await enqueueDelegatedTask(
            from: from,
            to: to.rawValue,
            objective: question,
            roleHint: nil,
            expectedDeliverable: nil,
            parentTaskID: parentTaskID,
            replyMode: .answer)
        if let taskID = queued.taskID {
            scheduledReplyTargets[taskID] = from
            scheduledReplyFormats[taskID] = .answer
            ensureSchedulerRunning()
        }
        return queued
    }

    func sendMessage(from: AgentID, to toName: String, content: String, taskID: TaskID? = nil) async -> String {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != from else { return "error: agent cannot message itself" }
        guard to != Self.automaticPermissionReviewerID else {
            return "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review"
        }
        guard registry.agent(to) != nil else { return "no such agent: \(toName)" }
        if let failure = communicationFailure(from: from, to: to, taskID: taskID, operation: .send) {
            return "error: \(failure)"
        }
        guard let payload = await bus.sendMessage(from: from, to: to, content: content, taskID: taskID) else {
            return "your message was blocked by the mediator"
        }
        _ = scheduler.enqueueMessage(PendingAgentMessage(
            id: payload.messageId,
            sender: from,
            recipient: to,
            content: payload.content,
            kind: AgentCommunicationKind.sendMessage.rawValue,
            taskID: taskID,
            causalParentID: taskID,
            inReplyTo: payload.inReplyTo))
        await enqueueMailboxWakeTask(sender: from, recipient: to, causalTaskID: taskID)
        return "sent message to @\(to.rawValue)"
    }

    func requestInformation(from: AgentID, to toName: String, question: String, taskID: TaskID? = nil) async -> String {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != from else { return "error: agent cannot request information from itself" }
        guard to != Self.automaticPermissionReviewerID else {
            return "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review"
        }
        guard registry.agent(to) != nil else { return "no such agent: \(toName)" }
        if let failure = communicationFailure(
            from: from,
            to: to,
            taskID: taskID,
            operation: .requestInformation) {
            return "error: \(failure)"
        }
        guard let payload = await bus.requestInformation(
            from: from,
            to: to,
            question: question,
            taskID: taskID) else {
            return "your information request was blocked by the mediator"
        }
        _ = scheduler.enqueueMessage(PendingAgentMessage(
            id: payload.requestID,
            sender: from,
            recipient: to,
            content: payload.question,
            kind: AgentCommunicationKind.requestInformation.rawValue,
            taskID: taskID,
            causalParentID: taskID))
        await enqueueMailboxWakeTask(sender: from, recipient: to, causalTaskID: taskID)
        return "requested information from @\(to.rawValue)"
    }

    func replyMessage(from: AgentID, to toName: String, content: String, inReplyTo: String?, taskID: TaskID? = nil) async -> String {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != from else { return "error: agent cannot reply to itself" }
        guard to != Self.automaticPermissionReviewerID else {
            return "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review"
        }
        guard registry.agent(to) != nil else { return "no such agent: \(toName)" }
        if let failure = communicationFailure(from: from, to: to, taskID: taskID, operation: .reply) {
            return "error: \(failure)"
        }
        let replyID = inReplyTo.map { MessageID(rawValue: $0) }
        guard let payload = await bus.replyMessage(
            from: from,
            to: to,
            content: content,
            inReplyTo: replyID,
            taskID: taskID) else {
            return "your reply was blocked by the mediator"
        }
        _ = scheduler.enqueueMessage(PendingAgentMessage(
            id: payload.replyID,
            sender: from,
            recipient: to,
            content: payload.content,
            kind: AgentCommunicationKind.replyMessage.rawValue,
            taskID: taskID,
            causalParentID: taskID,
            inReplyTo: payload.inReplyTo))
        await enqueueMailboxWakeTask(sender: from, recipient: to, causalTaskID: taskID)
        return "replied to @\(to.rawValue)"
    }

    func requestDelegation(from: AgentID, objective: String, reason: String, parentTaskID: TaskID? = nil) async -> String {
        guard let parentTaskID,
              let currentTask = taskGraph.node(parentTaskID),
              let recipient = currentTask.issuer else {
            return "error: delegation request has no assigning agent"
        }
        guard let lease = existingCapabilityLease(for: from, taskID: parentTaskID) else {
            return "error: delegation lease unavailable"
        }
        guard lease.tools.contains(.requestDelegation) else {
            return "error: requesting delegation is not granted for the current task"
        }
        switch lease.delegation {
        case .requestOnly, .granted:
            break
        case .none:
            return "error: requesting delegation is not granted for the current task"
        }
        let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = RequestID.new()
        let messageID = MessageID(rawValue: requestID.rawValue)
        let objectiveText = trimmedObjective.isEmpty ? "Additional help requested." : trimmedObjective
        let reasonText = trimmedReason.isEmpty ? "No reason supplied." : trimmedReason
        let content = "Delegation requested for: \(objectiveText)\nReason: \(reasonText)"
        guard let message = await bus.sendMessage(
            from: from,
            to: recipient,
            content: content,
            taskID: parentTaskID,
            messageID: messageID) else {
            return "your delegation request was blocked by the mediator"
        }
        try? await log.append(.delegationRequested(DelegationRequestedPayload(
            requestID: requestID,
            requester: from,
            recipient: recipient,
            objective: objectiveText,
            reason: reasonText,
            parentTaskID: parentTaskID,
            metadata: CoworkEventMetadata(
                taskID: parentTaskID,
                parentTaskID: parentTaskID,
                sender: from,
                recipient: recipient,
                agentID: from,
                scope: .task,
                visibility: .task))))
        _ = scheduler.enqueueMessage(PendingAgentMessage(
            id: message.messageId,
            sender: from,
            recipient: recipient,
            content: message.content,
            kind: "request_delegation",
            taskID: parentTaskID,
            causalParentID: parentTaskID))
        await enqueueMailboxWakeTask(sender: from, recipient: recipient, causalTaskID: parentTaskID)
        return "delegation request delivered to @\(recipient.rawValue)"
    }

    private func enqueuePendingMailboxWakeIfNeeded(for recipient: AgentID,
                                                   fallbackSender: AgentID? = nil) async {
        guard let pendingMessage = scheduler.peekMessage(for: recipient) else { return }
        let wakeSender = pendingMessage.sender
            ?? fallbackSender
            ?? registry.names.first(where: { $0 != recipient })
            ?? recipient
        await enqueueMailboxWakeTask(
            sender: wakeSender,
            recipient: recipient,
            causalTaskID: pendingMessage.causalParentID ?? pendingMessage.taskID)
    }

    private func enqueueMailboxWakeTask(sender: AgentID,
                                        recipient: AgentID,
                                        causalTaskID: TaskID?) async {
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        guard let target = registry.agent(recipient) else { return }
        let alreadyScheduled = scheduler.queuedTasks().contains {
            $0.assignee == recipient && $0.contract.kind == .mailboxDelivery
        } || scheduler.currentlyClaimedTasks().contains {
            $0.assignee == recipient && $0.contract.kind == .mailboxDelivery
        }
        guard !alreadyScheduled else {
            ensureSchedulerRunning()
            return
        }

        var prepared = prepareDelegatedTask(
            issuer: sender,
            assignee: target,
            objective: "Review and respond to pending mailbox messages.",
            roleHint: "mailbox responder",
            expectedDeliverable: "Handle each pending message using the appropriate reply or task tool.",
            parentTaskID: nil,
            replyMode: .none)
        prepared.contract.kind = .mailboxDelivery
        prepared.contract.relatedTasks = causalTaskID.map { [$0] } ?? []
        let contract = prepared.contract
        var preflightGraph = taskGraph
        guard case .success(let admission) = preflightGraph.addRootTask(contract) else { return }
        let metadata = taskMetadata(
            contract: contract,
            rootTaskID: admission.rootTaskID,
            sender: sender,
            recipient: recipient)
        let scheduled = ScheduledTask(
            contract: contract,
            input: contract.objective,
            rootTaskID: admission.rootTaskID,
            parentTaskID: nil,
            issuer: sender,
            assignee: recipient,
            causalParentID: causalTaskID,
            hopCount: admission.hopCount,
            visitedAgents: admission.visitedAgents,
            attempt: 1)
        var preflightScheduler = scheduler
        guard preflightScheduler.enqueue(scheduled, mode: .newTask).accepted else { return }
        do {
            try await appendAdmissionEvent(.capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: recipient,
                lease: prepared.capabilityLease,
                metadata: metadata)))
            try await appendAdmissionEvent(.workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                agent: recipient,
                lease: prepared.workspaceLease,
                metadata: metadata)))
            try await appendAdmissionEvent(.taskCreated(TaskCreatedPayload(
                contract: contract,
                metadata: metadata)))
            try await appendAdmissionEvent(.taskAssigned(TaskAssignedPayload(
                contract: contract,
                metadata: metadata)))
            try await appendAdmissionEvent(.taskQueued(TaskQueuedPayload(
                contract: contract,
                rootTaskID: admission.rootTaskID,
                issuer: sender,
                assignee: recipient,
                causalParentID: causalTaskID,
                hopCount: admission.hopCount,
                visitedAgents: admission.visitedAgents,
                attempt: 1,
                reason: "mailbox delivery",
                metadata: metadata)))
        } catch {
            await persistUncommittedAdmissionCancellation(
                task: scheduled,
                reason: "mailbox wake admission could not be persisted: \(error.localizedDescription)",
                metadata: metadata)
            try? await log.append(.error(ErrorPayload(
                code: "mailbox_wake_admission_persistence_failed",
                message: error.localizedDescription)))
            return
        }
        guard case .success = taskGraph.addRootTask(contract) else { return }
        capabilityLeases[prepared.capabilityLease.id] = prepared.capabilityLease
        workspaceLeases[prepared.workspaceLease.id] = prepared.workspaceLease
        _ = taskGraph.updateStatus(taskID: contract.id, status: .assigned)
        guard scheduler.enqueue(scheduled, mode: .newTask).accepted else { return }
        _ = taskGraph.updateStatus(taskID: contract.id, status: .queued)
        ensureSchedulerRunning()
    }

    func createRootTask(assignee: AgentID,
                        objective: String,
                        roleHint: String = "root task coordinator",
                        expectedDeliverable: String = "Coordinate assigned subtasks and synthesize the result.") async -> TaskID? {
        guard assignee != Self.automaticPermissionReviewerID else { return nil }
        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        guard let agent = registry.agent(assignee),
              let workspaceLeaseID = defaultWorkspaceLeaseIDs[agent.name],
              let workspaceLease = workspaceLeases[workspaceLeaseID],
              let capabilityLeaseID = defaultCapabilityLeaseIDs[agent.name],
              capabilityLeases[capabilityLeaseID] != nil else { return nil }
        let contract = TaskContract(
            kind: .root,
            issuer: nil,
            assignee: agent.name,
            objective: objective.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Coordinate the cowork task.",
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable,
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLeaseID,
            capabilityLeaseID: capabilityLeaseID,
            relatedAgents: agentVisibleNames(excluding: agent.name),
            replyMode: TaskReplyMode.none,
            executionTimeoutSeconds: executionPolicy.taskTimeoutSeconds,
            maxAttempts: executionPolicy.maxAttempts)
        var preflightGraph = taskGraph
        switch preflightGraph.addRootTask(contract) {
        case .success:
            let metadata = taskMetadata(
                contract: contract,
                rootTaskID: contract.id,
                parentTaskID: nil,
                sender: contract.issuer,
                recipient: contract.assignee)
            do {
                try await appendAdmissionEvent(.taskCreated(TaskCreatedPayload(
                    contract: contract,
                    metadata: metadata)))
                try await appendAdmissionEvent(.taskAssigned(TaskAssignedPayload(
                    contract: contract,
                    metadata: metadata)))
            } catch {
                try? await log.append(.error(ErrorPayload(
                    code: "root_admission_persistence_failed",
                    message: error.localizedDescription)))
                return nil
            }
            guard case .success = taskGraph.addRootTask(contract) else { return nil }
            _ = taskGraph.updateStatus(taskID: contract.id, status: .assigned)
            return contract.id
        case .failure(let violation):
            try? await log.append(.error(ErrorPayload(
                code: "task_graph_rejected",
                message: violation.message)))
            try? await log.append(.taskRejected(TaskRejectedPayload(
                contract: contract,
                requester: contract.issuer,
                assignee: contract.assignee,
                objective: contract.objective,
                reason: violation.message,
                violationKind: violation.kind.rawValue,
                metadata: taskMetadata(contract: contract, rootTaskID: contract.id))))
            return nil
        }
    }

    func delegateTask(from: AgentID,
                      to toName: String,
                      objective: String,
                      roleHint: String? = nil,
                      expectedDeliverable: String? = nil,
                      parentTaskID: TaskID? = nil) async -> String {
        let queued = await enqueueDelegatedTask(
            from: from,
            to: toName,
            objective: objective,
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable,
            parentTaskID: parentTaskID,
            replyMode: .taskReport)
        guard let taskID = queued.taskID else { return queued.message }
        scheduledReplyTargets[taskID] = from
        scheduledReplyFormats[taskID] = .taskReport
        ensureSchedulerRunning()
        return await awaitSchedulerResult(taskID) ?? queued.message
    }

    func enqueueDelegatedTask(from: AgentID,
                              to toName: String,
                              objective: String,
                              roleHint: String? = nil,
                              expectedDeliverable: String? = nil,
                              parentTaskID: TaskID? = nil,
                              replyMode: TaskReplyMode = .taskReport) async -> (taskID: TaskID?, message: String) {
        let normalizedName = Self.normalizedAgentName(toName)
        let to = AgentID(rawValue: normalizedName)
        guard to != Self.automaticPermissionReviewerID else {
            return (nil, "@\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review")
        }
        guard let toAgent = registry.agent(to) else { return (nil, "no such agent: \(toName)") }
        if let delegationFailure = delegationFailure(
            from: from,
            to: to,
            parentTaskID: parentTaskID) {
            return (nil, "error: \(delegationFailure)")
        }
        guard let mediatedObjective = await bus.deliver(
            from: from,
            to: to,
            content: objective) else {
            return (nil, "your delegated task was blocked by the mediator")
        }

        await acquireAdmissionLock()
        defer { releaseAdmissionLock() }
        guard let currentTarget = registry.agent(to) else {
            return (nil, "no such agent: \(toName)")
        }
        if let delegationFailure = delegationFailure(
            from: from,
            to: to,
            parentTaskID: parentTaskID) {
            return (nil, "error: \(delegationFailure)")
        }
        let prepared = prepareDelegatedTask(
            issuer: from,
            assignee: currentTarget,
            objective: mediatedObjective,
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable,
            parentTaskID: parentTaskID,
            replyMode: replyMode)
        let contract = prepared.contract

        let admission: TaskGraphAdmission
        var preflightGraph = taskGraph
        switch preflightGraph.addTask(contract) {
        case .success(let accepted):
            admission = accepted
        case .failure(let violation):
            try? await log.append(.error(ErrorPayload(
                code: "task_graph_rejected",
                message: violation.message)))
            try? await log.append(.delegationRejected(DelegationRejectedPayload(
                requester: from,
                assignee: toAgent.name,
                objective: contract.objective,
                reason: violation.message,
                violationKind: violation.kind.rawValue,
                metadata: taskMetadata(
                    contract: contract,
                    rootTaskID: parentTaskID ?? contract.id,
                    parentTaskID: parentTaskID,
                    sender: from,
                    recipient: toAgent.name))))
            try? await log.append(.taskRejected(TaskRejectedPayload(
                contract: contract,
                requester: from,
                assignee: toAgent.name,
                objective: contract.objective,
                reason: violation.message,
                violationKind: violation.kind.rawValue,
                metadata: taskMetadata(
                    contract: contract,
                    rootTaskID: parentTaskID ?? contract.id,
                    parentTaskID: parentTaskID,
                    sender: from,
                    recipient: toAgent.name))))
            return (nil, Self.delegationRejectionMessage(for: violation))
        }

        let metadata = taskMetadata(
            contract: contract,
            rootTaskID: admission.rootTaskID,
            parentTaskID: parentTaskID,
            sender: from,
            recipient: currentTarget.name)

        let scheduled = ScheduledTask(
            contract: contract,
            input: contract.objective,
            rootTaskID: admission.rootTaskID,
            parentTaskID: parentTaskID,
            issuer: from,
            assignee: currentTarget.name,
            causalParentID: parentTaskID,
            hopCount: admission.hopCount,
            visitedAgents: admission.visitedAgents,
            attempt: 1)
        var preflightScheduler = scheduler
        guard preflightScheduler.enqueue(scheduled, mode: .newTask).accepted,
              preflightGraph.updateStatus(taskID: contract.id, status: .assigned),
              preflightGraph.updateStatus(taskID: contract.id, status: .queued) else {
            return (nil, "error: scheduler rejected delegated task")
        }
        do {
            try await appendAdmissionEvent(.delegationApproved(DelegationApprovedPayload(
                contract: contract,
                metadata: metadata)))
            try await appendAdmissionEvent(.capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: currentTarget.name,
                lease: prepared.capabilityLease,
                metadata: metadata)))
            try await appendAdmissionEvent(.workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                agent: currentTarget.name,
                lease: prepared.workspaceLease,
                metadata: metadata)))
            try await appendAdmissionEvent(.taskCreated(TaskCreatedPayload(contract: contract, metadata: metadata)))
            try await appendAdmissionEvent(.taskAssigned(TaskAssignedPayload(contract: contract, metadata: metadata)))
            try await appendAdmissionEvent(.taskDelegated(TaskDelegatedPayload(contract: contract, metadata: metadata)))
            try await appendAdmissionEvent(.taskQueued(TaskQueuedPayload(
                contract: contract,
                rootTaskID: scheduled.rootTaskID,
                parentTaskID: scheduled.parentTaskID,
                issuer: scheduled.issuer,
                assignee: scheduled.assignee,
                causalParentID: scheduled.causalParentID,
                hopCount: scheduled.hopCount,
                visitedAgents: scheduled.visitedAgents,
                attempt: 1,
                reason: "delegation admitted",
                metadata: metadata)))
        } catch {
            await persistUncommittedAdmissionCancellation(
                task: scheduled,
                reason: "delegated task admission could not be persisted: \(error.localizedDescription)",
                metadata: metadata)
            try? await log.append(.error(ErrorPayload(
                code: "delegation_admission_persistence_failed",
                message: error.localizedDescription)))
            return (nil, "error: delegated task admission could not be persisted")
        }
        guard case .success = taskGraph.addTask(contract),
              taskGraph.updateStatus(taskID: contract.id, status: .assigned),
              scheduler.enqueue(scheduled, mode: .newTask).accepted,
              taskGraph.updateStatus(taskID: contract.id, status: .queued) else {
            return (nil, "error: delegated task admission could not be committed after persistence")
        }
        capabilityLeases[prepared.capabilityLease.id] = prepared.capabilityLease
        workspaceLeases[prepared.workspaceLease.id] = prepared.workspaceLease
        return (contract.id, "task queued: \(contract.id.rawValue)")
    }

    // MARK: - Coordinator tools (a lead agent spawns / lists / removes sub-agents)

    /// Create and attach a new sub-agent bound to `path`. Returns a status line
    /// the calling (coordinator) agent can read back.
    func spawnFromTool(requestedBy: AgentID,
                       currentTaskID: TaskID? = nil,
                       name: String,
                       path: String,
                       model: String,
                       canCoordinate: Bool = false) async -> String {
        if let validationError = Self.agentNameValidationError(name) {
            return "error: \(validationError)"
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return "error: not a folder: \(url.path)"
        }
        let id = AgentID(rawValue: name)
        guard id != Self.automaticPermissionReviewerID else {
            return "error: @\(Self.automaticPermissionReviewerID.rawValue) is reserved for automatic permission review"
        }
        guard let lease = existingCapabilityLease(for: requestedBy, taskID: currentTaskID),
              case .granted(let budget) = lease.delegation,
              lease.tools.contains(.attachWorkspace) else {
            return "error: spawning agents is not granted for the current task"
        }
        if canCoordinate, budget.maxDepth < 1 {
            return "error: coordinator spawning exceeds the delegation depth budget"
        }
        let activeAgentCount = registry.names.filter { $0 != Self.automaticPermissionReviewerID }.count
        guard activeAgentCount < taskGraph.policy.maxActiveAgentsPerThread else {
            return "error: active agent limit reached (\(taskGraph.policy.maxActiveAgentsPerThread))"
        }
        if registry.agent(id) != nil { return "error: an agent named @\(name) already exists" }
        try? await log.append(.agentSpawnRequested(AgentSpawnRequestedPayload(
            requestedBy: requestedBy,
            agent: id,
            path: url.path,
            model: ModelID(rawValue: model),
            metadata: CoworkEventMetadata(
                sender: requestedBy,
                agentID: id,
                scope: .agent))))
        let coordinationDepth = canCoordinate ? Agent.defaultCoordinationDepth : 0
        let attached = await attach(Agent(name: id, workspaceRoot: url,
                                          model: ModelID(rawValue: model), profile: .reviewed,
                                          coordinationDepth: coordinationDepth),
                                    admissionIssuer: requestedBy,
                                    causalParentTaskID: currentTaskID)
        if attached {
            spawnedAgentOwners[id] = requestedBy
            try? await log.append(.agentSpawned(AgentSpawnedPayload(
                requestedBy: requestedBy,
                agent: id,
                path: url.path,
                model: ModelID(rawValue: model),
                metadata: CoworkEventMetadata(
                    sender: requestedBy,
                    agentID: id,
                    scope: .agent))))
        }
        return attached
            ? "spawned @\(name) · model \(model) · \(canCoordinate ? "coordinator" : "worker") · \(url.path)"
            : "permission denied: workspace attach for @\(name)"
    }

    /// One line per active agent, for the coordinator to read.
    func listForTool() -> String {
        let all = registry.all()
            .filter { $0.name != Self.automaticPermissionReviewerID }
            .sorted { $0.name.rawValue < $1.name.rawValue }
        guard !all.isEmpty else { return "(no agents)" }
        return all.map {
            [
                "@\($0.name.rawValue)",
                $0.model.rawValue,
                agentListRole(for: $0),
                agentListTaskState(for: $0.name),
                $0.workspaceRoot.path,
            ].joined(separator: " · ")
        }
            .joined(separator: "\n")
    }

    private func agentListRole(for agent: Agent) -> String {
        let lease = defaultCapabilityLeaseIDs[agent.name].flatMap { capabilityLeases[$0] }
        let canCoordinate = lease.map(Self.canCoordinate) ?? (agent.coordinationDepth > 0)
        return canCoordinate ? "coordinator" : "worker"
    }

    private func agentListTaskState(for agentID: AgentID) -> String {
        let assignedTasks = taskGraph.nodes.values
            .filter { $0.assignee == agentID }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        let issuedActiveTasks = taskGraph.nodes.values
            .filter { $0.issuer == agentID && $0.assignee != agentID && Self.isActiveTaskStatus($0.status) }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        let mailbox = scheduler.mailbox(for: agentID)

        var parts: [String] = []
        if assignedTasks.isEmpty {
            parts.append("tasks idle")
        } else {
            parts.append("tasks \(Self.compactTaskStates(assignedTasks))")
        }
        if !issuedActiveTasks.isEmpty {
            parts.append("issued active \(Self.compactTaskStates(issuedActiveTasks))")
        }
        if !mailbox.pendingMessages.isEmpty {
            parts.append("messages \(mailbox.pendingMessages.count)")
        }
        if mailbox.pendingTasks.count > assignedTasks.filter({ Self.isActiveTaskStatus($0.status) }).count {
            parts.append("queued mailbox \(mailbox.pendingTasks.count)")
        }
        return parts.joined(separator: ", ")
    }

    /// Detach a sub-agent. `@main` is protected so the user always keeps a coordinator.
    func removeFromTool(requestedBy: AgentID, currentTaskID: TaskID?, name: String) async -> String {
        guard let lease = existingCapabilityLease(for: requestedBy, taskID: currentTaskID),
              case .granted = lease.delegation,
              lease.tools.contains(.delegateTask) else {
            return "error: removing agents is not granted for the current task"
        }
        let id = AgentID(rawValue: name)
        guard registry.agent(id) != nil else { return "error: no agent named @\(name)" }
        if name == "main" { return "error: cannot remove @main" }
        if id == Self.automaticPermissionReviewerID {
            return "error: @\(Self.automaticPermissionReviewerID.rawValue) is controlled by /default"
        }
        guard requestedBy == Self.mainAgentID || spawnedAgentOwners[id] == requestedBy else {
            return "error: @\(requestedBy.rawValue) does not own @\(name)"
        }
        guard !taskGraph.nodes.values.contains(where: {
            ($0.assignee == id || $0.issuer == id) && Self.isActiveTaskStatus($0.status)
        }) else {
            return "error: @\(name) still has active tasks; cancel them before removal"
        }
        guard await detach(id) else {
            return "error: @\(name) could not be removed because its detach audit was not persisted"
        }
        return "removed @\(name)"
    }

    private func run(_ agent: Agent,
                     input: String,
                     images: [ImageAttachment] = [],
                     userMessage: UserMessagePayload? = nil,
                     taskContract: TaskContract? = nil,
                     rootTaskID: TaskID? = nil,
                     taskAttempt: Int? = nil) async throws -> AgentRunResult {
        let capabilityLease = try capabilityLease(for: agent, taskContract: taskContract)
        let workspaceLease = try workspaceLease(for: agent, taskContract: taskContract)
        let provider = try await providerFor(agent)
        let messenger = BusMessenger(from: agent.name, currentTaskID: taskContract?.id, orchestrator: self)
        let manager = OrchestratorManager(
            orchestrator: self,
            requester: agent.name,
            currentTaskID: taskContract?.id,
            defaultModel: agent.model.rawValue)
        let toolRegistry = Self.toolRegistry(for: capabilityLease)
        let imageGenerator = await imageGeneratorFor(agent)
        let allowedToolNames = toolRegistry.descriptors().map(\.name).sorted()
        let canCoordinate = Self.canCoordinate(capabilityLease)
        // Give the agent a prompt that matches its current task lease. A numeric
        // depth may still exist on old agents, but the lease decides tool exposure.
        let systemPrompt = ContextBuilder.coworkSystemPrompt(
            name: agent.name.rawValue, folder: agent.workspaceRoot.path,
            coordinationDepth: agent.coordinationDepth,
            canCoordinate: canCoordinate)
        let contextBundle = ContextProjector().project(
            agentID: agent.name,
            taskContract: taskContract,
            events: await log.replay(),
            allowedToolNames: allowedToolNames,
            workspaceRoot: agent.workspaceRoot)
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: toolRegistry,
            engine: engine,
            responder: activePermissionResponder(),
            agent: agent,
            context: ContextBuilder(systemPrompt: systemPrompt,
                                    taskContract: taskContract,
                                    contextBundle: contextBundle),
            allowsShell: allowsShell,
            messenger: messenger,
            agentManager: manager,
            imageGenerator: imageGenerator,
            reasoningEffort: reasoningEffort,
            includeUsage: includeUsage || executionPolicy.tokenBudget != nil,
            maxIterations: maxSteps,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease,
            rootTaskID: rootTaskID,
            taskAttempt: taskAttempt,
            tokenBudgetMeter: tokenBudgetMeter
        )
        let output = try await loop.send(input, images: images, userMessage: userMessage)
        return AgentRunResult(
            output: output,
            presentedMessageIDs: contextBundle.directMessages.compactMap(\.messageID))
    }

    private static func normalizedAgentName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }

    private static let maxAgentNameCharacters = 64

    private static func agentNameValidationError(_ raw: String) -> String? {
        guard !raw.isEmpty else { return "an agent name is required" }
        if raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "agent names cannot contain control characters"
        }
        if raw.contains(where: { $0.isWhitespace }) {
            return "agent names cannot contain whitespace"
        }
        guard raw.count <= maxAgentNameCharacters else {
            return "agent names cannot exceed \(maxAgentNameCharacters) characters"
        }
        guard let first = raw.unicodeScalars.first,
              isASCIIAlphaNumeric(first),
              raw.unicodeScalars.allSatisfy(isValidAgentNameScalar) else {
            return "agent names must start with an ASCII letter or digit and contain only ASCII letters, digits, '-' or '_'"
        }
        return nil
    }

    private static func isValidAgentNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIAlphaNumeric(scalar) || scalar.value == 45 || scalar.value == 95
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }

    private func reverseLeaseAgents<ID: Hashable>(_ leaseAgents: [ID: AgentID]) -> [AgentID: ID] {
        var result: [AgentID: ID] = [:]
        for (leaseID, agent) in leaseAgents where result[agent] == nil {
            guard agent != Self.automaticPermissionReviewerID else { continue }
            result[agent] = leaseID
        }
        return result
    }

    private func deterministicDefaultCapabilityLeases(
        projection: CoworkProjection,
        taskLeaseIDs: Set<CapabilityLeaseID>
    ) -> [AgentID: CapabilityLeaseID] {
        var result: [AgentID: CapabilityLeaseID] = [:]
        let candidates = projection.capabilityLeaseAgents.compactMap { leaseID, agent -> (AgentID, CapabilityLeaseID)? in
            guard agent != Self.automaticPermissionReviewerID,
                  let lease = projection.capabilityLeases[leaseID],
                  lease.taskID == nil,
                  !taskLeaseIDs.contains(leaseID),
                  capabilityLeases[leaseID] != nil else { return nil }
            return (agent, leaseID)
        }.sorted {
            if $0.0 == $1.0 { return $0.1.rawValue < $1.1.rawValue }
            return $0.0.rawValue < $1.0.rawValue
        }
        for (agent, leaseID) in candidates where result[agent] == nil {
            result[agent] = leaseID
        }
        return result
    }

    private func deterministicDefaultWorkspaceLeases(
        projection: CoworkProjection,
        taskLeaseIDs: Set<WorkspaceLeaseID>
    ) -> [AgentID: WorkspaceLeaseID] {
        var result: [AgentID: WorkspaceLeaseID] = [:]
        let candidates = projection.workspaceLeaseAgents.compactMap { leaseID, agent -> (AgentID, WorkspaceLeaseID)? in
            guard agent != Self.automaticPermissionReviewerID,
                  let lease = projection.workspaceLeases[leaseID],
                  lease.taskID == nil,
                  !taskLeaseIDs.contains(leaseID),
                  workspaceLeases[leaseID] != nil else { return nil }
            return (agent, leaseID)
        }.sorted {
            if $0.0 == $1.0 { return $0.1.rawValue < $1.1.rawValue }
            return $0.0.rawValue < $1.0.rawValue
        }
        for (agent, leaseID) in candidates where result[agent] == nil {
            result[agent] = leaseID
        }
        return result
    }

    private func pendingMessageDetails(for agent: AgentID,
                                       pendingIDs: Set<MessageID>,
                                       events: [Envelope]) -> [PendingAgentMessage] {
        var details: [MessageID: PendingAgentMessage] = [:]
        for envelope in events {
            switch envelope.event {
            case .agentMessage(let payload):
                guard payload.to == agent, pendingIDs.contains(payload.messageId) else { continue }
                details[payload.messageId] = PendingAgentMessage(
                    id: payload.messageId,
                    sender: payload.from,
                    recipient: agent,
                    content: payload.content,
                    kind: payload.kind?.rawValue ?? "send_message",
                    taskID: payload.taskID,
                    causalParentID: payload.metadata?.causalParentID,
                    inReplyTo: payload.inReplyTo,
                    createdAt: payload.metadata?.createdAt ?? envelope.ts)
            case .informationRequested(let payload):
                guard payload.to == agent, pendingIDs.contains(payload.requestID) else { continue }
                details[payload.requestID] = PendingAgentMessage(
                    id: payload.requestID,
                    sender: payload.from,
                    recipient: agent,
                    content: payload.question,
                    kind: AgentCommunicationKind.requestInformation.rawValue,
                    taskID: payload.taskID,
                    causalParentID: payload.metadata?.causalParentID,
                    createdAt: payload.metadata?.createdAt ?? envelope.ts)
            case .informationReplied(let payload):
                guard payload.to == agent, pendingIDs.contains(payload.replyID) else { continue }
                details[payload.replyID] = PendingAgentMessage(
                    id: payload.replyID,
                    sender: payload.from,
                    recipient: agent,
                    content: payload.content,
                    kind: AgentCommunicationKind.replyMessage.rawValue,
                    taskID: payload.taskID,
                    causalParentID: payload.metadata?.causalParentID,
                    inReplyTo: payload.inReplyTo,
                    createdAt: payload.metadata?.createdAt ?? envelope.ts)
            default:
                break
            }
        }
        return pendingIDs.compactMap { details[$0] }.sorted { $0.createdAt < $1.createdAt }
    }

    private func activePermissionResponder() -> PermissionResponder {
        if automaticPermissionReviewDisabling {
            return responder
        }
        return automaticPermissionResponder ?? responder
    }

    private func agentVisibleNames(excluding excluded: AgentID) -> [AgentID] {
        registry.names.filter {
            $0 != excluded && $0 != Self.automaticPermissionReviewerID
        }
    }

    private func prepareDelegatedTask(issuer: AgentID,
                                      assignee: Agent,
                                      objective: String,
                                      roleHint: String? = nil,
                                      expectedDeliverable: String? = nil,
                                      parentTaskID: TaskID? = nil,
                                      replyMode: TaskReplyMode = .taskReport) -> PreparedDelegatedTask {
        let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let relatedAgents = agentVisibleNames(excluding: assignee.name)
        let taskID = TaskID.new()
        let defaultLease = defaultCapabilityLeaseIDs[assignee.name].flatMap { capabilityLeases[$0] }
        let capabilityLease: CapabilityLease
        if let defaultLease, Self.canCoordinate(defaultLease) {
            let budget: DelegationBudget
            if case .granted(let granted) = defaultLease.delegation {
                budget = granted
            } else {
                budget = DelegationBudget(maxTasks: 8, maxDepth: 1)
            }
            capabilityLease = .coordinator(taskID: taskID, budget: budget)
        } else {
            capabilityLease = .worker(taskID: taskID)
        }
        let workspaceAccess: WorkspaceAccess = Self.canCoordinate(capabilityLease) ? .readWrite : .readOnly
        let workspaceLease = workspaceLeaseForTask(
            agent: assignee,
            taskID: taskID,
            access: workspaceAccess,
            store: false)
        let contract = TaskContract(
            id: taskID,
            issuer: issuer,
            assignee: assignee.name,
            parentTaskID: parentTaskID,
            objective: trimmedObjective.isEmpty ? "Answer the assigned task." : trimmedObjective,
            roleHint: roleHint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? Self.defaultRoleHint(for: assignee.name, objective: trimmedObjective),
            expectedDeliverable: expectedDeliverable?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Answer the assigned task clearly and concisely.",
            workspaceID: workspaceLease.workspaceID,
            workspaceLeaseID: workspaceLease.id,
            capabilityLeaseID: capabilityLease.id,
            relatedAgents: relatedAgents,
            relatedTasks: [],
            constraints: Self.canCoordinate(capabilityLease) ? [] : Self.defaultWorkerConstraints,
            replyMode: replyMode,
            executionTimeoutSeconds: executionPolicy.taskTimeoutSeconds,
            maxAttempts: executionPolicy.maxAttempts)
        return PreparedDelegatedTask(
            contract: contract,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease)
    }

    @discardableResult
    private func createDefaultLeases(for agent: Agent) -> (capability: CapabilityLease, workspace: WorkspaceLease) {
        let leases = prepareDefaultLeases(for: agent)
        commitDefaultLeases(leases, for: agent.name)
        return leases
    }

    private func prepareDefaultLeases(for agent: Agent) -> (capability: CapabilityLease, workspace: WorkspaceLease) {
        let workspaceLease = WorkspaceLease(rootPath: agent.workspaceRoot.path, access: .readWrite)
        var capabilityLease: CapabilityLease = agent.coordinationDepth > 0
            ? .coordinator()
            : .worker()
        capabilityLease.expiresAtTaskCompletion = false
        return (capabilityLease, workspaceLease)
    }

    private func commitDefaultLeases(
        _ leases: (capability: CapabilityLease, workspace: WorkspaceLease),
        for agent: AgentID
    ) {
        workspaceLeases[leases.workspace.id] = leases.workspace
        defaultWorkspaceLeaseIDs[agent] = leases.workspace.id
        capabilityLeases[leases.capability.id] = leases.capability
        defaultCapabilityLeaseIDs[agent] = leases.capability.id
    }

    private func workspaceLeaseForTask(agent: Agent,
                                       taskID: TaskID,
                                       access: WorkspaceAccess,
                                       store: Bool = true) -> WorkspaceLease {
        if let leaseID = defaultWorkspaceLeaseIDs[agent.name],
           let defaultLease = workspaceLeases[leaseID] {
            var taskLease = WorkspaceLease(
                workspaceID: defaultLease.workspaceID,
                taskID: taskID,
                rootPath: defaultLease.rootPath,
                rootIdentity: defaultLease.rootIdentity,
                access: access,
                allowedPathRules: defaultLease.allowedPathRules,
                deniedPatterns: defaultLease.deniedPatterns,
                expiresAtTaskCompletion: true)
            // `WorkspaceLease.init` captures when passed nil for new grants;
            // derivation must preserve a legacy/missing identity as nil so the
            // execution boundary fails closed instead of blessing a swapped root.
            taskLease.rootIdentity = defaultLease.rootIdentity
            if store {
                workspaceLeases[taskLease.id] = taskLease
            }
            return taskLease
        }

        var taskLease = WorkspaceLease(
            taskID: taskID,
            rootPath: agent.workspaceRoot.path,
            access: access,
            expiresAtTaskCompletion: true)
        taskLease.rootIdentity = nil
        if store {
            workspaceLeases[taskLease.id] = taskLease
        }
        return taskLease
    }

    private func capabilityLease(for agent: Agent,
                                 taskContract: TaskContract?) throws -> CapabilityLease {
        if let taskContract {
            guard let leaseID = taskContract.capabilityLeaseID else {
                throw CoworkTaskExecutionError.invalidLease(
                    "task \(taskContract.id.rawValue) has no capability lease")
            }
            guard let lease = capabilityLeases[leaseID] else {
                throw CoworkTaskExecutionError.invalidLease(
                    "capability lease \(leaseID.rawValue) is missing or revoked")
            }
            if let boundTaskID = lease.taskID,
               boundTaskID != taskContract.id {
                throw CoworkTaskExecutionError.invalidLease(
                    "capability lease belongs to task \(boundTaskID.rawValue)")
            }
            return lease
        }
        if let leaseID = defaultCapabilityLeaseIDs[agent.name],
           let lease = capabilityLeases[leaseID] {
            return lease
        }
        var lease = CapabilityLease.worker()
        lease.expiresAtTaskCompletion = false
        capabilityLeases[lease.id] = lease
        defaultCapabilityLeaseIDs[agent.name] = lease.id
        return lease
    }

    private func workspaceLease(for agent: Agent,
                                taskContract: TaskContract?) throws -> WorkspaceLease? {
        if let taskContract {
            guard let leaseID = taskContract.workspaceLeaseID else {
                throw CoworkTaskExecutionError.invalidLease(
                    "task \(taskContract.id.rawValue) has no workspace lease")
            }
            guard let lease = workspaceLeases[leaseID] else {
                throw CoworkTaskExecutionError.invalidLease(
                    "workspace lease \(leaseID.rawValue) is missing or revoked")
            }
            if let boundTaskID = lease.taskID,
               boundTaskID != taskContract.id {
                throw CoworkTaskExecutionError.invalidLease(
                    "workspace lease belongs to task \(boundTaskID.rawValue)")
            }
            if let workspaceID = taskContract.workspaceID,
               workspaceID != lease.workspaceID {
                throw CoworkTaskExecutionError.invalidLease(
                    "workspace lease does not match the task workspace")
            }
            guard let rootIdentity = lease.rootIdentity else {
                throw CoworkTaskExecutionError.invalidLease(
                    "workspace lease has no reviewed root identity")
            }
            guard rootIdentity.matchesCurrentDirectory(rootPath: lease.rootPath) else {
                throw CoworkTaskExecutionError.invalidLease(
                    "workspace root identity changed after the lease was granted")
            }
            return lease
        }
        if let leaseID = defaultWorkspaceLeaseIDs[agent.name],
           let lease = workspaceLeases[leaseID] {
            guard let rootIdentity = lease.rootIdentity else {
                throw CoworkTaskExecutionError.invalidLease(
                    "default workspace lease has no reviewed root identity")
            }
            guard rootIdentity.matchesCurrentDirectory(rootPath: lease.rootPath) else {
                throw CoworkTaskExecutionError.invalidLease(
                    "default workspace root identity changed after the lease was granted")
            }
            return lease
        }
        return nil
    }

    private func existingCapabilityLease(for agentID: AgentID, taskID: TaskID?) -> CapabilityLease? {
        if let taskID {
            guard let node = taskGraph.node(taskID), node.assignee == agentID else { return nil }
            let contract = node.contract
            guard let leaseID = contract.capabilityLeaseID,
                  let lease = capabilityLeases[leaseID],
                  lease.taskID == nil || lease.taskID == taskID else { return nil }
            return lease
        }
        if let leaseID = defaultCapabilityLeaseIDs[agentID] {
            return capabilityLeases[leaseID]
        }
        return nil
    }

    private func delegationFailure(from: AgentID,
                                   to: AgentID,
                                   parentTaskID: TaskID?) -> String? {
        guard from != to else { return "agent cannot delegate to itself" }
        guard let lease = existingCapabilityLease(for: from, taskID: parentTaskID) else {
            return "delegation lease unavailable"
        }
        guard lease.tools.contains(.delegateTask) else {
            return "delegation tool capability is not granted for the current task"
        }
        guard case .granted(let budget) = lease.delegation else {
            return "delegation is not granted for the current task"
        }
        let issuedCount = taskGraph.nodes.values.filter { node in
            node.issuer == from && node.parentTaskID == parentTaskID
        }.count
        guard issuedCount < budget.maxTasks else {
            return "delegation task budget exhausted (\(budget.maxTasks))"
        }
        let relativeDepth: Int
        if let leaseTaskID = lease.taskID,
           let parentTaskID {
            relativeDepth = max(1, taskGraph.depth(of: parentTaskID) - taskGraph.depth(of: leaseTaskID) + 1)
        } else {
            relativeDepth = 1
        }
        guard relativeDepth <= budget.maxDepth else {
            return "delegation depth budget exhausted (\(budget.maxDepth))"
        }
        return nil
    }

    private func communicationFailure(from: AgentID,
                                      to: AgentID,
                                      taskID: TaskID?,
                                      operation: CommunicationOperation) -> String? {
        guard let lease = existingCapabilityLease(for: from, taskID: taskID) else {
            return "communication lease unavailable"
        }
        let requiredCapability: ToolCapability
        switch operation {
        case .send:
            requiredCapability = .sendMessage
        case .requestInformation:
            requiredCapability = .requestInformation
        case .reply:
            requiredCapability = .replyMessage
        }
        guard lease.tools.contains(requiredCapability) else {
            return "communication tool capability is not granted for the current task"
        }
        switch lease.communication {
        case .none:
            return "communication is not granted for the current task"
        case .replyOnly:
            guard operation == .reply else {
                return "the current lease allows replies only"
            }
            guard let taskID,
                  let issuer = taskGraph.node(taskID)?.issuer else {
                return "reply-only communication requires an assigning task"
            }
            if issuer != to {
                return "reply-only lease may only contact the assigning agent"
            }
            return nil
        case .selectedAgents(let agents):
            return agents.contains(to) ? nil : "target agent is outside the communication lease"
        case .taskGroup:
            guard let taskID,
                  let rootTaskID = taskGraph.node(taskID)?.rootTaskID,
                  taskGraph.nodes.values.contains(where: { $0.rootTaskID == rootTaskID && $0.assignee == to }) else {
                return "target agent is outside the task group"
            }
            return nil
        case .anyAgentInThread:
            return nil
        }
    }

    private func taskMetadata(contract: TaskContract,
                              rootTaskID: TaskID? = nil,
                              parentTaskID: TaskID? = nil,
                              sender: AgentID? = nil,
                              recipient: AgentID? = nil,
                              scope: CoworkEventScope = .task,
                              visibility: CoworkEventVisibility = .task) -> CoworkEventMetadata {
        CoworkEventMetadata(
            taskID: contract.id,
            rootTaskID: rootTaskID,
            parentTaskID: parentTaskID ?? contract.parentTaskID,
            sender: sender,
            recipient: recipient,
            agentID: contract.assignee,
            issuer: contract.issuer,
            assignee: contract.assignee,
            workspaceID: contract.workspaceID,
            workspaceLeaseID: contract.workspaceLeaseID,
            capabilityLeaseID: contract.capabilityLeaseID,
            causalParentID: parentTaskID ?? contract.parentTaskID,
            scope: scope,
            visibility: visibility)
    }

    @discardableResult
    func runNextScheduledTask() async -> Bool {
        guard let task = scheduler.claimNext(excluding: terminalCommitTaskIDs) else { return false }
        let execution = launchClaimedTask(task)
        await execution.value
        return true
    }

    private func launchClaimedTask(_ task: ScheduledTask) -> Task<Void, Never> {
        if let existing = runningExecutions[task.contract.id] {
            return existing
        }
        let execution = Task {
            await self.executeClaimedTask(task)
        }
        runningExecutions[task.contract.id] = execution
        return execution
    }

    private func ensureSchedulerRunning() {
        guard !schedulerSuspended else { return }
        let concurrencyLimit = max(1, executionPolicy.maxConcurrentTasks)
        while runningExecutions.count < concurrencyLimit,
              let task = scheduler.claimNext(excluding: terminalCommitTaskIDs) {
            _ = launchClaimedTask(task)
        }
        notifyIdleIfNeeded()
    }

    private func executeClaimedTask(_ task: ScheduledTask) async {
        let taskID = task.contract.id
        let metadata = taskMetadata(
            contract: task.contract,
            rootTaskID: task.rootTaskID,
            parentTaskID: task.parentTaskID,
            sender: task.issuer,
            recipient: task.assignee)
        if let taskStartGate {
            await taskStartGate(taskID)
        }
        guard scheduler.record(for: taskID)?.status == .queued else {
            executionDidFinish(taskID)
            return
        }
        guard !terminalCommitTaskIDs.contains(taskID) else {
            runningExecutions.removeValue(forKey: taskID)
            return
        }
        do {
            try await appendTaskLifecycleEvent(.taskStarted(TaskStartedPayload(
                taskID: taskID,
                agent: task.assignee,
                attempt: task.attempt,
                metadata: metadata)))
        } catch {
            if terminalCommitTaskIDs.contains(taskID)
                || scheduler.record(for: taskID)?.status.isTerminal == true {
                runningExecutions.removeValue(forKey: taskID)
                return
            }
            await finishFailedTask(
                task,
                message: "Task start could not be persisted: \(error.localizedDescription)",
                metadata: metadata)
            executionDidFinish(taskID)
            return
        }
        guard scheduler.recordStarted(task: task) else {
            if scheduler.record(for: taskID)?.status.isTerminal != true {
                await finishFailedTask(
                    task,
                    message: "durable task start could not be committed to scheduler state",
                    metadata: metadata)
            }
            executionDidFinish(taskID)
            return
        }
        guard taskGraph.updateStatus(taskID: taskID, status: .running) else {
            let metadata = taskMetadata(
                contract: task.contract,
                rootTaskID: task.rootTaskID,
                parentTaskID: task.parentTaskID,
                sender: task.issuer,
                recipient: task.assignee)
            await finishFailedTask(
                task,
                message: "invalid task state transition to running",
                metadata: metadata)
            executionDidFinish(taskID)
            return
        }

        var completedSuccessfully = false

        if let limit = executionPolicy.tokenBudget,
           consumedTokenCount >= limit {
            await finishFailedTask(
                task,
                message: CoworkTaskExecutionError.tokenBudgetExhausted(limit: limit).localizedDescription,
                metadata: metadata)
            executionDidFinish(taskID)
            return
        }

        guard let agent = registry.agent(task.assignee) else {
            let message = "scheduled task assignee is not attached: @\(task.assignee.rawValue)"
            await finishFailedTask(task, message: message, metadata: metadata)
            executionDidFinish(taskID)
            return
        }

        let invocation = rootInvocations[taskID]
        let timeout = task.contract.executionTimeoutSeconds ?? executionPolicy.taskTimeoutSeconds
        do {
            let runResult = try await withTaskTimeout(seconds: timeout) { [self] in
                try await run(
                    agent,
                    input: task.input,
                    images: invocation?.images ?? [],
                    userMessage: invocation?.userMessage,
                    taskContract: task.contract,
                    rootTaskID: task.rootTaskID,
                    taskAttempt: task.attempt)
            }
            let result = runResult.output
            try Task.checkCancellation()
            if let cancellationReason = cancellationReasons[taskID] {
                throw CoworkTaskExecutionError.cancelled(cancellationReason)
            }
            completedSuccessfully = await finishCompletedTask(
                task,
                result: result,
                presentedMessageIDs: Set(runResult.presentedMessageIDs),
                metadata: metadata)
        } catch {
            if error is CancellationError || cancellationReasons[taskID] != nil {
                let reason = cancellationReasons[taskID] ?? "execution cancelled"
                await finishCancelledTask(task, reason: reason, metadata: metadata)
            } else {
                await finishFailedTask(task, message: error.localizedDescription, metadata: metadata)
            }
        }
        executionDidFinish(taskID, resumeScheduler: false)
        if completedSuccessfully {
            await enqueuePendingMailboxWakeIfNeeded(for: task.assignee, fallbackSender: task.issuer)
        } else if task.contract.kind == .mailboxDelivery,
                  scheduler.record(for: taskID)?.status == .failed,
                  scheduler.peekMessage(for: task.assignee) != nil {
            _ = await admitRetry(taskID: taskID, reason: "automatic mailbox delivery retry")
        }
        ensureSchedulerRunning()
        notifyIdleIfNeeded()
    }

    func runSchedulerUntilIdle() async {
        ensureSchedulerRunning()
        if scheduler.queuedTasks().isEmpty, runningExecutions.isEmpty {
            await recycleIdleToolSpawnedAgents(reason: "scheduled tasks drained; auto-recycled idle tool-spawned agent")
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
        await recycleIdleToolSpawnedAgents(reason: "scheduled tasks drained; auto-recycled idle tool-spawned agent")
    }

    private func finishCompletedTask(_ task: ScheduledTask,
                                     result: String,
                                     presentedMessageIDs: Set<MessageID>,
                                     metadata: CoworkEventMetadata) async -> Bool {
        let report = Self.makeTaskReport(
            task: task,
            status: .completed,
            result: result,
            attempt: task.attempt)
        do {
            try await appendTaskLifecycleEvent(.taskCompleted(TaskCompletedPayload(
                taskID: task.contract.id,
                agent: task.assignee,
                result: result,
                report: report,
                attempt: task.attempt,
                metadata: metadata)))
        } catch {
            let message = "Task completion could not be persisted: \(error.localizedDescription)"
            _ = await finishFailedTask(task, message: message, metadata: metadata)
            return false
        }

        terminalPersistenceFailures.removeValue(forKey: task.contract.id)
        scheduler.recordCompleted(task: task, result: result)
        _ = taskGraph.updateStatus(taskID: task.contract.id, status: .completed)
        await consumeDeliveredMessages(for: task, messageIDs: presentedMessageIDs)
        await storeScheduledReply(task: task, result: result, report: report, error: nil)
        await revokeTaskLeases(contract: task.contract, reason: "task completed")
        await refreshConsumedTokenCount()
        completeResultWaiters(task.contract.id)
        await recycleToolSpawnedAgentIfIdle(
            task.assignee,
            reason: "task \(task.contract.id.rawValue) completed; auto-recycled tool-spawned agent")
        return true
    }

    @discardableResult
    private func finishFailedTask(_ task: ScheduledTask,
                                  message: String,
                                  metadata: CoworkEventMetadata) async -> Bool {
        let report = Self.makeTaskReport(
            task: task,
            status: .failed,
            error: message,
            attempt: task.attempt)
        do {
            try await appendTaskLifecycleEvent(.taskFailed(TaskFailedPayload(
                taskID: task.contract.id,
                agent: task.assignee,
                error: message,
                report: report,
                attempt: task.attempt,
                metadata: metadata)))
        } catch {
            await recordTerminalPersistenceFailure(task: task, error: error)
            return false
        }

        terminalPersistenceFailures.removeValue(forKey: task.contract.id)
        scheduler.recordFailed(task: task, error: message)
        commitFailedTaskGraphState(taskID: task.contract.id)
        await storeScheduledReply(task: task, result: nil, report: report, error: message)
        await revokeTaskLeases(contract: task.contract, reason: "task failed")
        await refreshConsumedTokenCount()
        completeResultWaiters(task.contract.id)
        return true
    }

    private func commitFailedTaskGraphState(taskID: TaskID) {
        if taskGraph.updateStatus(taskID: taskID, status: .failed) { return }
        guard let status = taskGraph.node(taskID)?.status,
              !status.isTerminal else { return }
        if status == .created {
            _ = taskGraph.updateStatus(taskID: taskID, status: .assigned)
        }
        if taskGraph.node(taskID)?.status == .assigned {
            _ = taskGraph.updateStatus(taskID: taskID, status: .queued)
        }
        if taskGraph.node(taskID)?.status == .queued {
            _ = taskGraph.updateStatus(taskID: taskID, status: .running)
        }
        _ = taskGraph.updateStatus(taskID: taskID, status: .failed)
    }

    @discardableResult
    private func finishCancelledTask(_ task: ScheduledTask,
                                     reason: String,
                                     metadata: CoworkEventMetadata) async -> Bool {
        let report = Self.makeTaskReport(
            task: task,
            status: .cancelled,
            error: reason,
            attempt: task.attempt)
        do {
            try await appendTaskLifecycleEvent(.taskCancelled(TaskCancelledPayload(
                taskID: task.contract.id,
                agent: task.assignee,
                reason: reason,
                report: report,
                attempt: task.attempt,
                metadata: metadata)))
        } catch {
            await recordTerminalPersistenceFailure(task: task, error: error)
            return false
        }

        terminalPersistenceFailures.removeValue(forKey: task.contract.id)
        scheduler.recordCancelled(task: task, reason: reason)
        _ = taskGraph.updateStatus(taskID: task.contract.id, status: .cancelled)
        await storeScheduledReply(task: task, result: nil, report: report, error: reason)
        await revokeTaskLeases(contract: task.contract, reason: "task cancelled")
        await refreshConsumedTokenCount()
        completeResultWaiters(task.contract.id)
        return true
    }

    private func appendTaskLifecycleEvent(_ event: Event) async throws {
        if let taskLifecycleEventAppender {
            try await taskLifecycleEventAppender(event)
        } else {
            try await log.append(event)
        }
    }

    private func appendAdmissionEvent(_ event: Event) async throws {
        if let admissionEventAppender {
            try await admissionEventAppender(event)
        } else {
            try await log.append(event)
        }
    }

    private func appendAdmissionEvents(_ events: [Event]) async throws {
        guard !events.isEmpty else { return }
        if let admissionEventsAppender {
            try await admissionEventsAppender(events)
        } else {
            // The real EventLog holds one cross-process lock for the entire
            // admission/revoke transaction. Do not fall back to the per-event
            // test seam here: doing so would make failure injection capable of
            // producing a state that production explicitly forbids.
            try await log.append(events)
        }
    }

    private func persistUncommittedAdmissionCancellation(
        task: ScheduledTask,
        reason: String,
        metadata: CoworkEventMetadata
    ) async {
        let report = Self.makeTaskReport(
            task: task,
            status: .cancelled,
            error: reason,
            attempt: task.attempt)
        try? await appendTaskLifecycleEvent(.taskCancelled(TaskCancelledPayload(
            taskID: task.contract.id,
            agent: task.assignee,
            reason: reason,
            report: report,
            attempt: task.attempt,
            metadata: metadata)))
    }

    private func acquireAdmissionLock() async {
        if !admissionLocked {
            admissionLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            admissionWaiters.append(continuation)
        }
    }

    private func releaseAdmissionLock() {
        if admissionWaiters.isEmpty {
            admissionLocked = false
        } else {
            admissionWaiters.removeFirst().resume()
        }
    }

    @discardableResult
    private func suspendScheduler() -> UUID {
        let token = UUID()
        schedulerSuspensionTokens.insert(token)
        return token
    }

    private func resumeScheduler(suspension token: UUID, ensureRunning: Bool) {
        guard schedulerSuspensionTokens.remove(token) != nil else { return }
        if ensureRunning {
            schedulerResumeRequested = true
        }
        guard schedulerSuspensionTokens.isEmpty else { return }
        let shouldEnsureRunning = schedulerResumeRequested
        schedulerResumeRequested = false
        if shouldEnsureRunning {
            ensureSchedulerRunning()
        }
    }

    private func acquireExecutionPolicyUpdateLock() async {
        if !executionPolicyUpdateLocked {
            executionPolicyUpdateLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            executionPolicyUpdateWaiters.append(continuation)
        }
    }

    private func releaseExecutionPolicyUpdateLock() {
        if executionPolicyUpdateWaiters.isEmpty {
            executionPolicyUpdateLocked = false
        } else {
            executionPolicyUpdateWaiters.removeFirst().resume()
        }
    }

    /// Internal observability for deterministic scheduler/budget regression
    /// tests. Production callers configure through `updateExecutionPolicy`.
    func isExecutionPolicyUpdateInProgress() -> Bool {
        executionPolicyUpdateInProgress
    }

    /// Internal visibility for regressions that must prove a timed-out detached
    /// AgentLoop cannot lose or duplicate its reservation across policy changes.
    func tokenBudgetSnapshotForTesting() async -> (
        limit: Int?,
        consumed: Int,
        reserved: Int,
        remaining: Int?
    ) {
        await tokenBudgetMeter.snapshot()
    }

    private func recordTerminalPersistenceFailure(task: ScheduledTask, error: Error) async {
        let message = "Task terminal state could not be persisted: \(error.localizedDescription)"
        try? await log.append(.error(ErrorPayload(
            code: "terminal_persistence_failed",
            message: "Task \(task.contract.id.rawValue): \(message)")))
        terminalPersistenceFailures[task.contract.id] = message
        _ = scheduler.releaseClaim(taskID: task.contract.id)
        completeResultWaiters(task.contract.id)
    }

    private func storeScheduledReply(task: ScheduledTask,
                                     result: String?,
                                     report: TaskReportPayload,
                                     error: String?) async {
        let explicitTarget = scheduledReplyTargets.removeValue(forKey: task.contract.id)
        let replyMode = task.contract.replyMode ?? .taskReport
        let replyTarget = explicitTarget ?? (replyMode == .none ? nil : task.contract.issuer)
        let explicitFormat = scheduledReplyFormats.removeValue(forKey: task.contract.id)
        guard let replyTarget else { return }
        let format = explicitFormat ?? (replyMode == .answer ? .answer : .taskReport)
        scheduledReplyResults[task.contract.id] = await deliverScheduledReply(
            format: format,
            from: task.assignee,
            to: replyTarget,
            result: result,
            report: report,
            error: error)
    }

    private func executionDidFinish(_ taskID: TaskID, resumeScheduler: Bool = true) {
        runningExecutions.removeValue(forKey: taskID)
        rootInvocations.removeValue(forKey: taskID)
        cancellationReasons.removeValue(forKey: taskID)
        restoredPendingTaskIDs.remove(taskID)
        if resumeScheduler {
            ensureSchedulerRunning()
            notifyIdleIfNeeded()
        }
    }

    private func notifyIdleIfNeeded() {
        guard scheduler.queuedTasks().isEmpty, runningExecutions.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func completeResultWaiters(_ taskID: TaskID) {
        guard let waiters = resultWaiters.removeValue(forKey: taskID) else { return }
        let value = terminalResult(for: taskID)
        for waiter in waiters { waiter.resume(returning: value) }
    }

    private func terminalResult(for taskID: TaskID) -> String? {
        if let failure = terminalPersistenceFailures[taskID] {
            return "error: \(failure)"
        }
        guard let record = scheduler.record(for: taskID), record.status.isTerminal else { return nil }
        return scheduledReplyResults[taskID]
            ?? record.result
            ?? record.error.map { "error: \($0)" }
            ?? (record.status == .cancelled ? "error: task cancelled" : nil)
    }

    private func consumeDeliveredMessages(for task: ScheduledTask,
                                          messageIDs: Set<MessageID>) async {
        let messages = scheduler.peekMessages(for: task.assignee).filter { messageIDs.contains($0.id) }
        for message in messages {
            let payload = AgentMessageConsumedPayload(
                messageID: message.id,
                agent: task.assignee,
                taskID: task.contract.id,
                metadata: CoworkEventMetadata(
                    taskID: task.contract.id,
                    rootTaskID: task.rootTaskID,
                    parentTaskID: task.parentTaskID,
                    sender: message.sender,
                    recipient: task.assignee,
                    agentID: task.assignee,
                    causalParentID: message.causalParentID,
                    scope: .agent,
                    visibility: .privateAgent))
            do {
                if let messageConsumptionAppender {
                    try await messageConsumptionAppender(payload)
                } else {
                    try await log.append(.agentMessageConsumed(payload))
                }
            } catch {
                continue
            }
            _ = scheduler.acknowledgeMessage(message.id, recipient: task.assignee)
        }
    }

    private func revokeTaskLeases(contract: TaskContract, reason: String) async {
        var events: [Event] = []
        var capabilityToRevoke: (CapabilityLeaseID, CapabilityLease)?
        var workspaceToRevoke: (WorkspaceLeaseID, WorkspaceLease)?
        if let leaseID = contract.capabilityLeaseID,
           let lease = capabilityLeases[leaseID],
           lease.expiresAtTaskCompletion {
            capabilityToRevoke = (leaseID, lease)
            events.append(.capabilityLeaseRevoked(CapabilityLeaseRevokedPayload(
                agent: contract.assignee,
                leaseID: leaseID,
                reason: reason,
                metadata: taskMetadata(contract: contract))))
        }
        if let leaseID = contract.workspaceLeaseID,
           let lease = workspaceLeases[leaseID],
           lease.expiresAtTaskCompletion {
            workspaceToRevoke = (leaseID, lease)
            events.append(.workspaceLeaseRevoked(WorkspaceLeaseRevokedPayload(
                agent: contract.assignee,
                leaseID: leaseID,
                reason: reason,
                metadata: taskMetadata(contract: contract))))
        }
        guard !events.isEmpty else { return }
        do {
            try await appendAdmissionEvents(events)
        } catch {
            // Keeping the leases in memory is the safe failure mode. The task is
            // already terminal, so they cannot authorize another execution, and
            // replay will drop terminal task-scoped leases.
            try? await log.append(.error(ErrorPayload(
                code: "task_lease_revoke_persistence_failed",
                message: "Task \(contract.id.rawValue): \(error.localizedDescription)")))
            return
        }
        if let (leaseID, lease) = capabilityToRevoke {
            capabilityLeaseHistory[leaseID] = lease
            capabilityLeases.removeValue(forKey: leaseID)
        }
        if let (leaseID, lease) = workspaceToRevoke {
            workspaceLeaseHistory[leaseID] = lease
            workspaceLeases.removeValue(forKey: leaseID)
        }
    }

    private func prepareTaskLeaseRenewal(_ original: TaskContract,
                                         assignee: AgentID) async throws -> TaskLeaseRenewal {
        guard registry.agent(assignee) != nil else {
            throw CoworkTaskExecutionError.invalidLease("task assignee @\(assignee.rawValue) is not attached")
        }
        guard let originalCapabilityLeaseID = original.capabilityLeaseID else {
            throw CoworkTaskExecutionError.invalidLease(
                "task \(original.id.rawValue) has no capability lease")
        }
        guard let originalWorkspaceLeaseID = original.workspaceLeaseID else {
            throw CoworkTaskExecutionError.invalidLease(
                "task \(original.id.rawValue) has no workspace lease")
        }

        if defaultCapabilityLeaseIDs[assignee] == originalCapabilityLeaseID,
           defaultWorkspaceLeaseIDs[assignee] == originalWorkspaceLeaseID,
           let capability = capabilityLeases[originalCapabilityLeaseID],
           let workspace = workspaceLeases[originalWorkspaceLeaseID],
           capability.taskID == nil,
           workspace.taskID == nil,
           !capability.expiresAtTaskCompletion,
           !workspace.expiresAtTaskCompletion {
            guard let rootIdentity = workspace.rootIdentity,
                  rootIdentity.matchesCurrentDirectory(rootPath: workspace.rootPath) else {
                throw CoworkTaskExecutionError.invalidLease(
                    "persistent workspace lease root identity is missing or changed")
            }
            return TaskLeaseRenewal(
                contract: original,
                capabilityLease: nil,
                workspaceLease: nil)
        }
        var contract = original
        guard let previousCapability = capabilityLeaseHistory[originalCapabilityLeaseID] else {
            throw CoworkTaskExecutionError.invalidLease(
                "capability lease \(originalCapabilityLeaseID.rawValue) is missing without renewal history")
        }
        guard previousCapability.taskID == original.id,
              previousCapability.expiresAtTaskCompletion else {
            throw CoworkTaskExecutionError.invalidLease(
                "capability lease renewal history is not task-scoped")
        }
        let createdCapabilityLease = CapabilityLease(
            taskID: contract.id,
            tools: previousCapability.tools,
            communication: previousCapability.communication,
            delegation: previousCapability.delegation,
            expiresAtTaskCompletion: true)
        contract.capabilityLeaseID = createdCapabilityLease.id

        guard let previousWorkspace = workspaceLeaseHistory[originalWorkspaceLeaseID] else {
            throw CoworkTaskExecutionError.invalidLease(
                "workspace lease \(originalWorkspaceLeaseID.rawValue) is missing without renewal history")
        }
        guard previousWorkspace.taskID == original.id,
              previousWorkspace.expiresAtTaskCompletion else {
            throw CoworkTaskExecutionError.invalidLease(
                "workspace lease renewal history is not task-scoped")
        }
        guard let previousRootIdentity = previousWorkspace.rootIdentity,
              previousRootIdentity.matchesCurrentDirectory(rootPath: previousWorkspace.rootPath) else {
            throw CoworkTaskExecutionError.invalidLease(
                "workspace lease renewal root identity is missing or changed")
        }
        let createdWorkspaceLease = WorkspaceLease(
            workspaceID: previousWorkspace.workspaceID,
            taskID: contract.id,
            rootPath: previousWorkspace.rootPath,
            rootIdentity: previousRootIdentity,
            access: previousWorkspace.access,
            allowedPathRules: previousWorkspace.allowedPathRules,
            deniedPatterns: previousWorkspace.deniedPatterns,
            expiresAtTaskCompletion: true)
        contract.workspaceLeaseID = createdWorkspaceLease.id
        contract.workspaceID = createdWorkspaceLease.workspaceID
        let metadata = taskMetadata(contract: contract)
        try await appendAdmissionEvents([
            .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: assignee,
                lease: createdCapabilityLease,
                metadata: metadata)),
            .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                agent: assignee,
                lease: createdWorkspaceLease,
                metadata: metadata)),
        ])
        return TaskLeaseRenewal(
            contract: contract,
            capabilityLease: createdCapabilityLease,
            workspaceLease: createdWorkspaceLease)
    }

    private func commitTaskLeaseRenewal(_ renewal: TaskLeaseRenewal) {
        if let lease = renewal.capabilityLease {
            capabilityLeases[lease.id] = lease
        }
        if let lease = renewal.workspaceLease {
            workspaceLeases[lease.id] = lease
        }
    }

    private func refreshConsumedTokenCount() async {
        consumedTokenCount = await log.replay().reduce(into: 0) { total, envelope in
            guard case .turnStats(let payload) = envelope.event else { return }
            total += payload.totalTokens
                ?? ((payload.promptTokens ?? 0) + (payload.completionTokens ?? 0))
        }
    }

    private func deliverScheduledReply(format: ScheduledReplyFormat,
                                       from: AgentID,
                                       to: AgentID,
                                       result: String?,
                                       report: TaskReportPayload,
                                       error: String?) async -> String {
        switch format {
        case .answer:
            let content = result ?? error.map { "error: \($0)" } ?? Self.formattedTaskReport(report)
            if let forwarded = await bus.deliver(from: from, to: to, content: content) {
                return forwarded
            }
            return error.map { "error: \($0)" }
                ?? "delegated task completed, but the result was blocked by the mediator; ask @\(from.rawValue) for a shorter summary"
        case .taskReport:
            let content = Self.formattedTaskReport(report)
            if let forwarded = await bus.deliver(from: from, to: to, content: content) {
                return forwarded
            }
            return "delegated task finished, but the task report was blocked by the mediator; ask @\(from.rawValue) for a shorter summary"
        }
    }

    private func recycleIdleToolSpawnedAgents(reason: String) async {
        let candidates = spawnedAgentOwners.keys.sorted { $0.rawValue < $1.rawValue }
        for agentID in candidates {
            await recycleToolSpawnedAgentIfIdle(agentID, reason: reason)
        }
    }

    private func recycleToolSpawnedAgentIfIdle(_ agentID: AgentID, reason: String) async {
        guard agentID != Self.mainAgentID,
              agentID != Self.automaticPermissionReviewerID,
              spawnedAgentOwners[agentID] != nil,
              registry.agent(agentID) != nil,
              isAgentIdleForRecycle(agentID) else {
            return
        }
        await detach(agentID, reason: reason)
    }

    private func isAgentIdleForRecycle(_ agentID: AgentID) -> Bool {
        guard taskGraph.nodes.values.contains(where: { $0.assignee == agentID }) else {
            return false
        }
        let mailbox = scheduler.mailbox(for: agentID)
        guard mailbox.pendingTasks.isEmpty, mailbox.pendingMessages.isEmpty else {
            return false
        }
        if scheduler.queuedTasks().contains(where: { $0.assignee == agentID || $0.issuer == agentID }) {
            return false
        }
        return !taskGraph.nodes.values.contains { node in
            Self.isActiveTaskStatus(node.status) && (node.assignee == agentID || node.issuer == agentID)
        }
    }

    func awaitSchedulerResult(_ taskID: TaskID) async -> String? {
        if terminalPersistenceFailures[taskID] != nil {
            return terminalResult(for: taskID)
        }
        if let record = scheduler.record(for: taskID), record.status.isTerminal {
            return terminalResult(for: taskID)
        }
        ensureSchedulerRunning()
        return await withCheckedContinuation { continuation in
            resultWaiters[taskID, default: []].append(continuation)
        }
    }

    private func causalMetadata(issuer: AgentID,
                                assignee: AgentID,
                                parentTaskID: TaskID?) -> (rootTaskID: TaskID?, hopCount: Int, visitedAgents: [AgentID], rejected: Bool) {
        guard let parentTaskID,
              let parent = scheduler.record(for: parentTaskID) else {
            return (nil, 1, Self.uniqueAgents([issuer, assignee]), false)
        }
        if parent.visitedAgents.contains(assignee) {
            return (parent.rootTaskID ?? parentTaskID, parent.hopCount + 1, parent.visitedAgents, true)
        }
        var visited = parent.visitedAgents
        visited.append(assignee)
        return (parent.rootTaskID ?? parentTaskID, parent.hopCount + 1, Self.uniqueAgents(visited), false)
    }

    private static func uniqueAgents(_ agents: [AgentID]) -> [AgentID] {
        var seen = Set<AgentID>()
        var result: [AgentID] = []
        for agent in agents where !seen.contains(agent) {
            seen.insert(agent)
            result.append(agent)
        }
        return result
    }

    private static func makeTaskReport(task: ScheduledTask,
                                       status: TaskStatus,
                                       result: String? = nil,
                                       error: String? = nil,
                                       attempt: Int? = nil) -> TaskReportPayload {
        let detail = nonEmptyTrimmed(result).map { truncate($0, maxCharacters: 2_000) }
        let errorText = nonEmptyTrimmed(error).map { truncate($0, maxCharacters: 1_000) }
        let summarySource = detail ?? errorText ?? defaultSummary(status: status, agent: task.assignee)
        return TaskReportPayload(
            taskID: task.contract.id,
            agent: task.assignee,
            status: status,
            objective: task.contract.objective,
            expectedDeliverable: task.contract.expectedDeliverable,
            summary: summaryLine(from: summarySource, status: status),
            detail: detail,
            error: errorText,
            attempt: attempt)
    }

    private static func formattedTaskReport(_ report: TaskReportPayload) -> String {
        var lines: [String] = [
            "Task Report",
            "task: \(report.taskID.rawValue)",
            "status: \(report.status.rawValue)",
            "agent: @\(report.agent.rawValue)",
            "objective: \(report.objective)",
            "expected deliverable: \(report.expectedDeliverable)",
            "summary: \(report.summary)",
        ]
        if let error = report.error {
            lines.append("error: \(error)")
        }
        if let detail = report.detail, detail != report.summary {
            lines.append("detail:")
            lines.append(detail)
        }
        return lines.joined(separator: "\n")
    }

    private static func summaryLine(from text: String, status: TaskStatus) -> String {
        let firstLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return truncate(firstLine ?? defaultSummary(status: status, agent: nil), maxCharacters: 500)
    }

    private static func defaultSummary(status: TaskStatus, agent: AgentID?) -> String {
        let actor = agent.map { " by @\($0.rawValue)" } ?? ""
        switch status {
        case .completed:
            return "Task completed\(actor)."
        case .failed:
            return "Task failed\(actor)."
        case .created, .assigned, .queued, .running, .cancelled:
            return "Task status is \(status.rawValue)\(actor)."
        }
    }

    private static func nonEmptyTrimmed(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func truncate(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let index = text.index(text.startIndex, offsetBy: maxCharacters)
        return String(text[..<index]) + "..."
    }

    private static func compactTaskStates(_ nodes: [TaskNode], limit: Int = 4) -> String {
        let visible = nodes.prefix(limit).map { "\($0.id.rawValue):\($0.status.rawValue)" }
        guard nodes.count > limit else {
            return visible.joined(separator: ",")
        }
        return (visible + ["+\(nodes.count - limit) more"]).joined(separator: ",")
    }

    private static func isActiveTaskStatus(_ status: TaskStatus) -> Bool {
        switch status {
        case .created, .assigned, .queued, .running:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    private static func delegationRejectionMessage(for violation: TaskGraphViolation) -> String {
        switch violation.kind {
        case .selfDelegation:
            return "error: agent cannot delegate to itself"
        case .cycleDetected:
            return "error: delegation cycle rejected"
        case .duplicateTask:
            return violation.existingTaskID.map { "error: duplicate task rejected: \($0.rawValue)" }
                ?? "error: duplicate task rejected"
        case .maxDepthExceeded:
            return "error: task depth limit exceeded"
        case .maxDelegationHopsExceeded:
            return "error: delegation hop limit exceeded"
        case .maxTasksPerRootExceeded:
            return "error: task limit exceeded"
        case .maxActiveAgentsExceeded:
            return "error: active agent limit exceeded"
        case .missingParentTask:
            return "error: parent task not found"
        case .duplicateTaskID:
            return "error: duplicate task id"
        }
    }

    static func toolRegistry(for lease: CapabilityLease) -> ToolRegistry {
        var tools: [any Tool] = []
        if lease.tools.contains(.readWorkspace) {
            tools.append(ReadFileTool())
        }
        if lease.tools.contains(.readPDF) {
            tools.append(ReadPDFTool())
        }
        if lease.tools.contains(.listWorkspace) {
            tools.append(ListFilesTool())
        }
        if lease.tools.contains(.searchWorkspace) {
            tools.append(SearchTextTool())
        }
        if lease.tools.contains(.applyPatch) {
            tools.append(WriteFileTool())
            tools.append(ApplyPatchTool())
        }
        if lease.tools.contains(.editPDF) {
            tools.append(EditPDFPagesTool())
        }
        // Raw run_shell is deliberately not exposed, even when a legacy lease
        // contains `.runShell`: arbitrary shell cannot declare exact touched
        // paths for WorkspaceLease denied-pattern enforcement. The capability
        // remains as a compatibility signal for the read-only Git tools below.
        if lease.tools.contains(.gitControl) || lease.tools.contains(.runShell) {
            tools.append(GitStatusTool())
            tools.append(GitDiffTool())
            tools.append(GitInfoTool())
            tools.append(GitRecentCommitsTool())
            tools.append(GitDiffBaseTool())
        }
        if lease.tools.contains(.gitControl) {
            tools.append(GitStagedDiffTool())
            tools.append(GitBranchTool())
            tools.append(GitCreateBranchTool())
            tools.append(GitStageTool())
            tools.append(GitUnstageTool())
            tools.append(GitCommitTool())
            tools.append(GitApplyPatchCheckTool())
            tools.append(GitApplyPatchTool())
            tools.append(GitStagePatchTool())
            tools.append(GitUnstagePatchTool())
            tools.append(GitRevertPatchTool())
            tools.append(GitWorktreeListTool())
            tools.append(GitWorktreeCreateTool())
            tools.append(GitWorktreeRemoveTool())
        }
        if lease.tools.contains(.gitRemote) {
            tools.append(GitRemotesTool())
            tools.append(GitFetchTool())
            tools.append(GitPullFastForwardTool())
            tools.append(GitPushTool())
            tools.append(GitSwitchBranchTool())
        }
        if lease.tools.contains(.reconstructDocument) {
            tools.append(ReconstructDocumentImageTool())
        }
        if lease.tools.contains(.compileLaTeX) {
            tools.append(CompileLaTeXTool())
        }
        if lease.tools.contains(.generateMedia) {
            tools.append(GenerateImageTool())
        }
        if lease.tools.contains(.browseWeb) {
            tools.append(WebFetchTool())
            tools.append(BrowserDiagnosticsTool())
            tools.append(BrowserProfilesTool())
            tools.append(BrowserProfileDeleteTool())
            tools.append(BrowserHistoryTool())
            tools.append(BrowserNavigateTool())
            tools.append(BrowserSnapshotTool())
            tools.append(BrowserHandoffTool())
            tools.append(BrowserReloadTool())
            tools.append(BrowserBackTool())
            tools.append(BrowserForwardTool())
            tools.append(BrowserClickTool())
            tools.append(BrowserTypeTool())
            tools.append(BrowserSubmitTool())
            tools.append(BrowserSelectOptionTool())
            tools.append(BrowserPressKeyTool())
            tools.append(BrowserScrollTool())
            tools.append(BrowserWaitTool())
            tools.append(BrowserScreenshotTool())
            tools.append(BrowserUploadFileTool())
            tools.append(BrowserDownloadTool())
            tools.append(BrowserDownloadsTool())
            tools.append(BrowserSearchTool())
        }
        let canInitiateCommunication: Bool
        switch lease.communication {
        case .selectedAgents, .taskGroup, .anyAgentInThread:
            canInitiateCommunication = true
        case .none, .replyOnly:
            canInitiateCommunication = false
        }
        let canReply: Bool
        switch lease.communication {
        case .none:
            canReply = false
        case .replyOnly, .selectedAgents, .taskGroup, .anyAgentInThread:
            canReply = true
        }
        let hasDelegationGrant: Bool
        switch lease.delegation {
        case .granted:
            hasDelegationGrant = true
        case .none, .requestOnly:
            hasDelegationGrant = false
        }

        if lease.tools.contains(.requestInformation), canInitiateCommunication {
            tools.append(RequestInformationTool())
        }
        if lease.tools.contains(.delegateTask), hasDelegationGrant {
            tools.append(AskAgentTool())
        }
        if lease.tools.contains(.sendMessage), canInitiateCommunication {
            tools.append(SendMessageTool())
        }
        if lease.tools.contains(.replyMessage), canReply {
            tools.append(ReplyMessageTool())
        }
        if lease.tools.contains(.requestDelegation), lease.delegation != .none {
            tools.append(RequestDelegationTool())
        }
        if lease.tools.contains(.delegateTask), hasDelegationGrant {
            tools.append(DelegateTaskTool())
        }
        if hasDelegationGrant, lease.tools.contains(.attachWorkspace) {
            tools.append(SpawnAgentTool())
        }
        if lease.tools.contains(.delegateTask), hasDelegationGrant {
            tools.append(ListAgentsTool())
            tools.append(RemoveAgentTool())
        }
        return ToolRegistry(tools)
    }

    private static func canCoordinate(_ lease: CapabilityLease) -> Bool {
        guard case .granted = lease.delegation else { return false }
        return lease.tools.contains(.delegateTask)
            || lease.tools.contains(.attachWorkspace)
    }

    private static let defaultWorkerConstraints: [String] = [
        "Complete only the assigned task.",
        "Do not re-run the global task decomposition.",
        "Do not create, remove, or coordinate other agents.",
        "If you need help, report the need to the assigning agent or user.",
    ]

    private static func defaultRoleHint(for assignee: AgentID, objective: String) -> String {
        let name = assignee.rawValue.lowercased()
        let lowerObjective = objective.lowercased()
        if name.contains("macos"), name.contains("counter"), lowerObjective.contains("swift") {
            return "macOS Swift file counter"
        }
        if name.contains("ios"), name.contains("counter"), lowerObjective.contains("swift") {
            return "iOS Swift file counter"
        }
        let parts = assignee.rawValue
            .split { "-_ .".contains($0) }
            .map { displayRoleToken(String($0)) }
        return parts.isEmpty ? "assigned task worker" : parts.joined(separator: " ")
    }

    private static func displayRoleToken(_ token: String) -> String {
        switch token.lowercased() {
        case "macos": return "macOS"
        case "ios": return "iOS"
        case "swift": return "Swift"
        default: return token
        }
    }
}

private struct PreparedDelegatedTask: Sendable {
    var contract: TaskContract
    var capabilityLease: CapabilityLease
    var workspaceLease: WorkspaceLease
}

private struct WorkspaceAttachAssessment: Sendable {
    var canonical: URL?
    var canAskUser: Bool
    var risk: RiskLevel
    var reason: String
}

private func assessWorkspaceAttach(_ url: URL) -> WorkspaceAttachAssessment {
    do {
        let canonical = try PathConfinement.canonicalExistingDirectory(url)
        if isDeniedWorkspaceRoot(canonical) {
            return WorkspaceAttachAssessment(
                canonical: canonical,
                canAskUser: false,
                risk: .high,
                reason: "workspace path is too broad or system-sensitive: \(canonical.path)")
        }
        return WorkspaceAttachAssessment(
            canonical: canonical,
            canAskUser: true,
            risk: .medium,
            reason: "attach new agent workspace: \(canonical.path)")
    } catch {
        return WorkspaceAttachAssessment(
            canonical: nil,
            canAskUser: false,
            risk: .high,
            reason: error.localizedDescription)
    }
}

private func isDeniedWorkspaceRoot(_ url: URL) -> Bool {
    let path = url.path
    let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
    if path == "/" || path == "/Users" || path == "/var" || path == "/private/var" || path == home {
        return true
    }
    let deniedPrefixes = [
        "/System", "/Library", "/bin", "/sbin", "/usr", "/etc", "/private/etc",
        "/var/db", "/var/root", "/private/var/db", "/private/var/root",
        home + "/.ssh", home + "/Library/Keychains",
    ]
    return deniedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
}

private func attachArgs(agent: Agent,
                        canonicalPath: String,
                        admissionTaskID: TaskID,
                        capabilityLease: CapabilityLease,
                        workspaceLease: WorkspaceLease) -> String {
    let object: [String: Any] = [
        "agent": agent.name.rawValue,
        "path": canonicalPath,
        "model": agent.model.rawValue,
        "profile": agent.profile.rawValue,
        "coordinationDepth": agent.coordinationDepth,
        "canCoordinate": agent.coordinationDepth > 0,
        "admissionTaskID": admissionTaskID.rawValue,
        "capabilityLeaseID": capabilityLease.id.rawValue,
        "workspaceLeaseID": workspaceLease.id.rawValue,
        "workspaceAccess": workspaceLease.access.rawValue,
        "capabilities": capabilityLease.tools.map(\.rawValue).sorted(),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}

/// Per-agent messenger handed to each agent's loop; binds `from` and routes
/// through the orchestrator (and thus the mediated bus).
struct BusMessenger: AgentMessenger {
    let from: AgentID
    let currentTaskID: TaskID?
    let orchestrator: Orchestrator

    func ask(to agent: String, question: String) async -> String {
        await orchestrator.ask(from: from, to: agent, question: question, parentTaskID: currentTaskID)
    }

    func sendMessage(to agent: String, content: String) async -> String {
        await orchestrator.sendMessage(from: from, to: agent, content: content, taskID: currentTaskID)
    }

    func requestInformation(to agent: String, question: String) async -> String {
        await orchestrator.requestInformation(from: from, to: agent, question: question, taskID: currentTaskID)
    }

    func replyMessage(to agent: String, content: String, inReplyTo: String?) async -> String {
        await orchestrator.replyMessage(from: from, to: agent, content: content, inReplyTo: inReplyTo, taskID: currentTaskID)
    }

    func requestDelegation(objective: String, reason: String) async -> String {
        await orchestrator.requestDelegation(from: from, objective: objective, reason: reason, parentTaskID: currentTaskID)
    }

    func delegateTask(to agent: String,
                      objective: String,
                      roleHint: String?,
                      expectedDeliverable: String?) async -> String {
        await orchestrator.delegateTask(
            from: from,
            to: agent,
            objective: objective,
            roleHint: roleHint,
            expectedDeliverable: expectedDeliverable,
            parentTaskID: currentTaskID)
    }
}

/// Coordinator seam handed to each agent's loop; routes lifecycle calls through
/// the orchestrator actor (and thus its registry + event log). `defaultModel` is
/// the spawning agent's model, used when the tool call omits one.
struct OrchestratorManager: AgentManager {
    let orchestrator: Orchestrator
    let requester: AgentID
    let currentTaskID: TaskID?
    let defaultModel: String

    func spawnAgent(name: String, path: String, model: String?, canCoordinate: Bool) async -> String {
        await orchestrator.spawnFromTool(
            requestedBy: requester,
            currentTaskID: currentTaskID,
            name: name,
            path: path,
            model: model ?? defaultModel,
            canCoordinate: canCoordinate)
    }
    func listAgents() async -> String { await orchestrator.listForTool() }
    func removeAgent(name: String) async -> String {
        await orchestrator.removeFromTool(
            requestedBy: requester,
            currentTaskID: currentTaskID,
            name: name)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
