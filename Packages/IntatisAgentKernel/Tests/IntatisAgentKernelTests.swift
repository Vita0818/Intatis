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

private struct PartialThenFailingToolProvider: ToolCallingProvider {
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("partial"))
            continuation.finish(throwing: IntatisError.decoding(
                "tool-calling streaming request ended before a completion marker. Check endpoint compatibility."))
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
                          responder: PermissionResponder,
                          includeUsage: Bool = false) -> AgentLoop {
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
            git: NoGit(),
            includeUsage: includeUsage
        )
    }

    private func toolResults(in log: EventLog) async -> [ToolResultPayload] {
        await log.replay().compactMap { envelope in
            guard case .toolResult(let payload) = envelope.event else { return nil }
            return payload
        }
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

    func testAgentLoopPreservesPartialTextWhenStreamEndsWithoutCompletionMarker() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let loop = makeLoop(ws: ws,
                            log: log,
                            provider: PartialThenFailingToolProvider(),
                            responder: FixedResponder(.allow))

        do {
            try await loop.send("inspect")
            XCTFail("expected incomplete stream error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("completion marker"))
        }

        let projection = CodeProjection.build(from: await log.replay())
        let agentItem = projection.items.first { $0.kind == .agent }
        XCTAssertEqual(agentItem?.body, "partial")
        XCTAssertEqual(agentItem?.complete, false)
        XCTAssertEqual(agentItem?.recoveryAdvice?.title, "Response stopped before completion")
        let errorItem = projection.items.first { $0.kind == .error }
        XCTAssertEqual(errorItem?.recoveryAdvice?.title, "Check endpoint compatibility")
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
        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertTrue(types.contains(.permissionRequest))
        let result = events.compactMap { envelope -> ToolResultPayload? in
            if case .toolResult(let payload) = envelope.event { return payload }
            return nil
        }.first
        XCTAssertTrue(result?.observation.contains("user denied") == true)
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

    func testAgentLoopMergesResponseUsageThenAccumulatesAcrossToolIterations() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }
        try Data("data".utf8).write(to: ws.appendingPathComponent("in.txt"))

        let provider = ScriptedProvider([
            [
                .usage(Usage(promptTokens: 10, cachedPromptTokens: 4)),
                .usage(Usage(completionTokens: 1, totalTokens: 11)),
                .toolCalls([ToolCall(id: "read", name: "read_file", arguments: #"{"path":"in.txt"}"#)]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("Done."),
                .usage(Usage(promptTokens: 5, cachedPromptTokens: 1)),
                .usage(Usage(completionTokens: 2, totalTokens: 7)),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = makeLoop(ws: ws,
                            log: log,
                            provider: provider,
                            responder: FixedResponder(.deny),
                            includeUsage: true)

        try await loop.send("read in.txt")

        let stats = await log.replay().compactMap { envelope -> TurnStatsPayload? in
            guard case .turnStats(let payload) = envelope.event else { return nil }
            return payload
        }.last
        XCTAssertEqual(stats?.promptTokens, 15)
        XCTAssertEqual(stats?.cachedPromptTokens, 5)
        XCTAssertEqual(stats?.completionTokens, 3)
        XCTAssertEqual(stats?.totalTokens, 18)
    }

    func testInvalidJSONToolArgumentsDoNotRequestPermissionOrExecuteTool() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "bad_json",
                                  name: "write_file",
                                  arguments: #"{"path":"out.txt","content":"unterminated"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I need valid JSON."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("create out.txt")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("out.txt").path))
        XCTAssertFalse(types.contains(.permissionRequest))
        XCTAssertFalse(types.contains(.patchProposed))
        let result = await toolResults(in: log).first
        XCTAssertTrue(result?.observation.hasPrefix("invalid tool input:") == true)
        XCTAssertTrue(result?.observation.contains("write_file") == true)
    }

    func testNonObjectToolArgumentsDoNotRequestPermissionOrExecuteTool() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "not_object",
                                  name: "write_file",
                                  arguments: #""out.txt""#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I need an object."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("create out.txt")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("out.txt").path))
        XCTAssertFalse(types.contains(.permissionRequest))
        let result = await toolResults(in: log).first
        XCTAssertEqual(result?.observation, "invalid tool input: arguments for write_file must be a JSON object matching the tool schema.")
    }

    func testMissingRequiredToolArgumentsDoNotRequestPermissionOrExecuteTool() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "missing_required",
                                  name: "write_file",
                                  arguments: #"{"path":"out.txt"}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I need content."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("create out.txt")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("out.txt").path))
        XCTAssertFalse(types.contains(.permissionRequest))
        XCTAssertFalse(types.contains(.patchProposed))
        let result = await toolResults(in: log).first
        XCTAssertEqual(result?.observation, "invalid tool input: arguments for write_file are missing required field(s): content.")
    }

    func testWrongTypeToolArgumentsDoNotRequestPermissionOrExecuteTool() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "wrong_type",
                                  name: "write_file",
                                  arguments: #"{"path":"out.txt","content":42}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I need text content."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("create out.txt")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("out.txt").path))
        XCTAssertFalse(types.contains(.permissionRequest))
        let result = await toolResults(in: log).first
        XCTAssertEqual(result?.observation, "invalid tool input: argument content for write_file must be string.")
    }

    func testNumericConstraintToolArgumentsDoNotRequestPermissionOrExecuteTool() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }
        try Data("data".utf8).write(to: ws.appendingPathComponent("in.txt"))

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "bad_limit",
                                  name: "read_file",
                                  arguments: #"{"path":"in.txt","maxBytes":0}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I need a positive byte limit."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("read in.txt")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertFalse(types.contains(.permissionRequest))
        let result = await toolResults(in: log).first
        XCTAssertEqual(result?.observation, "invalid tool input: argument maxBytes for read_file must be >= 1.")
    }

    func testStringLengthToolArgumentsDoNotRequestPermissionOrExecuteTool() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "empty_command",
                                  name: "run_shell",
                                  arguments: #"{"command":""}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I need a command."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("run an empty command")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertFalse(types.contains(.permissionRequest))
        let result = await toolResults(in: log).first
        XCTAssertEqual(result?.observation, "invalid tool input: argument command for run_shell must have at least 1 character.")
    }

    func testUnknownToolArgumentsDoNotRequestPermissionOrExecuteTool() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "unknown_field",
                                  name: "write_file",
                                  arguments: #"{"path":"out.txt","content":"hello","overwrite":true}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I should only use known fields."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("create out.txt")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("out.txt").path))
        XCTAssertFalse(types.contains(.permissionRequest))
        XCTAssertFalse(types.contains(.patchProposed))
        let result = await toolResults(in: log).first
        XCTAssertEqual(result?.observation,
                       "invalid tool input: arguments for write_file contain unknown field(s): overwrite. Allowed fields: content, path.")
    }

    func testEmptyArgumentsAreNormalizedForNoArgumentTools() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "status", name: "git_status", arguments: "")]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Clean."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.deny))

        try await loop.send("show git status")

        let events = await log.replay()
        let result = await toolResults(in: log).first
        XCTAssertFalse(events.map { $0.event.type }.contains(.permissionRequest))
        XCTAssertEqual(result?.observation, "clean")
    }

    func testNoArgumentToolsRejectUnknownArguments() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "status_with_extra",
                                  name: "git_status",
                                  arguments: #"{"path":"."}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("No extra fields."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.deny))

        try await loop.send("show git status")

        let events = await log.replay()
        let result = await toolResults(in: log).first
        XCTAssertFalse(events.map { $0.event.type }.contains(.permissionRequest))
        XCTAssertEqual(result?.observation,
                       "invalid tool input: arguments for git_status contain unknown field(s): path. Allowed fields: no fields.")
    }
}
