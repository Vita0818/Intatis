#if canImport(SwiftUI)
import Foundation
import SwiftUI
import IntatisCore
import IntatisConversation

/// Window-local selected-agent transcript state. Runtime ownership remains in
/// AppSessionRuntimeManager/CoworkViewModel; this object owns only selection,
/// one bounded page, request generations, and lightweight per-agent page
/// boundaries.
@MainActor
public final class CoworkAgentThreadPresentationModel: ObservableObject {
    public typealias PageLoader = @MainActor @Sendable (
        _ agentID: AgentID,
        _ requestedUpperBound: Int?
    ) async -> CoworkAgentThreadPage
    public typealias UpdateStream = @MainActor @Sendable (
        _ agentID: AgentID
    ) -> AsyncStream<CoworkAgentThreadUpdate>

    @Published public private(set) var selectedAgentID: String
    @Published public private(set) var page: CoworkAgentThreadPage
    @Published public private(set) var isLoading = false
    @Published public private(set) var isRichRenderingEligible = false

    private var mainAgentID: AgentID
    private var selectableAgentIDs: Set<AgentID>
    private var requestedUpperBounds: [AgentID: Int] = [:]
    private var requestGeneration: UInt64 = 0
    private var pendingSwitchGeneration: UInt64?
    private var pendingSwitchStartedAt: UInt64?
    private var pageTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var richEligibilityTask: Task<Void, Never>?
    private var pendingRichEligibilityGeneration: UInt64?
    private var isActive = false
    private let richRenderingDwell: Duration
    private let loadPage: PageLoader
    private let updates: UpdateStream

    public init(
        mainAgentID: String,
        richRenderingDwell: Duration = .milliseconds(300),
        loadPage: @escaping PageLoader,
        updates: @escaping UpdateStream
    ) {
        let main = AgentID(rawValue: mainAgentID)
        self.mainAgentID = main
        self.selectableAgentIDs = [main]
        self.selectedAgentID = main.rawValue
        self.page = .empty(agentID: main)
        self.richRenderingDwell = richRenderingDwell
        self.loadPage = loadPage
        self.updates = updates
    }

    deinit {
        pageTask?.cancel()
        updateTask?.cancel()
        richEligibilityTask?.cancel()
    }

    public func activate(
        mainAgentID: String,
        selectableAgentIDs: [String]
    ) {
        isActive = true
        reconcile(
            mainAgentID: mainAgentID,
            selectableAgentIDs: selectableAgentIDs)
        beginSelection(
            clearVisiblePage: page.projectedThroughSeq < 0,
            recordsSwitch: true)
    }

    public func deactivate() {
        recordPendingSwitchAsStale()
        isActive = false
        requestGeneration &+= 1
        pageTask?.cancel()
        pageTask = nil
        updateTask?.cancel()
        updateTask = nil
        richEligibilityTask?.cancel()
        richEligibilityTask = nil
        pendingRichEligibilityGeneration = nil
        isRichRenderingEligible = false
        isLoading = false
    }

    public func reconcile(
        mainAgentID: String,
        selectableAgentIDs: [String]
    ) {
        let wasViewingMain = selectedAgentID == self.mainAgentID.rawValue
        let nextMain = AgentID(rawValue: mainAgentID)
        let nextSelectable = Set(
            selectableAgentIDs.map { AgentID(rawValue: $0) })
            .union([nextMain])
        self.mainAgentID = nextMain
        self.selectableAgentIDs = nextSelectable

        if wasViewingMain,
           selectedAgentID != nextMain.rawValue {
            selectedAgentID = nextMain.rawValue
            beginSelection(clearVisiblePage: true, recordsSwitch: true)
            return
        }

        let selected = AgentID(rawValue: selectedAgentID)
        guard nextSelectable.contains(selected) else {
            select(nextMain.rawValue)
            return
        }
    }

    public func select(_ agentID: String) {
        let candidate = AgentID(rawValue: agentID)
        guard selectableAgentIDs.contains(candidate) else { return }
        guard candidate.rawValue != selectedAgentID else { return }
        selectedAgentID = candidate.rawValue
        beginSelection(clearVisiblePage: true, recordsSwitch: true)
    }

    public func showEarlier() {
        guard let upperBound = page.earlierRequestedUpperBound else { return }
        setRequestedUpperBound(upperBound)
    }

    public func showNewer() {
        guard page.hasLater else { return }
        setRequestedUpperBound(page.newerRequestedUpperBound)
    }

    public func showLatest() {
        setRequestedUpperBound(nil)
    }

    private func setRequestedUpperBound(_ upperBound: Int?) {
        let agent = AgentID(rawValue: selectedAgentID)
        if let upperBound {
            requestedUpperBounds[agent] = upperBound
        } else {
            requestedUpperBounds.removeValue(forKey: agent)
        }
        requestPage(
            clearVisiblePage: false,
            resetsRichEligibility: true)
    }

    private func beginSelection(
        clearVisiblePage: Bool,
        recordsSwitch: Bool
    ) {
        guard isActive else { return }
        recordPendingSwitchAsStale()
        requestGeneration &+= 1
        let generation = requestGeneration
        if recordsSwitch {
            pendingSwitchGeneration = generation
            pendingSwitchStartedAt = DispatchTime.now().uptimeNanoseconds
            IntatisPerformanceDiagnostics.shared.recordCoworkAgentSwitch(
                outcome: .requested,
                generation: generation)
        }
        prepareRichEligibility(generation: generation)
        let agent = AgentID(rawValue: selectedAgentID)
        pageTask?.cancel()
        updateTask?.cancel()
        if clearVisiblePage {
            page = .empty(agentID: agent)
        }
        subscribe(to: agent, generation: generation)
        requestPage(clearVisiblePage: false, generation: generation)
    }

    private func subscribe(to agent: AgentID, generation: UInt64) {
        let stream = updates(agent)
        updateTask = Task { @MainActor [weak self] in
            for await update in stream {
                guard let self,
                      !Task.isCancelled,
                      self.isActive,
                      self.requestGeneration == generation,
                      self.selectedAgentID == update.agentID.rawValue else {
                    return
                }
                self.requestPage(
                    clearVisiblePage: false,
                    generation: generation,
                    resetsRichEligibility: true)
            }
        }
    }

    private func requestPage(
        clearVisiblePage: Bool,
        generation explicitGeneration: UInt64? = nil,
        resetsRichEligibility: Bool = false
    ) {
        guard isActive else { return }
        let generation: UInt64
        if let explicitGeneration {
            generation = explicitGeneration
        } else {
            recordPendingSwitchAsStale()
            requestGeneration &+= 1
            generation = requestGeneration
            let agent = AgentID(rawValue: selectedAgentID)
            updateTask?.cancel()
            subscribe(to: agent, generation: generation)
        }
        if resetsRichEligibility {
            prepareRichEligibility(generation: generation)
        }
        let agent = AgentID(rawValue: selectedAgentID)
        let upperBound = requestedUpperBounds[agent]
        pageTask?.cancel()
        if clearVisiblePage {
            page = .empty(agentID: agent)
        }
        isLoading = true
        pageTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let loaded = await self.loadPage(agent, upperBound)
            guard !Task.isCancelled,
                  self.isActive,
                  self.requestGeneration == generation,
                  self.selectedAgentID == agent.rawValue,
                  loaded.agentID == agent else {
                if self.pendingSwitchGeneration == generation {
                    self.recordPendingSwitchAsStale()
                }
                return
            }
            self.page = loaded
            self.isLoading = false
            self.scheduleRichEligibilityIfNeeded(
                generation: generation)
            if self.pendingSwitchGeneration == generation {
                let now = DispatchTime.now().uptimeNanoseconds
                let startedAt = self.pendingSwitchStartedAt ?? now
                IntatisPerformanceDiagnostics.shared.recordCoworkAgentSwitch(
                    outcome: .committed,
                    durationNanoseconds: now >= startedAt
                        ? now - startedAt
                        : 0,
                    generation: generation,
                    rowCount: loaded.items.count)
                self.pendingSwitchGeneration = nil
                self.pendingSwitchStartedAt = nil
            } else {
                IntatisPerformanceDiagnostics.shared
                    .recordCoworkAgentThreadPublication(
                        rowCount: loaded.items.count)
            }
        }
    }

    private func recordPendingSwitchAsStale() {
        guard let generation = pendingSwitchGeneration else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let startedAt = pendingSwitchStartedAt ?? now
        IntatisPerformanceDiagnostics.shared.recordCoworkAgentSwitch(
            outcome: .stale,
            durationNanoseconds: now >= startedAt ? now - startedAt : 0,
            generation: generation)
        pendingSwitchGeneration = nil
        pendingSwitchStartedAt = nil
    }

    /// Repeated agent/page navigation keeps the bounded raw page visible but
    /// must not mount a fresh AppKit Markdown selection tree for every click.
    /// Rich rendering is admitted only after one exact selection has remained
    /// stable for a short, cancellable dwell.
    private func prepareRichEligibility(generation: UInt64) {
        richEligibilityTask?.cancel()
        richEligibilityTask = nil
        pendingRichEligibilityGeneration = generation
        if isRichRenderingEligible {
            isRichRenderingEligible = false
        }
    }

    private func scheduleRichEligibilityIfNeeded(generation: UInt64) {
        guard pendingRichEligibilityGeneration == generation else { return }
        pendingRichEligibilityGeneration = nil
        richEligibilityTask?.cancel()
        richEligibilityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.richRenderingDwell)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.isActive,
                  self.requestGeneration == generation,
                  self.page.agentID.rawValue == self.selectedAgentID else {
                return
            }
            self.isRichRenderingEligible = true
            self.richEligibilityTask = nil
        }
    }
}
#endif
