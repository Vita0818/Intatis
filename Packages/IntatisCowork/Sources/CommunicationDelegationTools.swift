import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

public struct SendMessageTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "send_message",
        description: "Send a message to another attached agent without creating a task.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "to": .object(["type": .string("string"), "description": .string("target agent name")]),
                "content": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("to"), .string("content")]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable { let to: String; let content: String }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "agent.message",
            resources: [PermissionResource(kind: .agent, value: value?.to ?? "unknown")],
            metadata: ["contentLength": .number(Double(value?.content.count ?? 0))],
            dataEffects: [.none],
            controlEffects: [.message],
            risks: [.controlPlaneMutation],
            replayPolicy: .requiresManualReconciliation)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            throw IntatisError.io("agent messaging is not available in this session")
        }
        return try Self.checked(
            await messenger.sendMessage(to: a.to, content: a.content),
            successPrefix: "sent message to @")
    }
}

public struct RequestInformationTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "request_information",
        description: "Ask another attached agent for information without creating a delegated task.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "to": .object(["type": .string("string"), "description": .string("target agent name")]),
                "question": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("to"), .string("question")]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable { let to: String; let question: String }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "information.request",
            resources: [PermissionResource(kind: .agent, value: value?.to ?? "unknown")],
            metadata: ["questionLength": .number(Double(value?.question.count ?? 0))],
            dataEffects: [.none],
            controlEffects: [.message],
            risks: [.controlPlaneMutation],
            replayPolicy: .requiresManualReconciliation)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            throw IntatisError.io("agent messaging is not available in this session")
        }
        return try Self.checked(
            await messenger.requestInformation(to: a.to, question: a.question),
            successPrefix: "requested information from @")
    }
}

public struct ReplyMessageTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "reply_message",
        description: "Reply to another agent's message or information request without creating a task.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "to": .object(["type": .string("string"), "description": .string("target agent name")]),
                "content": .object(["type": .string("string")]),
                "inReplyTo": .object(["type": .string("string"), "description": .string("optional message id")]),
            ]),
            "required": .array([.string("to"), .string("content")]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable { let to: String; let content: String; let inReplyTo: String? }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        var metadata: [String: JSONValue] = [
            "contentLength": .number(Double(value?.content.count ?? 0)),
        ]
        if let replyID = value?.inReplyTo { metadata["inReplyTo"] = .string(replyID) }
        return PermissionIntent(
            action: "information.reply",
            resources: [PermissionResource(kind: .agent, value: value?.to ?? "unknown")],
            metadata: metadata,
            dataEffects: [.none],
            controlEffects: [.message],
            risks: [.controlPlaneMutation],
            replayPolicy: .requiresManualReconciliation)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            throw IntatisError.io("agent messaging is not available in this session")
        }
        return try Self.checked(await messenger.replyMessage(
            to: a.to,
            content: a.content,
            inReplyTo: a.inReplyTo),
            successPrefix: "replied to @")
    }
}

public struct RequestDelegationTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "request_delegation",
        description: "Ask the assigning agent or orchestrator for additional help without spawning agents or creating tasks.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "objective": .object(["type": .string("string")]),
                "reason": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("objective"), .string("reason")]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable { let objective: String; let reason: String }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "task.delegation.request",
            resources: [PermissionResource(kind: .task, value: "current")],
            metadata: [
                "objectiveLength": .number(Double(value?.objective.count ?? 0)),
                "reasonLength": .number(Double(value?.reason.count ?? 0)),
            ],
            dataEffects: [.none],
            controlEffects: [.message],
            risks: [.controlPlaneMutation],
            replayPolicy: .requiresManualReconciliation)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            throw IntatisError.io("agent messaging is not available in this session")
        }
        return try Self.checked(await messenger.requestDelegation(
            objective: a.objective,
            reason: a.reason),
            successPrefix: "delegation request delivered to @")
    }
}

public struct DelegateTaskTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "delegate_task",
        description: "Run one ready durable WorkTask by ID. The WorkTask remains the source of truth, "
            + "and the invocation report is only a candidate result until task_update explicitly settles it. "
            + "Legacy unscoped calls may provide objective instead. If 'to' names an attached agent it is reused; "
            + "if that name does not exist, or 'to' is omitted/'auto', Intatis reuses an idle worker "
            + "or atomically creates a worker in your current workspace. Returns invocation task_id, agent_id, and the mediated Task Report.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "to": .object(["type": .string("string"), "description": .string("target agent name")]),
                "work_task_id": .object(["type": .string("string"), "description": .string("ready durable WorkTask ID")]),
                "objective": .object(["type": .string("string"), "description": .string("legacy unscoped invocation objective")]),
                "role_hint": .object(["type": .string("string")]),
                "expected_deliverable": .object(["type": .string("string")]),
                // Compatibility aliases for previously emitted tool calls.
                "roleHint": .object(["type": .string("string")]),
                "expectedDeliverable": .object(["type": .string("string")]),
            ]),
            "required": .array([]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable {
        let to: String?
        let workTaskID: WorkTaskID?
        let objective: String?
        let roleHint: String?
        let expectedDeliverable: String?

        enum CodingKeys: String, CodingKey {
            case to
            case workTaskID = "work_task_id"
            case objective
            case roleHint = "role_hint"
            case expectedDeliverable = "expected_deliverable"
            case legacyRoleHint = "roleHint"
            case legacyExpectedDeliverable = "expectedDeliverable"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            to = try container.decodeIfPresent(String.self, forKey: .to)
            workTaskID = try container.decodeIfPresent(WorkTaskID.self, forKey: .workTaskID)
            objective = try container.decodeIfPresent(String.self, forKey: .objective)
            roleHint = try container.decodeIfPresent(String.self, forKey: .roleHint)
                ?? container.decodeIfPresent(String.self, forKey: .legacyRoleHint)
            expectedDeliverable = try container.decodeIfPresent(String.self, forKey: .expectedDeliverable)
                ?? container.decodeIfPresent(String.self, forKey: .legacyExpectedDeliverable)
        }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "task.delegate",
            resources: [
                PermissionResource(kind: .agent, value: value?.to ?? "auto"),
                PermissionResource(kind: .task, value: value?.workTaskID?.rawValue ?? "new"),
                PermissionResource(
                    kind: .workspace,
                    value: workspaceRoot.standardizedFileURL.path,
                    access: .readOnly),
            ],
            metadata: [
                "objectiveLength": .number(Double(value?.objective?.count ?? 0)),
                "roleHint": value?.roleHint.map(JSONValue.string) ?? .null,
                "mayCreateWorker": .bool(true),
            ],
            dataEffects: [.none],
            controlEffects: [.delegateTask, .createAgent, .attachWorkspace, .grantCapability],
            risks: [.controlPlaneMutation, .capabilityGrant, .modelCost],
            replayPolicy: .requiresManualReconciliation)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            throw IntatisError.io("agent delegation is not available in this session")
        }
        guard a.workTaskID != nil
                || !(a.objective?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            throw IntatisError.decoding("delegate_task requires work_task_id or a legacy objective")
        }
        guard let authorization = context.authorization,
              authorization.toolName == Self.descriptor.name,
              let concreteTarget = authorization.intent.resources.first(where: {
                  $0.kind == .agent
              })?.value,
              !concreteTarget.isEmpty,
              concreteTarget.lowercased() != "auto" else {
            throw IntatisError.permissionDenied(
                "delegate_task requires a concrete host-resolved target authorization")
        }
        return try Self.checked(await messenger.delegateTask(
            authorization: authorization,
            to: concreteTarget,
            workTaskID: a.workTaskID,
            objective: a.objective,
            roleHint: a.roleHint,
            expectedDeliverable: a.expectedDeliverable),
            successPrefix: "task_id=")
    }
}

private extension Tool {
    static func checked(_ result: String, successPrefix: String) throws -> ToolObservation {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(successPrefix) else {
            let message = trimmed.lowercased().hasPrefix("error:")
                ? String(trimmed.dropFirst("error:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : trimmed
            throw IntatisError.io(message.isEmpty ? "tool operation did not complete" : message)
        }
        return ToolObservation(text: trimmed)
    }
}
