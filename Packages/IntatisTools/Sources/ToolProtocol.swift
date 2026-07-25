import Foundation
import CryptoKit
import IntatisCore
import IntatisProtocol

/// Raw JSON arguments for a tool call, with a typed decode helper.
public struct ToolArgs: Sendable {
    public let raw: String
    public init(raw: String) { self.raw = raw }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard let data = raw.data(using: .utf8) else {
            throw IntatisError.decoding("tool args are not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw IntatisError.decoding("tool args: \(error.localizedDescription)")
        }
    }
}

/// The result of executing a tool. `diff`/`changedFiles` are set by mutating tools.
public struct ToolObservation: Equatable, Sendable {
    public var text: String
    public var truncated: Bool
    public var diff: String?
    public var changedFiles: [String]?
    public init(text: String, truncated: Bool = false, diff: String? = nil, changedFiles: [String]? = nil) {
        self.text = text
        self.truncated = truncated
        self.diff = diff
        self.changedFiles = changedFiles
    }
}

/// Static metadata the permission gate reads. Tools are dumb executors; they do
/// not decide whether they may run (ARCHITECTURE.md §1.2 principle E).
public struct ToolDescriptor: Sendable {
    public let name: String
    public let description: String
    public let sideEffect: SideEffect
    public let parameters: JSONValue   // JSON-Schema object
    public init(name: String, description: String, sideEffect: SideEffect, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.sideEffect = sideEffect
        self.parameters = parameters
    }
}

// MARK: - Injected services (keep tools testable + backend-swappable)

public struct ShellResult: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int
    public init(stdout: String, stderr: String, exitCode: Int) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// A managed workspace sandbox rejected process startup before the target
/// executable was entered. Only the sandbox runner may manufacture this
/// error from an attributable wrapper diagnostic. Generic command failures,
/// including an unqualified `EPERM`, must remain ordinary `ShellResult`s.
///
/// Because this error proves the target process did not start, AgentKernel may
/// durably settle the prepared execution as `not_started` without retrying it.
public struct WorkspaceSandboxDeniedError: Error, Equatable, Sendable, LocalizedError {
    public let reason: String

    init(reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

public struct GitPatchResult: Equatable, Sendable {
    public var text: String
    public var changedFiles: [String]
    public var diff: String
    public init(text: String, changedFiles: [String], diff: String) {
        self.text = text
        self.changedFiles = changedFiles
        self.diff = diff
    }
}

public protocol ShellRunner: Sendable {
    func run(_ command: String, cwd: URL) async throws -> ShellResult
}

/// Immutable host identity for a terminal process. The model receives only the
/// opaque session ID; it cannot choose or widen this owner binding.
public struct TerminalSessionOwner: Equatable, Sendable {
    public let sessionID: SessionID
    public let agent: AgentID
    public let taskID: TaskID?
    public let taskAttempt: Int?
    public let workspaceRootIdentity: WorkspaceRootIdentity

    public init(sessionID: SessionID,
                agent: AgentID,
                taskID: TaskID?,
                taskAttempt: Int? = nil,
                workspaceRootIdentity: WorkspaceRootIdentity) {
        self.sessionID = sessionID
        self.agent = agent
        self.taskID = taskID
        self.taskAttempt = taskAttempt
        self.workspaceRootIdentity = workspaceRootIdentity
    }
}

public struct TerminalExecRequest: Equatable, Sendable {
    public let command: String
    public let workingDirectory: String?
    public let shellPath: String
    public let loginShell: Bool
    public let usesTTY: Bool
    public let allowsNetwork: Bool
    public let yieldMilliseconds: Int
    public let timeoutMilliseconds: Int

    public init(command: String,
                workingDirectory: String? = nil,
                shellPath: String = "/bin/zsh",
                loginShell: Bool = true,
                usesTTY: Bool = false,
                allowsNetwork: Bool = false,
                yieldMilliseconds: Int = 10_000,
                timeoutMilliseconds: Int = 300_000) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.shellPath = shellPath
        self.loginShell = loginShell
        self.usesTTY = usesTTY
        self.allowsNetwork = allowsNetwork
        self.yieldMilliseconds = yieldMilliseconds
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

public struct TerminalInteractionRequest: Equatable, Sendable {
    public let characters: String?
    public let closeInput: Bool
    public let terminate: Bool
    public let yieldMilliseconds: Int

    public init(characters: String? = nil,
                closeInput: Bool = false,
                terminate: Bool = false,
                yieldMilliseconds: Int = 1_000) {
        self.characters = characters
        self.closeInput = closeInput
        self.terminate = terminate
        self.yieldMilliseconds = yieldMilliseconds
    }
}

public struct TerminalSessionObservation: Equatable, Sendable {
    public let sessionID: String?
    public let isRunning: Bool
    public let stdout: String
    public let stderr: String
    public let exitCode: Int?
    public let timedOut: Bool
    public let truncated: Bool

    public init(sessionID: String?,
                isRunning: Bool,
                stdout: String,
                stderr: String,
                exitCode: Int?,
                timedOut: Bool = false,
                truncated: Bool = false) {
        self.sessionID = sessionID
        self.isRunning = isRunning
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.truncated = truncated
    }
}

/// Session-owned terminal backend. A Code or Cowork runtime retains one
/// instance across AgentLoop turns and drains it during runtime shutdown.
public protocol TerminalSessionManaging: Sendable {
    func execute(_ request: TerminalExecRequest,
                 owner: TerminalSessionOwner,
                 workspaceLease: WorkspaceLease) async throws -> TerminalSessionObservation
    func interact(sessionID: String,
                  request: TerminalInteractionRequest,
                  owner: TerminalSessionOwner) async throws -> TerminalSessionObservation
    func terminate(taskID: TaskID, reason: String) async
    func terminateAll(reason: String) async
    func shutdown(reason: String) async
}

/// Git backend. v0.2 dev uses `ProcessGitService` (spawns git); the App Store
/// sandbox build swaps in a libgit2-backed implementation (ARCHITECTURE.md §9.1).
public protocol GitService: Sendable {
    func status(workspace: URL) async throws -> String   // porcelain v1
    func diff(workspace: URL) async throws -> String      // unified diff
    func stagedDiff(workspace: URL) async throws -> String // unified diff for index
    func repositoryInfo(workspace: URL) async throws -> String
    func recentCommits(limit: Int, workspace: URL) async throws -> String
    func diffAgainst(base: String, workspace: URL) async throws -> String
    func branchInfo(workspace: URL) async throws -> String
    func createBranch(name: String, startPoint: String?, workspace: URL) async throws -> String
    func stage(paths: [String], workspace: URL) async throws -> String
    func unstage(paths: [String], workspace: URL) async throws -> String
    func commit(message: String, workspace: URL) async throws -> String
    func applyPatch(diff: String, reverse: Bool, checkOnly: Bool, cached: Bool, workspace: URL) async throws -> GitPatchResult
    func worktrees(workspace: URL) async throws -> String
    func createWorktree(name: String, startPoint: String?, branch: String?, workspace: URL) async throws -> String
    func removeWorktree(name: String, force: Bool, workspace: URL) async throws -> String
    func remotes(workspace: URL) async throws -> String
    func fetch(remote: String, branch: String?, prune: Bool, workspace: URL) async throws -> String
    func pullFastForward(remote: String, branch: String, workspace: URL) async throws -> String
    func push(remote: String, branch: String, setUpstream: Bool, workspace: URL) async throws -> String
    func switchBranch(name: String, workspace: URL) async throws -> String
}

/// Provider-backed or local-model image generation service injected by the app
/// or CLI. The tool layer owns path validation; the service owns model/provider
/// resolution and writing generated bytes to the requested workspace path.
public protocol ImageGenerationToolService: Sendable {
    func generateImage(prompt: String,
                       size: String,
                       count: Int,
                       outputPath: String,
                       workspaceRoot: URL) async throws -> ToolObservation
}

/// Seam for agent-to-agent messaging (v0.3). Cowork provides an implementation
/// bound to the asking agent; the `ask_agent` tool routes through it so all
/// cross-agent traffic goes through the mediated Message Bus (ARCHITECTURE.md §7).
public enum AgentMessengerReply: Equatable, Sendable {
    case success(String)
    case failure(String)
}

public protocol AgentMessenger: Sendable {
    func ask(to agent: String, question: String) async -> AgentMessengerReply
    func sendMessage(to agent: String, content: String) async -> String
    func requestInformation(to agent: String, question: String) async -> String
    func replyMessage(to agent: String, content: String, inReplyTo: String?) async -> String
    func requestDelegation(objective: String, reason: String) async -> String
    func delegateTask(authorization: ResolvedToolAuthorization,
                      to agent: String?,
                      workTaskID: WorkTaskID?,
                      objective: String?,
                      roleHint: String?,
                      expectedDeliverable: String?) async -> String
}

/// Seam for agent lifecycle management (v0.3 coordinator). Cowork provides an
/// implementation bound to the orchestrator so a coordinator agent can create,
/// list, and remove sub-agents through tools. Like `AgentMessenger`, the real
/// work happens in the orchestrator/registry — tools are just thin executors.
public protocol AgentManager: Sendable {
    func spawnAgent(authorization: ResolvedToolAuthorization?,
                    name: String,
                    path: String,
                    model: String?,
                    inferenceProfileID: String?,
                    requestedAccess: WorkspaceAccess,
                    canCoordinate: Bool) async -> String
    func listAgents() async -> String
    func listInferenceProfiles() async -> String
    func removeAgent(name: String) async -> String
}

public struct ToolContext: Sendable {
    public let workspaceRoot: URL
    /// Effective task/workspace lease. Direct tool hosts that omit it receive
    /// the standard read-write lease (including default secret deny patterns),
    /// so process-backed tools never silently run with a wider policy.
    public let workspaceLease: WorkspaceLease
    /// Raw, model-authored shell commands. The default runner is workspace and
    /// network confined.
    public let shell: ShellRunner
    /// Shell backend for structured Swift tools (browser/document wrappers)
    /// whose arguments and paths have already been validated by the tool. This
    /// runner is workspace-confined and network-denied.
    public let structuredShell: ShellRunner
    /// Dedicated workspace-confined structured runner for tools whose
    /// descriptor and permission request explicitly declare network access.
    /// Keeping this separate prevents a document/LaTeX wrapper from inheriting
    /// browser network authority merely because both are process-backed.
    public let networkStructuredShell: ShellRunner
    /// Long-lived, runtime-owned terminal service used by `exec_command` and
    /// `write_stdin`. It is optional so isolated tool hosts must opt in rather
    /// than silently creating a process manager with the wrong lifetime.
    public let terminal: (any TerminalSessionManaging)?
    public let git: GitService
    public let messenger: AgentMessenger?
    public let agentManager: AgentManager?
    public let workTaskManager: WorkTaskManager?
    public let goalManager: GoalManager?
    public let imageGenerator: ImageGenerationToolService?
    /// Host service bound to the session that owns this exact invocation.
    /// The model never supplies a session identifier.
    public let sessionNaming: SessionNamingService?
    /// Durable executor operation identifier used to make session renames
    /// idempotent across retries and reconciliation.
    public let executionID: String?
    /// Immutable host authorization for the exact executor invocation. Tools
    /// that need a host-resolved target (for example delegate_task(to:auto))
    /// must consume this snapshot instead of resolving a different target from
    /// model-authored arguments after review.
    public let authorization: ResolvedToolAuthorization?
    public init(workspaceRoot: URL,
                workspaceLease: WorkspaceLease? = nil,
                shell: ShellRunner = ProcessShellRunner(),
                structuredShell: ShellRunner? = nil,
                networkStructuredShell: ShellRunner? = nil,
                terminal: (any TerminalSessionManaging)? = nil,
                git: GitService = ProcessGitService(),
                messenger: AgentMessenger? = nil,
                agentManager: AgentManager? = nil,
                workTaskManager: WorkTaskManager? = nil,
                goalManager: GoalManager? = nil,
                imageGenerator: ImageGenerationToolService? = nil,
                sessionNaming: SessionNamingService? = nil,
                executionID: String? = nil,
                authorization: ResolvedToolAuthorization? = nil) {
        let effectiveLease = workspaceLease ?? WorkspaceLease(
            rootPath: workspaceRoot.resolvingSymlinksInPath().standardizedFileURL.path,
            access: .readWrite)
        self.workspaceRoot = workspaceRoot
        self.workspaceLease = effectiveLease
        if let processShell = shell as? ProcessShellRunner {
            self.shell = processShell.scoped(to: effectiveLease)
        } else {
            self.shell = shell
        }
        let resolvedStructuredShell: ShellRunner
        if let structuredShell {
            if let processShell = structuredShell as? StructuredProcessShellRunner {
                resolvedStructuredShell = processShell.scoped(to: effectiveLease)
            } else if let processShell = structuredShell as? ProcessShellRunner {
                resolvedStructuredShell = processShell.scoped(to: effectiveLease)
            } else {
                resolvedStructuredShell = structuredShell
            }
        } else if shell is ProcessShellRunner {
            resolvedStructuredShell = StructuredProcessShellRunner(workspaceLease: effectiveLease)
        } else {
            // Preserve injected fake runners in unit tests and custom hosts.
            resolvedStructuredShell = shell
        }
        self.structuredShell = resolvedStructuredShell
        if let networkStructuredShell {
            if let processShell = networkStructuredShell as? StructuredProcessShellRunner {
                self.networkStructuredShell = processShell.scoped(to: effectiveLease)
            } else if let processShell = networkStructuredShell as? ProcessShellRunner {
                self.networkStructuredShell = processShell.scoped(to: effectiveLease)
            } else {
                self.networkStructuredShell = networkStructuredShell
            }
        } else if shell is ProcessShellRunner, structuredShell == nil {
            self.networkStructuredShell = StructuredProcessShellRunner(
                allowsNetwork: true,
                workspaceLease: effectiveLease)
        } else {
            // Preserve the pre-existing single fake-runner injection behavior.
            self.networkStructuredShell = resolvedStructuredShell
        }
        self.terminal = terminal
        if let processGit = git as? ProcessGitService {
            self.git = processGit.scoped(to: effectiveLease)
        } else {
            self.git = git
        }
        self.messenger = messenger
        self.agentManager = agentManager
        self.workTaskManager = workTaskManager
        self.goalManager = goalManager
        self.imageGenerator = imageGenerator
        self.sessionNaming = sessionNaming
        self.executionID = executionID
        self.authorization = authorization
    }
}

// MARK: - Tool

public protocol Tool: Sendable {
    static var descriptor: ToolDescriptor { get }
    /// Stable host-facing permission family. This can deliberately differ
    /// from the exact operation in `PermissionIntent.action`; for example,
    /// `write_file` and `apply_patch` are two operations in one
    /// `filesystem.edit` capability family.
    static var canonicalPermission: String? { get }
    func touchedPaths(_ args: ToolArgs) -> [String]
    func risksNetwork(_ args: ToolArgs) -> Bool
    /// Build the structured authorization input for this exact invocation.
    /// `workspaceRoot` is context only; it is not an approval or a replacement
    /// for CapabilityLease / WorkspaceLease enforcement in AgentKernel.
    func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent
    /// Bounded semantic fields for the reviewer. The returned value is
    /// redacted by `PermissionActionPreview` and never substitutes for the raw
    /// argument digest used by host validation.
    func permissionActionPreview(_ args: ToolArgs) -> PermissionActionPreview?
    /// Secret-safe material used to bind the in-memory invocation to its
    /// immutable authorization snapshot. Most tools use the normalized raw
    /// JSON. Tools that accept secret-like interactive bytes may instead
    /// return a structural identity that deliberately omits those bytes.
    func authorizationArgumentIdentity(_ args: ToolArgs) -> String
    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation
}

public extension Tool {
    static var canonicalPermission: String? { nil }
    func touchedPaths(_ args: ToolArgs) -> [String] { [] }
    func risksNetwork(_ args: ToolArgs) -> Bool { false }
    func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let descriptor = Self.descriptor
        var intent = PermissionIntent.derived(
            toolName: descriptor.name,
            sideEffect: descriptor.sideEffect,
            touchedPaths: touchedPaths(args),
            risksNetwork: risksNetwork(args))
        guard let object = Self.permissionArgumentObject(args) else { return intent }

        if descriptor.name == "run_shell",
           case .string(let command)? = object["command"] {
            intent.resources.append(PermissionResource(kind: .command, value: command))
        }
        if descriptor.name.hasPrefix("git_") {
            intent.resources.append(PermissionResource(kind: .git, value: workspaceRoot.path))
            for key in ["remote", "branch", "base", "name", "startPoint"] {
                if case .string(let value)? = object[key] {
                    intent.metadata[key] = .string(value)
                }
            }
        }
        if descriptor.name.hasPrefix("browser_") || descriptor.name == "web_fetch" {
            for key in ["url", "startURL"] {
                if case .string(let value)? = object[key] {
                    intent.resources.append(PermissionResource(kind: .url, value: value))
                }
            }
            if case .string(let query)? = object["query"] {
                intent.metadata["query"] = .string(query)
            }
        }
        return intent
    }

    func permissionActionPreview(_ args: ToolArgs) -> PermissionActionPreview? {
        guard let object = Self.permissionArgumentObject(args) else { return nil }
        let semanticKeys = [
            "command", "content", "diff", "question", "objective", "reason",
            "role_hint", "roleHint", "expected_deliverable", "expectedDeliverable",
            "prompt", "query", "url", "startURL", "host", "port", "server",
            "tool", "to", "name", "path", "model", "work_task_id",
        ]
        var fields: [String: String] = [:]
        for key in semanticKeys {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let string):
                fields[key] = string
            case .number(let number):
                fields[key] = String(number)
            case .bool(let value):
                fields[key] = String(value)
            case .null, .array, .object:
                continue
            }
        }
        guard !fields.isEmpty else { return nil }
        return PermissionActionPreview(kind: Self.descriptor.name, fields: fields)
    }

    func authorizationArgumentIdentity(_ args: ToolArgs) -> String { args.raw }

    private static func permissionArgumentObject(_ args: ToolArgs) -> [String: JSONValue]? {
        guard let data = args.raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = decoded else { return nil }
        return object
    }
}

/// One authoritative model-visible tool entry. The concrete tool supplies both
/// its schema and executor; `grantingCapabilities` records which lease
/// capability aliases may expose that concrete entry in a scoped registry.
public struct ToolRegistration: Sendable {
    public let tool: any Tool
    public let grantingCapabilities: Set<ToolCapability>
    public let requiredCommunication: ToolCommunicationRequirement
    public let requiredDelegation: ToolDelegationRequirement

    public init(tool: any Tool,
                grantingCapabilities: Set<ToolCapability> = [],
                requiredCommunication: ToolCommunicationRequirement = .none,
                requiredDelegation: ToolDelegationRequirement = .none) {
        self.tool = tool
        self.grantingCapabilities = grantingCapabilities
        self.requiredCommunication = requiredCommunication
        self.requiredDelegation = requiredDelegation
    }
}

public enum ToolRegistryAuthorizationError: Error, Equatable, Sendable, LocalizedError {
    case unregisteredTool(String)
    case duplicateRegistration(String)
    case missingCapabilityLease(tool: String, required: [ToolCapability])
    case capabilityNotGranted(tool: String, required: [ToolCapability])
    case authorizationRegistryMismatch(expected: String, actual: String)
    case authorizationSchemaMismatch(expected: Int, actual: Int)
    case authorizationToolMismatch(expected: String, actual: String)
    case authorizationConcreteToolMismatch(expected: String, actual: String)
    case authorizationDescriptorMismatch(tool: String)
    case authorizationArgumentsMismatch(tool: String)
    case authorizationIntentMismatch(tool: String)
    case authorizationCapabilityMismatch(tool: String)
    case authorizationLeaseMismatch(tool: String)
    case authorizationInvocationMismatch(tool: String)
    case communicationNotGranted(tool: String, required: ToolCommunicationRequirement)
    case delegationNotGranted(tool: String, required: ToolDelegationRequirement)
    case leaseTaskMismatch(tool: String)

    public var errorDescription: String? {
        switch self {
        case .unregisteredTool(let tool):
            return "tool is not registered: \(tool)"
        case .duplicateRegistration(let tool):
            return "tool registration is ambiguous because the name is duplicated: \(tool)"
        case .missingCapabilityLease(let tool, let required):
            return "tool \(tool) requires an active capability lease granting one of: \(Self.names(required))"
        case .capabilityNotGranted(let tool, let required):
            return "tool \(tool) is not granted by the active capability lease; expected one of: \(Self.names(required))"
        case .authorizationRegistryMismatch(let expected, let actual):
            return "authorization registry mismatch; expected \(expected), got \(actual)"
        case .authorizationSchemaMismatch(let expected, let actual):
            return "authorization schema mismatch; expected \(expected), got \(actual)"
        case .authorizationToolMismatch(let expected, let actual):
            return "authorization tool mismatch; expected \(expected), got \(actual)"
        case .authorizationConcreteToolMismatch(let expected, let actual):
            return "authorization concrete tool mismatch; expected \(expected), got \(actual)"
        case .authorizationDescriptorMismatch(let tool):
            return "authorization descriptor fingerprint no longer matches registered tool \(tool)"
        case .authorizationArgumentsMismatch(let tool):
            return "authorization arguments no longer match the reviewed invocation for \(tool)"
        case .authorizationIntentMismatch(let tool):
            return "authorization intent no longer matches the reviewed invocation for \(tool)"
        case .authorizationCapabilityMismatch(let tool):
            return "authorization capability mapping no longer matches registered tool \(tool)"
        case .authorizationLeaseMismatch(let tool):
            return "authorization lease identity no longer matches the reviewed invocation for \(tool)"
        case .authorizationInvocationMismatch(let tool):
            return "authorization invocation identity no longer matches the current call for \(tool)"
        case .communicationNotGranted(let tool, let required):
            return "tool \(tool) requires communication grant \(required.rawValue)"
        case .delegationNotGranted(let tool, let required):
            return "tool \(tool) requires delegation grant \(required.rawValue)"
        case .leaseTaskMismatch(let tool):
            return "tool \(tool) is not authorized for the current task binding"
        }
    }

    private static func names(_ capabilities: [ToolCapability]) -> String {
        capabilities.map(\.rawValue).sorted().joined(separator: ", ")
    }
}

public struct ToolRegistry: Sendable {
    public let registryVersion: String
    private let registrations: [String: ToolRegistration]
    private let conflictedNames: Set<String>

    public init(_ tools: [any Tool], registryVersion: String = "intatis.standard.v1") {
        self.init(
            registrations: tools.map { ToolRegistration(tool: $0) },
            registryVersion: registryVersion)
    }

    public init(registrations: [ToolRegistration],
                registryVersion: String) {
        self.init(
            registrations: registrations,
            registryVersion: registryVersion,
            inheritedConflicts: [])
    }

    private init(registrations: [ToolRegistration],
                 registryVersion: String,
                 inheritedConflicts: Set<String>) {
        self.registryVersion = registryVersion
        var resolved: [String: ToolRegistration] = [:]
        var conflicts = inheritedConflicts
        for registration in registrations {
            let name = type(of: registration.tool).descriptor.name
            guard !conflicts.contains(name) else { continue }
            if resolved.removeValue(forKey: name) != nil {
                conflicts.insert(name)
            } else {
                resolved[name] = registration
            }
        }
        self.registrations = resolved
        self.conflictedNames = conflicts
    }

    public func tool(named name: String) -> (any Tool)? {
        guard !conflictedNames.contains(name) else { return nil }
        return registrations[name]?.tool
    }
    public func registration(named name: String) -> ToolRegistration? {
        guard !conflictedNames.contains(name) else { return nil }
        return registrations[name]
    }
    public func all() -> [any Tool] { registrations.values.map(\.tool) }
    public func descriptors() -> [ToolDescriptor] { all().map { type(of: $0).descriptor } }

    /// Resolves immutable host facts for this exact invocation. Scoped Cowork
    /// registries fail closed when their capability alias no longer belongs to
    /// the active lease; ordinary unscoped registries retain legacy behavior.
    public func resolveAuthorization(toolName: String,
                                     intent: PermissionIntent,
                                     risksNetwork: Bool,
                                     normalizedArguments: String,
                                     authorizationID: String? = nil,
                                     invocation: ToolAuthorizationInvocationContext = .init(),
                                     capabilityLease: CapabilityLease?,
                                     workspaceLease: WorkspaceLease?,
                                     targetAgentInferenceBinding: AgentInferenceBinding? = nil) throws -> ResolvedToolAuthorization {
        guard let registration = registrations[toolName] else {
            if conflictedNames.contains(toolName) {
                throw ToolRegistryAuthorizationError.duplicateRegistration(toolName)
            }
            throw ToolRegistryAuthorizationError.unregisteredTool(toolName)
        }
        let descriptor = type(of: registration.tool).descriptor
        let granting = registration.grantingCapabilities.sorted { $0.rawValue < $1.rawValue }
        let requiresLease = !granting.isEmpty
            || registration.requiredCommunication != .none
            || registration.requiredDelegation != .none
        let membership: ToolAuthorizationMembership
        if !requiresLease {
            membership = .notRequired
        } else {
            guard let capabilityLease else {
                throw ToolRegistryAuthorizationError.missingCapabilityLease(
                    tool: toolName,
                    required: granting)
            }
            guard granting.isEmpty
                    || !registration.grantingCapabilities.isDisjoint(with: capabilityLease.tools) else {
                throw ToolRegistryAuthorizationError.capabilityNotGranted(
                    tool: toolName,
                    required: granting)
            }
            guard Self.communication(
                capabilityLease.communication,
                satisfies: registration.requiredCommunication) else {
                throw ToolRegistryAuthorizationError.communicationNotGranted(
                    tool: toolName,
                    required: registration.requiredCommunication)
            }
            guard Self.delegation(
                capabilityLease.delegation,
                satisfies: registration.requiredDelegation) else {
                throw ToolRegistryAuthorizationError.delegationNotGranted(
                    tool: toolName,
                    required: registration.requiredDelegation)
            }
            if let leaseTaskID = capabilityLease.taskID,
               leaseTaskID != invocation.taskID {
                throw ToolRegistryAuthorizationError.leaseTaskMismatch(tool: toolName)
            }
            membership = .granted
        }
        if let workspaceTaskID = workspaceLease?.taskID,
           workspaceTaskID != invocation.taskID {
            throw ToolRegistryAuthorizationError.leaseTaskMismatch(tool: toolName)
        }
        let authorizationArguments = registration.tool.authorizationArgumentIdentity(
            ToolArgs(raw: normalizedArguments))
        return ResolvedToolAuthorization(
            authorizationID: authorizationID ?? IDGen.random(prefix: "tool-authorization"),
            registryVersion: registryVersion,
            concreteToolID: "\(registryVersion)/\(descriptor.name)",
            descriptorFingerprint: Self.descriptorFingerprint(descriptor),
            toolName: descriptor.name,
            canonicalAction: intent.action,
            canonicalPermission: type(of: registration.tool).canonicalPermission ?? intent.action,
            actionPreview: registration.tool.permissionActionPreview(
                ToolArgs(raw: normalizedArguments)),
            requiredCapabilities: granting,
            membership: membership,
            capabilityLeaseID: capabilityLease?.id,
            capabilityTaskID: capabilityLease?.taskID,
            workspaceLeaseID: workspaceLease?.id,
            workspaceAccess: workspaceLease?.access,
            workspaceRootIdentity: workspaceLease?.rootIdentity,
            invocation: invocation,
            normalizedArgumentsDigest: Self.sha256(Data(authorizationArguments.utf8)),
            normalizedArgumentsCharacterCount: authorizationArguments.count,
            intent: intent,
            sideEffect: descriptor.sideEffect,
            risksNetwork: risksNetwork,
            replayPolicy: intent.replayPolicy,
            requiredCommunication: registration.requiredCommunication,
            requiredDelegation: registration.requiredDelegation,
            capabilityLeaseFingerprint: capabilityLease.map(Self.authorizationFingerprint),
            workspaceID: workspaceLease?.workspaceID,
            workspaceTaskID: workspaceLease?.taskID,
            workspaceRootPath: workspaceLease?.rootPath,
            workspaceLeaseFingerprint: workspaceLease.map(Self.authorizationFingerprint),
            targetAgentInferenceBinding: targetAgentInferenceBinding)
    }

    /// Rechecks the immutable authorization identity against the exact
    /// registry entry and invocation that are about to execute. The registry
    /// is currently a value type, but keeping this check at the executor
    /// boundary prevents a future mutable registry or decoded/forwarded
    /// snapshot from silently widening an approval.
    public func validateAuthorizationSnapshot(
        _ authorization: ResolvedToolAuthorization,
        toolName: String,
        normalizedArguments: String,
        intent: PermissionIntent,
        risksNetwork: Bool,
        invocation: ToolAuthorizationInvocationContext? = nil,
        capabilityLease: CapabilityLease? = nil,
        workspaceLease: WorkspaceLease? = nil
    ) throws {
        guard authorization.schemaVersion == 1 else {
            throw ToolRegistryAuthorizationError.authorizationSchemaMismatch(
                expected: 1,
                actual: authorization.schemaVersion)
        }
        guard authorization.registryVersion == registryVersion else {
            throw ToolRegistryAuthorizationError.authorizationRegistryMismatch(
                expected: registryVersion,
                actual: authorization.registryVersion)
        }
        guard authorization.toolName == toolName else {
            throw ToolRegistryAuthorizationError.authorizationToolMismatch(
                expected: toolName,
                actual: authorization.toolName)
        }
        let expectedConcreteToolID = "\(registryVersion)/\(toolName)"
        guard authorization.concreteToolID == expectedConcreteToolID else {
            throw ToolRegistryAuthorizationError.authorizationConcreteToolMismatch(
                expected: expectedConcreteToolID,
                actual: authorization.concreteToolID)
        }
        guard let registration = registrations[toolName] else {
            if conflictedNames.contains(toolName) {
                throw ToolRegistryAuthorizationError.duplicateRegistration(toolName)
            }
            throw ToolRegistryAuthorizationError.unregisteredTool(toolName)
        }
        let descriptor = type(of: registration.tool).descriptor
        guard authorization.descriptorFingerprint == Self.descriptorFingerprint(descriptor),
              authorization.sideEffect == descriptor.sideEffect else {
            throw ToolRegistryAuthorizationError.authorizationDescriptorMismatch(tool: toolName)
        }
        let authorizationArguments = registration.tool.authorizationArgumentIdentity(
            ToolArgs(raw: normalizedArguments))
        guard authorization.normalizedArgumentsDigest == Self.sha256(Data(authorizationArguments.utf8)),
              authorization.normalizedArgumentsCharacterCount == authorizationArguments.count else {
            throw ToolRegistryAuthorizationError.authorizationArgumentsMismatch(tool: toolName)
        }
        let expectedCanonicalPermission = type(of: registration.tool).canonicalPermission ?? intent.action
        let expectedPreview = registration.tool.permissionActionPreview(
            ToolArgs(raw: normalizedArguments))
        guard authorization.intent == intent,
              authorization.canonicalAction == intent.action,
              authorization.canonicalPermission == expectedCanonicalPermission,
              authorization.actionPreview == expectedPreview,
              authorization.risksNetwork == risksNetwork,
              authorization.replayPolicy == intent.replayPolicy else {
            throw ToolRegistryAuthorizationError.authorizationIntentMismatch(tool: toolName)
        }
        let required = registration.grantingCapabilities.sorted { $0.rawValue < $1.rawValue }
        guard authorization.requiredCapabilities == required,
              authorization.requiredCommunication == registration.requiredCommunication,
              authorization.requiredDelegation == registration.requiredDelegation else {
            throw ToolRegistryAuthorizationError.authorizationCapabilityMismatch(tool: toolName)
        }
        let requiresLease = !required.isEmpty
            || registration.requiredCommunication != .none
            || registration.requiredDelegation != .none
        guard authorization.membership == (requiresLease ? .granted : .notRequired) else {
            throw ToolRegistryAuthorizationError.authorizationCapabilityMismatch(tool: toolName)
        }
        let pinsCapabilityLease = authorization.capabilityLeaseID != nil
            || authorization.capabilityTaskID != nil
            || authorization.capabilityLeaseFingerprint != nil
        if requiresLease || pinsCapabilityLease, capabilityLease == nil {
            throw ToolRegistryAuthorizationError.authorizationLeaseMismatch(tool: toolName)
        }
        if let capabilityLease {
            guard authorization.capabilityLeaseID == capabilityLease.id,
                  authorization.capabilityTaskID == capabilityLease.taskID,
                  authorization.capabilityLeaseFingerprint == Self.authorizationFingerprint(capabilityLease),
                  (required.isEmpty || !registration.grantingCapabilities.isDisjoint(with: capabilityLease.tools)),
                  Self.communication(capabilityLease.communication,
                                     satisfies: registration.requiredCommunication),
                  Self.delegation(capabilityLease.delegation,
                                  satisfies: registration.requiredDelegation) else {
                throw ToolRegistryAuthorizationError.authorizationLeaseMismatch(tool: toolName)
            }
        }
        let pinsWorkspaceLease = authorization.workspaceLeaseID != nil
            || authorization.workspaceID != nil
            || authorization.workspaceTaskID != nil
            || authorization.workspaceRootPath != nil
            || authorization.workspaceAccess != nil
            || authorization.workspaceRootIdentity != nil
            || authorization.workspaceLeaseFingerprint != nil
        if pinsWorkspaceLease, workspaceLease == nil {
            throw ToolRegistryAuthorizationError.authorizationLeaseMismatch(tool: toolName)
        }
        if let workspaceLease {
            guard authorization.workspaceLeaseID == workspaceLease.id,
                  authorization.workspaceID == workspaceLease.workspaceID,
                  authorization.workspaceTaskID == workspaceLease.taskID,
                  authorization.workspaceRootPath == workspaceLease.rootPath,
                  authorization.workspaceAccess == workspaceLease.access,
                  authorization.workspaceRootIdentity == workspaceLease.rootIdentity,
                  authorization.workspaceLeaseFingerprint == Self.authorizationFingerprint(workspaceLease) else {
                throw ToolRegistryAuthorizationError.authorizationLeaseMismatch(tool: toolName)
            }
        }
        let pinsInvocation = authorization.sessionID != nil
            || authorization.agent != nil
            || authorization.taskID != nil
            || authorization.rootTaskID != nil
            || authorization.parentTaskID != nil
            || authorization.attempt != nil
            || authorization.toolCallID != nil
            || authorization.taskObjective != nil
        if pinsInvocation, invocation == nil {
            throw ToolRegistryAuthorizationError.authorizationInvocationMismatch(tool: toolName)
        }
        if let invocation {
            guard authorization.sessionID == invocation.sessionID,
                  authorization.agent == invocation.agent,
                  authorization.taskID == invocation.taskID,
                  authorization.rootTaskID == invocation.rootTaskID,
                  authorization.parentTaskID == invocation.parentTaskID,
                  authorization.attempt == invocation.attempt,
                  authorization.toolCallID == invocation.toolCallID,
                  authorization.taskObjective == invocation.taskObjective else {
                throw ToolRegistryAuthorizationError.authorizationInvocationMismatch(tool: toolName)
            }
        }
    }

    public static func authorizationFingerprint(_ lease: CapabilityLease) -> String {
        let fields = [
            "capability-lease-v1",
            lease.id.rawValue,
            lease.taskID?.rawValue ?? "",
            lease.tools.map(\.rawValue).sorted().joined(separator: "\u{1f}"),
            communicationFingerprint(lease.communication),
            delegationFingerprint(lease.delegation),
            lease.expiresAtTaskCompletion ? "1" : "0",
        ]
        return sha256(Data(framed(fields).utf8))
    }

    public static func authorizationFingerprint(_ lease: WorkspaceLease) -> String {
        let identity = lease.rootIdentity.map {
            framed([
                $0.canonicalPath,
                String($0.deviceID),
                String($0.fileID),
            ])
        } ?? ""
        let fields = [
            "workspace-lease-v1",
            lease.id.rawValue,
            lease.workspaceID.rawValue,
            lease.taskID?.rawValue ?? "",
            lease.rootPath,
            identity,
            lease.access.rawValue,
            lease.allowedPathRules.map(\.pattern).sorted().joined(separator: "\u{1f}"),
            lease.deniedPatterns.sorted().joined(separator: "\u{1f}"),
            lease.expiresAtTaskCompletion ? "1" : "0",
        ]
        return sha256(Data(framed(fields).utf8))
    }

    /// Stable secret-free identity used to bind a reviewed control-plane
    /// action to the exact target inference route. Raw endpoint/options and
    /// credential references are intentionally absent from this protocol type.
    public static func authorizationFingerprint(_ binding: AgentInferenceBinding) -> String {
        let fields = [
            binding.inferenceProfileID.rawValue,
            binding.inferenceProfileRevision.rawValue,
            binding.inferenceConnectionID.rawValue,
            binding.inferenceConnectionRevision.rawValue,
            binding.modelID.rawValue,
            binding.variantID ?? "",
            binding.trustDomain ?? "",
            binding.egressClassification ?? "",
            binding.safeRouteLabel ?? "",
            binding.immutableDefinitionFingerprint,
        ]
        return sha256(Data(framed(fields).utf8))
    }

    public static func authorizationDigest(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    public static func capabilityLease(
        _ lease: CapabilityLease,
        grants capabilities: [ToolCapability],
        communication requirement: ToolCommunicationRequirement,
        delegation delegationRequirement: ToolDelegationRequirement
    ) -> Bool {
        let capabilityMatch = capabilities.isEmpty
            || !Set(capabilities).isDisjoint(with: lease.tools)
        return capabilityMatch
            && communication(lease.communication, satisfies: requirement)
            && delegation(lease.delegation, satisfies: delegationRequirement)
    }

    private static func framed(_ fields: [String]) -> String {
        fields.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static func communicationFingerprint(_ grant: CommunicationGrant) -> String {
        switch grant {
        case .none:
            return "none"
        case .replyOnly:
            return "reply-only"
        case .selectedAgents(let agents):
            return "selected:" + agents.map(\.rawValue).sorted().joined(separator: "\u{1f}")
        case .taskGroup(let group):
            return "task-group:" + group.rawValue
        case .anyAgentInThread:
            return "any-agent-in-thread"
        }
    }

    private static func delegationFingerprint(_ grant: DelegationGrant) -> String {
        switch grant {
        case .none:
            return "none"
        case .requestOnly:
            return "request-only"
        case .granted(let budget):
            return "granted:\(budget.maxTasks):\(budget.maxDepth)"
        }
    }

    private static func communication(
        _ grant: CommunicationGrant,
        satisfies requirement: ToolCommunicationRequirement
    ) -> Bool {
        switch requirement {
        case .none:
            return true
        case .initiate:
            switch grant {
            case .selectedAgents, .taskGroup, .anyAgentInThread:
                return true
            case .none, .replyOnly:
                return false
            }
        case .reply:
            if case .none = grant { return false }
            return true
        }
    }

    private static func delegation(
        _ grant: DelegationGrant,
        satisfies requirement: ToolDelegationRequirement
    ) -> Bool {
        switch requirement {
        case .none:
            return true
        case .requestOrGranted:
            if case .none = grant { return false }
            return true
        case .granted:
            if case .granted = grant { return true }
            return false
        }
    }

    private static func descriptorFingerprint(_ descriptor: ToolDescriptor) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let schema = (try? encoder.encode(descriptor.parameters)) ?? Data()
        var material = Data(descriptor.name.utf8)
        material.append(0)
        material.append(Data(descriptor.description.utf8))
        material.append(0)
        material.append(Data(descriptor.sideEffect.rawValue.utf8))
        material.append(0)
        material.append(schema)
        return sha256(material)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A new registry with extra tools added (e.g. Cowork's `ask_agent`).
    public func adding(_ extra: [any Tool]) -> ToolRegistry {
        ToolRegistry(
            registrations: Array(registrations.values)
                + extra.map { ToolRegistration(tool: $0) },
            registryVersion: registryVersion,
            inheritedConflicts: conflictedNames)
    }

    /// The production read/write/Git/document/browser tool set. Raw `run_shell`
    /// stays implemented for isolated tests/future helper processes but is not
    /// model-exposed because arbitrary commands cannot declare exact touched
    /// paths for WorkspaceLease denied-pattern enforcement.
    public static func standard(includesTerminal: Bool = false) -> ToolRegistry {
        var tools: [any Tool] = [
            ReadFileTool(), ListFilesTool(), SearchTextTool(), WriteFileTool(),
            ApplyPatchTool(), GitStatusTool(), GitDiffTool(),
            GitStagedDiffTool(), GitInfoTool(), GitRecentCommitsTool(),
            GitDiffBaseTool(), GitBranchTool(), GitCreateBranchTool(),
            GitStageTool(), GitUnstageTool(), GitCommitTool(),
            GitApplyPatchCheckTool(), GitApplyPatchTool(), GitStagePatchTool(),
            GitUnstagePatchTool(), GitRevertPatchTool(), GitWorktreeListTool(),
            GitWorktreeCreateTool(), GitWorktreeRemoveTool(),
            GitRemotesTool(), GitFetchTool(), GitPullFastForwardTool(),
            GitPushTool(), GitSwitchBranchTool(),
            ReadPDFTool(), EditPDFPagesTool(), ReconstructDocumentImageTool(),
            CompileLaTeXTool(), GenerateImageTool(),
            WebFetchTool(), BrowserDiagnosticsTool(), BrowserProfilesTool(), BrowserProfileDeleteTool(), BrowserHistoryTool(),
            BrowserNavigateTool(), BrowserSnapshotTool(), BrowserHandoffTool(), BrowserClickTool(),
            BrowserReloadTool(), BrowserBackTool(), BrowserForwardTool(),
            BrowserTypeTool(), BrowserSubmitTool(), BrowserSelectOptionTool(),
            BrowserPressKeyTool(), BrowserScrollTool(), BrowserWaitTool(), BrowserScreenshotTool(),
            BrowserUploadFileTool(), BrowserDownloadTool(), BrowserDownloadsTool(),
            BrowserSearchTool(), RenameSessionTool(),
        ]
        if includesTerminal {
            tools.append(ExecCommandTool())
            tools.append(WriteStdinTool())
        }
        return ToolRegistry(tools)
    }
}

// MARK: - Small JSON-Schema helpers

enum Schema {
    static let string = JSONValue.object(["type": .string("string")])
    static let nonEmptyString = boundedString(minLength: 1)
    static let integer = JSONValue.object(["type": .string("integer")])
    static let boolean = JSONValue.object(["type": .string("boolean")])

    static func boundedString(minLength: Int? = nil, maxLength: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string")]
        if let minLength { schema["minLength"] = .number(Double(minLength)) }
        if let maxLength { schema["maxLength"] = .number(Double(maxLength)) }
        return .object(schema)
    }

    static func boundedInteger(minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("integer")]
        if let minimum { schema["minimum"] = .number(Double(minimum)) }
        if let maximum { schema["maximum"] = .number(Double(maximum)) }
        return .object(schema)
    }

    static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }
}
