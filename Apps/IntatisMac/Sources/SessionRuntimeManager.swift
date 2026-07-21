#if canImport(SwiftUI)
import Foundation
import Combine
import IntatisCore
import IntatisProviders
import IntatisConversation
import IntatisArtifacts
import IntatisMultimodal
import IntatisSharedUI

struct AppSessionRuntimeKey: Hashable, Sendable {
    let kind: SessionKind
    let sessionID: SessionID

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind.rawValue == rhs.kind.rawValue && lhs.sessionID == rhs.sessionID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind.rawValue)
        hasher.combine(sessionID)
    }
}

struct AppSessionDisplayNameChange: Equatable, Sendable {
    let key: AppSessionRuntimeKey
    let displayName: String
    let settingsRevision: Int
    let projectedThroughSeq: Int
}

enum AppSessionRuntimeManagerError: Error, LocalizedError {
    case quiescing
    case runtimeBusy(AppSessionRuntimeKey)

    var errorDescription: String? {
        switch self {
        case .quiescing:
            return "The application is stopping and cannot open another session runtime."
        case .runtimeBusy(let key):
            return "The \(key.kind.rawValue) session \(key.sessionID.rawValue) is still running. Stop it before deleting the session."
        }
    }
}

@MainActor
final class AppChatSessionRuntime {
    let sessionID: SessionID
    let log: EventLog
    let multimodal: MultimodalService
    let viewModel: ChatViewModel

    init(sessionID: SessionID, registry: ProviderRegistry) throws {
        self.sessionID = sessionID
        self.log = try EventLog(
            session: sessionID,
            fileURL: AppConfig.sessionFile(sessionID))
        let store = try ArtifactStore(root: AppConfig.artifactsDir(sessionID))
        self.multimodal = MultimodalService(log: log, store: store)
        self.viewModel = ChatViewModel(log: log, registry: registry)
        updateProviderRegistry(registry)
    }

    var isBusy: Bool { viewModel.isBusy }

    func start() {
        viewModel.start()
    }

    func updateProviderRegistry(_ registry: ProviderRegistry) {
        viewModel.updateProviderRegistry(registry)
        let multimodal = multimodal
        viewModel.onGenerateImage = { prompt in
            guard let provider = try await registry.defaultImageProvider(),
                  let model = await registry.imageModel() else {
                throw IntatisError.config("image generation is not configured")
            }
            _ = try await multimodal.generateImage(
                using: provider,
                model: model,
                prompt: prompt)
        }
    }

    func shutdown(reason: String) async {
        await viewModel.shutdown(reason: reason)
    }
}

/// Process-owned registry for every live macOS session runtime.
///
/// Views retain only the runtime they are currently presenting. This manager
/// is the authoritative owner, so selecting another page/window never tears
/// down provider, tool, Goal, projection, or workspace state.
@MainActor
final class AppSessionRuntimeManager: ObservableObject {
    enum State: Equatable {
        case running
        case quiescing
        case stopped
    }

    private struct RuntimeEntry {
        var isBusy: @MainActor () -> Bool
        var shutdown: @MainActor (String) async -> Void
    }

    private enum CoworkSlot {
        case creating(UUID, Task<CoworkViewModel, Error>)
        case ready(CoworkViewModel)
    }

    static let shared = AppSessionRuntimeManager()

    @Published private(set) var state: State = .running
    @Published private(set) var runtimeRevision: UInt64 = 0
    let runtimeRemoved = PassthroughSubject<AppSessionRuntimeKey, Never>()
    let sessionDisplayNameChanged = PassthroughSubject<AppSessionDisplayNameChange, Never>()
    private var chatRuntimes: [SessionID: AppChatSessionRuntime] = [:]
    private var codeRuntimes: [SessionID: CodeViewModel] = [:]
    private var coworkRuntimes: [SessionID: CoworkSlot] = [:]
    private var entries: [AppSessionRuntimeKey: RuntimeEntry] = [:]
    private var currentRegistry: ProviderRegistry?
    private var currentInferenceOptions: [AppInferenceProfileOption] = []
    private var runtimeObservations: [AppSessionRuntimeKey: AnyCancellable] = [:]
    private var sessionDisplayNameWatermarks: [AppSessionRuntimeKey: (revision: Int, seq: Int)] = [:]
    private var shutdownBatch: BoundedSessionRuntimeShutdown?
    private(set) var shutdownReport: SessionRuntimeShutdownReport?
    #if DEBUG
    private var validationRuntimeObjects: [AppSessionRuntimeKey: AnyObject] = [:]
    #endif

    var acceptsNewRuntimes: Bool { state == .running }

    func chatRuntime(
        sessionID: SessionID,
        registry: ProviderRegistry
    ) throws -> AppChatSessionRuntime {
        guard state == .running else { throw AppSessionRuntimeManagerError.quiescing }
        currentRegistry = registry
        if let existing = chatRuntimes[sessionID] {
            existing.updateProviderRegistry(registry)
            return existing
        }
        let runtime = try AppChatSessionRuntime(
            sessionID: sessionID,
            registry: registry)
        let key = AppSessionRuntimeKey(kind: .chat, sessionID: sessionID)
        chatRuntimes[sessionID] = runtime
        entries[key] = RuntimeEntry(
            isBusy: { runtime.isBusy },
            shutdown: { reason in await runtime.shutdown(reason: reason) })
        observe(runtime.viewModel, key: key)
        runtime.start()
        return runtime
    }

    func cachedCodeRuntime(sessionID: SessionID) -> CodeViewModel? {
        codeRuntimes[sessionID]
    }

    func registerCodeRuntime(_ runtime: CodeViewModel) throws -> CodeViewModel {
        guard state == .running else {
            Task { @MainActor in
                await runtime.shutdown(reason: "Application shutdown raced Code session creation")
            }
            throw AppSessionRuntimeManagerError.quiescing
        }
        if let existing = codeRuntimes[runtime.sessionID] {
            Task { @MainActor in
                await runtime.shutdown(reason: "Duplicate Code session runtime")
            }
            return existing
        }
        if let currentRegistry {
            runtime.updateProviderRegistry(currentRegistry)
        }
        let key = AppSessionRuntimeKey(kind: .code, sessionID: runtime.sessionID)
        codeRuntimes[runtime.sessionID] = runtime
        entries[key] = RuntimeEntry(
            isBusy: { runtime.isWorking },
            shutdown: { reason in await runtime.shutdown(reason: reason) })
        observe(runtime, key: key)
        runtime.start()
        return runtime
    }

    func coworkRuntime(
        sessionID: SessionID,
        create: @escaping @MainActor () async throws -> CoworkViewModel
    ) async throws -> CoworkViewModel {
        guard state == .running else { throw AppSessionRuntimeManagerError.quiescing }
        if let slot = coworkRuntimes[sessionID] {
            switch slot {
            case .ready(let runtime):
                return runtime
            case .creating(let generation, let task):
                return try await finishCoworkCreation(
                    sessionID: sessionID,
                    generation: generation,
                    task: task)
            }
        }

        let generation = UUID()
        let task = Task { @MainActor in try await create() }
        coworkRuntimes[sessionID] = .creating(generation, task)
        markRuntimeChanged()
        return try await finishCoworkCreation(
            sessionID: sessionID,
            generation: generation,
            task: task)
    }

    private func finishCoworkCreation(
        sessionID: SessionID,
        generation: UUID,
        task: Task<CoworkViewModel, Error>
    ) async throws -> CoworkViewModel {
        do {
            let runtime = try await task.value
            if case .ready(let existing)? = coworkRuntimes[sessionID] {
                return existing
            }
            guard case .creating(let activeGeneration, _)? = coworkRuntimes[sessionID],
                  activeGeneration == generation,
                  state == .running else {
                await runtime.stop(reason: "Application shutdown raced Cowork session creation")
                throw AppSessionRuntimeManagerError.quiescing
            }
            if let currentRegistry {
                runtime.updateProviderRegistry(
                    currentRegistry,
                    inferenceProfileOptions: currentInferenceOptions)
            }
            let key = AppSessionRuntimeKey(kind: .cowork, sessionID: sessionID)
            coworkRuntimes[sessionID] = .ready(runtime)
            entries[key] = RuntimeEntry(
                isBusy: { runtime.hasActiveWork },
                shutdown: { reason in await runtime.stop(reason: reason) })
            observe(runtime, key: key)
            runtime.start()
            return runtime
        } catch {
            if case .creating(let activeGeneration, _)? = coworkRuntimes[sessionID],
               activeGeneration == generation {
                coworkRuntimes.removeValue(forKey: sessionID)
                markRuntimeChanged()
            }
            throw error
        }
    }

    func updateProviderRegistry(
        _ registry: ProviderRegistry,
        inferenceProfileOptions: [AppInferenceProfileOption]
    ) {
        currentRegistry = registry
        currentInferenceOptions = inferenceProfileOptions
        for runtime in chatRuntimes.values {
            runtime.updateProviderRegistry(registry)
        }
        for runtime in codeRuntimes.values {
            runtime.updateProviderRegistry(registry)
        }
        for slot in coworkRuntimes.values {
            guard case .ready(let runtime) = slot else { continue }
            runtime.updateProviderRegistry(
                registry,
                inferenceProfileOptions: inferenceProfileOptions)
        }
    }

    func isBusy(kind: SessionKind, sessionID: SessionID) -> Bool {
        let key = AppSessionRuntimeKey(kind: kind, sessionID: sessionID)
        if case .creating? = coworkRuntimes[sessionID], kind.rawValue == SessionKind.cowork.rawValue {
            return true
        }
        return entries[key]?.isBusy() ?? false
    }

    func statusLabel(kind: SessionKind, sessionID: SessionID) -> String? {
        if state == .quiescing,
           entries[AppSessionRuntimeKey(kind: kind, sessionID: sessionID)] != nil {
            return "Stopping"
        }
        if kind.rawValue == SessionKind.cowork.rawValue,
           case .creating? = coworkRuntimes[sessionID] {
            return "Opening"
        }
        return isBusy(kind: kind, sessionID: sessionID) ? "Running" : nil
    }

    /// Publishes only the newest verified display-name projection for an exact
    /// session. Concurrent rename transactions can finish rebuilding their
    /// projections out of order, so revision and sequence form a per-key
    /// high-watermark before any window is notified.
    func publishSessionDisplayNameChange(_ change: AppSessionDisplayNameChange) {
        if let watermark = sessionDisplayNameWatermarks[change.key] {
            guard change.settingsRevision > watermark.revision ||
                    (change.settingsRevision == watermark.revision &&
                     change.projectedThroughSeq > watermark.seq) else {
                return
            }
        }
        sessionDisplayNameWatermarks[change.key] = (
            revision: change.settingsRevision,
            seq: change.projectedThroughSeq)
        sessionDisplayNameChanged.send(change)
    }

    func removeRuntime(
        kind: SessionKind,
        sessionID: SessionID,
        reason: String
    ) async throws {
        let key = AppSessionRuntimeKey(kind: kind, sessionID: sessionID)
        guard !isBusy(kind: kind, sessionID: sessionID) else {
            throw AppSessionRuntimeManagerError.runtimeBusy(key)
        }
        switch kind {
        case .chat:
            if let runtime = chatRuntimes.removeValue(forKey: sessionID) {
                await runtime.shutdown(reason: reason)
            }
        case .code:
            if let runtime = codeRuntimes.removeValue(forKey: sessionID) {
                await runtime.shutdown(reason: reason)
            }
        case .cowork:
            if case .ready(let runtime)? = coworkRuntimes.removeValue(forKey: sessionID) {
                await runtime.stop(reason: reason)
            }
        }
        entries.removeValue(forKey: key)
        runtimeObservations.removeValue(forKey: key)?.cancel()
        sessionDisplayNameWatermarks.removeValue(forKey: key)
        runtimeRemoved.send(key)
        markRuntimeChanged()
    }

    /// Atomically quiesces the registry, broadcasts shutdown to every retained
    /// runtime, and waits only until the monotonic deadline. A timed-out child
    /// is cancelled but deliberately not joined; process termination and the
    /// next cold-start reconciliation remain the final safety boundary.
    func shutdownAll(
        reason: String,
        deadline: SessionRuntimeShutdownDeadline = .after(.seconds(8))
    ) async -> SessionRuntimeShutdownReport {
        if let shutdownBatch {
            let report = await shutdownBatch.shutdown()
            shutdownReport = report
            state = .stopped
            return report
        }

        state = .quiescing
        var requests = entries.map { key, entry in
            SessionRuntimeStopRequest(
                identity: SessionRuntimeIdentity(
                    kind: key.kind,
                    sessionID: key.sessionID),
                stop: {
                    await entry.shutdown(reason)
                })
        }

        // A Cowork factory can be suspended in migration before a ViewModel is
        // published. Include that exact key in the same quit report and ensure
        // any late-created runtime is immediately drained instead of escaping
        // the quiescing fence.
        for (sessionID, slot) in coworkRuntimes {
            guard case .creating(_, let creation) = slot else { continue }
            let cleanup = Task { @MainActor in
                creation.cancel()
                if let runtime = try? await creation.value {
                    await runtime.stop(reason: reason)
                }
            }
            requests.append(SessionRuntimeStopRequest(
                identity: SessionRuntimeIdentity(
                    kind: .cowork,
                    sessionID: sessionID),
                stop: { await cleanup.value }))
        }

        let batch = BoundedSessionRuntimeShutdown(
            requests: requests,
            deadline: deadline)
        shutdownBatch = batch
        let report = await batch.shutdown()
        shutdownReport = report
        state = .stopped
        return report
    }

    #if DEBUG
    /// Returns the manager-owned validation runtime for an exact key, creating
    /// and registering it only once. The fixture view itself is deliberately
    /// window-owned, so closing every window proves that this registry—not a
    /// second static fixture store—keeps the runtime alive.
    func validationRuntime<Runtime: AnyObject & ObservableObject>(
        key: AppSessionRuntimeKey,
        create: @MainActor () -> Runtime,
        isBusy: @escaping @MainActor (Runtime) -> Bool,
        shutdown: @escaping @MainActor (Runtime, String) async -> Void
    ) -> Runtime {
        if let existing = validationRuntimeObjects[key] {
            guard let typed = existing as? Runtime else {
                preconditionFailure("Phase-L validation runtime type changed for \(key)")
            }
            return typed
        }
        precondition(state == .running, "Phase-L validation runtime registered after quiescing")
        precondition(entries[key] == nil, "Phase-L validation key collides with a production runtime")
        let runtime = create()
        validationRuntimeObjects[key] = runtime
        entries[key] = RuntimeEntry(
            isBusy: { isBusy(runtime) },
            shutdown: { reason in await shutdown(runtime, reason) })
        observe(runtime, key: key)
        return runtime
    }
    #endif

    private func observe<Runtime: ObservableObject>(
        _ runtime: Runtime,
        key: AppSessionRuntimeKey
    ) {
        runtimeObservations[key] = runtime.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.markRuntimeChanged()
            }
        }
        markRuntimeChanged()
    }

    private func markRuntimeChanged() {
        runtimeRevision &+= 1
    }
}
#endif
