import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
@testable import IntatisAgentKernel

private final class ContextCapturingProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequests: [AgentRequest] = []

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequests.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("done"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

final class ContextProjectionTests: XCTestCase {
    private let session = SessionID(rawValue: "sess_context")
    private let main = AgentID(rawValue: "main")
    private let macos = AgentID(rawValue: "macos-counter")
    private let ios = AgentID(rawValue: "ios-counter")

    private func envelope(_ seq: Int, _ event: Event) -> Envelope {
        Envelope(seq: seq, session: session, event: event)
    }

    private func macosContract() -> TaskContract {
        TaskContract(
            id: TaskID(rawValue: "task_macos"),
            issuer: main,
            assignee: macos,
            objective: "Recursively count macOS Swift files only.",
            roleHint: "macOS Swift file counter",
            expectedDeliverable: "Swift file count and path list.",
            relatedAgents: [ios],
            constraints: [
                "Complete only the assigned task.",
                "Do not re-run the global task decomposition.",
                "Do not create, remove, or coordinate other agents.",
            ])
    }

    private func projectionEvents(contract: TaskContract) -> [Envelope] {
        [
            envelope(1, .userMessage(UserMessagePayload(
                text: "拉起两个子 Agent，分别对本文件夹下的 macOS 和 iOS Swift 文件进行计数。"))),
            envelope(2, .userMessage(UserMessagePayload(
                text: "Unrelated raw global transcript that must not appear: IOS_SECRET_CONTEXT"))),
            envelope(3, .taskCreated(TaskCreatedPayload(contract: contract))),
            envelope(4, .taskAssigned(TaskAssignedPayload(contract: contract))),
            envelope(5, .agentToAgentMessage(AgentToAgentMessagePayload(
                from: main,
                to: macos,
                content: "Count macOS Swift files only.",
                mediated: true))),
            envelope(6, .agentToAgentMessage(AgentToAgentMessagePayload(
                from: main,
                to: ios,
                content: "Count iOS Swift files only. iOS workspace detail: /ios/private/App.swift",
                mediated: true))),
            envelope(7, .toolCall(ToolCallPayload(
                toolCallId: "ios-search",
                agent: ios,
                name: "search_text",
                args: #"{"path":"/ios/private/App.swift","pattern":"IOS_PRIVATE_TOOL_EVENT"}"#))),
            envelope(8, .messageCompleted(MessageCompletedPayload(
                messageId: MessageID(rawValue: "ios-answer"),
                role: .agent,
                agent: ios,
                text: "iOS private count result should not be projected."))),
            envelope(9, .agentToAgentMessage(AgentToAgentMessagePayload(
                from: macos,
                to: main,
                content: "macOS count is in progress.",
                mediated: true))),
            envelope(10, .artifactAdded(ArtifactAddedPayload(
                artifactId: ArtifactID(rawValue: "art_shared"),
                kind: "text",
                mime: "text/plain",
                path: "/tmp/shared.txt",
                producedBy: "main"))),
        ]
    }

    func testAgentContextIncludesTaskContractLineageAndDirectMessages() throws {
        let contract = macosContract()
        let bundle = ContextProjector().project(
            agentID: macos,
            taskContract: contract,
            events: projectionEvents(contract: contract),
            allowedToolNames: ["search_text", "read_file"],
            workspaceRoot: URL(fileURLWithPath: "/workspace/macos"))

        XCTAssertEqual(bundle.taskContract, contract)
        XCTAssertTrue(bundle.lineage.contains { $0.text.contains("@main assigned task task_macos to @macos-counter") })
        XCTAssertTrue(bundle.lineage.contains { $0.text.contains("responsible only for: Recursively count macOS Swift files only.") })
        XCTAssertEqual(bundle.directMessages.count, 1)
        XCTAssertEqual(bundle.directMessages.first?.sender, main)
        XCTAssertTrue(bundle.directMessages.first?.content.contains("macOS Swift files only") == true)
        XCTAssertEqual(bundle.explicitlySharedArtifacts, [ArtifactID(rawValue: "art_shared")])
        XCTAssertEqual(bundle.allowedToolNames, ["read_file", "search_text"])
    }

    func testAgentContextExcludesUnrelatedTranscriptAndOtherAgentPrivateEvents() {
        let contract = macosContract()
        let bundle = ContextProjector().project(
            agentID: macos,
            taskContract: contract,
            events: projectionEvents(contract: contract),
            allowedToolNames: ["read_file"],
            workspaceRoot: URL(fileURLWithPath: "/workspace/macos"))

        let projectedText = [
            bundle.globalBrief,
            bundle.lineage.map(\.text).joined(separator: "\n"),
            bundle.directMessages.map(\.content).joined(separator: "\n"),
            bundle.agentLocalEvents.map(\.content).joined(separator: "\n"),
            bundle.workspaceBrief ?? "",
        ].joined(separator: "\n")

        XCTAssertFalse(projectedText.contains("IOS_SECRET_CONTEXT"))
        XCTAssertFalse(projectedText.contains("/ios/private/App.swift"))
        XCTAssertFalse(projectedText.contains("IOS_PRIVATE_TOOL_EVENT"))
        XCTAssertFalse(projectedText.contains("iOS private count result"))
        XCTAssertTrue(projectedText.contains("macOS count is in progress."))
    }

    func testMacOSCounterProjectionMentionsSiblingWithoutIOSWorkspaceDetails() {
        let contract = macosContract()
        let bundle = ContextProjector().project(
            agentID: macos,
            taskContract: contract,
            events: projectionEvents(contract: contract),
            allowedToolNames: ["read_file"],
            workspaceRoot: URL(fileURLWithPath: "/workspace/macos"))
        let prompt = ContextBuilder(systemPrompt: "system", contextBundle: bundle)
            .initialMessages(history: [], userText: "Count macOS Swift files only.")
            .first?.content ?? ""

        XCTAssertTrue(prompt.contains("macOS Swift file counter"))
        XCTAssertTrue(prompt.contains("Recursively count macOS Swift files only."))
        XCTAssertTrue(prompt.contains("@ios-counter"))
        XCTAssertFalse(prompt.contains("/ios/private/App.swift"))
        XCTAssertFalse(prompt.contains("Count iOS Swift files only"))
    }

    func testWorkerPromptDoesNotReplayOriginalSpawnInstructionAsFreshUserMessage() async throws {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }
        let log = try EventLog(session: session, fileURL: ws.appendingPathComponent("events.jsonl"))
        try await log.append(.userMessage(UserMessagePayload(
            text: "拉起两个子 Agent，分别对 macOS 和 iOS Swift 文件计数。")))

        let contract = macosContract()
        let bundle = ContextProjector().project(
            agentID: macos,
            taskContract: contract,
            events: await log.replay(),
            allowedToolNames: ["read_file"],
            workspaceRoot: ws)
        let provider = ContextCapturingProvider()
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: ToolRegistry([ReadFileTool()]),
            engine: PermissionEngine(),
            responder: FixedResponder(.allow),
            agent: Agent(name: macos, workspaceRoot: ws, model: ModelID(rawValue: "m"), profile: .reviewed),
            context: ContextBuilder(systemPrompt: "system", contextBundle: bundle),
            allowsShell: false)

        try await loop.send("Count macOS Swift files only.")

        let request = try XCTUnwrap(provider.requests.first)
        let userMessages = request.messages.filter { $0.role == .user }.compactMap(\.content)
        XCTAssertEqual(userMessages, ["Count macOS Swift files only."])
        XCTAssertFalse(userMessages.joined(separator: "\n").contains("拉起两个子 Agent"))
        let systemPrompt = try XCTUnwrap(request.messages.first?.content)
        XCTAssertTrue(systemPrompt.contains("Scoped context:"))
        XCTAssertTrue(systemPrompt.contains("Lineage:"))
        XCTAssertTrue(systemPrompt.contains("Allowed tools:"))
    }
}
