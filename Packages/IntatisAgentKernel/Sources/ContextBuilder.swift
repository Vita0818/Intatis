import Foundation
import IntatisProviders
import IntatisTools

/// Builds the model request: system prompt + tool specs + message history.
public struct ContextBuilder: Sendable {
    public let systemPrompt: String

    public init(systemPrompt: String = ContextBuilder.defaultSystemPrompt) {
        self.systemPrompt = systemPrompt
    }

    public static let defaultSystemPrompt = """
    You are an Intatis coding agent working inside a single local workspace.
    Use the provided tools to read, search, and edit files. Prefer small, focused
    changes. Read before you write. When you are done, briefly explain what you did.
    Never attempt to access files outside the workspace or read secrets.
    """

    /// Tool specs derived from a registry's descriptors.
    public func toolSpecs(_ registry: ToolRegistry) -> [ToolSpec] {
        registry.descriptors().map {
            ToolSpec(name: $0.name, description: $0.description, parameters: $0.parameters)
        }
    }

    /// system + prior history + the new user turn (optionally with images).
    public func initialMessages(history: [AgentMessage], userText: String,
                                userImages: [ImageAttachment] = []) -> [AgentMessage] {
        var messages: [AgentMessage] = [.system(systemPrompt)]
        messages.append(contentsOf: history)
        messages.append(.user(userText, images: userImages))
        return messages
    }
}
