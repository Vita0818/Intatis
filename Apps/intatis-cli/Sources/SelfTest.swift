import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation
import IntatisTools
import IntatisPermission
import IntatisAgentKernel

// Built-in fake models — let `intatis selftest` prove the chat + code paths work
// offline, with no API key and no network. They drive the exact same ChatLoop /
// AgentLoop / renderer / approval code the real commands use.

private struct FakeChat: ChatProvider {
    let parts: [String]
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { c in
            for p in parts { c.yield(.delta(p)) }
            c.yield(.done); c.finish()
        }
    }
}

private final class FakeAgent: ToolCallingProvider, @unchecked Sendable {
    private var turns: [[AgentChunk]]
    private var i = 0
    private let lock = NSLock()
    init(_ turns: [[AgentChunk]]) { self.turns = turns }
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        let turn = turns.isEmpty ? [.done(finishReason: "stop")] : turns[min(i, turns.count - 1)]
        i += 1
        lock.unlock()
        return AsyncThrowingStream { c in
            for x in turn { c.yield(x) }
            c.finish()
        }
    }
}

private func tempLog(_ tag: String) throws -> EventLog {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-\(tag)-\(UUID().uuidString)", isDirectory: true)
    return try EventLog(session: SessionID.new(), fileURL: dir.appendingPathComponent("events.jsonl"))
}

private let green = "\u{001B}[32m", red = "\u{001B}[31m", bold = "\u{001B}[1m", reset = "\u{001B}[0m"

func runSelfTest() async throws {
    out("\(bold)Intatis self-test\(reset) — offline, no API key, no network.\n")

    // 1) CHAT: a full streamed turn.
    out("\n\(bold)[chat]\(reset)\n› hi")
    let chatLog = try tempLog("chat")
    let chatLoop = ChatLoop(log: chatLog,
                            provider: FakeChat(parts: ["Hello! ", "I am Intatis."]),
                            model: ModelID(rawValue: "fake"))
    let r1 = Task { await renderLoop(chatLog) }
    try await chatLoop.send("hi")
    try? await Task.sleep(nanoseconds: 60_000_000)
    r1.cancel()
    let chatMsgs = ConversationProjection.build(from: await chatLog.replay()).messages
    let okChat = chatMsgs.contains { $0.role == .assistant && $0.text == "Hello! I am Intatis." }
    out(okChat ? "\(green)PASS\(reset) streamed a complete reply\n"
               : "\(red)FAIL\(reset) chat reply not assembled\n")

    // 2) CODE: write a file, then read it back.
    out("\n\(bold)[code]\(reset)\n› create note.txt and read it back")
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("intatis-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let codeLog = try tempLog("code")
    let writeArgs = String(decoding: try JSONSerialization.data(
        withJSONObject: ["path": "note.txt", "content": "hello from intatis"]), as: UTF8.self)
    let agent = Agent(name: AgentID(rawValue: "selftest"), workspaceRoot: workspace,
                      model: ModelID(rawValue: "fake"), profile: .reviewed)
    let codeLoop = AgentLoop(
        log: codeLog,
        provider: FakeAgent([
            [.toolCalls([ToolCall(id: "c1", name: "write_file", arguments: writeArgs)]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(id: "c2", name: "read_file", arguments: #"{"path":"note.txt"}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Wrote and read note.txt."), .done(finishReason: "stop")],
        ]),
        registry: .standard(),
        engine: PermissionEngine(),
        responder: FixedResponder(.allow),   // auto-approve writes for the self-test
        agent: agent,
        allowsShell: true
    )
    let r2 = Task { await renderLoop(codeLog) }
    _ = try await codeLoop.send("create note.txt and read it back")
    try? await Task.sleep(nanoseconds: 60_000_000)
    r2.cancel()
    let onDisk = (try? String(contentsOf: workspace.appendingPathComponent("note.txt"), encoding: .utf8)) ?? ""
    let okCode = onDisk == "hello from intatis"
    out(okCode ? "\(green)PASS\(reset) wrote + read note.txt in the workspace\n"
               : "\(red)FAIL\(reset) file not written (got: \(onDisk.isEmpty ? "<empty>" : onDisk))\n")

    out("\n" + (okChat && okCode
        ? "\(green)\(bold)All good.\(reset) Point it at a real endpoint:\n  INTATIS_API_KEY=sk-... swift run intatis chat\n"
        : "\(red)\(bold)Self-test failed.\(reset)\n"))
}
