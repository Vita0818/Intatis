import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

/// The only way one agent can reach another. It carries a question (a summary,
/// not raw files) through the injected `AgentMessenger`, which routes via the
/// mediated Message Bus. Declared `readOnly` because it has no local side effects
/// — content safety is the Mediator's job, not the permission gate's.
public struct AskAgentTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "ask_agent",
        description: "Ask another attached agent a question. Provide a concise summary or interface "
            + "question, never raw file contents. Returns their answer.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "to": .object(["type": .string("string"), "description": .string("target agent name")]),
                "question": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("to"), .string("question")]),
        ])
    )

    struct Args: Decodable { let to: String; let question: String }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard let messenger = context.messenger else {
            return ToolObservation(text: "agent messaging is not available in this session")
        }
        let answer = await messenger.ask(to: a.to, question: a.question)
        return ToolObservation(text: answer)
    }
}
