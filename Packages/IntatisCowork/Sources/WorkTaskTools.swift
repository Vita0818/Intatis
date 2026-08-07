import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

private let workTaskStringSchema: JSONValue = .object([
    "type": .string("string"),
    "minLength": .number(1),
])

private let workTaskStringArraySchema: JSONValue = .object([
    "type": .string("array"),
    "items": workTaskStringSchema,
])

private func encodeWorkTaskToolResult<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func normalizedWorkTaskAgentID(_ raw: String) -> AgentID {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return AgentID(rawValue: trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed)
}

private func joinedWorkTaskPreviewValues(_ values: [String]?) -> String {
    values?.joined(separator: ", ") ?? ""
}

private func workTaskNamespaceHint(
    rawID: String,
    underlyingError: Error
) -> Error {
    let isNotFound: Bool
    if let error = underlyingError as? IntatisError,
       case .notFound = error {
        isNotFound = true
    } else if let violation = underlyingError as? WorkTaskGraphViolation,
              violation.kind == .missingTask {
        isNotFound = true
    } else {
        isNotFound = false
    }
    guard isNotFound,
          rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("task_") else {
        return underlyingError
    }
    return ToolExecutionRejectedWithoutSideEffect(
        code: "work_task_id_required",
        message: "\(rawID) is an AgentInvocation TaskID, not a WorkTask ID. Use task_get or task_list to obtain the durable WorkTask ID (normally wt_…), then retry with its latest authoritative revision.")
}

public struct TaskCreateTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "task_create",
        description: "Create one durable WorkTask in the current ContinuationRun. Returns the stable task_id, host-computed status, and revision. Use concise acceptance criteria and real dependencies; this is a control-plane change, not a workspace write.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "title": workTaskStringSchema,
                "description": workTaskStringSchema,
                "acceptance_criteria": workTaskStringArraySchema,
                "expected_artifacts": workTaskStringArraySchema,
                "depends_on": workTaskStringArraySchema,
                "owner": workTaskStringSchema,
                "priority": .object([
                    "type": .string("string"),
                    "enum": .array(WorkTaskPriority.allCases.map { .string($0.rawValue) }),
                ]),
            ]),
            "required": .array([.string("title"), .string("description")]),
            "additionalProperties": .bool(false),
        ]))

    private struct Args: Decodable {
        var title: String
        var description: String
        var acceptanceCriteria: [String]?
        var expectedArtifacts: [String]?
        var dependsOn: [String]?
        var owner: String?
        var priority: WorkTaskPriority?

        enum CodingKeys: String, CodingKey {
            case title, description, owner, priority
            case acceptanceCriteria = "acceptance_criteria"
            case expectedArtifacts = "expected_artifacts"
            case dependsOn = "depends_on"
        }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "task.create",
            resources: [PermissionResource(kind: .task, value: "current-run")],
            metadata: [
                "title": value.map { .string(String($0.title.prefix(160))) } ?? .null,
                "owner": value?.owner.map(JSONValue.string) ?? .null,
                "dependencyCount": .number(Double(value?.dependsOn?.count ?? 0)),
            ],
            dataEffects: [.none],
            controlEffects: [.createTask],
            risks: [.controlPlaneMutation],
            replayPolicy: .requiresManualReconciliation)
    }

    public func permissionActionPreview(
        _ args: ToolArgs
    ) -> PermissionActionPreview? {
        guard let value = try? args.decode(Args.self) else { return nil }
        return PermissionActionPreview(
            kind: Self.descriptor.name,
            fields: [
                "title": value.title,
                "description": value.description,
                "owner": value.owner ?? "unassigned",
                "acceptance_criteria": joinedWorkTaskPreviewValues(value.acceptanceCriteria),
                "expected_artifacts": joinedWorkTaskPreviewValues(value.expectedArtifacts),
                "depends_on": joinedWorkTaskPreviewValues(value.dependsOn),
                "priority": (value.priority ?? .normal).rawValue,
            ])
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        guard let manager = context.workTaskManager else {
            return ToolObservation(text: "WorkTask management is not available in this session")
        }
        let request = WorkTaskCreateRequest(
            title: value.title,
            description: value.description,
            acceptanceCriteria: value.acceptanceCriteria ?? [],
            expectedArtifacts: value.expectedArtifacts ?? [],
            dependsOn: (value.dependsOn ?? []).map { WorkTaskID(rawValue: $0) },
            owner: value.owner.map(normalizedWorkTaskAgentID),
            priority: value.priority ?? .normal)
        return ToolObservation(text: try encodeWorkTaskToolResult(
            await manager.createWorkTask(request)))
    }
}

public struct TaskUpdateTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "task_update",
        description: "Patch a durable WorkTask (normally wt_…), never an AgentInvocation TaskID (task_…). Use task_get/task_list to obtain the WorkTask ID and its latest authoritative revision before updating. expected_revision is required; send only fields that must change and omit repeated contract fields. Workers may update progress/status/result/evidence on their assigned task but cannot change its contract. Do not redundantly settle an already-terminal WorkTask. Only an explicit completed update with a non-empty result, and evidence when acceptance criteria exist, settles a WorkTask. AgentInvocation completion alone never does.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "task_id": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                    "description": .string("Durable WorkTask ID, normally wt_…. Do not pass an AgentInvocation task_… ID."),
                ]),
                "expected_revision": .object([
                    "type": .string("integer"),
                    "minimum": .number(0),
                ]),
                "title": workTaskStringSchema,
                "description": workTaskStringSchema,
                "acceptance_criteria": workTaskStringArraySchema,
                "expected_artifacts": workTaskStringArraySchema,
                "owner": .object(["type": .string("string")]),
                "depends_on": workTaskStringArraySchema,
                "priority": .object([
                    "type": .string("string"),
                    "enum": .array(WorkTaskPriority.allCases.map { .string($0.rawValue) }),
                ]),
                "progress_note": .object(["type": .string("string")]),
                "status": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string(WorkTaskStatus.inProgress.rawValue),
                        .string(WorkTaskStatus.blocked.rawValue),
                        .string(WorkTaskStatus.completed.rawValue),
                        .string(WorkTaskStatus.failed.rawValue),
                        .string(WorkTaskStatus.cancelled.rawValue),
                        .string(WorkTaskStatus.ready.rawValue),
                    ]),
                ]),
                "result": .object(["type": .string("string")]),
                "evidence": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "kind": workTaskStringSchema,
                            "reference": workTaskStringSchema,
                            "summary": workTaskStringSchema,
                        ]),
                        "required": .array([.string("kind"), .string("reference"), .string("summary")]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
                "retry": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("task_id"), .string("expected_revision")]),
            "additionalProperties": .bool(false),
        ]))

    private struct Args: Decodable {
        var taskID: String
        var expectedRevision: Int
        var title: String?
        var description: String?
        var acceptanceCriteria: [String]?
        var expectedArtifacts: [String]?
        var owner: String?
        var dependsOn: [String]?
        var priority: WorkTaskPriority?
        var progressNote: String?
        var status: WorkTaskStatus?
        var result: String?
        var evidence: [WorkTaskEvidenceInput]?
        var retry: Bool?

        enum CodingKeys: String, CodingKey {
            case title, description, owner, priority, status, result, evidence, retry
            case taskID = "task_id"
            case expectedRevision = "expected_revision"
            case acceptanceCriteria = "acceptance_criteria"
            case expectedArtifacts = "expected_artifacts"
            case dependsOn = "depends_on"
            case progressNote = "progress_note"
        }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        let cancelling = value?.status == .cancelled
        return PermissionIntent(
            action: cancelling ? "task.cancel" : "task.update",
            resources: [PermissionResource(kind: .task, value: value?.taskID ?? "unknown")],
            metadata: [
                "expectedRevision": .number(Double(value?.expectedRevision ?? -1)),
                "status": value?.status.map { .string($0.rawValue) } ?? .null,
                "retry": .bool(value?.retry ?? false),
            ],
            dataEffects: [.none],
            controlEffects: [cancelling ? .cancelTask : .updateTask],
            risks: [.controlPlaneMutation],
            replayPolicy: .requiresManualReconciliation)
    }

    public func permissionActionPreview(
        _ args: ToolArgs
    ) -> PermissionActionPreview? {
        guard let value = try? args.decode(Args.self) else { return nil }
        var changedFields: [String] = []
        if value.title != nil { changedFields.append("title") }
        if value.description != nil { changedFields.append("description") }
        if value.acceptanceCriteria != nil { changedFields.append("acceptance_criteria") }
        if value.expectedArtifacts != nil { changedFields.append("expected_artifacts") }
        if value.owner != nil { changedFields.append("owner") }
        if value.dependsOn != nil { changedFields.append("depends_on") }
        if value.priority != nil { changedFields.append("priority") }
        if value.progressNote != nil { changedFields.append("progress_note") }
        if value.status != nil { changedFields.append("status") }
        if value.result != nil { changedFields.append("result") }
        if value.evidence != nil { changedFields.append("evidence") }
        if value.retry != nil { changedFields.append("retry") }
        return PermissionActionPreview(
            kind: Self.descriptor.name,
            fields: [
                "task_id": value.taskID,
                "expected_revision": String(value.expectedRevision),
                "status": value.status?.rawValue ?? "unchanged",
                "changed_fields": changedFields.joined(separator: ", "),
                "progress_note": value.progressNote ?? "",
                "result": value.result ?? "",
                "evidence_count": String(value.evidence?.count ?? 0),
                "retry": String(value.retry ?? false),
            ])
    }

    static func decodeRequest(_ args: ToolArgs) throws -> WorkTaskUpdateRequest {
        let value = try args.decode(Args.self)
        let owner: WorkTaskOwnerUpdate
        if let rawOwner = value.owner {
            let normalized = rawOwner.trimmingCharacters(in: .whitespacesAndNewlines)
            owner = normalized.isEmpty || ["none", "unassigned"].contains(normalized.lowercased())
                ? .unassigned
                : .agent(normalizedWorkTaskAgentID(normalized))
        } else {
            owner = .unchanged
        }
        return WorkTaskUpdateRequest(
            taskID: WorkTaskID(rawValue: value.taskID),
            expectedRevision: value.expectedRevision,
            title: value.title,
            description: value.description,
            acceptanceCriteria: value.acceptanceCriteria,
            expectedArtifacts: value.expectedArtifacts,
            owner: owner,
            dependsOn: value.dependsOn?.map { WorkTaskID(rawValue: $0) },
            priority: value.priority,
            progressNote: value.progressNote,
            status: value.status,
            result: value.result,
            evidence: value.evidence,
            isRetry: value.retry ?? false)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let request = try Self.decodeRequest(args)
        guard let manager = context.workTaskManager else {
            return ToolObservation(text: "WorkTask management is not available in this session")
        }
        do {
            let detail = try await manager.updateWorkTask(request)
            return ToolObservation(text: try encodeWorkTaskToolResult(detail))
        } catch {
            throw workTaskNamespaceHint(
                rawID: request.taskID.rawValue,
                underlyingError: error)
        }
    }
}

public struct TaskGetTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "task_get",
        description: "Read one authoritative durable WorkTask (normally wt_…), including dependency states, downstream tasks, linked AgentInvocations, candidate results, evidence, and revision. Do not pass an AgentInvocation task_… ID.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "task_id": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                    "description": .string("Durable WorkTask ID, normally wt_…. Do not pass an AgentInvocation task_… ID."),
                ]),
            ]),
            "required": .array([.string("task_id")]),
            "additionalProperties": .bool(false),
        ]))

    private struct Args: Decodable {
        var taskID: String
        enum CodingKeys: String, CodingKey { case taskID = "task_id" }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "task.get",
            resources: [PermissionResource(kind: .task, value: value?.taskID ?? "unknown")],
            dataEffects: [.read],
            replayPolicy: .safeToReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        guard let manager = context.workTaskManager else {
            return ToolObservation(text: "WorkTask management is not available in this session")
        }
        do {
            return ToolObservation(text: try encodeWorkTaskToolResult(
                await manager.getWorkTask(WorkTaskID(rawValue: value.taskID))))
        } catch {
            throw workTaskNamespaceHint(
                rawID: value.taskID,
                underlyingError: error)
        }
    }
}

public struct TaskListTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "task_list",
        description: "List the authoritative WorkTask projection in stable creation order. Use this instead of guessing state from old chat text. run_id accepts current, goal, or an explicit run_* ID; status and owner are optional filters. Goal-history access remains host-authorized.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "run_id": workTaskStringSchema,
                "status": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string(WorkTaskStatus.pending.rawValue),
                            .string(WorkTaskStatus.ready.rawValue),
                            .string(WorkTaskStatus.inProgress.rawValue),
                            .string(WorkTaskStatus.blocked.rawValue),
                            .string(WorkTaskStatus.completed.rawValue),
                            .string(WorkTaskStatus.failed.rawValue),
                            .string(WorkTaskStatus.cancelled.rawValue),
                        ]),
                    ]),
                ]),
                "owner": .object(["type": .string("string")]),
            ]),
            "required": .array([]),
            "additionalProperties": .bool(false),
        ]))

    private struct Args: Decodable {
        var runID: String?
        var status: [WorkTaskStatus]?
        var owner: String?
        enum CodingKeys: String, CodingKey {
            case status, owner
            case runID = "run_id"
        }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "task.list",
            resources: [PermissionResource(kind: .task, value: value?.runID ?? "current-run")],
            dataEffects: [.read],
            replayPolicy: .safeToReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        guard let manager = context.workTaskManager else {
            return ToolObservation(text: "WorkTask management is not available in this session")
        }
        let normalizedRun = value.runID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOwner = value.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = WorkTaskListRequest(
            runID: normalizedRun.flatMap {
                $0.isEmpty || $0.lowercased() == "current" || $0.lowercased() == "goal"
                    ? nil
                    : ContinuationRunID(rawValue: $0)
            },
            includeGoalHistory: normalizedRun?.lowercased() == "goal",
            statuses: Set(value.status ?? []),
            owner: normalizedOwner.flatMap {
                $0.isEmpty || $0.lowercased() == "any" || $0.lowercased() == "unassigned"
                    ? nil
                    : normalizedWorkTaskAgentID($0)
            },
            unassignedOnly: normalizedOwner?.lowercased() == "unassigned")
        struct Response: Encodable { var tasks: [WorkTaskDetail] }
        return ToolObservation(text: try encodeWorkTaskToolResult(
            Response(tasks: await manager.listWorkTasks(request))))
    }
}
