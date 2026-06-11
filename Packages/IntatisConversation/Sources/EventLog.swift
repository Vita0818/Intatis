import Foundation
import IntatisCore
import IntatisProtocol

/// Append-only, per-session event log persisted as JSONL (one `Envelope` per
/// line). This is the single source of truth (ARCHITECTURE.md §1.2 principle A):
/// `append` is the only mutation; `replay`/`stream` are projections; `resume`
/// is just "read from a `seq`". An `actor` so appends are serialized.
public actor EventLog {
    private let session: SessionID
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var nextSeq: Int
    private var subscribers: [UUID: AsyncStream<Envelope>.Continuation] = [:]

    public init(session: SessionID, fileURL: URL) throws {
        self.session = session
        self.fileURL = fileURL
        self.encoder = Envelope.makeEncoder()
        self.decoder = Envelope.makeDecoder()

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Recover nextSeq from any existing log without calling instance methods.
        var maxSeq = -1
        if let data = try? Data(contentsOf: fileURL) {
            let dec = Envelope.makeDecoder()
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let env = try? dec.decode(Envelope.self, from: Data(line)) {
                    maxSeq = max(maxSeq, env.seq)
                }
            }
        }
        self.nextSeq = maxSeq + 1
    }

    public var sessionID: SessionID { session }

    /// Append an event. Returns the persisted envelope (with its assigned seq).
    @discardableResult
    public func append(_ event: Event, ts: Date = Date()) throws -> Envelope {
        let env = Envelope(seq: nextSeq, ts: ts, session: session, event: event)
        var line = try encoder.encode(env)
        line.append(0x0A)
        try appendBytes(line)
        nextSeq += 1
        for (_, continuation) in subscribers {
            continuation.yield(env)
        }
        return env
    }

    /// All events with `seq >= from`. Undecodable lines are skipped so a newer
    /// event type written by a future version can't break resume (§8 risk 7).
    public func replay(from seq: Int = 0) -> [Envelope] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        var result: [Envelope] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let env = try? decoder.decode(Envelope.self, from: Data(line)), env.seq >= seq {
                result.append(env)
            }
        }
        return result
    }

    /// Replays existing events (>= `from`), then streams live ones as appended.
    /// Built with `makeStream` so the replay + subscriber registration run in
    /// this actor-isolated method body, not inside a `@Sendable` closure.
    public func stream(from seq: Int = 0) -> AsyncStream<Envelope> {
        let (stream, continuation) = AsyncStream<Envelope>.makeStream()
        for env in replay(from: seq) {
            continuation.yield(env)
        }
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func appendBytes(_ data: Data) throws {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
