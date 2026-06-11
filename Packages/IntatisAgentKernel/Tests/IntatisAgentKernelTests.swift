import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
@testable import IntatisAgentKernel

/// Replays a scripted sequence of chunk-lists, one per `stream` call.
private final class ScriptedProvider: ToolCallingProvider, @unchecked Sendable {
    private var responses: [[AgentChunk]]
    private var index = 0
    private let lock = NSLock()

    init(_ responses: [[AgentChunk]]) { self.responses = responses }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        let chunks = responses[min(index, responses.count - 1)]
        index += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private struct NoShell: ShellRunner {
    func run(_ command: String, cwd: URL) async throws -> ShellResult { ShellResult(stdout: "", stderr: "", exitCode: 0) }
}
private struct NoGit: GitService {
    func status(workspace: URL) async throws -> String { "" }
    func diff(workspace: URL) async throws -> String { "" }
}

final class IntatisAgentKernelTests: XCTestCase {

    private func workspaceAndLog() throws -> (URL, EventLog) {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-kernel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let log = try EventLog(session: SessionID(rawValue: "sess_k"),
                               fileURL: ws.appendingPathComponent(".log/events.jsonl"))
        return (ws, log)
    }

    private func writeArgs(path: String, content: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["path": path, "content": content])
        return String(decoding: data, as: UTF8.self)
    }

    private func makeLoop(ws: URL, log: EventLog, provider: ToolCallingProvider,
                          responder: PermissionResponder) -> AgentLoop {
        AgentLoop(
            log: log,
            provider: provider,
            registry: .standard(),
            engine: PermissionEngine(),
            responder: responder,
            agent: Agent(name: AgentID(rawValue: "Coder"), workspaceRoot: ws,
                         model: ModelID(rawValue: "m"), profile: .reviewed),
            allowsShell: true,
            shell: NoShell(),
            git: NoGit()
        )
    }

    func testApprovedWriteExecutesAndLogs() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "c1", name: "write_file", arguments: writeArgs(path: "out.txt", content: "hello"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Done."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))
        try await loop.send("create out.txt with hello")

        let written = try String(contentsOf: ws.appendingPathComponent("out.txt"), encoding: .utf8)
        XCTAssertEqual(written, "hello")

        let types = await log.replay().map { $0.event.type }
        XCTAssertTrue(types.contains(.toolCall))
        XCTAssertTrue(types.contains(.permissionRequest))   // write in reviewed → pass → no reviewer → ask
        XCTAssertTrue(types.contains(.toolResult))
        XCTAssertTrue(types.contains(.messageCompleted))
    }

    func testDeniedWriteDoesNotExecute() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "c1", name: "write_file", arguments: writeArgs(path: "out.txt", content: "x"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Okay, I won't."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.deny))
        try await loop.send("create out.txt")

        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("out.txt").path))
        let types = await log.replay().map { $0.event.type }
        XCTAssertTrue(types.contains(.permissionRequest))
    }

    func testReadOnlyToolNeedsNoApproval() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }
        try Data("data".utf8).write(to: ws.appendingPathComponent("in.txt"))

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "c1", name: "read_file", arguments: #"{"path":"in.txt"}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("It says data."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.deny))
        try await loop.send("read in.txt")

        let types = await log.replay().map { $0.event.type }
        XCTAssertTrue(types.contains(.toolResult))
        XCTAssertFalse(types.contains(.permissionRequest))   // reads are auto-allowed
    }
}
