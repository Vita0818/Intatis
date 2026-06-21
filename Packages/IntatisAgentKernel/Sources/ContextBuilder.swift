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

    If you are given agent-coordination tools (spawn_agent, list_agents,
    remove_agent, ask_agent) you may also act as a coordinator: create specialized
    sub-agents bound to specific folders with spawn_agent, delegate concrete
    sub-tasks to them with ask_agent, and remove them with remove_agent when done.
    You can only reach other agents through ask_agent (there is no shared memory),
    so send concise, self-contained instructions — never raw file contents. Do
    simple work yourself; delegate only when a task is large or needs its own
    workspace.
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
