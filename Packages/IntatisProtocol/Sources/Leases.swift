import Foundation
import IntatisCore

public enum ToolCapability: String, Codable, Sendable, Hashable {
    case readWorkspace = "read_workspace"
    case listWorkspace = "list_workspace"
    case searchWorkspace = "search_workspace"
    case runShell = "run_shell"
    case proposePatch = "propose_patch"
    case applyPatch = "apply_patch"
    case sendMessage = "send_message"
    case requestInformation = "request_information"
    case replyMessage = "reply_message"
    case requestDelegation = "request_delegation"
    case delegateTask = "delegate_task"
    case attachWorkspace = "attach_workspace"
}

public struct DelegationBudget: Codable, Sendable, Hashable {
    public var maxTasks: Int
    public var maxDepth: Int

    public init(maxTasks: Int, maxDepth: Int) {
        self.maxTasks = maxTasks
        self.maxDepth = maxDepth
    }
}

public enum DelegationGrant: Codable, Sendable, Hashable {
    case none
    case requestOnly
    case granted(DelegationBudget)
}

public enum CommunicationGrant: Codable, Sendable, Hashable {
    case none
    case replyOnly
    case selectedAgents([AgentID])
    case taskGroup(TaskGroupID)
    case anyAgentInThread
}

public struct CapabilityLease: Codable, Sendable, Hashable {
    public var id: CapabilityLeaseID
    public var taskID: TaskID?
    public var tools: Set<ToolCapability>
    public var communication: CommunicationGrant
    public var delegation: DelegationGrant
    public var expiresAtTaskCompletion: Bool

    public init(id: CapabilityLeaseID = CapabilityLeaseID.new(),
                taskID: TaskID? = nil,
                tools: Set<ToolCapability>,
                communication: CommunicationGrant = .none,
                delegation: DelegationGrant = .none,
                expiresAtTaskCompletion: Bool = true) {
        self.id = id
        self.taskID = taskID
        self.tools = tools
        self.communication = communication
        self.delegation = delegation
        self.expiresAtTaskCompletion = expiresAtTaskCompletion
    }

    public static func worker(taskID: TaskID? = nil) -> CapabilityLease {
        CapabilityLease(
            taskID: taskID,
            tools: [
                .readWorkspace,
                .listWorkspace,
                .searchWorkspace,
                .replyMessage,
                .requestDelegation,
            ],
            communication: .replyOnly,
            delegation: .requestOnly)
    }

    public static func coordinator(taskID: TaskID? = nil,
                                   budget: DelegationBudget = DelegationBudget(maxTasks: 8, maxDepth: 1)) -> CapabilityLease {
        CapabilityLease(
            taskID: taskID,
            tools: [
                .readWorkspace,
                .listWorkspace,
                .searchWorkspace,
                .runShell,
                .proposePatch,
                .applyPatch,
                .sendMessage,
                .requestInformation,
                .replyMessage,
                .requestDelegation,
                .delegateTask,
                .attachWorkspace,
            ],
            communication: .anyAgentInThread,
            delegation: .granted(budget),
            expiresAtTaskCompletion: taskID != nil)
    }
}

public enum WorkspaceAccess: String, Codable, Sendable, Hashable {
    case readOnly = "read_only"
    case readWrite = "read_write"
}

public struct PathRule: Codable, Sendable, Hashable {
    public var pattern: String

    public init(pattern: String) {
        self.pattern = pattern
    }
}

public struct WorkspaceLease: Codable, Sendable, Hashable {
    public var id: WorkspaceLeaseID
    public var workspaceID: WorkspaceID
    public var rootPath: String
    public var access: WorkspaceAccess
    public var allowedPathRules: [PathRule]
    public var deniedPatterns: [String]

    public init(id: WorkspaceLeaseID = WorkspaceLeaseID.new(),
                workspaceID: WorkspaceID = WorkspaceID.new(),
                rootPath: String,
                access: WorkspaceAccess,
                allowedPathRules: [PathRule] = [PathRule(pattern: ".")],
                deniedPatterns: [String] = [
                    ".env",
                    ".ssh",
                    "Library/Keychains",
                    "**/secret*",
                    "**/*token*",
                    "**/*key*",
                ]) {
        self.id = id
        self.workspaceID = workspaceID
        self.rootPath = rootPath
        self.access = access
        self.allowedPathRules = allowedPathRules
        self.deniedPatterns = deniedPatterns
    }
}
