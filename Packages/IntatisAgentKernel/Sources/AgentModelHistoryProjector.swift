import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders

/// Rebuilds the model-facing Cowork `@main` history from durable
/// `model_history_item` records.
///
/// This is deliberately separate from `ConversationProjection` and the
/// bounded tool-call audit events. It follows the same split as Codex's
/// rollout ResponseItems versus its UI events: only records written at the
/// provider/tool boundaries are allowed to become provider history.
public struct AgentModelHistoryProjector: Sendable {
    public init() {}

    public func project(
        agentID: AgentID,
        currentTask: TaskContract,
        events: [Envelope]
    ) throws -> [AgentMessage] {
        guard currentTask.kind == .root,
              currentTask.issuer == nil,
              currentTask.assignee == agentID,
              let currentSubmissionID = currentTask.submissionID else {
            return []
        }

        let accepted = Self.acceptedSubmissions(from: events)
        guard let current = accepted[currentSubmissionID] else {
            throw AgentModelHistoryProjectionError.missingAcceptedSubmission(
                currentSubmissionID)
        }
        guard !current.conflicted else {
            throw AgentModelHistoryProjectionError.conflictingAcceptedSubmission(
                currentSubmissionID)
        }
        guard current.payload.to == nil || current.payload.to == agentID else {
            throw AgentModelHistoryProjectionError.invalidItem(
                "accepted-submission:\(currentSubmissionID.rawValue)",
                "accepted user target does not match the current root assignee")
        }

        let bindings = Self.rootBindings(
            currentTask: currentTask,
            events: events)
        try Self.requireRootBinding(
            taskID: currentTask.id,
            submissionID: currentSubmissionID,
            agentID: agentID,
            bindings: bindings)

        let priorSubmissionIDs: Set<SubmissionID> = Set(accepted.compactMap { entry in
            let (submissionID, value) = entry
            guard submissionID != currentSubmissionID,
                  !value.conflicted,
                  value.sequence < current.sequence else {
                return nil
            }
            return submissionID
        })

        let directTurns = try Self.directTurns(
            agentID: agentID,
            priorSubmissionIDs: priorSubmissionIDs,
            accepted: accepted,
            bindings: bindings,
            events: events)
        var turnsBySubmission = Dictionary(
            uniqueKeysWithValues: AgentThreadHistoryProjector()
                .turns(
                    agentID: agentID,
                    currentTask: currentTask,
                    events: events)
                .map {
                    (
                        $0.submissionID,
                        ProjectedTurn(
                            acceptedSequence: $0.acceptedSequence,
                            messages: [
                                .user($0.userText),
                                .assistant($0.assistantText),
                            ])
                    )
                })

        // A direct model-history record is authoritative for its submission.
        // The legacy text-only bridge is used solely for turns written before
        // this event type existed.
        for (submissionID, turn) in directTurns {
            turnsBySubmission[submissionID] = turn
        }

        return turnsBySubmission.values
            .sorted { lhs, rhs in
                lhs.acceptedSequence < rhs.acceptedSequence
            }
            .flatMap(\.messages)
    }

    private struct AcceptedSubmission {
        var sequence: Int
        var payload: UserMessagePayload
        var conflicted: Bool
    }

    private struct RootBinding: Hashable {
        var submissionID: SubmissionID
        var assignee: AgentID
    }

    private struct SequencedItem {
        var sequence: Int
        var payload: ModelHistoryItemPayload
    }

    private struct ProjectedTurn {
        var acceptedSequence: Int
        var messages: [AgentMessage]
    }

    private struct SequencedOutput {
        var sequence: Int
        var payload: ModelHistoryItemPayload
    }

    private struct CallKey: Hashable {
        var turnID: TurnID
        var callID: String
    }

    private static func directTurns(
        agentID: AgentID,
        priorSubmissionIDs: Set<SubmissionID>,
        accepted: [SubmissionID: AcceptedSubmission],
        bindings: [TaskID: Set<RootBinding>],
        events: [Envelope]
    ) throws -> [SubmissionID: ProjectedTurn] {
        var seenItemIDs: [String: ModelHistoryItemPayload] = [:]
        var grouped: [SubmissionID: [SequencedItem]] = [:]

        for envelope in events.sorted(by: { $0.seq < $1.seq }) {
            guard case .modelHistoryItem(let payload) = envelope.event,
                  let submissionID = payload.submissionID,
                  priorSubmissionIDs.contains(submissionID) else {
                continue
            }
            guard let acceptedSubmission = accepted[submissionID],
                  !acceptedSubmission.conflicted,
                  envelope.seq > acceptedSubmission.sequence else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "item is not after one unambiguous accepted submission")
            }
            guard let taskID = payload.taskID else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "root model history is missing taskID")
            }
            let rootBinding = try uniqueRootBinding(
                taskID: taskID,
                bindings: bindings)
            guard rootBinding.submissionID == submissionID else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "item submission does not match its durable root task")
            }
            guard acceptedSubmission.payload.to == nil
                    || acceptedSubmission.payload.to == rootBinding.assignee else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "accepted user target does not match the durable root assignee")
            }
            guard payload.agent == rootBinding.assignee else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "item agent does not match the durable root assignee")
            }
            guard rootBinding.assignee == agentID else {
                continue
            }

            let trimmedItemID = payload.itemID.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !trimmedItemID.isEmpty else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "itemID is empty")
            }
            if let existing = seenItemIDs[payload.itemID] {
                guard existing == payload else {
                    throw AgentModelHistoryProjectionError.conflictingItemID(
                        payload.itemID)
                }
                continue
            }
            seenItemIDs[payload.itemID] = payload
            grouped[submissionID, default: []].append(
                SequencedItem(sequence: envelope.seq, payload: payload))
        }

        var result: [SubmissionID: ProjectedTurn] = [:]
        for (submissionID, items) in grouped {
            guard let acceptedSubmission = accepted[submissionID] else {
                continue
            }
            let selected = try selectLatestInvocation(
                submissionID: submissionID,
                items: items)
            result[submissionID] = ProjectedTurn(
                acceptedSequence: acceptedSubmission.sequence,
                messages: try projectInvocation(
                    acceptedUser: acceptedSubmission.payload,
                    items: selected))
        }
        return result
    }

    /// A retried submission replaces an earlier failed invocation. Within the
    /// selected attempt, a second invocation likewise replaces a partial
    /// predecessor. This prevents a restart from duplicating the same user
    /// message while retaining all items from the chosen provider turn.
    private static func selectLatestInvocation(
        submissionID: SubmissionID,
        items: [SequencedItem]
    ) throws -> [SequencedItem] {
        for item in items {
            guard item.payload.schemaVersion == ModelHistoryItemPayload.currentSchemaVersion else {
                throw AgentModelHistoryProjectionError.unsupportedSchema(
                    itemID: item.payload.itemID,
                    version: item.payload.schemaVersion)
            }
            if let attempt = item.payload.taskAttempt, attempt < 1 {
                throw AgentModelHistoryProjectionError.invalidItem(
                    item.payload.itemID,
                    "taskAttempt must be one-based")
            }
        }

        let selectedAttempt = items.map { $0.payload.taskAttempt ?? 1 }.max() ?? 1
        let attemptItems = items.filter {
            ($0.payload.taskAttempt ?? 1) == selectedAttempt
        }
        let userItems = attemptItems.filter {
            $0.payload.kind == .message && $0.payload.role == .user
        }
        guard let selectedUser = userItems.max(by: { $0.sequence < $1.sequence }) else {
            throw AgentModelHistoryProjectionError.missingUserItem(
                submissionID)
        }
        return attemptItems
            .filter { $0.payload.turnID == selectedUser.payload.turnID }
            .sorted { $0.sequence < $1.sequence }
    }

    private static func projectInvocation(
        acceptedUser: UserMessagePayload,
        items: [SequencedItem]
    ) throws -> [AgentMessage] {
        guard let first = items.first else { return [] }
        let turnID = first.payload.turnID
        guard items.allSatisfy({ $0.payload.turnID == turnID }) else {
            throw AgentModelHistoryProjectionError.invalidItem(
                first.payload.itemID,
                "one invocation contains multiple turn IDs")
        }

        let userItems = items.filter {
            $0.payload.kind == .message && $0.payload.role == .user
        }
        guard userItems.count == 1,
              let userContent = userItems[0].payload.content,
              userContent == acceptedUser.text else {
            throw AgentModelHistoryProjectionError.invalidItem(
                userItems.first?.payload.itemID ?? first.payload.itemID,
                "durable user item does not exactly match the accepted submission")
        }
        guard items.firstIndex(where: {
            $0.payload.itemID == userItems[0].payload.itemID
        }) == 0 else {
            throw AgentModelHistoryProjectionError.invalidItem(
                userItems[0].payload.itemID,
                "user item is not first in its invocation")
        }

        var callSequenceByKey: [CallKey: Int] = [:]
        var outputsByKey: [CallKey: [SequencedOutput]] = [:]
        for item in items {
            try validateShape(item.payload)
            switch item.payload.kind {
            case .functionCallBatch:
                for call in item.payload.functionCalls ?? [] {
                    let key = CallKey(
                        turnID: item.payload.turnID,
                        callID: call.callID)
                    guard callSequenceByKey[key] == nil else {
                        throw AgentModelHistoryProjectionError.ambiguousCallID(
                            call.callID)
                    }
                    callSequenceByKey[key] = item.sequence
                }
            case .functionCallOutput:
                guard let callID = item.payload.callID else { continue }
                let key = CallKey(
                    turnID: item.payload.turnID,
                    callID: callID)
                outputsByKey[key, default: []].append(
                    SequencedOutput(
                        sequence: item.sequence,
                        payload: item.payload))
            case .message, .reasoning:
                break
            }
        }

        var messages: [AgentMessage] = []
        for item in items {
            switch item.payload.kind {
            case .message:
                guard let role = item.payload.role,
                      let content = item.payload.content else {
                    throw AgentModelHistoryProjectionError.invalidItem(
                        item.payload.itemID,
                        "message is missing role or content")
                }
                switch role {
                case .user:
                    messages.append(.user(content))
                case .assistant:
                    messages.append(.assistant(content))
                }

            case .functionCallBatch:
                let calls = (item.payload.functionCalls ?? []).map {
                    ToolCall(
                        id: $0.callID,
                        name: $0.name,
                        arguments: $0.arguments)
                }
                messages.append(.assistant(
                    toolCalls: calls,
                    content: item.payload.content))
                for call in calls {
                    let key = CallKey(turnID: turnID, callID: call.id)
                    let validOutputs = (outputsByKey[key] ?? []).filter {
                        $0.sequence > item.sequence
                    }
                    guard validOutputs.count <= 1 else {
                        throw AgentModelHistoryProjectionError.conflictingOutput(
                            call.id)
                    }
                    messages.append(.tool(
                        id: call.id,
                        content: validOutputs.first?.payload.output ?? "aborted"))
                }

            case .functionCallOutput:
                // Outputs are emitted immediately after their matching call,
                // in call order. Orphan outputs are intentionally omitted.
                continue

            case .reasoning:
                // The current Chat Completions-shaped AgentRequest cannot
                // represent provider-native reasoning items. No writer emits
                // this kind yet; retaining the tagged schema leaves the resume
                // format additive for a provider adapter that can.
                continue
            }
        }
        return messages
    }

    private static func validateShape(
        _ payload: ModelHistoryItemPayload
    ) throws {
        func invalid(_ reason: String) throws -> Never {
            throw AgentModelHistoryProjectionError.invalidItem(
                payload.itemID,
                reason)
        }

        switch payload.kind {
        case .message:
            guard payload.role != nil,
                  payload.content != nil,
                  payload.functionCalls == nil,
                  payload.callID == nil,
                  payload.output == nil else {
                try invalid("message fields are inconsistent")
            }

        case .functionCallBatch:
            guard payload.role == nil,
                  let calls = payload.functionCalls,
                  !calls.isEmpty,
                  payload.callID == nil,
                  payload.output == nil else {
                try invalid("function-call batch fields are inconsistent")
            }
            for call in calls {
                guard !call.callID.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty,
                      !call.name.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty,
                      isJSONObject(call.arguments) else {
                    try invalid("function call has an invalid ID, name, or JSON argument object")
                }
            }

        case .functionCallOutput:
            guard payload.role == nil,
                  payload.functionCalls == nil,
                  let callID = payload.callID,
                  !callID.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty,
                  payload.output != nil else {
                try invalid("function-call output fields are inconsistent")
            }

        case .reasoning:
            guard payload.role == nil,
                  payload.functionCalls == nil,
                  payload.callID == nil,
                  payload.output == nil else {
                try invalid("reasoning fields are inconsistent")
            }
        }
    }

    private static func isJSONObject(_ string: String) -> Bool {
        guard let data = string.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]) else {
            return false
        }
        return value is [String: Any]
    }

    private static func acceptedSubmissions(
        from events: [Envelope]
    ) -> [SubmissionID: AcceptedSubmission] {
        var result: [SubmissionID: AcceptedSubmission] = [:]
        for envelope in events.sorted(by: { $0.seq < $1.seq }) {
            guard case .userMessage(let payload) = envelope.event,
                  let submissionID = payload.submissionID else {
                continue
            }
            if var existing = result[submissionID] {
                if existing.payload != payload {
                    existing.conflicted = true
                    result[submissionID] = existing
                }
            } else {
                result[submissionID] = AcceptedSubmission(
                    sequence: envelope.seq,
                    payload: payload,
                    conflicted: false)
            }
        }
        return result
    }

    private static func rootBindings(
        currentTask: TaskContract,
        events: [Envelope]
    ) -> [TaskID: Set<RootBinding>] {
        var result: [TaskID: Set<RootBinding>] = [:]
        func record(_ contract: TaskContract) {
            guard contract.kind == .root,
                  contract.issuer == nil,
                  let submissionID = contract.submissionID else {
                return
            }
            result[contract.id, default: []].insert(
                RootBinding(
                    submissionID: submissionID,
                    assignee: contract.assignee))
        }
        record(currentTask)
        for envelope in events {
            guard let contract = taskContract(from: envelope.event) else {
                continue
            }
            record(contract)
        }
        return result
    }

    private static func requireRootBinding(
        taskID: TaskID,
        submissionID: SubmissionID,
        agentID: AgentID,
        bindings: [TaskID: Set<RootBinding>]
    ) throws {
        let binding = try uniqueRootBinding(
            taskID: taskID,
            bindings: bindings)
        guard binding == RootBinding(
                  submissionID: submissionID,
                  assignee: agentID) else {
            throw AgentModelHistoryProjectionError.ambiguousRootBinding(
                taskID)
        }
    }

    private static func uniqueRootBinding(
        taskID: TaskID,
        bindings: [TaskID: Set<RootBinding>]
    ) throws -> RootBinding {
        let candidates = bindings[taskID] ?? []
        guard candidates.count == 1,
              let binding = candidates.first else {
            throw AgentModelHistoryProjectionError.ambiguousRootBinding(
                taskID)
        }
        return binding
    }

    private static func taskContract(from event: Event) -> TaskContract? {
        switch event {
        case .taskCreated(let payload):
            return payload.contract
        case .taskAssigned(let payload):
            return payload.contract
        case .taskQueued(let payload):
            return payload.contract
        case .taskDelegated(let payload):
            return payload.contract
        case .delegationApproved(let payload):
            return payload.contract
        case .taskRejected(let payload):
            return payload.contract
        default:
            return nil
        }
    }
}

public enum AgentModelHistoryProjectionError:
    Error, Equatable, Sendable, LocalizedError
{
    case missingAcceptedSubmission(SubmissionID)
    case conflictingAcceptedSubmission(SubmissionID)
    case ambiguousRootBinding(TaskID)
    case unsupportedSchema(itemID: String, version: Int)
    case conflictingItemID(String)
    case invalidItem(String, String)
    case missingUserItem(SubmissionID)
    case ambiguousCallID(String)
    case conflictingOutput(String)

    public var errorDescription: String? {
        switch self {
        case .missingAcceptedSubmission(let submissionID):
            return "Model history has no accepted user submission \(submissionID.rawValue)."
        case .conflictingAcceptedSubmission(let submissionID):
            return "Accepted user submission \(submissionID.rawValue) has conflicting durable payloads."
        case .ambiguousRootBinding(let taskID):
            return "Model history root task \(taskID.rawValue) has no unique durable submission/agent binding."
        case .unsupportedSchema(let itemID, let version):
            return "Model history item \(itemID) uses unsupported schema version \(version)."
        case .conflictingItemID(let itemID):
            return "Model history item ID \(itemID) was reused with conflicting payloads."
        case .invalidItem(let itemID, let reason):
            return "Model history item \(itemID) is invalid: \(reason)."
        case .missingUserItem(let submissionID):
            return "Model history for submission \(submissionID.rawValue) has no durable user item."
        case .ambiguousCallID(let callID):
            return "Model history reused tool call ID \(callID) within one provider turn."
        case .conflictingOutput(let callID):
            return "Model history contains multiple outputs for tool call ID \(callID)."
        }
    }
}
