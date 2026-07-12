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

private struct PartialThenFailingProvider: ChatProvider {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.delta("partial"))
            continuation.finish(throwing: IntatisError.decoding(
                "streaming request ended before a completion marker. Check endpoint compatibility."))
        }
    }
}

private struct SplitUsageProvider: ChatProvider {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.delta("ok"))
            continuation.yield(.usage(Usage(promptTokens: 7, cachedPromptTokens: 3)))
            continuation.yield(.usage(Usage(completionTokens: 2, totalTokens: 9)))
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

    func testConcurrentEventLogInstancesAssignUniqueMonotonicSequences() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = SessionID(rawValue: "sess_multi_writer")
        let first = try EventLog(session: session, fileURL: url)
        let second = try EventLog(session: session, fileURL: url)
        let count = 80

        let persisted = try await withThrowingTaskGroup(of: Envelope.self) { group in
            for index in 0..<count {
                let log = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    try await log.append(.userMessage(.init(text: "event-\(index)")))
                }
            }
            var envelopes: [Envelope] = []
            for try await envelope in group {
                envelopes.append(envelope)
            }
            return envelopes
        }

        XCTAssertEqual(persisted.map(\.seq).sorted(), Array(0..<count))
        let replayed = await first.replay()
        XCTAssertEqual(replayed.map(\.seq), Array(0..<count))
        XCTAssertEqual(Set(replayed.map(\.seq)).count, count)
        XCTAssertEqual(replayed.count, count)

        // A fresh instance must recover the sequence written by both actors.
        let reopened = try EventLog(session: session, fileURL: url)
        let next = try await reopened.append(.userMessage(.init(text: "after-reopen")))
        XCTAssertEqual(next.seq, count)
    }

    func testWriterLeaseRejectsSecondRuntimeButAllowsReadOnlyReplay() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = SessionID(rawValue: "sess_writer_lease")
        let first = try EventLog(session: session, fileURL: url)
        let second = try EventLog(session: session, fileURL: url)
        _ = try await first.append(.userMessage(.init(text: "persisted")))

        let lease = try first.acquireWriterLease()
        do {
            _ = try second.acquireWriterLease()
            XCTFail("a second task-executing runtime must not acquire the same session")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .writerAlreadyActive)
            XCTAssertFalse(error.localizedDescription.contains(url.path))
            XCTAssertNotNil(error.recoverySuggestion)
        }

        // The lifetime writer lease is distinct from the short I/O lock, so
        // history/projection reads may coexist with the active runtime.
        let concurrentReplay = await second.replay()
        XCTAssertEqual(concurrentReplay.map(\.seq), [0])

        lease.release()
        let replacementLease = try second.acquireWriterLease()
        replacementLease.release()
    }

    func testAppendBatchPersistsContiguousSequenceGroup() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(
            session: SessionID(rawValue: "sess_batch"),
            fileURL: url)

        let envelopes = try await log.append([
            .userMessage(.init(text: "one")),
            .userMessage(.init(text: "two")),
            .userMessage(.init(text: "three")),
        ], ts: Date(timeIntervalSince1970: 123))

        XCTAssertEqual(envelopes.map(\.seq), [0, 1, 2])
        XCTAssertEqual(envelopes.map(\.ts), Array(repeating: Date(timeIntervalSince1970: 123), count: 3))
        let replayed = await log.replay()
        XCTAssertEqual(replayed.map(\.seq), [0, 1, 2])
    }

    func testUnknownFutureEventReservesItsSequenceForConcurrentSafeAppend() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let session = SessionID(rawValue: "sess_future_sequence")
        let encoder = Envelope.makeEncoder()
        let known = try encoder.encode(Envelope(
            seq: 0,
            ts: Date(timeIntervalSince1970: 0),
            session: session,
            event: .userMessage(.init(text: "known"))))
        let futureBase = try encoder.encode(Envelope(
            seq: 7,
            ts: Date(timeIntervalSince1970: 7),
            session: session,
            event: .userMessage(.init(text: "placeholder"))))
        var futureObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: futureBase) as? [String: Any])
        futureObject["type"] = "future_event_type"
        futureObject["payload"] = ["futureField": true]
        let future = try JSONSerialization.data(withJSONObject: futureObject, options: [.sortedKeys])
        var initialData = known
        initialData.append(0x0A)
        initialData.append(future)
        initialData.append(0x0A)
        try initialData.write(to: url)

        let log = try EventLog(session: session, fileURL: url)
        let appended = try await log.append(.userMessage(.init(text: "current")))

        XCTAssertEqual(appended.seq, 8)
        // The future event is intentionally skipped by this binary, but its
        // occupied sequence remains reserved.
        let replayed = await log.replay()
        XCTAssertEqual(replayed.map(\.seq), [0, 8])
    }

    func testInitializationRejectsNonMonotonicValidEnvelopeHeadersWithoutPathLeak() throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let session = SessionID(rawValue: "sess_bad_sequence")
        let encoder = Envelope.makeEncoder()
        var data = try encoder.encode(Envelope(
            seq: 2,
            ts: Date(timeIntervalSince1970: 0),
            session: session,
            event: .userMessage(.init(text: "first"))))
        data.append(0x0A)
        data.append(try encoder.encode(Envelope(
            seq: 2,
            ts: Date(timeIntervalSince1970: 1),
            session: session,
            event: .userMessage(.init(text: "duplicate")))))
        data.append(0x0A)
        try data.write(to: url)

        do {
            _ = try EventLog(session: session, fileURL: url)
            XCTFail("duplicate valid sequence headers must fail closed")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .nonMonotonicSequence(previous: 2, current: 2))
            XCTAssertFalse(error.localizedDescription.contains(url.path))
            XCTAssertNotNil(error.recoverySuggestion)
        }
    }

    func testAppendAfterCrashTailKeepsNewEnvelopeReplayable() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = SessionID(rawValue: "sess_crash_tail")
        let initialLog = try EventLog(session: session, fileURL: url)
        _ = try await initialLog.append(.userMessage(.init(text: "before crash")))

        let corruptTail = Data(#"{"seq":999,"type":"user_message","payload":{"text":"partial""#.utf8)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: corruptTail)
        try handle.close()

        let reloaded = try EventLog(session: session, fileURL: url)
        let appended = try await reloaded.append(.userMessage(.init(text: "after restart")))
        let replayed = await reloaded.replay()

        XCTAssertEqual(appended.seq, 1)
        XCTAssertEqual(replayed.map(\.seq), [0, 1])
        XCTAssertEqual(replayed.compactMap { envelope -> String? in
            guard case .userMessage(let payload) = envelope.event else { return nil }
            return payload.text
        }, ["before crash", "after restart"])

        let persistedLines = try Data(contentsOf: url).split(separator: 0x0A)
        XCTAssertEqual(persistedLines.count, 3)
        XCTAssertEqual(Data(persistedLines[1]), corruptTail)
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

    func testChatLoopPreservesPartialTextWhenStreamEndsWithoutCompletionMarker() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_partial_eof"), fileURL: url)
        let loop = ChatLoop(log: log,
                            provider: PartialThenFailingProvider(),
                            model: ModelID(rawValue: "m"))

        do {
            try await loop.send("hi")
            XCTFail("expected incomplete stream error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("completion marker"))
        }

        let projection = ConversationProjection.build(from: await log.replay())
        XCTAssertEqual(projection.messages.count, 3)
        XCTAssertEqual(projection.messages[0].role, .user)
        XCTAssertEqual(projection.messages[1].role, .assistant)
        XCTAssertEqual(projection.messages[1].text, "partial")
        XCTAssertFalse(projection.messages[1].isComplete)
        XCTAssertEqual(projection.messages[1].recoveryAdvice?.title, "Response stopped before completion")
        XCTAssertEqual(projection.messages[2].role, .system)
        XCTAssertEqual(projection.messages[2].recoveryAdvice?.title, "Check endpoint compatibility")
    }

    func testChatLoopMergesSplitUsageChunksIntoTurnStats() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: SessionID(rawValue: "sess_split_usage"), fileURL: url)
        let loop = ChatLoop(log: log,
                            provider: SplitUsageProvider(),
                            model: ModelID(rawValue: "m"),
                            includeUsage: true)

        try await loop.send("hi")

        let stats = await log.replay().compactMap { envelope -> TurnStatsPayload? in
            guard case .turnStats(let payload) = envelope.event else { return nil }
            return payload
        }.last
        XCTAssertEqual(stats?.promptTokens, 7)
        XCTAssertEqual(stats?.cachedPromptTokens, 3)
        XCTAssertEqual(stats?.completionTokens, 2)
        XCTAssertEqual(stats?.totalTokens, 9)
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

    func testConversationProjectionAddsRecoveryAdviceForProviderErrors() {
        let session = SessionID(rawValue: "sess_chat_error_recovery")
        let envelope = Envelope(
            seq: 0,
            ts: Date(timeIntervalSince1970: 0),
            session: session,
            event: .error(.init(
                code: "provider",
                message: "streaming request failed with HTTP 401 Unauthorized. Check your API key.")))

        let message = ConversationProjection.build(from: [envelope]).messages.first

        XCTAssertEqual(message?.role, .system)
        XCTAssertEqual(message?.recoveryAdvice?.title, "Fix provider configuration")
        XCTAssertEqual(message?.recoveryAdvice?.retryable, false)
    }

    func testConversationProjectionMarksPartialStreamStoppedByError() {
        let session = SessionID(rawValue: "sess_chat_partial_stop")
        let messageID = MessageID(rawValue: "m_partial")
        func env(_ seq: Int, _ event: Event) -> Envelope {
            Envelope(seq: seq, ts: Date(timeIntervalSince1970: Double(seq)), session: session, event: event)
        }
        let envelopes: [Envelope] = [
            env(0, .messageDelta(.init(messageId: messageID, role: .assistant, textDelta: "partial"))),
            env(1, .error(.init(
                code: "provider",
                message: "streaming request failed with HTTP 503 Service Unavailable. Retry later."))),
        ]

        let projection = ConversationProjection.build(from: envelopes)

        XCTAssertEqual(projection.messages.count, 2)
        XCTAssertEqual(projection.messages[0].id, messageID)
        XCTAssertEqual(projection.messages[0].text, "partial")
        XCTAssertFalse(projection.messages[0].isComplete)
        XCTAssertEqual(projection.messages[0].recoveryAdvice?.title, "Response stopped before completion")
        XCTAssertEqual(projection.messages[0].recoveryAdvice?.retryable, true)
        XCTAssertEqual(projection.messages[1].recoveryAdvice?.title, "Retry or switch provider")
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
