import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
@testable import IntatisAgentKernel

private final class SubmissionHistoryCapturingProvider: ToolCallingProvider, @unchecked Sendable {
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
            continuation.yield(.textDelta("current response"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

final class SubmittedIntentHistoryTests: XCTestCase {
    func testRetryHistoryKeepsEarlierCompletedTurnAndExcludesCurrentAndLaterSubmissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "intatis-submission-history-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = try EventLog(
            session: SessionID(rawValue: "sess_submission_history"),
            fileURL: root.appendingPathComponent("events.jsonl"))
        let priorID = SubmissionID(rawValue: "sub_prior")
        let currentID = SubmissionID(rawValue: "sub_current")
        let laterID = SubmissionID(rawValue: "sub_later")

        try await log.append(.userMessage(UserMessagePayload(
            text: "prior submission",
            submissionID: priorID)))
        try await log.append(.userMessage(UserMessagePayload(
            text: "current submission",
            submissionID: currentID)))
        try await log.append(.userMessage(UserMessagePayload(
            text: "later queued submission",
            submissionID: laterID)))

        // The prior response may be appended after later submissions were
        // accepted. Logical submission order must still retain it.
        let priorMessageID = MessageID(rawValue: "msg_prior")
        try await log.append(.messageDelta(MessageDeltaPayload(
            messageId: priorMessageID,
            role: .agent,
            agent: AgentID(rawValue: "agent"),
            textDelta: "prior partial",
            submissionID: priorID)))
        try await log.append(.messageCompleted(MessageCompletedPayload(
            messageId: priorMessageID,
            role: .agent,
            agent: AgentID(rawValue: "agent"),
            text: "prior full response",
            submissionID: priorID)))

        // Output from an earlier failed attempt of the current submission and
        // output correlated with the later queued submission are both excluded.
        try await log.append(.messageCompleted(MessageCompletedPayload(
            messageId: MessageID(rawValue: "msg_current_stale"),
            role: .agent,
            agent: AgentID(rawValue: "agent"),
            text: "stale current response",
            submissionID: currentID)))
        try await log.append(.messageCompleted(MessageCompletedPayload(
            messageId: MessageID(rawValue: "msg_later"),
            role: .agent,
            agent: AgentID(rawValue: "agent"),
            text: "later response",
            submissionID: laterID)))

        let provider = SubmissionHistoryCapturingProvider()
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: ToolRegistry([]),
            engine: PermissionEngine(),
            responder: FixedResponder(.deny),
            agent: Agent(
                name: AgentID(rawValue: "agent"),
                workspaceRoot: root,
                model: ModelID(rawValue: "test-model"),
                profile: .reviewed),
            allowsShell: false)

        let result = try await loop.send(
            "current submission",
            recordUserMessage: false,
            submissionID: currentID)

        XCTAssertEqual(result, "current response")
        let request = try XCTUnwrap(provider.requests.first)
        let conversation = request.messages
            .filter { $0.role != .system }
            .map { ($0.role, $0.content) }
        XCTAssertEqual(conversation.count, 3)
        XCTAssertEqual(conversation[0].0, .user)
        XCTAssertEqual(conversation[0].1, "prior submission")
        XCTAssertEqual(conversation[1].0, .assistant)
        XCTAssertEqual(conversation[1].1, "prior full response")
        XCTAssertEqual(conversation[2].0, .user)
        XCTAssertEqual(conversation[2].1, "current submission")
        XCTAssertFalse(request.messages.contains { $0.content == "stale current response" })
        XCTAssertFalse(request.messages.contains { $0.content == "later queued submission" })
        XCTAssertFalse(request.messages.contains { $0.content == "later response" })

        let canonicalUsers = await log.replay().compactMap { envelope -> UserMessagePayload? in
            guard case .userMessage(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(canonicalUsers.compactMap(\.submissionID), [priorID, currentID, laterID])
        XCTAssertEqual(canonicalUsers.filter { $0.submissionID == currentID }.count, 1)
    }
}
