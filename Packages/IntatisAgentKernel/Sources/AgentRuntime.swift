import Foundation
import IntatisConversation
import IntatisCore
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisTools

/// Optional durable scope for one AgentLoop turn. Cowork hosts can supply a
/// scope explicitly for control-plane runs; ordinary task executions derive
/// missing invocation/agent identifiers inside AgentLoop.
public struct AgentExecutionScope: Equatable, Sendable {
    public var goalID: GoalID?
    public var continuationRunID: ContinuationRunID?
    public var workTaskID: WorkTaskID?
    public var invocationTaskID: TaskID?
    public var agentID: AgentID?

    public init(goalID: GoalID? = nil,
                continuationRunID: ContinuationRunID? = nil,
                workTaskID: WorkTaskID? = nil,
                invocationTaskID: TaskID? = nil,
                agentID: AgentID? = nil) {
        self.goalID = goalID
        self.continuationRunID = continuationRunID
        self.workTaskID = workTaskID
        self.invocationTaskID = invocationTaskID
        self.agentID = agentID
    }
}

/// Shared headless execution unit used by visible Code sessions and every
/// Cowork agent. UI/ViewModels own presentation; this type owns the common
/// request/tool/permission configuration that must not drift between modes.
public struct AgentRuntime: Sendable {
    public let environment: RuntimeEnvironmentManifest
    public let registry: ToolRegistry
    public let engine: PermissionEngine
    public let allowsShell: Bool
    public let reasoningEffort: ReasoningEffort?
    public let includeUsage: Bool
    public let maxIterations: Int

    public init(environment: RuntimeEnvironmentManifest,
                registry: ToolRegistry,
                engine: PermissionEngine = PermissionEngine(),
                allowsShell: Bool,
                reasoningEffort: ReasoningEffort? = nil,
                includeUsage: Bool = false,
                maxIterations: Int = 50) {
        self.environment = environment
        self.registry = registry
        self.engine = engine
        self.allowsShell = allowsShell
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage
        self.maxIterations = max(1, maxIterations)
    }

    public static func code(registry: ToolRegistry = .standard(),
                            allowsShell: Bool,
                            reasoningEffort: ReasoningEffort? = nil,
                            includeUsage: Bool = false,
                            maxIterations: Int = 50) -> AgentRuntime {
        AgentRuntime(
            environment: .code,
            registry: registry,
            allowsShell: allowsShell,
            reasoningEffort: reasoningEffort,
            includeUsage: includeUsage,
            maxIterations: maxIterations)
    }

    public static func cowork(registry: ToolRegistry,
                              engine: PermissionEngine,
                              allowsShell: Bool,
                              reasoningEffort: ReasoningEffort? = nil,
                              includeUsage: Bool = false,
                              maxIterations: Int = 50) -> AgentRuntime {
        AgentRuntime(
            environment: .cowork,
            registry: registry,
            engine: engine,
            allowsShell: allowsShell,
            reasoningEffort: reasoningEffort,
            includeUsage: includeUsage,
            maxIterations: maxIterations)
    }

    public func makeLoop(log: EventLog,
                         provider: ToolCallingProvider,
                         responder: PermissionResponder,
                         agent: Agent,
                         context: ContextBuilder? = nil,
                         shell: ShellRunner = ProcessShellRunner(),
                         terminal: (any TerminalSessionManaging)? = nil,
                         git: GitService = ProcessGitService(),
                         messenger: AgentMessenger? = nil,
                         agentManager: AgentManager? = nil,
                         workTaskManager: WorkTaskManager? = nil,
                         goalManager: GoalManager? = nil,
                         imageGenerator: ImageGenerationToolService? = nil,
                         sessionNaming: SessionNamingService? = nil,
                         capabilityLease: CapabilityLease? = nil,
                         workspaceLease: WorkspaceLease? = nil,
                         rootTaskID: TaskID? = nil,
                         taskAttempt: Int? = nil,
                         executionScope: AgentExecutionScope? = nil,
                         tokenBudgetMeter: AgentTokenBudgetMeter? = nil,
                         authorizationPreparer: ToolAuthorizationPreparer? = nil,
                         authorizationRevalidator: ToolAuthorizationRevalidator? = nil) -> AgentLoop {
        let supplied = context ?? ContextBuilder()
        let runtimeContext = ContextBuilder(
            systemPrompt: supplied.systemPrompt,
            taskContract: supplied.taskContract,
            contextBundle: supplied.contextBundle,
            runtimeEnvironment: environment,
            conversationHistoryPolicy: supplied.conversationHistoryPolicy)
        return AgentLoop(
            log: log,
            provider: provider,
            registry: registry,
            engine: engine,
            responder: responder,
            agent: agent,
            context: runtimeContext,
            allowsShell: allowsShell,
            shell: shell,
            terminal: terminal,
            git: git,
            messenger: messenger,
            agentManager: agentManager,
            workTaskManager: workTaskManager,
            goalManager: goalManager,
            imageGenerator: imageGenerator,
            sessionNaming: sessionNaming,
            reasoningEffort: reasoningEffort,
            includeUsage: includeUsage,
            maxIterations: maxIterations,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease,
            rootTaskID: rootTaskID,
            taskAttempt: taskAttempt,
            executionScope: executionScope,
            tokenBudgetMeter: tokenBudgetMeter,
            authorizationPreparer: authorizationPreparer,
            authorizationRevalidator: authorizationRevalidator)
    }
}
