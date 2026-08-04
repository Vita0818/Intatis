#if os(macOS)
import XCTest
import IntatisCore
import IntatisConversation
@testable import IntatisSharedUI

@MainActor
final class CoworkAgentThreadPresentationModelTests: XCTestCase {
    func testDefaultsToMainAndRejectsNonSelectableReviewer() async {
        let model = makeImmediateModel()
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        await settle()

        XCTAssertEqual(model.selectedAgentID, "main")
        XCTAssertEqual(model.page.agentID.rawValue, "main")

        model.select("permission-reviewer")
        await settle()
        XCTAssertEqual(model.selectedAgentID, "main")

        model.select("worker")
        await settle()
        XCTAssertEqual(model.selectedAgentID, "worker")
        XCTAssertEqual(model.page.items.map(\.id), ["worker-row"])
    }

    func testRapidMainToWorkerToWriterCommitsOnlyWriter() async throws {
        let model = CoworkAgentThreadPresentationModel(
            mainAgentID: "main",
            loadPage: { agentID, _ in
                let delay: UInt64
                switch agentID.rawValue {
                case "main": delay = 80_000_000
                case "worker": delay = 50_000_000
                default: delay = 0
                }
                try? await Task.sleep(nanoseconds: delay)
                return Self.page(agentID: agentID)
            },
            updates: { _ in AsyncStream { $0.finish() } })
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker", "writer"])
        model.select("worker")
        model.select("writer")

        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(model.selectedAgentID, "writer")
        XCTAssertEqual(model.page.agentID.rawValue, "writer")
        XCTAssertEqual(model.page.items.map(\.id), ["writer-row"])
    }

    func testHistoricalDetachedSelectionRemainsSelected() async {
        let model = makeImmediateModel()
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        model.select("worker")
        await settle()
        XCTAssertEqual(model.selectedAgentID, "worker")

        model.reconcile(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        await settle()
        XCTAssertEqual(model.selectedAgentID, "worker")
        XCTAssertEqual(model.page.agentID.rawValue, "worker")
    }

    func testSelectionFallsBackWhenIdentityIsMissingFromHistoricalCatalog() async {
        let model = makeImmediateModel()
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        model.select("worker")
        await settle()

        model.reconcile(
            mainAgentID: "main",
            selectableAgentIDs: ["main"])
        await settle()
        XCTAssertEqual(model.selectedAgentID, "main")
        XCTAssertEqual(model.page.agentID.rawValue, "main")
    }

    func testLargeHistoricalCatalogKeepsDetachedIdentitySelectable() async {
        let model = makeImmediateModel()
        let historicalIDs = ["main"]
            + (0..<512).map { "worker-\($0)" }
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: historicalIDs)
        model.select("worker-0")
        await settle()

        model.reconcile(
            mainAgentID: "main",
            selectableAgentIDs: historicalIDs)
        await settle()

        XCTAssertEqual(model.selectedAgentID, "worker-0")
        XCTAssertEqual(model.page.agentID.rawValue, "worker-0")
        XCTAssertEqual(model.page.items.map(\.id), ["worker-0-row"])
    }

    func testEachAgentRestoresItsOwnEarlierBoundary() async {
        let recorder = PageRequestRecorder()
        let model = CoworkAgentThreadPresentationModel(
            mainAgentID: "main",
            loadPage: { agentID, upperBound in
                recorder.requests.append((agentID.rawValue, upperBound))
                return Self.page(
                    agentID: agentID,
                    upperBound: upperBound ?? 40,
                    totalCount: 40)
            },
            updates: { _ in AsyncStream { $0.finish() } })
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        await settle()
        model.showEarlier()
        await settle()
        XCTAssertEqual(model.page.upperBound, 24)

        model.select("worker")
        await settle()
        model.select("main")
        await settle()

        XCTAssertEqual(model.page.agentID.rawValue, "main")
        XCTAssertEqual(model.page.upperBound, 24)
        XCTAssertEqual(recorder.requests.last?.0, "main")
        XCTAssertEqual(recorder.requests.last?.1, 24)
    }

    func testNonSelectedAgentUpdateDoesNotPublishCurrentTranscript() async {
        let recorder = PageRequestRecorder()
        let source = TestAgentThreadUpdateSource()
        let model = CoworkAgentThreadPresentationModel(
            mainAgentID: "main",
            loadPage: { agentID, _ in
                recorder.requests.append((agentID.rawValue, nil))
                return Self.page(agentID: agentID)
            },
            updates: { agentID in source.stream(for: agentID) })
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        await settle()
        let initialCount = recorder.requests.count

        source.publish(agentID: AgentID(rawValue: "worker"))
        await settle()
        XCTAssertEqual(recorder.requests.count, initialCount)

        source.publish(agentID: AgentID(rawValue: "main"))
        await settle()
        XCTAssertEqual(recorder.requests.count, initialCount + 1)
    }

    func testTwoWindowPresentationModelsKeepIndependentSelections() async {
        let firstWindow = makeImmediateModel()
        let secondWindow = makeImmediateModel()
        firstWindow.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        secondWindow.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        await settle()

        firstWindow.select("worker")
        await settle()

        XCTAssertEqual(firstWindow.selectedAgentID, "worker")
        XCTAssertEqual(firstWindow.page.agentID.rawValue, "worker")
        XCTAssertEqual(secondWindow.selectedAgentID, "main")
        XCTAssertEqual(secondWindow.page.agentID.rawValue, "main")
    }

    func testRichRenderingWaitsForStableSelectionDwell() async throws {
        let model = CoworkAgentThreadPresentationModel(
            mainAgentID: "main",
            richRenderingDwell: .milliseconds(30),
            loadPage: { agentID, _ in Self.page(agentID: agentID) },
            updates: { _ in AsyncStream { $0.finish() } })
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        await settle()
        XCTAssertFalse(model.isRichRenderingEligible)

        model.select("worker")
        try await Task.sleep(nanoseconds: 15_000_000)
        XCTAssertFalse(model.isRichRenderingEligible)
        try await Task.sleep(nanoseconds: 35_000_000)
        XCTAssertTrue(model.isRichRenderingEligible)
        XCTAssertEqual(model.page.agentID.rawValue, "worker")
    }

    func testSelectedAgentUpdateRestartsRichRenderingDwell() async throws {
        let source = TestAgentThreadUpdateSource()
        let model = CoworkAgentThreadPresentationModel(
            mainAgentID: "main",
            richRenderingDwell: .milliseconds(30),
            loadPage: { agentID, _ in Self.page(agentID: agentID) },
            updates: { agentID in source.stream(for: agentID) })
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main"])
        try await Task.sleep(nanoseconds: 45_000_000)
        XCTAssertTrue(model.isRichRenderingEligible)

        source.publish(agentID: AgentID(rawValue: "main"))
        await Task.yield()
        XCTAssertFalse(model.isRichRenderingEligible)
        try await Task.sleep(nanoseconds: 15_000_000)
        XCTAssertFalse(model.isRichRenderingEligible)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(model.isRichRenderingEligible)
    }

    private func makeImmediateModel() -> CoworkAgentThreadPresentationModel {
        CoworkAgentThreadPresentationModel(
            mainAgentID: "main",
            loadPage: { agentID, upperBound in
                Self.page(
                    agentID: agentID,
                    upperBound: upperBound ?? 1,
                    totalCount: 1)
            },
            updates: { _ in AsyncStream { $0.finish() } })
    }

    private static func page(
        agentID: AgentID,
        upperBound: Int = 1,
        totalCount: Int = 1
    ) -> CoworkAgentThreadPage {
        let lowerBound = max(0, upperBound - 16)
        return CoworkAgentThreadPage(
            agentID: agentID,
            items: [CodeItem(
                id: "\(agentID.rawValue)-row",
                kind: .agent,
                title: agentID.rawValue,
                body: agentID.rawValue)],
            lowerBound: lowerBound,
            upperBound: upperBound,
            totalCount: totalCount,
            capacity: 16,
            projectedThroughSeq: 1,
            projectionGeneration: UUID(),
            isAgentWorking: false)
    }

    private func settle() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
        await Task.yield()
    }
}

@MainActor
private final class PageRequestRecorder {
    var requests: [(String, Int?)] = []
}

@MainActor
private final class TestAgentThreadUpdateSource {
    private var continuations: [
        AgentID: [AsyncStream<CoworkAgentThreadUpdate>.Continuation]
    ] = [:]
    private var revision: UInt64 = 0

    func stream(
        for agentID: AgentID
    ) -> AsyncStream<CoworkAgentThreadUpdate> {
        let pair = AsyncStream<CoworkAgentThreadUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        continuations[agentID, default: []].append(pair.continuation)
        return pair.stream
    }

    func publish(agentID: AgentID) {
        revision &+= 1
        let update = CoworkAgentThreadUpdate(
            agentID: agentID,
            throughSeq: Int(revision),
            revision: revision)
        for continuation in continuations[agentID] ?? [] {
            continuation.yield(update)
        }
    }
}
#endif
