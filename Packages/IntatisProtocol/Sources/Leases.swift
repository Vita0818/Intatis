import Foundation
import IntatisCore

public enum ToolCapability: String, Codable, Sendable, Hashable {
    case readWorkspace = "read_workspace"
    case listWorkspace = "list_workspace"
    case searchWorkspace = "search_workspace"
    case searchKnowledge = "search_knowledge"
    case buildKnowledge = "build_knowledge"
    case runShell = "run_shell"
    case gitControl = "git_control"
    case gitRemote = "git_remote"
    case proposePatch = "propose_patch"
    case applyPatch = "apply_patch"
    case readPDF = "read_pdf"
    case readDOCX = "read_docx"
    case readPPTX = "read_pptx"
    case readXLSX = "read_xlsx"
    case readHTML = "read_html"
    case readEPUB = "read_epub"
    case documentOCR = "document_ocr"
    case documentRender = "document_render"
    case documentExportPDF = "document_export_pdf"
    case documentWrite = "document_write"
    // Legacy capabilities. Fresh leases must not issue them. Cowork may map
    // `documentRead` to the exact replacement readers when replaying an old
    // default lease; the other cases remain decode-only.
    case documentRead = "document_read"
    case readDocument = "read_document"
    case editPDF = "edit_pdf"
    case reconstructDocument = "reconstruct_document"
    case compileLaTeX = "compile_latex"
    case generateMedia = "generate_media"
    case browseWeb = "browse_web"
    /// Provider-hosted model search. This is intentionally independent from
    /// browser profiles, URL fetching, and local/MCP search implementations.
    case hostedWebSearch = "hosted_web_search"
    case sendMessage = "send_message"
    case requestInformation = "request_information"
    case replyMessage = "reply_message"
    case delegateTask = "delegate_task"
    case attachWorkspace = "attach_workspace"
    case readWorkTasks = "read_work_tasks"
    case updateBoundWorkTask = "update_bound_work_task"
    case manageWorkTasks = "manage_work_tasks"
    case readGoal = "read_goal"
    case submitGoalVerdict = "submit_goal_verdict"
    case renameSession = "rename_session"
    case controlRun = "control_run"
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
    /// Exact external-MCP authority. Legacy leases and all standard
    /// worker/coordinator factories intentionally start with no grants.
    public var mcpGrants: [MCPGrant]

    public init(id: CapabilityLeaseID = CapabilityLeaseID.new(),
                taskID: TaskID? = nil,
                tools: Set<ToolCapability>,
                communication: CommunicationGrant = .none,
                delegation: DelegationGrant = .none,
                expiresAtTaskCompletion: Bool = true,
                mcpGrants: [MCPGrant] = []) {
        self.id = id
        self.taskID = taskID
        self.tools = tools
        self.communication = communication
        self.delegation = delegation
        self.expiresAtTaskCompletion = expiresAtTaskCompletion
        self.mcpGrants = mcpGrants
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case taskID
        case tools
        case communication
        case delegation
        case expiresAtTaskCompletion
        case mcpGrants
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CapabilityLeaseID.self, forKey: .id)
        taskID = try container.decodeIfPresent(TaskID.self, forKey: .taskID)
        tools = try container.decode(Set<ToolCapability>.self, forKey: .tools)
        communication = try container.decode(CommunicationGrant.self, forKey: .communication)
        delegation = try container.decode(DelegationGrant.self, forKey: .delegation)
        expiresAtTaskCompletion =
            try container.decodeIfPresent(Bool.self, forKey: .expiresAtTaskCompletion) ?? true
        mcpGrants = try container.decodeIfPresent([MCPGrant].self, forKey: .mcpGrants) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(taskID, forKey: .taskID)
        try container.encode(tools, forKey: .tools)
        try container.encode(communication, forKey: .communication)
        try container.encode(delegation, forKey: .delegation)
        try container.encode(expiresAtTaskCompletion, forKey: .expiresAtTaskCompletion)
        try container.encode(mcpGrants, forKey: .mcpGrants)
    }

    public static func worker(taskID: TaskID? = nil,
                              workspaceAccess: WorkspaceAccess = .readOnly) -> CapabilityLease {
        var tools: Set<ToolCapability> = [
            .readWorkspace,
            .listWorkspace,
            .searchWorkspace,
            .readPDF,
            .readDOCX,
            .readPPTX,
            .readXLSX,
            .readHTML,
            .readEPUB,
            .documentOCR,
            .requestInformation,
            .replyMessage,
            .readWorkTasks,
            .updateBoundWorkTask,
            .readGoal,
        ]
        if workspaceAccess == .readWrite {
            tools.formUnion([
                .runShell,
                .gitControl,
                .gitRemote,
                .applyPatch,
                .documentRender,
                .documentExportPDF,
                .documentWrite,
                .compileLaTeX,
                .generateMedia,
                .browseWeb,
                .hostedWebSearch,
            ])
        }
        return CapabilityLease(
            taskID: taskID,
            tools: tools,
            communication: .replyOnly,
            delegation: .none)
    }

    public static func coordinator(taskID: TaskID? = nil,
                                   budget: DelegationBudget = DelegationBudget(maxTasks: 8, maxDepth: 1),
                                   workspaceAccess: WorkspaceAccess = .readWrite) -> CapabilityLease {
        var tools = worker(taskID: taskID, workspaceAccess: workspaceAccess).tools
        tools.formUnion([
            .sendMessage,
            .requestInformation,
            .replyMessage,
            .delegateTask,
            .attachWorkspace,
            .manageWorkTasks,
        ])
        return CapabilityLease(
            taskID: taskID,
            tools: tools,
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

/// Stable identity of the directory that was reviewed when a workspace lease
/// was created. A path string alone is not an authority boundary: an owner of
/// the parent directory can rename the reviewed directory and replace it with
/// a symlink or a different directory at the same path. The canonical path plus
/// filesystem device/inode tuple lets every execution reject that swap.
public struct WorkspaceRootIdentity: Codable, Sendable, Hashable {
    public var canonicalPath: String
    public var deviceID: UInt64
    public var fileID: UInt64

    public init(canonicalPath: String, deviceID: UInt64, fileID: UInt64) {
        self.canonicalPath = canonicalPath
        self.deviceID = deviceID
        self.fileID = fileID
    }

    public static func capture(rootPath: String) -> WorkspaceRootIdentity? {
        let expanded = URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath)
        let canonical = expanded.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: canonical.path,
            isDirectory: &isDirectory),
            isDirectory.boolValue,
            let attributes = try? FileManager.default.attributesOfItem(atPath: canonical.path),
            let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        return WorkspaceRootIdentity(
            canonicalPath: canonical.path,
            deviceID: device,
            fileID: file)
    }

    public func matchesCurrentDirectory(rootPath: String) -> Bool {
        Self.capture(rootPath: rootPath) == self
    }
}

public struct WorkspaceLease: Codable, Sendable, Hashable {
    /// Host-owned Knowledge publication components are never ordinary
    /// workspace files. This floor is re-applied at executor boundaries so a
    /// legacy or explicitly decoded lease cannot grant file, Git, document,
    /// browser, or managed-terminal mutation authority over a published
    /// snapshot, pointer, or coordination record.
    public static let mandatoryManagedStoreDeniedPatterns: [String] = [
        ".intatis-rag-store.json",
        ".intatis-rag-snapshots",
        ".intatis-rag-host",
    ]

    /// Sensitive path floor for a model-facing general-purpose terminal. A
    /// caller may add narrower denied patterns to a lease, but the terminal
    /// execution boundary must always union this complete list back in so an
    /// old or explicitly empty lease cannot remove the credential boundary.
    public static let mandatoryTerminalDeniedPatterns: [String] = [
        "**/.env*",
        ".netrc",
        ".pgpass",
        ".npmrc",
        ".pypirc",
        "id_rsa",
        "id_dsa",
        "id_ecdsa",
        "id_ed25519",
        "credentials",
        ".ssh",
        ".aws",
        ".gnupg",
        ".gpg",
        "keychains",
        "**/secrets/**",
        "**/*secret*",
        "**/*token*",
        "**/*key*",
        "**/*credential*",
        "**/*keychain*",
        "**/*certificate*",
        "**/*cert*",
        "**/*.pem",
        "**/*.key",
        "**/*.p12",
        "**/*.pfx",
        "**/*.keystore",
        "**/*.jks",
        "**/*.asc",
        "**/.config/gh/**",
        "**/.config/opencode/**",
        "**/.config/intatis/**",
        "**/.local/share/opencode/**",
        "**/.local/share/intatis/**",
        "**/.git/config",
        "**/.git/config.worktree",
        "Library/Keychains",
    ] + mandatoryManagedStoreDeniedPatterns

    /// New leases persist the same floor for clear previews and replay. The
    /// executor still unions `mandatoryTerminalDeniedPatterns` independently,
    /// because durable data is not itself an enforcement boundary.
    public static let defaultDeniedPatterns = mandatoryTerminalDeniedPatterns

    public var id: WorkspaceLeaseID
    public var workspaceID: WorkspaceID
    public var taskID: TaskID?
    public var rootPath: String
    public var rootIdentity: WorkspaceRootIdentity?
    public var access: WorkspaceAccess
    public var allowedPathRules: [PathRule]
    public var deniedPatterns: [String]
    public var expiresAtTaskCompletion: Bool

    public init(id: WorkspaceLeaseID = WorkspaceLeaseID.new(),
                workspaceID: WorkspaceID = WorkspaceID.new(),
                taskID: TaskID? = nil,
                rootPath: String,
                rootIdentity: WorkspaceRootIdentity? = nil,
                access: WorkspaceAccess,
                allowedPathRules: [PathRule] = [PathRule(pattern: ".")],
                deniedPatterns: [String] = WorkspaceLease.defaultDeniedPatterns,
                expiresAtTaskCompletion: Bool = false) {
        self.id = id
        self.workspaceID = workspaceID
        self.taskID = taskID
        self.rootPath = rootPath
        self.rootIdentity = rootIdentity ?? WorkspaceRootIdentity.capture(rootPath: rootPath)
        self.access = access
        self.allowedPathRules = allowedPathRules
        self.deniedPatterns = deniedPatterns
        self.expiresAtTaskCompletion = expiresAtTaskCompletion
    }

    private enum CodingKeys: String, CodingKey {
        case id, workspaceID, taskID, rootPath, rootIdentity, access, allowedPathRules, deniedPatterns
        case expiresAtTaskCompletion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(WorkspaceLeaseID.self, forKey: .id)
        workspaceID = try container.decode(WorkspaceID.self, forKey: .workspaceID)
        taskID = try container.decodeIfPresent(TaskID.self, forKey: .taskID)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        rootIdentity = try container.decodeIfPresent(WorkspaceRootIdentity.self, forKey: .rootIdentity)
        access = try container.decode(WorkspaceAccess.self, forKey: .access)
        allowedPathRules = try container.decode([PathRule].self, forKey: .allowedPathRules)
        deniedPatterns = try container.decode([String].self, forKey: .deniedPatterns)
        expiresAtTaskCompletion = try container.decodeIfPresent(Bool.self, forKey: .expiresAtTaskCompletion) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encodeIfPresent(taskID, forKey: .taskID)
        try container.encode(rootPath, forKey: .rootPath)
        try container.encodeIfPresent(rootIdentity, forKey: .rootIdentity)
        try container.encode(access, forKey: .access)
        try container.encode(allowedPathRules, forKey: .allowedPathRules)
        try container.encode(deniedPatterns, forKey: .deniedPatterns)
        try container.encode(expiresAtTaskCompletion, forKey: .expiresAtTaskCompletion)
    }
}
