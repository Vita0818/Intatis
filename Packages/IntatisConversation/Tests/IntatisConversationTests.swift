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
}
