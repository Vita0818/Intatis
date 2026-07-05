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

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            return ToolObservation(text: "agent messaging is not available in this session")
        }
        return ToolObservation(text: await messenger.sendMessage(to: a.to, content: a.content))
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

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            return ToolObservation(text: "agent messaging is not available in this session")
        }
        return ToolObservation(text: await messenger.requestInformation(to: a.to, question: a.question))
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

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            return ToolObservation(text: "agent messaging is not available in this session")
        }
        return ToolObservation(text: await messenger.replyMessage(to: a.to, content: a.content, inReplyTo: a.inReplyTo))
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

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            return ToolObservation(text: "agent messaging is not available in this session")
        }
        return ToolObservation(text: await messenger.requestDelegation(objective: a.objective, reason: a.reason))
    }
}

public struct DelegateTaskTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "delegate_task",
        description: "Create a TaskContract for another attached agent. Requires delegation capability.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "to": .object(["type": .string("string"), "description": .string("target agent name")]),
                "objective": .object(["type": .string("string")]),
                "roleHint": .object(["type": .string("string")]),
                "expectedDeliverable": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("to"), .string("objective")]),
            "additionalProperties": .bool(false),
        ])
    )

    struct Args: Decodable {
        let to: String
        let objective: String
        let roleHint: String?
        let expectedDeliverable: String?
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            return ToolObservation(text: "agent delegation is not available in this session")
        }
        return ToolObservation(text: await messenger.delegateTask(
            to: a.to,
            objective: a.objective,
            roleHint: a.roleHint,
            expectedDeliverable: a.expectedDeliverable))
    }
}
