import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
@testable import IntatisConversation

private struct MockProvider: ChatProvider {
    let parts: [String]
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            for p in parts { continuation.yield(.delta(p)) }
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

final class IntatisConversationTests: XCTestCase {

    private func tmpFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-conv-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    func testAppendReplayAndResumeSeq() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = SessionID(rawValue: "sess_r")
        let log = try EventLog(session: s, fileURL: url)
        _ = try await log.append(.userMessage(.init(text: "a")))
        _ = try await log.append(.userMessage(.init(text: "b")))

        // Reload: seq continues from the persisted max.
        let reloaded = try EventLog(session: s, fileURL: url)
        let all = await reloaded.replay()
        XCTAssertEqual(all.map { $0.seq }, [0, 1])
        let next = try await reloaded.append(.userMessage(.init(text: "c")))
        XCTAssertEqual(next.seq, 2)
    }

    func testReplayFromSeqFiltersEarlier() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_f"), fileURL: url)
        for t in ["a", "b", "c"] { _ = try await log.append(.userMessage(.init(text: t))) }
        let tail = await log.replay(from: 1)
        XCTAssertEqual(tail.map { $0.seq }, [1, 2])
    }

    func testStreamReplaysThenLive() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_s"), fileURL: url)
        _ = try await log.append(.userMessage(.init(text: "first")))

        let stream = await log.stream(from: 0)
        var iterator = stream.makeAsyncIterator()
        _ = try await log.append(.userMessage(.init(text: "second")))

        let e0 = await iterator.next()
        let e1 = await iterator.next()
        XCTAssertEqual(e0?.seq, 0)
        XCTAssertEqual(e1?.seq, 1)
    }

    func testChatLoopStreamsAndProjects() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_c"), fileURL: url)
        let loop = ChatLoop(log: log, provider: MockProvider(parts: ["He", "llo"]), model: ModelID(rawValue: "m"))
        try await loop.send("hi")

        let projection = ConversationProjection.build(from: await log.replay())
        XCTAssertEqual(projection.messages.count, 2)
        XCTAssertEqual(projection.messages[0].role, .user)
        XCTAssertEqual(projection.messages[0].text, "hi")
        XCTAssertEqual(projection.messages[1].role, .assistant)
        XCTAssertEqual(projection.messages[1].text, "Hello")
        XCTAssertTrue(projection.messages[1].isComplete)
    }

    func testChatLoopCanPersistGoalUserPayload() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_goal_loop"), fileURL: url)
        let loop = ChatLoop(log: log, provider: MockProvider(parts: ["ok"]), model: ModelID(rawValue: "m"))
        let parsed = try XCTUnwrap(GoalInputParser.parse("/goal ship v0.12").successValue)

        try await loop.send(parsed.text, userMessage: parsed.userMessagePayload)

        let replayed = await log.replay()
        let first = try XCTUnwrap(replayed.first)
        guard case .userMessage(let payload) = first.event else {
            return XCTFail("first event should be user_message")
        }
        XCTAssertEqual(payload.text, "ship v0.12")
        XCTAssertEqual(payload.tags ?? [], ["Goal"])
        XCTAssertEqual(payload.goal, "ship v0.12")
    }

    func testChatLoopBuildsHistoryAcrossTurns() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_h"), fileURL: url)
        let loop = ChatLoop(log: log, provider: MockProvider(parts: ["ok"]), model: ModelID(rawValue: "m"))
        try await loop.send("first")
        try await loop.send("second")

        let projection = ConversationProjection.build(from: await log.replay())
        XCTAssertEqual(projection.messages.map { $0.role }, [.user, .assistant, .user, .assistant])
    }

    func testConversationProjectionUsesStableSyntheticMessageIDsAcrossReplay() {
        let session = SessionID(rawValue: "sess_stable_chat")
        func env(_ seq: Int, _ event: Event) -> Envelope {
            Envelope(seq: seq, ts: Date(timeIntervalSince1970: Double(seq)), session: session, event: event)
        }
        let envelopes: [Envelope] = [
            env(0, .userMessage(.init(text: "draw"))),
            env(1, .error(.init(code: "provider", message: "failed"))),
            env(2, .artifactAdded(.init(
                artifactId: ArtifactID(rawValue: "art_stable"),
                kind: "image",
                mime: "image/png",
                path: "/tmp/image.png",
                prompt: "draw"))),
        ]

        let first = ConversationProjection.build(from: envelopes).messages.map(\.id)
        let second = ConversationProjection.build(from: envelopes).messages.map(\.id)

        XCTAssertEqual(first, second)
    }

    func testConversationProjectionKeepsGoalMetadata() {
        let session = SessionID(rawValue: "sess_goal_projection")
        let envelopes: [Envelope] = [
            Envelope(seq: 0, ts: Date(timeIntervalSince1970: 0), session: session,
                     event: .userMessage(.init(text: "ship v0.12", tags: ["Goal"], goal: "ship v0.12"))),
        ]

        let message = ConversationProjection.build(from: envelopes).messages.first

        XCTAssertEqual(message?.text, "ship v0.12")
        XCTAssertEqual(message?.tags ?? [], ["Goal"])
        XCTAssertEqual(message?.goal, "ship v0.12")
    }

    func testGoalInputParserStripsGoalCommandAndKeepsBoundary() throws {
        let parsed = try XCTUnwrap(GoalInputParser.parse("  /goal   ship v0.12  ").successValue)

        XCTAssertEqual(parsed.text, "ship v0.12")
        XCTAssertEqual(parsed.goal, "ship v0.12")
        XCTAssertEqual(parsed.tags, ["Goal"])

        let plain = try XCTUnwrap(GoalInputParser.parse("/goals are useful").successValue)
        XCTAssertEqual(plain.text, "/goals are useful")
        XCTAssertNil(plain.goal)
        XCTAssertTrue(plain.tags.isEmpty)
    }

    func testGoalInputParserRejectsEmptyGoal() {
        XCTAssertEqual(GoalInputParser.parse("/goal").failureValue, .missingGoal)
        XCTAssertEqual(GoalInputParser.parse(" /goal   ").failureValue, .missingGoal)
        XCTAssertEqual(GoalInputParser.parse("   ").failureValue, .empty)
    }

    func testArtifactProgressProjectionTracksActiveJobsAndClearsOnArtifactAdded() {
        let session = SessionID(rawValue: "sess_artifacts")
        let artifact = ArtifactID(rawValue: "art_image")
        func env(_ seq: Int, _ event: Event) -> Envelope {
            Envelope(seq: seq, ts: Date(timeIntervalSince1970: Double(seq)), session: session, event: event)
        }

        var projection = ArtifactProgressProjection.build(from: [
            env(0, .artifactProgress(.init(artifactId: artifact, progress: 0.1, state: "queued"))),
            env(1, .artifactProgress(.init(artifactId: artifact, progress: 0.6, state: "running"))),
        ])

        XCTAssertEqual(projection.active, [
            ArtifactProgressSnapshot(id: artifact, progress: 0.6, state: "running", seq: 1)
        ])

        projection.apply(env(2, .artifactAdded(.init(
            artifactId: artifact,
            kind: "image",
            mime: "image/png",
            path: "/tmp/image.png",
            prompt: "draw"))))

        XCTAssertTrue(projection.active.isEmpty)
    }
}

private extension Result {
    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }

    var failureValue: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}
