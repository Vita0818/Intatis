#if os(macOS)
import XCTest
@testable import IntatisSharedUI

@MainActor
final class ThreadScrollCoordinatorTests: XCTestCase {
    private let codeA = IntatisThreadPresentationScope(
        kind: "code",
        sessionID: "code-a")
    private let codeB = IntatisThreadPresentationScope(
        kind: "code",
        sessionID: "code-b")
    private let coworkA = IntatisThreadPresentationScope(
        kind: "cowork",
        sessionID: "cowork-a")

    func testScopeAndBottomAnchorAreSessionSpecific() {
        XCTAssertNotEqual(codeA, codeB)
        XCTAssertNotEqual(codeA, coworkA)
        XCTAssertNotEqual(
            IntatisThreadBottomAnchorID(scope: codeA),
            IntatisThreadBottomAnchorID(scope: codeB))
    }

    func testScopeChangeCancelsPendingRequest() async {
        let coordinator = IntatisThreadScrollCoordinator()
        var executed: [IntatisThreadScrollRequest] = []
        coordinator.activate(scope: codeA)
        coordinator.request(scope: codeA, reason: .liveUpdate) {
            executed.append($0)
        }

        coordinator.activate(scope: codeB)
        await drainMainActor()

        XCTAssertTrue(executed.isEmpty)
        XCTAssertEqual(coordinator.activeScope, codeB)
        XCTAssertNil(coordinator.pendingRequest)
        XCTAssertEqual(coordinator.cancellationCount, 1)
    }

    func testBurstCoalescesToLatestGeneration() async {
        let coordinator = IntatisThreadScrollCoordinator()
        var executed: [IntatisThreadScrollRequest] = []
        coordinator.activate(scope: codeA)

        for _ in 0..<100 {
            coordinator.request(scope: codeA, reason: .liveUpdate) {
                executed.append($0)
            }
        }
        await drainMainActor()

        XCTAssertEqual(executed.count, 1)
        XCTAssertEqual(executed.first?.generation, coordinator.generation)
        XCTAssertEqual(coordinator.executionCount, 1)
        XCTAssertEqual(coordinator.cancellationCount, 99)
        XCTAssertNil(coordinator.pendingRequest)
    }

    func testUserLeavingBottomSuppressesLiveUpdatesUntilReturning() async {
        let coordinator = IntatisThreadScrollCoordinator()
        var executed: [IntatisThreadScrollReason] = []
        coordinator.activate(scope: codeA)
        coordinator.userInteractionDidBegin(scope: codeA)
        coordinator.updateBottomProximity(false, scope: codeA)
        coordinator.userInteractionDidEnd(scope: codeA)

        XCTAssertFalse(coordinator.isFollowingBottom)
        XCTAssertNil(coordinator.request(
            scope: codeA,
            reason: .liveUpdate
        ) { executed.append($0.reason) })

        coordinator.userInteractionDidBegin(scope: codeA)
        coordinator.updateBottomProximity(true, scope: codeA)
        coordinator.userInteractionDidEnd(scope: codeA)
        coordinator.request(scope: codeA, reason: .liveUpdate) {
            executed.append($0.reason)
        }
        await drainMainActor()

        XCTAssertTrue(coordinator.isFollowingBottom)
        XCTAssertEqual(executed, [.liveUpdate])
    }

    func testInitialRestoreIsUnanimatedAndCompletionIsAnimated() async {
        let coordinator = IntatisThreadScrollCoordinator()
        var executed: [IntatisThreadScrollRequest] = []
        coordinator.activate(scope: codeA)
        coordinator.request(scope: codeA, reason: .initialRestore) {
            executed.append($0)
        }
        await drainMainActor()
        coordinator.request(scope: codeA, reason: .completion) {
            executed.append($0)
        }
        await drainMainActor()

        XCTAssertEqual(executed.map(\.reason), [.initialRestore, .completion])
        XCTAssertEqual(executed.map(\.animated), [false, true])
    }

    func testWindowLocalCoordinatorsDoNotCancelEachOther() async {
        let firstWindow = IntatisThreadScrollCoordinator()
        let secondWindow = IntatisThreadScrollCoordinator()
        var firstExecutions = 0
        var secondExecutions = 0
        firstWindow.activate(scope: codeA)
        secondWindow.activate(scope: codeA)

        firstWindow.request(scope: codeA, reason: .liveUpdate) { _ in
            firstExecutions += 1
        }
        secondWindow.request(scope: codeA, reason: .liveUpdate) { _ in
            secondExecutions += 1
        }
        firstWindow.deactivate(scope: codeA)
        await drainMainActor()

        XCTAssertEqual(firstExecutions, 0)
        XCTAssertEqual(secondExecutions, 1)
    }

    func testGeometryUsesToleranceAndIgnoresSubpixelHeightJitter() {
        let atBottom = IntatisThreadScrollGeometry.measure(
            contentOffsetY: 476,
            containerHeight: 500,
            bottomInset: 0,
            contentHeight: 1_000)
        XCTAssertTrue(atBottom.isAtBottom)

        let previous = IntatisThreadScrollGeometry(
            isAtBottom: true,
            contentHeight: 1_000)
        let jitter = IntatisThreadScrollGeometry(
            isAtBottom: false,
            contentHeight: 1_000.5)
        let materialGrowth = IntatisThreadScrollGeometry(
            isAtBottom: false,
            contentHeight: 1_002)
        XCTAssertFalse(jitter.hasMaterialHeightChange(from: previous))
        XCTAssertTrue(materialGrowth.hasMaterialHeightChange(from: previous))
    }

    func testRichHeightCorrectionRequiresBottomFollowing() async {
        let coordinator = IntatisThreadScrollCoordinator()
        var executions = 0
        coordinator.activate(scope: coworkA)
        coordinator.userInteractionDidBegin(scope: coworkA)
        coordinator.updateBottomProximity(false, scope: coworkA)
        coordinator.userInteractionDidEnd(scope: coworkA)

        XCTAssertNil(coordinator.requestRichHeightCorrection(
            scope: coworkA,
            contentHeight: 1_000
        ) { _ in
            executions += 1
        })
        await drainMainActor()
        XCTAssertEqual(executions, 0)

        coordinator.userInteractionDidBegin(scope: coworkA)
        coordinator.updateBottomProximity(true, scope: coworkA)
        coordinator.userInteractionDidEnd(scope: coworkA)
        XCTAssertNotNil(coordinator.requestRichHeightCorrection(
            scope: coworkA,
            contentHeight: 1_000
        ) { _ in
            executions += 1
        })
        await drainMainActor()
        XCTAssertEqual(executions, 1)

        XCTAssertNil(coordinator.requestRichHeightCorrection(
            scope: coworkA,
            contentHeight: 999.5
        ) { _ in
            executions += 1
        })
        XCTAssertNotNil(coordinator.requestRichHeightCorrection(
            scope: coworkA,
            contentHeight: 1_002
        ) { _ in
            executions += 1
        })
        await drainMainActor()
        XCTAssertEqual(executions, 2)

        // A completed layout can legitimately shrink (for example after a
        // width or rich-document replacement) and later grow again without
        // reaching its older peak. Reaching bottom at the smaller height
        // starts a new bounded correction baseline.
        coordinator.updateBottomProximity(
            true,
            contentHeight: 800,
            scope: coworkA)
        XCTAssertNotNil(coordinator.requestRichHeightCorrection(
            scope: coworkA,
            contentHeight: 900
        ) { _ in
            executions += 1
        })
        await drainMainActor()
        XCTAssertEqual(executions, 3)

        // The same shrink/regrow oscillation cannot reopen the recovery
        // window within this content/width epoch.
        coordinator.updateBottomProximity(
            true,
            contentHeight: 800,
            scope: coworkA)
        XCTAssertNil(coordinator.requestRichHeightCorrection(
            scope: coworkA,
            contentHeight: 900
        ) { _ in
            executions += 1
        })
        await drainMainActor()
        XCTAssertEqual(executions, 3)

        // A real raw-content or width revision begins a new bounded epoch.
        coordinator.beginLayoutEpoch(scope: coworkA)
        coordinator.updateBottomProximity(
            true,
            contentHeight: 800,
            scope: coworkA)
        XCTAssertNotNil(coordinator.requestRichHeightCorrection(
            scope: coworkA,
            contentHeight: 900
        ) { _ in
            executions += 1
        })
        await drainMainActor()
        XCTAssertEqual(executions, 4)
    }

    private func drainMainActor() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}
#endif
