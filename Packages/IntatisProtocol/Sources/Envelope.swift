import Foundation
import IntatisCore

/// Wraps an `Event` with the metadata needed for ordering, resume, and audit.
///
/// On the wire / on disk the shape is flat:
/// ```json
/// { "seq": 1421, "ts": "2026-06-11T09:14:22Z", "session": "sess_8f2a",
///   "v": 1, "type": "message_delta", "payload": { ... } }
/// ```
/// `seq` is monotonic per session and powers `session.resume { fromSeq }`.
public struct Envelope: Codable, Equatable, Sendable {
    public var seq: Int
    public var ts: Date
    public var session: SessionID
    /// Event schema version. Additive-only evolution (ARCHITECTURE.md §8 risk 7).
    public var v: Int
    public var event: Event

    public init(seq: Int, ts: Date = Date(), session: SessionID, v: Int = 1, event: Event) {
        self.seq = seq
        self.ts = ts
        self.session = session
        self.v = v
        self.event = event
    }

    private enum CodingKeys: String, CodingKey {
        case seq, ts, session, v, type, payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        ts = try c.decode(Date.self, forKey: .ts)
        session = try c.decode(SessionID.self, forKey: .session)
        v = try c.decode(Int.self, forKey: .v)
        let tag = try c.decode(Event.TypeTag.self, forKey: .type)
        switch tag {
        case .userMessage:
            event = .userMessage(try c.decode(UserMessagePayload.self, forKey: .payload))
        case .messageDelta:
            event = .messageDelta(try c.decode(MessageDeltaPayload.self, forKey: .payload))
        case .messageCompleted:
            event = .messageCompleted(try c.decode(MessageCompletedPayload.self, forKey: .payload))
        case .error:
            event = .error(try c.decode(ErrorPayload.self, forKey: .payload))
        case .toolCall:
            event = .toolCall(try c.decode(ToolCallPayload.self, forKey: .payload))
        case .toolResult:
            event = .toolResult(try c.decode(ToolResultPayload.self, forKey: .payload))
        case .permissionRequest:
            event = .permissionRequest(try c.decode(PermissionRequestPayload.self, forKey: .payload))
        case .permissionResolved:
            event = .permissionResolved(try c.decode(PermissionResolvedPayload.self, forKey: .payload))
        case .patchProposed:
            event = .patchProposed(try c.decode(PatchProposedPayload.self, forKey: .payload))
        case .agentStatus:
            event = .agentStatus(try c.decode(AgentStatusPayload.self, forKey: .payload))
        case .agentAttached:
            event = .agentAttached(try c.decode(AgentAttachedPayload.self, forKey: .payload))
        case .agentAttachRequested:
            event = .agentAttachRequested(try c.decode(AgentAttachRequestedPayload.self, forKey: .payload))
        case .agentDetached:
            event = .agentDetached(try c.decode(AgentDetachedPayload.self, forKey: .payload))
        case .agentSpawnRequested:
            event = .agentSpawnRequested(try c.decode(AgentSpawnRequestedPayload.self, forKey: .payload))
        case .agentSpawned:
            event = .agentSpawned(try c.decode(AgentSpawnedPayload.self, forKey: .payload))
        case .agentMessage:
            event = .agentMessage(try c.decode(AgentMessagePayload.self, forKey: .payload))
        case .agentToAgentMessage:
            event = .agentToAgentMessage(try c.decode(AgentToAgentMessagePayload.self, forKey: .payload))
        case .informationRequested:
            event = .informationRequested(try c.decode(InformationRequestedPayload.self, forKey: .payload))
        case .informationReplied:
            event = .informationReplied(try c.decode(InformationRepliedPayload.self, forKey: .payload))
        case .delegationRequested:
            event = .delegationRequested(try c.decode(DelegationRequestedPayload.self, forKey: .payload))
        case .delegationApproved:
            event = .delegationApproved(try c.decode(DelegationApprovedPayload.self, forKey: .payload))
        case .delegationRejected:
            event = .delegationRejected(try c.decode(DelegationRejectedPayload.self, forKey: .payload))
        case .taskDelegated:
            event = .taskDelegated(try c.decode(TaskDelegatedPayload.self, forKey: .payload))
        case .workspaceLeaseRequested:
            event = .workspaceLeaseRequested(try c.decode(WorkspaceLeaseRequestedPayload.self, forKey: .payload))
        case .workspaceLeaseGranted:
            event = .workspaceLeaseGranted(try c.decode(WorkspaceLeaseGrantedPayload.self, forKey: .payload))
        case .workspaceLeaseDenied:
            event = .workspaceLeaseDenied(try c.decode(WorkspaceLeaseDeniedPayload.self, forKey: .payload))
        case .capabilityLeaseCreated:
            event = .capabilityLeaseCreated(try c.decode(CapabilityLeaseCreatedPayload.self, forKey: .payload))
        case .capabilityLeaseRevoked:
            event = .capabilityLeaseRevoked(try c.decode(CapabilityLeaseRevokedPayload.self, forKey: .payload))
        case .permissionReview:
            event = .permissionReview(try c.decode(PermissionReviewPayload.self, forKey: .payload))
        case .taskCreated:
            event = .taskCreated(try c.decode(TaskCreatedPayload.self, forKey: .payload))
        case .taskAssigned:
            event = .taskAssigned(try c.decode(TaskAssignedPayload.self, forKey: .payload))
        case .taskQueued:
            event = .taskQueued(try c.decode(TaskQueuedPayload.self, forKey: .payload))
        case .taskStarted:
            event = .taskStarted(try c.decode(TaskStartedPayload.self, forKey: .payload))
        case .taskCompleted:
            event = .taskCompleted(try c.decode(TaskCompletedPayload.self, forKey: .payload))
        case .taskFailed:
            event = .taskFailed(try c.decode(TaskFailedPayload.self, forKey: .payload))
        case .taskRejected:
            event = .taskRejected(try c.decode(TaskRejectedPayload.self, forKey: .payload))
        case .artifactAdded:
            event = .artifactAdded(try c.decode(ArtifactAddedPayload.self, forKey: .payload))
        case .artifactProgress:
            event = .artifactProgress(try c.decode(ArtifactProgressPayload.self, forKey: .payload))
        case .turnStats:
            event = .turnStats(try c.decode(TurnStatsPayload.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(ts, forKey: .ts)
        try c.encode(session, forKey: .session)
        try c.encode(v, forKey: .v)
        try c.encode(event.type, forKey: .type)
        switch event {
        case .userMessage(let p):        try c.encode(p, forKey: .payload)
        case .messageDelta(let p):       try c.encode(p, forKey: .payload)
        case .messageCompleted(let p):   try c.encode(p, forKey: .payload)
        case .error(let p):              try c.encode(p, forKey: .payload)
        case .toolCall(let p):           try c.encode(p, forKey: .payload)
        case .toolResult(let p):         try c.encode(p, forKey: .payload)
        case .permissionRequest(let p):  try c.encode(p, forKey: .payload)
        case .permissionResolved(let p): try c.encode(p, forKey: .payload)
        case .patchProposed(let p):      try c.encode(p, forKey: .payload)
        case .agentStatus(let p):        try c.encode(p, forKey: .payload)
        case .agentAttached(let p):       try c.encode(p, forKey: .payload)
        case .agentAttachRequested(let p): try c.encode(p, forKey: .payload)
        case .agentDetached(let p):       try c.encode(p, forKey: .payload)
        case .agentSpawnRequested(let p): try c.encode(p, forKey: .payload)
        case .agentSpawned(let p):        try c.encode(p, forKey: .payload)
        case .agentMessage(let p):        try c.encode(p, forKey: .payload)
        case .agentToAgentMessage(let p): try c.encode(p, forKey: .payload)
        case .informationRequested(let p): try c.encode(p, forKey: .payload)
        case .informationReplied(let p):   try c.encode(p, forKey: .payload)
        case .delegationRequested(let p):  try c.encode(p, forKey: .payload)
        case .delegationApproved(let p):   try c.encode(p, forKey: .payload)
        case .delegationRejected(let p):   try c.encode(p, forKey: .payload)
        case .taskDelegated(let p):        try c.encode(p, forKey: .payload)
        case .workspaceLeaseRequested(let p): try c.encode(p, forKey: .payload)
        case .workspaceLeaseGranted(let p):   try c.encode(p, forKey: .payload)
        case .workspaceLeaseDenied(let p):    try c.encode(p, forKey: .payload)
        case .capabilityLeaseCreated(let p):  try c.encode(p, forKey: .payload)
        case .capabilityLeaseRevoked(let p):  try c.encode(p, forKey: .payload)
        case .permissionReview(let p):    try c.encode(p, forKey: .payload)
        case .taskCreated(let p):          try c.encode(p, forKey: .payload)
        case .taskAssigned(let p):         try c.encode(p, forKey: .payload)
        case .taskQueued(let p):           try c.encode(p, forKey: .payload)
        case .taskStarted(let p):          try c.encode(p, forKey: .payload)
        case .taskCompleted(let p):        try c.encode(p, forKey: .payload)
        case .taskFailed(let p):           try c.encode(p, forKey: .payload)
        case .taskRejected(let p):         try c.encode(p, forKey: .payload)
        case .artifactAdded(let p):       try c.encode(p, forKey: .payload)
        case .artifactProgress(let p):    try c.encode(p, forKey: .payload)
        case .turnStats(let p):           try c.encode(p, forKey: .payload)
        }
    }
}

public extension Envelope {
    /// Canonical encoder/decoder for the event log and the wire protocol.
    /// ISO-8601 dates on both sides so round-trips are stable.
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
