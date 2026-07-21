import Foundation
import IntatisCore

/// Host-side conclusion about whether a concrete registered tool belongs to
/// the active capability lease. The model reviewer may consume this fact but
/// cannot reinterpret aliases or widen it.
public enum ToolAuthorizationMembership: String, Codable, Equatable, Sendable {
    case granted
    case notRequired = "not_required"
}

public enum ToolCommunicationRequirement: String, Codable, Equatable, Sendable {
    case none
    case initiate
    case reply
}

public enum ToolDelegationRequirement: String, Codable, Equatable, Sendable {
    case none
    case requestOrGranted = "request_or_granted"
    case granted
}

/// Result of bounding and redacting text before it is persisted as a semantic
/// approval preview or sent to the automatic reviewer. This is deliberately
/// separate from raw tool arguments: rejected or sensitive values have no
/// durable raw-value representation, while validated non-sensitive calls may
/// retain a digest plus character count.
public struct PermissionReviewTextSanitization: Equatable, Sendable {
    public let text: String
    public let redacted: Bool
    public let truncated: Bool

    public init(text: String, redacted: Bool, truncated: Bool) {
        self.text = text
        self.redacted = redacted
        self.truncated = truncated
    }
}

/// Shared, deterministic scrubber for every untrusted string that can reach a
/// permission-review prompt. The patterns intentionally cover both common
/// token formats and authorization-like key/value syntax (including URL query
/// parameters); callers still retain exact raw-argument identity via a digest.
public enum PermissionReviewTextSanitizer {
    /// HTTP(S) locations are not secrets by definition, so ordinary permission
    /// previews keep using `sanitize`. Diagnostics opt in to this additional
    /// rule because provider endpoints can identify private infrastructure and
    /// must not survive into EventLog or task-failure text.
    private static let diagnosticURLPattern =
        #"(?i)\bhttps?://(?:[^\s/@<>\"'\\]+@)?(?:\[[0-9a-f:.%]+\]|[^\s/:?#<>\"'\\\[\]{}()]+)(?::[0-9]{1,5})?(?:[/?#][^\s<>\"'\\]*)?"#

    private static let replacementPatterns: [(pattern: String, replacement: String)] = [
        (
            #"(?i)(authorization\s*[:=]\s*)(?:bearer\s+)?[^\s,;"'\]}]+"#,
            "$1[REDACTED]"
        ),
        (
            #"(?i)([?&](?:access[_-]?token|refresh[_-]?token|auth[_-]?token|token|api[_-]?key|secret|password|client[_-]?secret)=)[^&#\s]+"#,
            "$1[REDACTED]"
        ),
        (
            #"(?i)("?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|token|secret|password|passwd|client[_-]?secret|private[_-]?key|access[_-]?key)"?\s*[:=]\s*"?)[^\s,"'\]}&;]+"#,
            "$1[REDACTED]"
        ),
        (
            #"(?i)\b(?:sk-[a-z0-9_-]{8,}|rk-[a-z0-9_-]{8,}|ghp_[a-z0-9_]{8,}|github_pat_[a-z0-9_]{8,}|xox[baprs]-[a-z0-9-]{8,}|(?:AKIA|ASIA)[A-Z0-9]{8,}|AIza[A-Za-z0-9_-]{8,})\b"#,
            "[REDACTED_TOKEN]"
        ),
        (
            #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]{8,})?\b"#,
            "[REDACTED_JWT]"
        ),
    ]

    public static func sanitize(_ value: String,
                                maxCharacters: Int) -> PermissionReviewTextSanitization {
        sanitize(value, maxCharacters: maxCharacters, redactingDiagnosticURLs: false)
    }

    /// Scrubs untrusted error/audit diagnostics, including complete HTTP(S)
    /// URLs even when they contain no query or credential-shaped component.
    /// This is intentionally opt-in so normal provider configuration and UI
    /// values are never rewritten by a global URL policy.
    public static func sanitizeDiagnostic(_ value: String,
                                          maxCharacters: Int) -> PermissionReviewTextSanitization {
        sanitize(value, maxCharacters: maxCharacters, redactingDiagnosticURLs: true)
    }

    private static func sanitize(_ value: String,
                                 maxCharacters: Int,
                                 redactingDiagnosticURLs: Bool) -> PermissionReviewTextSanitization {
        let boundedLimit = max(0, maxCharacters)
        let lower = value.lowercased()
        if lower.contains("-----begin"), lower.contains("private key") {
            return PermissionReviewTextSanitization(
                text: "[REDACTED_PRIVATE_KEY]",
                redacted: true,
                truncated: value.count > boundedLimit)
        }

        var output = value
        var redacted = false
        if redactingDiagnosticURLs {
            let replaced = output.replacingOccurrences(
                of: diagnosticURLPattern,
                with: "[REDACTED_URL]",
                options: .regularExpression)
            if replaced != output { redacted = true }
            output = replaced
        }
        for entry in replacementPatterns {
            let replaced = output.replacingOccurrences(
                of: entry.pattern,
                with: entry.replacement,
                options: .regularExpression)
            if replaced != output { redacted = true }
            output = replaced
        }

        let truncated = output.count > boundedLimit
        if truncated {
            output = String(output.prefix(boundedLimit)) + "..."
        }
        return PermissionReviewTextSanitization(
            text: output,
            redacted: redacted,
            truncated: truncated)
    }

    public static func containsSensitiveMaterial(_ value: String) -> Bool {
        sanitize(value, maxCharacters: value.count).redacted
    }
}

/// Bounded, already-redacted semantic facts that let a reviewer understand an
/// exact action without receiving the raw JSON argument object. Decoding runs
/// the scrubber again so a forged/replayed event cannot inject unsanitized
/// preview text into a later reviewer session.
public struct PermissionActionPreview: Codable, Equatable, Sendable {
    public let kind: String
    public let fields: [String: String]
    public let redacted: Bool
    public let truncated: Bool

    public init(kind: String, fields: [String: String]) {
        self = Self.normalized(
            kind: kind,
            fields: fields,
            declaredRedacted: false,
            declaredTruncated: false)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case fields
        case redacted
        case truncated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = Self.normalized(
            kind: try container.decode(String.self, forKey: .kind),
            fields: try container.decode([String: String].self, forKey: .fields),
            declaredRedacted: try container.decodeIfPresent(Bool.self, forKey: .redacted) ?? false,
            declaredTruncated: try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(fields, forKey: .fields)
        try container.encode(redacted, forKey: .redacted)
        try container.encode(truncated, forKey: .truncated)
    }

    private init(kind: String,
                 fields: [String: String],
                 redacted: Bool,
                 truncated: Bool) {
        self.kind = kind
        self.fields = fields
        self.redacted = redacted
        self.truncated = truncated
    }

    private static func normalized(kind: String,
                                   fields: [String: String],
                                   declaredRedacted: Bool,
                                   declaredTruncated: Bool) -> PermissionActionPreview {
        let safeKind = PermissionReviewTextSanitizer.sanitize(kind, maxCharacters: 80)
        let selectedKeys = fields.keys.sorted().prefix(8)
        var safeFields: [String: String] = [:]
        var wasRedacted = declaredRedacted || safeKind.redacted
        var wasTruncated = declaredTruncated
            || safeKind.truncated
            || fields.count > selectedKeys.count
        var remainingCharacters = 2_400

        for rawKey in selectedKeys {
            guard remainingCharacters > 0 else {
                wasTruncated = true
                break
            }
            let safeKey = PermissionReviewTextSanitizer.sanitize(rawKey, maxCharacters: 80)
            let fieldLimit = min(800, remainingCharacters)
            let safeValue = PermissionReviewTextSanitizer.sanitize(
                fields[rawKey] ?? "",
                maxCharacters: fieldLimit)
            safeFields[safeKey.text] = safeValue.text
            remainingCharacters -= safeValue.text.count
            wasRedacted = wasRedacted || safeKey.redacted || safeValue.redacted
            wasTruncated = wasTruncated || safeKey.truncated || safeValue.truncated
        }

        return PermissionActionPreview(
            kind: safeKind.text,
            fields: safeFields,
            redacted: wasRedacted,
            truncated: wasTruncated)
    }
}

/// Invocation identity supplied by AgentKernel while the registry resolves a
/// concrete tool. Raw arguments are intentionally not stored here; the
/// resulting snapshot records a digest and character count instead.
public struct ToolAuthorizationInvocationContext: Equatable, Sendable {
    public var sessionID: SessionID?
    public var agent: AgentID?
    public var taskID: TaskID?
    public var rootTaskID: TaskID?
    public var parentTaskID: TaskID?
    public var attempt: Int?
    public var toolCallID: String?
    public var taskObjective: String?

    public init(sessionID: SessionID? = nil,
                agent: AgentID? = nil,
                taskID: TaskID? = nil,
                rootTaskID: TaskID? = nil,
                parentTaskID: TaskID? = nil,
                attempt: Int? = nil,
                toolCallID: String? = nil,
                taskObjective: String? = nil) {
        self.sessionID = sessionID
        self.agent = agent
        self.taskID = taskID
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.attempt = attempt
        self.toolCallID = toolCallID
        self.taskObjective = taskObjective
    }
}

/// Immutable authorization facts resolved from the same registry entry that
/// supplies the model schema and executor. It is copied into review and tool
/// execution events so an approval can be audited against the exact action
/// that later ran.
public struct ResolvedToolAuthorization: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let authorizationID: String
    public let registryVersion: String
    public let concreteToolID: String
    public let descriptorFingerprint: String
    public let toolName: String
    public let canonicalAction: String
    public let canonicalPermission: String?
    public let actionPreview: PermissionActionPreview?
    public let requiredCapabilities: [ToolCapability]
    public let requiredCommunication: ToolCommunicationRequirement
    public let requiredDelegation: ToolDelegationRequirement
    public let membership: ToolAuthorizationMembership
    public let capabilityLeaseID: CapabilityLeaseID?
    public let capabilityTaskID: TaskID?
    public let capabilityLeaseFingerprint: String?
    public let workspaceLeaseID: WorkspaceLeaseID?
    public let workspaceID: WorkspaceID?
    public let workspaceTaskID: TaskID?
    public let workspaceRootPath: String?
    public let workspaceAccess: WorkspaceAccess?
    public let workspaceRootIdentity: WorkspaceRootIdentity?
    public let workspaceLeaseFingerprint: String?
    public let sessionID: SessionID?
    public let agent: AgentID?
    public let taskID: TaskID?
    public let rootTaskID: TaskID?
    public let parentTaskID: TaskID?
    public let attempt: Int?
    public let toolCallID: String?
    public let taskObjective: String?
    /// Exact, secret-free inference identity of a host-resolved target agent.
    /// This is populated for control-plane actions such as delegate/spawn so
    /// permission review and durable execution revalidation bind the route as
    /// well as the agent/workspace identity.
    public let targetAgentInferenceBinding: AgentInferenceBinding?
    public let normalizedArgumentsDigest: String
    public let normalizedArgumentsCharacterCount: Int
    public let intent: PermissionIntent
    public let sideEffect: SideEffect
    public let risksNetwork: Bool
    public let replayPolicy: ToolExecutionReplayPolicy
    public let deterministicGate: PermissionReviewGateSnapshot?

    public init(schemaVersion: Int = 1,
                authorizationID: String,
                registryVersion: String,
                concreteToolID: String,
                descriptorFingerprint: String,
                toolName: String,
                canonicalAction: String,
                canonicalPermission: String? = nil,
                actionPreview: PermissionActionPreview? = nil,
                requiredCapabilities: [ToolCapability],
                membership: ToolAuthorizationMembership,
                capabilityLeaseID: CapabilityLeaseID?,
                capabilityTaskID: TaskID?,
                workspaceLeaseID: WorkspaceLeaseID?,
                workspaceAccess: WorkspaceAccess?,
                workspaceRootIdentity: WorkspaceRootIdentity?,
                invocation: ToolAuthorizationInvocationContext = .init(),
                normalizedArgumentsDigest: String,
                normalizedArgumentsCharacterCount: Int,
                intent: PermissionIntent,
                sideEffect: SideEffect,
                risksNetwork: Bool,
                replayPolicy: ToolExecutionReplayPolicy,
                deterministicGate: PermissionReviewGateSnapshot? = nil,
                requiredCommunication: ToolCommunicationRequirement = .none,
                requiredDelegation: ToolDelegationRequirement = .none,
                capabilityLeaseFingerprint: String? = nil,
                workspaceID: WorkspaceID? = nil,
                workspaceTaskID: TaskID? = nil,
                workspaceRootPath: String? = nil,
                workspaceLeaseFingerprint: String? = nil,
                targetAgentInferenceBinding: AgentInferenceBinding? = nil) {
        self.schemaVersion = schemaVersion
        self.authorizationID = authorizationID
        self.registryVersion = registryVersion
        self.concreteToolID = concreteToolID
        self.descriptorFingerprint = descriptorFingerprint
        self.toolName = toolName
        self.canonicalAction = canonicalAction
        self.canonicalPermission = canonicalPermission
        self.actionPreview = actionPreview
        self.requiredCapabilities = requiredCapabilities
        self.requiredCommunication = requiredCommunication
        self.requiredDelegation = requiredDelegation
        self.membership = membership
        self.capabilityLeaseID = capabilityLeaseID
        self.capabilityTaskID = capabilityTaskID
        self.capabilityLeaseFingerprint = capabilityLeaseFingerprint
        self.workspaceLeaseID = workspaceLeaseID
        self.workspaceID = workspaceID
        self.workspaceTaskID = workspaceTaskID
        self.workspaceRootPath = workspaceRootPath
        self.workspaceAccess = workspaceAccess
        self.workspaceRootIdentity = workspaceRootIdentity
        self.workspaceLeaseFingerprint = workspaceLeaseFingerprint
        self.sessionID = invocation.sessionID
        self.agent = invocation.agent
        self.taskID = invocation.taskID
        self.rootTaskID = invocation.rootTaskID
        self.parentTaskID = invocation.parentTaskID
        self.attempt = invocation.attempt
        self.toolCallID = invocation.toolCallID
        self.taskObjective = invocation.taskObjective
        self.targetAgentInferenceBinding = targetAgentInferenceBinding
        self.normalizedArgumentsDigest = normalizedArgumentsDigest
        self.normalizedArgumentsCharacterCount = normalizedArgumentsCharacterCount
        self.intent = intent
        self.sideEffect = sideEffect
        self.risksNetwork = risksNetwork
        self.replayPolicy = replayPolicy
        self.deterministicGate = deterministicGate
    }

    public func withDeterministicGate(_ gate: PermissionReviewGateSnapshot) -> ResolvedToolAuthorization {
        ResolvedToolAuthorization(
            schemaVersion: schemaVersion,
            authorizationID: authorizationID,
            registryVersion: registryVersion,
            concreteToolID: concreteToolID,
            descriptorFingerprint: descriptorFingerprint,
            toolName: toolName,
            canonicalAction: canonicalAction,
            canonicalPermission: canonicalPermission,
            actionPreview: actionPreview,
            requiredCapabilities: requiredCapabilities,
            membership: membership,
            capabilityLeaseID: capabilityLeaseID,
            capabilityTaskID: capabilityTaskID,
            workspaceLeaseID: workspaceLeaseID,
            workspaceAccess: workspaceAccess,
            workspaceRootIdentity: workspaceRootIdentity,
            invocation: ToolAuthorizationInvocationContext(
                sessionID: sessionID,
                agent: agent,
                taskID: taskID,
                rootTaskID: rootTaskID,
                parentTaskID: parentTaskID,
                attempt: attempt,
                toolCallID: toolCallID,
                taskObjective: taskObjective),
            normalizedArgumentsDigest: normalizedArgumentsDigest,
            normalizedArgumentsCharacterCount: normalizedArgumentsCharacterCount,
            intent: intent,
            sideEffect: sideEffect,
            risksNetwork: risksNetwork,
            replayPolicy: replayPolicy,
            deterministicGate: gate,
            requiredCommunication: requiredCommunication,
            requiredDelegation: requiredDelegation,
            capabilityLeaseFingerprint: capabilityLeaseFingerprint,
            workspaceID: workspaceID,
            workspaceTaskID: workspaceTaskID,
            workspaceRootPath: workspaceRootPath,
            workspaceLeaseFingerprint: workspaceLeaseFingerprint,
            targetAgentInferenceBinding: targetAgentInferenceBinding)
    }
}

/// Source and durable reviewer metadata returned across the responder boundary.
/// This remains separate from the event payload so legacy responders can use
/// the default adapter without changing their storage contract.
public enum PermissionApprovalSource: String, Codable, Equatable, Sendable {
    case deterministicPolicy = "deterministic_policy"
    case authorizationRevalidation = "authorization_revalidation"
    case callerCancellation = "caller_cancellation"
    case user
    case automaticReviewer = "automatic_reviewer"
    case automaticReviewerFailure = "automatic_reviewer_failure"
}

public enum PermissionApprovalFailureKind: String, Codable, Equatable, Sendable {
    case callerCancelled = "caller_cancelled"
    case reviewerTimedOut = "reviewer_timed_out"
    case reviewerCancelled = "reviewer_cancelled"
    case malformedVerdict = "malformed_verdict"
    case reviewerContractViolation = "reviewer_contract_violation"
    case providerFailure = "provider_failure"
    case providerStillStopping = "provider_still_stopping"
    case queueCapacity = "queue_capacity"
    case controlPlaneShutdown = "control_plane_shutdown"
    case reconciliationFailure = "reconciliation_failure"
    case requestPersistenceFailure = "request_persistence_failure"
    case settlementPersistenceFailure = "settlement_persistence_failure"
    case authorizationSnapshotInvalid = "authorization_snapshot_invalid"
}

/// Explicit user/control-plane response to one permission request. `decline`
/// denies only the current call, while `cancelTurn` interrupts its enclosing
/// turn and must not be represented to the model as a fabricated denied tool
/// result.
public enum PermissionResponseAction: String, Codable, Equatable, Sendable {
    case approve
    case decline
    case cancelTurn = "cancel_turn"
}

public struct PermissionApprovalResolution: Codable, Equatable, Sendable {
    public var decision: PermissionDecision
    /// Additive explicit response semantics. Nil denotes a legacy responder;
    /// use `effectiveAction` to derive approve/decline from its decision.
    public var action: PermissionResponseAction?
    public var reason: String?
    public var risk: RiskLevel?
    public var source: PermissionApprovalSource
    public var reviewTaskID: PermissionReviewTaskID?
    public var reviewStatus: PermissionReviewStatus?
    public var failureKind: PermissionApprovalFailureKind?
    public var failureSource: ExecutionFailureSource?

    public init(decision: PermissionDecision,
                action: PermissionResponseAction? = nil,
                reason: String? = nil,
                risk: RiskLevel? = nil,
                source: PermissionApprovalSource,
                reviewTaskID: PermissionReviewTaskID? = nil,
                reviewStatus: PermissionReviewStatus? = nil,
                failureKind: PermissionApprovalFailureKind? = nil,
                failureSource: ExecutionFailureSource? = nil) {
        self.decision = decision
        self.action = action
        self.reason = reason
        self.risk = risk
        self.source = source
        self.reviewTaskID = reviewTaskID
        self.reviewStatus = reviewStatus
        self.failureKind = failureKind
        self.failureSource = failureSource
    }

    public var effectiveAction: PermissionResponseAction {
        if let action { return action }
        return decision == .allow ? .approve : .decline
    }
}
