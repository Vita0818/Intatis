#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisSharedUI

@MainActor
private final class WorkspaceChromeStressModel: ObservableObject {
    @Published var mode = 0
    @Published var codeInspector = true
    @Published var coworkInspector = true
    @Published var coworkSelectedAgentID = "main"
}

private struct WorkspaceChromeStressHarness: View {
    @ObservedObject var model: WorkspaceChromeStressModel
    @State private var codeInput = ""
    @State private var coworkInput = ""

    var body: some View {
        NavigationSplitView {
            VStack {
                Text("Intatis")
                Text("Chat")
                Text("Code")
                Text("Cowork")
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detail
        }
        .navigationTitle("")
    }

    @ViewBuilder private var detail: some View {
        switch model.mode {
        case 1:
            CodeShell(
                items: [],
                presentationScope: IntatisThreadPresentationScope(
                    kind: "code",
                    sessionID: "layout-stress-code"),
                sessionTitle: "Code",
                pending: nil,
                isWorking: false,
                workspaceName: "Workspace",
                agentState: "idle",
                showsInspector: Binding(
                    get: { model.codeInspector },
                    set: { model.codeInspector = $0 }),
                input: $codeInput,
                onSend: {},
                onResolve: { _ in })
        case 2:
            CoworkShell(
                threadPage: .empty(
                    agentID: AgentID(
                        rawValue: model.coworkSelectedAgentID)),
                presentationScope: IntatisThreadPresentationScope(
                    kind: "cowork",
                    sessionID: "layout-stress-cowork"),
                sessionTitle: "Cowork",
                agents: [
                    CoworkAgentInfo(
                        id: "main",
                        name: "main",
                        workspace: "Workspace",
                        model: "Model A",
                        profile: "full"),
                    CoworkAgentInfo(
                        id: "worker",
                        name: "worker",
                        workspace: "Workspace",
                        model: "Model B",
                        profile: "read-only",
                        isAttached: false),
                ],
                pending: nil,
                summary: CoworkStatusSummary(),
                composerError: nil,
                isWorking: false,
                showsInspector: Binding(
                    get: { model.coworkInspector },
                    set: { model.coworkInspector = $0 }),
                input: $coworkInput,
                onSend: {},
                onResolve: { _ in },
                selectedAgentID: model.coworkSelectedAgentID,
                onSelectAgent: { model.coworkSelectedAgentID = $0 },
                onShowEarlier: {},
                onShowNewer: {},
                onShowLatest: {})
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text("Chat")
                    .font(.largeTitle)
                Spacer()
                TextField("Message", text: .constant(""))
            }
            .padding(24)
        }
    }
}

final class ThreadLayoutTests: XCTestCase {
    func testLeadingAssistantAndAgentRowsUseTheFullAvailableWidth() {
        XCTAssertEqual(
            IntatisThreadBubbleWidthPolicy.resolve(
                isTrailing: false,
                fillsAvailableWidth: true,
                maxWidth: 560,
                gutter: 48),
            .fullWidthLeading)
    }

    func testTrailingUserRowsKeepTheirBubbleWidthAndLeadingGutter() {
        XCTAssertEqual(
            IntatisThreadBubbleWidthPolicy.resolve(
                isTrailing: true,
                fillsAvailableWidth: false,
                maxWidth: 560,
                gutter: 48),
            .constrained(isTrailing: true, maxWidth: 560, gutter: 48))
    }

    func testOtherLeadingRowsKeepTheirExistingConstrainedLayout() {
        XCTAssertEqual(
            IntatisThreadBubbleWidthPolicy.resolve(
                isTrailing: false,
                fillsAvailableWidth: false,
                maxWidth: 560,
                gutter: 48),
            .constrained(isTrailing: false, maxWidth: 560, gutter: 48))
    }

    func testUserMessagesDoNotRepeatAnIdentityHeader() {
        XCTAssertFalse(IntatisMessageHeaderPolicy.showsIdentity(for: .user))
        XCTAssertTrue(IntatisMessageHeaderPolicy.showsIdentity(for: .assistant))
        XCTAssertTrue(IntatisMessageHeaderPolicy.showsIdentity(for: .agent))
        XCTAssertTrue(IntatisMessageHeaderPolicy.showsIdentity(for: .system))
    }

    func testPermissionDetailsUseStructuredScopeWithoutRawArguments() {
        let request = PermissionRequestPayload(
            requestId: RequestID(rawValue: "permission-ui-test"),
            tool: "apply_patch",
            args: #"{"apiKey":"must-not-render","path":"Sources/App.swift"}"#,
            risk: .medium,
            reason: "Update the app",
            context: PermissionRequestContext(
                touchedPaths: ["Sources/App.swift"],
                sideEffect: .write,
                intent: PermissionIntent(
                    action: "filesystem.patch",
                    resources: [PermissionResource(
                        kind: .workspacePath,
                        value: "Sources/App.swift",
                        access: .readWrite)],
                    dataEffects: [.mutate],
                    risks: [.workspaceMutation],
                    replayPolicy: .requiresManualReconciliation)))

        let renderedDetails = PermissionReviewPresentation.details(for: request)
            .map(\.text)
            .joined(separator: " ")

        XCTAssertTrue(renderedDetails.contains("filesystem.patch"))
        XCTAssertTrue(renderedDetails.contains("Sources/App.swift"))
        XCTAssertFalse(renderedDetails.contains("must-not-render"))
        XCTAssertFalse(renderedDetails.contains("apiKey"))
    }

    func testPermissionDiffRemainsAvailableOnlyInsideDetails() {
        let args = #"{"diff":"*** Begin Patch\n*** End Patch"}"#
        XCTAssertEqual(
            PermissionCard.diff(from: args),
            "*** Begin Patch\n*** End Patch")
    }

    func testCompactPermissionSummaryDoesNotRenderRawArguments() {
        let request = PermissionRequestPayload(
            requestId: RequestID(rawValue: "compact-permission-ui-test"),
            tool: "write_file",
            args: #"{"apiKey":"must-not-render","path":"Sources/App.swift"}"#,
            risk: .medium,
            reason: "Update the selected workspace file")

        let summary = PermissionReviewPresentation.compactSummary(for: request)

        XCTAssertEqual(summary, "Update the selected workspace file")
        XCTAssertFalse(summary.contains("must-not-render"))
        XCTAssertFalse(summary.contains("apiKey"))
    }

    func testWorkspaceInspectorUsesOnlyTheStableOuterWidth() {
        let hidden = IntatisWorkspaceInspectorLayoutPolicy.resolve(
            availableWidth: 979,
            isRequested: true,
            activationWidth: 980,
            minimumThreadWidth: 620,
            minimumInspectorWidth: 286,
            idealInspectorWidth: 318,
            maximumInspectorWidth: 390)
        XCTAssertEqual(
            hidden,
            IntatisWorkspaceInspectorLayout(
                isVisible: false,
                threadWidth: 979,
                inspectorWidth: 0))

        let visible = IntatisWorkspaceInspectorLayoutPolicy.resolve(
            availableWidth: 980,
            isRequested: true,
            activationWidth: 980,
            minimumThreadWidth: 620,
            minimumInspectorWidth: 286,
            idealInspectorWidth: 318,
            maximumInspectorWidth: 390)
        XCTAssertTrue(visible.isVisible)
        XCTAssertEqual(visible.inspectorWidth, 318)
        XCTAssertEqual(
            visible.threadWidth + visible.inspectorWidth + 1,
            980)
        XCTAssertLessThan(visible.threadWidth, 980)

        let integratedCowork = IntatisWorkspaceInspectorLayoutPolicy.resolve(
            availableWidth: 980,
            isRequested: true,
            activationWidth: 980,
            minimumThreadWidth: 620,
            minimumInspectorWidth: 286,
            idealInspectorWidth: 318,
            maximumInspectorWidth: 390,
            dividerWidth: 0)
        XCTAssertTrue(integratedCowork.isVisible)
        XCTAssertEqual(
            integratedCowork.threadWidth + integratedCowork.inspectorWidth,
            980)

        for _ in 0..<10_000 {
            XCTAssertEqual(
                IntatisWorkspaceInspectorLayoutPolicy.resolve(
                    availableWidth: 980,
                    isRequested: true,
                    activationWidth: 980,
                    minimumThreadWidth: 620,
                    minimumInspectorWidth: 286,
                    idealInspectorWidth: 318,
                    maximumInspectorWidth: 390),
                visible)
        }
    }

    func testCoworkStatusRailAndConversationWidthStayFixedAcrossContentStates() {
        XCTAssertEqual(IntatisCoworkStatusRailLayoutPolicy.railWidth, 348)
        XCTAssertEqual(IntatisCoworkStatusRailLayoutPolicy.cardWidth, 318)
        XCTAssertEqual(IntatisCoworkStatusRailLayoutPolicy.cardSpacing, 18)

        for availableWidth in [CGFloat(980), 1_100, 1_372, 1_800] {
            let emptyConversation =
                IntatisCoworkStatusRailLayoutPolicy.resolve(
                    availableWidth: availableWidth,
                    isRequested: true)
            let longConversation =
                IntatisCoworkStatusRailLayoutPolicy.resolve(
                    availableWidth: availableWidth,
                    isRequested: true)

            XCTAssertEqual(emptyConversation, longConversation)
            XCTAssertTrue(emptyConversation.isVisible)
            XCTAssertEqual(emptyConversation.inspectorWidth, 348)
            XCTAssertEqual(
                emptyConversation.threadWidth
                    + emptyConversation.inspectorWidth,
                availableWidth)
        }
    }

    func testCoworkStatusRailRenderSnapshotExcludesConversationSelection() {
        let beforeSelection = CoworkStatusRailRenderSnapshot(
            agents: [],
            pending: nil,
            permissionNotice: nil,
            goal: nil,
            workTasks: CoworkWorkTaskSummary(),
            colorScheme: .light)
        let afterSelection = CoworkStatusRailRenderSnapshot(
            agents: [],
            pending: nil,
            permissionNotice: nil,
            goal: nil,
            workTasks: CoworkWorkTaskSummary(),
            colorScheme: .light)
        let changedRailState = CoworkStatusRailRenderSnapshot(
            agents: [],
            pending: nil,
            permissionNotice: nil,
            goal: nil,
            workTasks: CoworkWorkTaskSummary(tasks: [
                CoworkWorkTaskLine(
                    id: "finished",
                    title: "Finished",
                    status: "completed"),
            ]),
            colorScheme: .light)

        XCTAssertEqual(beforeSelection, afterSelection)
        XCTAssertNotEqual(beforeSelection, changedRailState)
    }

    func testWorkspaceInspectorNeverProducesInvalidGeometry() {
        for width in stride(from: CGFloat(-100), through: 2_000, by: 0.5) {
            let layout = IntatisWorkspaceInspectorLayoutPolicy.resolve(
                availableWidth: width,
                isRequested: true,
                activationWidth: 940,
                minimumThreadWidth: 620,
                minimumInspectorWidth: 260,
                idealInspectorWidth: 292,
                maximumInspectorWidth: 360)
            XCTAssertTrue(layout.threadWidth.isFinite)
            XCTAssertTrue(layout.inspectorWidth.isFinite)
            XCTAssertGreaterThan(layout.threadWidth, 0)
            XCTAssertGreaterThanOrEqual(layout.inspectorWidth, 0)
        }

        for invalidWidth in [
            CGFloat.infinity,
            -CGFloat.infinity,
            CGFloat.nan,
        ] {
            XCTAssertEqual(
                IntatisWorkspaceInspectorLayoutPolicy.resolve(
                    availableWidth: invalidWidth,
                    isRequested: true,
                    activationWidth: 940,
                    minimumThreadWidth: 620,
                    minimumInspectorWidth: 260,
                    idealInspectorWidth: 292,
                    maximumInspectorWidth: 360),
                IntatisWorkspaceInspectorLayout(
                    isVisible: false,
                    threadWidth: 1,
                    inspectorWidth: 0))
        }
    }

    func testWorkspaceThreadsDoNotVendWindowToolbarOrNestedInspectorPreferences() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for filename in ["CodeViews.swift", "CoworkViews.swift"] {
            let source = try String(
                contentsOf: packageRoot
                    .appendingPathComponent("Sources")
                    .appendingPathComponent(filename),
                encoding: .utf8)
            XCTAssertFalse(source.contains(".toolbar {"), filename)
            XCTAssertFalse(source.contains(".inspector("), filename)
            if filename == "CoworkViews.swift" {
                XCTAssertTrue(
                    source.contains(
                        "IntatisCoworkStatusRailLayoutPolicy.resolve("),
                    filename)
            } else {
                XCTAssertTrue(
                    source.contains(
                        "IntatisWorkspaceInspectorLayoutPolicy.resolve("),
                    filename)
            }
        }

        let coworkSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/CoworkViews.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            coworkSource.contains(".overlay(alignment: .trailing)"))
        XCTAssertFalse(
            coworkSource.contains("ZStack(alignment: .trailing)"))
        XCTAssertTrue(
            coworkSource.contains(
                "IntatisCoworkStatusRailLayoutPolicy.resolve("))
        XCTAssertTrue(coworkSource.contains("for: .scrollContent"))
        XCTAssertTrue(coworkSource.contains("primaryScrollerClearance"))
        XCTAssertTrue(coworkSource.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(
            coworkSource.contains("CoworkStatusRailRenderBoundary("))
        XCTAssertTrue(coworkSource.contains(".equatable()"))
        XCTAssertTrue(coworkSource.contains(
            ".frame(width: rawWidth, height: rawHeight)"))
        XCTAssertTrue(coworkSource.contains(
            ".overlay(alignment: .leading)"))
        XCTAssertTrue(coworkSource.contains(
            "not the transcript's intrinsic size"))
        XCTAssertFalse(coworkSource.contains(".visualEffect { content, proxy in"))
        XCTAssertFalse(coworkSource.contains(".pixelAlignmentOffset("))
        XCTAssertTrue(coworkSource.contains(
            "selection.selectedAgentID == agentID ? 1 : 0"))
        XCTAssertTrue(coworkSource.contains("transaction.animation = nil"))
        XCTAssertTrue(coworkSource.contains(
            "transaction.disablesAnimations = true"))
        XCTAssertFalse(
            coworkSource.contains(
                "IntatisGlassEffectGroup(\n                spacing: IntatisCoworkStatusRailLayoutPolicy"))

        let surfaceSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/ThreadSurfaces.swift"),
            encoding: .utf8)
        XCTAssertTrue(surfaceSource.contains(
            "private struct IntatisClearLiquidGlassBackdrop"))
        XCTAssertTrue(surfaceSource.contains(
            "content.background {\n                IntatisClearLiquidGlassBackdrop("))
        XCTAssertTrue(surfaceSource.contains(
            "colorScheme: colorScheme)\n                    .equatable()"))

        let railSnapshotStart = try XCTUnwrap(
            coworkSource.range(
                of: "struct CoworkStatusRailRenderSnapshot: Equatable"))
        let railSnapshotEnd = try XCTUnwrap(
            coworkSource.range(
                of: "private final class CoworkStatusRailSelectionState",
                range: railSnapshotStart.upperBound..<coworkSource.endIndex))
        let railSnapshotSource = coworkSource[
            railSnapshotStart.lowerBound..<railSnapshotEnd.lowerBound]
        XCTAssertFalse(railSnapshotSource.contains("threadPage"))
        XCTAssertFalse(railSnapshotSource.contains("isThreadPageLoading"))
        XCTAssertFalse(railSnapshotSource.contains("isRichRenderingEligible"))
        XCTAssertFalse(railSnapshotSource.contains("selectedAgentID"))

        let repositoryRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Apps/IntatisMac/Sources/IntatisMacApp.swift"),
            encoding: .utf8)
        let codeStart = try XCTUnwrap(
            appSource.range(of: "struct CodeSessionView: View"))
        let codeEnd = try XCTUnwrap(
            appSource.range(
                of: "struct CoworkSessionView: View",
                range: codeStart.upperBound..<appSource.endIndex))
        let coworkEnd = try XCTUnwrap(
            appSource.range(
                of: "private var goalEditorValidationMessage",
                range: codeEnd.upperBound..<appSource.endIndex))
        let workspaceSessionViews = appSource[
            codeStart.lowerBound..<coworkEnd.lowerBound]
        XCTAssertFalse(workspaceSessionViews.contains(".toolbar {"))
        XCTAssertTrue(workspaceSessionViews.contains("headerActions:"))
    }

    @MainActor
    func testProductionShapedWorkspaceChromeSurvivesRepeatedModeResizeAndInspectorChanges() {
        let model = WorkspaceChromeStressModel()
        let host = NSHostingView(
            rootView: AnyView(WorkspaceChromeStressHarness(model: model)))
        let initialFrame = NSRect(x: 0, y: 0, width: 1_180, height: 760)
        host.frame = initialFrame
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(host: host, window: window, cycles: 6)

        let widths: [CGFloat] = [860, 1_119, 1_120, 1_159, 1_160, 1_420]
        for cycle in 0..<360 {
            model.mode = cycle % 3
            model.codeInspector = cycle % 4 != 0
            model.coworkInspector = cycle % 5 != 0
            model.coworkSelectedAgentID = cycle.isMultiple(of: 2)
                ? "main"
                : "worker"
            window.setContentSize(NSSize(
                width: widths[cycle % widths.count],
                height: cycle.isMultiple(of: 2) ? 720 : 800))
            settle(host: host, window: window, cycles: 1)

            XCTAssertTrue(host.frame.width.isFinite)
            XCTAssertTrue(host.frame.height.isFinite)
            XCTAssertGreaterThan(host.frame.width, 0)
            XCTAssertGreaterThan(host.frame.height, 0)
        }

        window.orderOut(nil)
        host.rootView = AnyView(EmptyView())
        settle(host: host, window: window, cycles: 4)
        window.contentView = nil
    }

    @MainActor
    private func settle(
        host: NSHostingView<AnyView>,
        window: NSWindow,
        cycles: Int
    ) {
        for _ in 0..<cycles {
            window.displayIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            _ = RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.002))
        }
    }
}
#endif
