import Foundation
import IntatisCore
import IntatisProtocol

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Failures raised by the event-log coordination layer. Messages deliberately
/// omit the backing file URL because session paths can contain private user or
/// workspace information.
public enum EventLogError: Error, Equatable, LocalizedError, Sendable {
    case lockUnavailable(code: Int32)
    case lockTimedOut
    case writerAlreadyActive
    case storageUnavailable(operation: String, code: Int)
    case nonMonotonicSequence(previous: Int, current: Int)
    case sequenceRegressed(expectedAtLeast: Int, found: Int)
    case sequenceExhausted

    public var errorDescription: String? {
        switch self {
        case .lockUnavailable(let code):
            return "The session event log lock could not be opened (error code \(code))."
        case .lockTimedOut:
            return "The session event log is busy in another Intatis operation."
        case .writerAlreadyActive:
            return "Another Intatis runtime is already writing this session."
        case .storageUnavailable(let operation, let code):
            return "The session event log could not \(operation) (error code \(code))."
        case .nonMonotonicSequence(let previous, let current):
            return "The session event log has non-monotonic sequence numbers (\(previous), \(current))."
        case .sequenceRegressed(let expectedAtLeast, let found):
            return "The session event log was replaced or truncated (expected sequence \(expectedAtLeast) or later, found \(found))."
        case .sequenceExhausted:
            return "The session event log sequence space is exhausted."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .lockUnavailable, .storageUnavailable:
            return "Check storage permissions and available disk space, then retry."
        case .lockTimedOut:
            return "Wait for the other operation to finish, or close the other Intatis process using this session, then retry."
        case .writerAlreadyActive:
            return "Close the other Code or Cowork runtime for this session, then retry. Read-only replay can remain open."
        case .nonMonotonicSequence, .sequenceRegressed:
            return "Stop writing to this session and inspect or restore its event log before retrying."
        case .sequenceExhausted:
            return "Start a new session."
        }
    }
}

/// The stable envelope fields needed to reserve sequence numbers even when an
/// older binary cannot decode a future event `type` or payload schema.
private struct EnvelopeSequenceHeader: Decodable {
    let seq: Int
    let ts: Date
    let session: SessionID
    let v: Int
    let type: String
    let payload: JSONValue
}

private struct EventLogSequenceState {
    let nextSeq: Int
    let needsSeparator: Bool
}

/// Advisory lock shared by every EventLog instance that targets the same
/// canonical JSONL path. The descriptor is always close-on-exec and is held
/// only for the read or append critical section, so a process crash releases
/// it automatically. Readers use a shared lock; appenders use an exclusive
/// lock and re-read sequence state while holding it.
fileprivate final class EventLogFileLock {
    enum Mode {
        case shared
        case exclusive
    }

    private static let retryCount = 400
    private static let retryInterval: TimeInterval = 0.005

    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at url: URL,
                        mode: Mode,
                        contentionError: EventLogError = .lockTimedOut,
                        maxRetries: Int = retryCount) throws -> EventLogFileLock {
        let descriptor = openLockFile(at: url)
        guard descriptor >= 0 else {
            throw EventLogError.lockUnavailable(code: currentErrno())
        }

        let operation: Int32
        switch mode {
        case .shared:
            operation = LOCK_SH | LOCK_NB
        case .exclusive:
            operation = LOCK_EX | LOCK_NB
        }
        for attempt in 0...maxRetries {
            if applyLock(descriptor, operation: operation) == 0 {
                return EventLogFileLock(descriptor: descriptor)
            }

            let code = currentErrno()
            guard code == EWOULDBLOCK || code == EAGAIN else {
                closeFile(descriptor)
                throw EventLogError.lockUnavailable(code: code)
            }
            guard attempt < maxRetries else {
                closeFile(descriptor)
                throw contentionError
            }
            Thread.sleep(forTimeInterval: retryInterval)
        }

        closeFile(descriptor)
        throw contentionError
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = Self.applyLock(descriptor, operation: LOCK_UN)
        Self.closeFile(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }

    private static func openLockFile(at url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            let flags = O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW
#if canImport(Darwin)
            return Darwin.open(path, flags, mode_t(S_IRUSR | S_IWUSR))
#elseif canImport(Glibc)
            return Glibc.open(path, flags, mode_t(S_IRUSR | S_IWUSR))
#else
            return -1
#endif
        }
    }

    private static func applyLock(_ descriptor: Int32, operation: Int32) -> Int32 {
#if canImport(Darwin) || canImport(Glibc)
        return flock(descriptor, operation)
#else
        return -1
#endif
    }

    private static func closeFile(_ descriptor: Int32) {
#if canImport(Darwin)
        _ = Darwin.close(descriptor)
#elseif canImport(Glibc)
        _ = Glibc.close(descriptor)
#endif
    }

    private static func currentErrno() -> Int32 {
#if canImport(Darwin) || canImport(Glibc)
        return errno
#else
        return -1
#endif
    }
}

/// Optional long-lived lease for runtimes that execute tasks from an EventLog.
/// EventLog itself does not acquire this lease at initialization, so history
/// and read-only projections may coexist. A Code/Cowork runtime keeps the
/// returned object alive for its whole execution lifetime; a second runtime
/// targeting the same log receives `writerAlreadyActive`. Releasing the object
/// or terminating the process closes the descriptor and frees the lease.
public final class EventLogWriterLease: @unchecked Sendable {
    private let stateLock = NSLock()
    private var fileLock: EventLogFileLock?

    fileprivate init(fileLock: EventLogFileLock) {
        self.fileLock = fileLock
    }

    public func release() {
        stateLock.lock()
        let lock = fileLock
        fileLock = nil
        stateLock.unlock()
        lock?.release()
    }

    deinit {
        release()
    }
}

/// Append-only, per-session event log persisted as JSONL (one `Envelope` per
/// line). This is the single source of truth (ARCHITECTURE.md §1.2 principle A):
/// `append` is the only mutation; `replay`/`stream` are projections; `resume`
/// is just "read from a `seq`". The actor serializes one instance, while a
/// cross-process file lock serializes all instances targeting the same file.
public actor EventLog {
    private let session: SessionID
    private let fileURL: URL
    /// Package-internal identity for process-wide coordination registries.
    /// It may contain a private filesystem path and must never be logged or
    /// surfaced to models/UI.
    package nonisolated let coordinationKey: String
    private let lockURL: URL
    private let writerLockURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var nextSeq: Int
    private var subscribers: [UUID: AsyncStream<Envelope>.Continuation] = [:]

    public init(session: SessionID, fileURL: URL) throws {
        self.session = session
        let canonicalFileURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        self.fileURL = canonicalFileURL
        self.coordinationKey = canonicalFileURL.path
        self.lockURL = canonicalFileURL.appendingPathExtension("lock")
        self.writerLockURL = canonicalFileURL.appendingPathExtension("writer.lock")
        self.encoder = Envelope.makeEncoder()
        self.decoder = Envelope.makeDecoder()

        do {
            try FileManager.default.createDirectory(
                at: canonicalFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch {
            throw Self.storageError(operation: "initialize its directory", error: error)
        }

        let lock = try EventLogFileLock.acquire(at: lockURL, mode: .shared)
        defer { lock.release() }
        self.nextSeq = try Self.sequenceState(
            at: canonicalFileURL,
            decoder: Envelope.makeDecoder()).nextSeq
    }

    public var sessionID: SessionID { session }

    /// Acquires an optional process-lifetime writer lease for a task-executing
    /// runtime. Ordinary append calls remain independently protected so Chat
    /// and migration callers do not need to hold this lease.
    public nonisolated func acquireWriterLease() throws -> EventLogWriterLease {
        let lock = try EventLogFileLock.acquire(
            at: writerLockURL,
            mode: .exclusive,
            contentionError: .writerAlreadyActive,
            maxRetries: 0)
        return EventLogWriterLease(fileLock: lock)
    }

    /// Append an event. Returns the persisted envelope (with its assigned seq).
    @discardableResult
    public func append(_ event: Event, ts: Date = Date()) throws -> Envelope {
        guard let envelope = try append([event], ts: ts).first else {
            preconditionFailure("a single-event append must produce one envelope")
        }
        return envelope
    }

    /// Appends a contiguous group of events while holding one cross-process
    /// exclusive lock. The group is encoded before any bytes are written and
    /// flushed with one synchronize operation. Local sequence state and live
    /// subscribers advance only after the write and flush succeed.
    @discardableResult
    public func append(_ events: [Event], ts: Date = Date()) throws -> [Envelope] {
        guard !events.isEmpty else { return [] }

        let lock = try EventLogFileLock.acquire(at: lockURL, mode: .exclusive)
        defer { lock.release() }

        // Re-read the persisted tail while holding the cross-process lock.
        // This is the sequence CAS: a stale EventLog instance must observe
        // appends made by another instance before assigning its own range.
        let state = try Self.tailSequenceState(at: fileURL, decoder: decoder)
        guard state.nextSeq >= nextSeq else {
            throw EventLogError.sequenceRegressed(
                expectedAtLeast: nextSeq,
                found: state.nextSeq)
        }

        var envelopes: [Envelope] = []
        envelopes.reserveCapacity(events.count)
        var bytes = Data()
        if state.needsSeparator {
            bytes.append(0x0A)
        }

        for (offset, event) in events.enumerated() {
            let (seq, overflow) = state.nextSeq.addingReportingOverflow(offset)
            guard !overflow else { throw EventLogError.sequenceExhausted }
            let envelope = Envelope(seq: seq, ts: ts, session: session, event: event)
            var line: Data
            do {
                line = try encoder.encode(envelope)
            } catch {
                throw Self.storageError(operation: "encode an event", error: error)
            }
            line.append(0x0A)
            bytes.append(line)
            envelopes.append(envelope)
        }

        let (advancedNextSeq, overflow) = state.nextSeq.addingReportingOverflow(events.count)
        guard !overflow else { throw EventLogError.sequenceExhausted }
        try appendBytes(bytes)

        nextSeq = advancedNextSeq
        for envelope in envelopes {
            for (_, continuation) in subscribers {
                continuation.yield(envelope)
            }
        }
        return envelopes
    }

    /// All events with `seq >= from`. Undecodable lines are skipped so a newer
    /// event type written by a future version can't break resume (§8 risk 7).
    public func replay(from seq: Int = 0) -> [Envelope] {
        guard let lock = try? EventLogFileLock.acquire(at: lockURL, mode: .shared) else {
            return []
        }
        defer { lock.release() }
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
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw EventLogError.storageUnavailable(operation: "create its data file", code: 0)
            }
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: fileURL)
        } catch {
            throw Self.storageError(operation: "open for append", error: error)
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            throw Self.storageError(operation: "append and synchronize data", error: error)
        }
    }

    private static func sequenceState(at fileURL: URL,
                                      decoder: JSONDecoder) throws -> EventLogSequenceState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return EventLogSequenceState(nextSeq: 0, needsSeparator: false)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw storageError(operation: "read sequence state", error: error)
        }

        var previous: Int?
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let header = try? decoder.decode(EnvelopeSequenceHeader.self, from: Data(line)) else {
                continue
            }
            if let previous, header.seq <= previous {
                throw EventLogError.nonMonotonicSequence(
                    previous: previous,
                    current: header.seq)
            }
            previous = header.seq
        }

        let nextSeq: Int
        if let previous {
            let (advanced, overflow) = previous.addingReportingOverflow(1)
            guard !overflow else { throw EventLogError.sequenceExhausted }
            nextSeq = advanced
        } else {
            nextSeq = 0
        }
        return EventLogSequenceState(
            nextSeq: nextSeq,
            needsSeparator: !data.isEmpty && data.last != 0x0A)
    }

    /// Finds the most recent decodable envelope header without re-reading a
    /// long session from byte zero on every append. The search starts with the
    /// final 64 KiB and doubles until it reaches a complete valid line or the
    /// beginning of the file. Initialization still performs a full monotonicity
    /// validation; this locked tail read is the per-append cross-instance CAS.
    private static func tailSequenceState(at fileURL: URL,
                                          decoder: JSONDecoder) throws -> EventLogSequenceState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return EventLogSequenceState(nextSeq: 0, needsSeparator: false)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw storageError(operation: "open sequence state", error: error)
        }
        defer { try? handle.close() }

        do {
            let endOffset = try handle.seekToEnd()
            guard endOffset > 0 else {
                return EventLogSequenceState(nextSeq: 0, needsSeparator: false)
            }

            var window = min(endOffset, 64 * 1_024)
            var needsSeparator = false
            var inspectedEndByte = false
            while true {
                let startOffset = endOffset - window
                try handle.seek(toOffset: startOffset)
                let data = try handle.read(upToCount: Int(window)) ?? Data()
                if !inspectedEndByte {
                    needsSeparator = data.last != 0x0A
                    inspectedEndByte = true
                }

                var lines = data.split(separator: 0x0A)
                if startOffset > 0, data.first != 0x0A, !lines.isEmpty {
                    // The window began in the middle of a JSON object. Ignore
                    // that fragment until a larger window reaches its start.
                    lines.removeFirst()
                }
                for line in lines.reversed() where !line.isEmpty {
                    guard let header = try? decoder.decode(
                        EnvelopeSequenceHeader.self,
                        from: Data(line)) else {
                        continue
                    }
                    let (nextSeq, overflow) = header.seq.addingReportingOverflow(1)
                    guard !overflow else { throw EventLogError.sequenceExhausted }
                    return EventLogSequenceState(
                        nextSeq: nextSeq,
                        needsSeparator: needsSeparator)
                }

                guard startOffset > 0 else {
                    return EventLogSequenceState(
                        nextSeq: 0,
                        needsSeparator: needsSeparator)
                }
                window = min(endOffset, window * 2)
            }
        } catch let error as EventLogError {
            throw error
        } catch {
            throw storageError(operation: "read sequence state", error: error)
        }
    }

    private static func storageError(operation: String, error: Error) -> EventLogError {
        EventLogError.storageUnavailable(
            operation: operation,
            code: (error as NSError).code)
    }
}
