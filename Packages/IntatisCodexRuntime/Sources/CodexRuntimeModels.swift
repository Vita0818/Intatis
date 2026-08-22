import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders

public enum CodexRuntimeMode: String, Codable, Equatable, Sendable {
    case code
    case cowork

    var developerInstructions: String {
        switch self {
        case .code:
            return "You are the coding agent for an Intatis Code workspace. Work directly in the current workspace, use the runtime tools when needed, and report concrete results to the user."
        case .cowork:
            return "You are @main for an Intatis Cowork workspace. Own the user request end to end and use Codex collaboration tools when delegation materially helps. Child agents must remain scoped to this workspace and report back through the runtime."
        }
    }

    var baseInstructions: String {
        "You are Codex, the coding agent embedded in Intatis. Collaborate with the user until the requested workspace task is genuinely handled. Use the runtime's tools and approval system directly, preserve existing user work, verify changes in proportion to risk, and report concrete outcomes."
    }
}

public enum CodexRuntimeApprovalReviewer: String, Codable, Equatable, Sendable {
    case user
    case automatic = "auto_review"
}

public struct CodexRuntimeConfiguration: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let sessionID: SessionID
    public let mode: CodexRuntimeMode
    public let workspaceURL: URL
    public let runtimeRootURL: URL
    public let route: ResponsesRuntimeRoute
    public let approvalReviewer: CodexRuntimeApprovalReviewer
    public let reasoningEffort: String?
    public let executableOverride: URL?
    public let allowsThreadCreation: Bool

    public init(
        sessionID: SessionID,
        mode: CodexRuntimeMode,
        workspaceURL: URL,
        runtimeRootURL: URL,
        route: ResponsesRuntimeRoute,
        approvalReviewer: CodexRuntimeApprovalReviewer = .automatic,
        reasoningEffort: String? = nil,
        executableOverride: URL? = nil,
        allowsThreadCreation: Bool = true
    ) {
        self.sessionID = sessionID
        self.mode = mode
        self.workspaceURL = workspaceURL
        self.runtimeRootURL = runtimeRootURL
        self.route = route
        self.approvalReviewer = approvalReviewer
        self.reasoningEffort = reasoningEffort
        self.executableOverride = executableOverride
        self.allowsThreadCreation = allowsThreadCreation
    }

    public var description: String {
        "CodexRuntimeConfiguration(session: <configured>, mode: \(mode.rawValue), workspace: <configured>, route: \(route), approvalReviewer: \(approvalReviewer.rawValue))"
    }

    public var debugDescription: String { description }
}

public struct CodexRuntimeIdentity: Codable, Equatable, Sendable {
    public let threadID: String
    public let runtimeVersion: String
    public let mode: CodexRuntimeMode

    public init(
        threadID: String,
        runtimeVersion: String,
        mode: CodexRuntimeMode
    ) {
        self.threadID = threadID
        self.runtimeVersion = runtimeVersion
        self.mode = mode
    }
}

public struct CodexRuntimeItem: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case command
        case fileChange
        case mcpTool
        case dynamicTool
        case collaboration
        case subagent
        case webSearch
        case image
        case plan
        case reasoning
        case other
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String
    public let status: String?
    public let isFailure: Bool
    public let relatedThreadIDs: [String]

    public init(
        id: String,
        kind: Kind,
        title: String,
        detail: String = "",
        status: String? = nil,
        isFailure: Bool = false,
        relatedThreadIDs: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.status = status
        self.isFailure = isFailure
        self.relatedThreadIDs = relatedThreadIDs
    }
}

public enum CodexRuntimeApprovalKind: String, Equatable, Sendable {
    case command
    case fileChange
    case permissions
}

public struct CodexRuntimeRequestID: Hashable, Equatable, Sendable,
    CustomStringConvertible
{
    let wireValue: JSONValue
    public let description: String

    init?(wireValue: JSONValue) {
        switch wireValue {
        case .string(let value):
            self.wireValue = wireValue
            self.description = value
        case .number(let value):
            guard value.isFinite,
                  value.rounded() == value,
                  value >= Double(Int64.min),
                  value < Double(Int64.max) else {
                return nil
            }
            self.wireValue = wireValue
            self.description = String(Int64(value))
        default:
            return nil
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(description)
    }
}

public struct CodexRuntimeApprovalRequest: Equatable, Sendable {
    public let requestID: CodexRuntimeRequestID
    public let kind: CodexRuntimeApprovalKind
    public let threadID: String
    public let turnID: String
    public let itemID: String
    public let title: String
    public let summary: String
    let requestedPermissions: JSONValue?

    init(
        requestID: CodexRuntimeRequestID,
        kind: CodexRuntimeApprovalKind,
        threadID: String,
        turnID: String,
        itemID: String,
        title: String,
        summary: String,
        requestedPermissions: JSONValue? = nil
    ) {
        self.requestID = requestID
        self.kind = kind
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.title = title
        self.summary = summary
        self.requestedPermissions = requestedPermissions
    }
}

public enum CodexRuntimeApprovalDecision: String, Equatable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

public struct CodexRuntimeTurnResult: Equatable, Sendable {
    public let turnID: String
    public let status: String
    public let errorMessage: String?

    public init(
        turnID: String,
        status: String,
        errorMessage: String? = nil
    ) {
        self.turnID = turnID
        self.status = status
        self.errorMessage = errorMessage
    }

    public var succeeded: Bool { status == "completed" }
}

public enum CodexRuntimeEvent: Equatable, Sendable {
    case ready(CodexRuntimeIdentity)
    case turnStarted(String)
    case assistantDelta(itemID: String, text: String)
    case assistantCompleted(itemID: String, text: String)
    case reasoningDelta(itemID: String, text: String)
    case itemStarted(CodexRuntimeItem)
    case itemCompleted(CodexRuntimeItem)
    case approvalRequested(CodexRuntimeApprovalRequest)
    case approvalResolved(CodexRuntimeRequestID)
    case turnCompleted(CodexRuntimeTurnResult)
    case runtimeError(code: String, message: String, fatal: Bool)
}

public enum CodexRuntimeError: Error, Equatable, Sendable, LocalizedError {
    case executableUnavailable
    case incompatibleRuntime(expected: String, actual: String)
    case unsafeRuntimeStorage
    case shellSnapshotStoragePresent
    case processLaunchFailed(String)
    case processTerminated(Int32, String)
    case malformedProtocol(String)
    case serverError(code: Int?, message: String)
    case notStarted
    case alreadyRunning
    case runtimeAlreadyActive
    case noActiveTurn
    case requestNotPending
    case requestTimedOut(String)
    case threadMigrationRequired
    case turnFailed(String)

    public var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "Codex Runtime 0.145.0-intatis.2 is not installed or bundled. Install that exact audited runtime, or set INTATIS_CODEX_RUNTIME to its executable path."
        case .incompatibleRuntime(let expected, let actual):
            return "Codex Runtime version mismatch. Intatis requires \(expected), but found \(actual)."
        case .unsafeRuntimeStorage:
            return "The Codex Runtime session directory is not a safe owner-only directory."
        case .shellSnapshotStoragePresent:
            return "This session's isolated Codex home contains shell snapshots from an older configuration. Start a new session; Intatis will not load or delete files that may contain credentials."
        case .processLaunchFailed(let message):
            return "Codex Runtime could not start: \(message)"
        case .processTerminated(let status, let diagnostic):
            let suffix = diagnostic.isEmpty ? "" : " — \(diagnostic)"
            return "Codex Runtime exited with status \(status)\(suffix)"
        case .malformedProtocol(let message):
            return "Codex Runtime returned malformed protocol data: \(message)"
        case .serverError(let code, let message):
            let prefix = code.map { "Codex Runtime RPC error \($0)" }
                ?? "Codex Runtime RPC error"
            return "\(prefix): \(message)"
        case .notStarted:
            return "Codex Runtime is not started."
        case .alreadyRunning:
            return "A Codex Runtime turn is already running."
        case .runtimeAlreadyActive:
            return "Another Intatis process already owns this session's Codex Runtime."
        case .noActiveTurn:
            return "There is no active Codex Runtime turn to interrupt."
        case .requestNotPending:
            return "The Codex Runtime approval request is no longer pending."
        case .requestTimedOut(let method):
            return "Codex Runtime did not answer \(method) before the request deadline."
        case .threadMigrationRequired:
            return "This session contains legacy Intatis agent history but has no Codex thread. Open a new Code/Cowork session for the first runtime version; automatic context migration is intentionally disabled."
        case .turnFailed(let message):
            return "Codex Runtime turn failed: \(message)"
        }
    }
}
