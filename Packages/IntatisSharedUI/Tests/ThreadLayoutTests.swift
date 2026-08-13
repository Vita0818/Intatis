#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import IntatisConversation
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
                errorTexts: [],
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
    func testIOSComposerGlassMergeThresholdStaysBelowRowGap() {
        XCTAssertEqual(IntatisComposerControlMetrics.rowSpacing, 8)
        XCTAssertEqual(
            IntatisComposerControlMetrics.glassEffectSpacing(for: .iOS),
            0)
        XCTAssertEqual(
            IntatisComposerControlMetrics.glassEffectSpacing(for: .macOS),
            10)
        XCTAssertLessThan(
            IntatisComposerControlMetrics.glassEffectSpacing(for: .iOS),
            IntatisComposerControlMetrics.rowSpacing)
    }

    func testComposerUsesPlatformControlSizeWithinSharedFortyPointGeometry() {
        XCTAssertEqual(IntatisComposerControlMetrics.controlHeight, 40)
        XCTAssertEqual(
            IntatisComposerControlMetrics.iconControlSize(for: .iOS),
            .small)
        XCTAssertEqual(
            IntatisComposerControlMetrics.iconControlSize(for: .macOS),
            .regular)
    }

    func testSidebarOpenGestureRequiresLeadingEdgeHorizontalIntent() {
        XCTAssertTrue(IntatisSidebarGesturePolicy.shouldOpen(
            startX: 8,
            translation: CGSize(width: 72, height: 8)))
        XCTAssertFalse(IntatisSidebarGesturePolicy.shouldOpen(
            startX: 40,
            translation: CGSize(width: 72, height: 8)))
        XCTAssertFalse(IntatisSidebarGesturePolicy.shouldOpen(
            startX: 8,
            translation: CGSize(width: 48, height: 4)))
        XCTAssertFalse(IntatisSidebarGesturePolicy.shouldOpen(
            startX: 8,
            translation: CGSize(width: 72, height: 64)))
        XCTAssertFalse(IntatisSidebarGesturePolicy.shouldOpen(
            startX: 8,
            translation: CGSize(width: -72, height: 4)))
    }

    func testSidebarCloseGestureRequiresHorizontalLeftIntent() {
        XCTAssertTrue(IntatisSidebarGesturePolicy.shouldClose(
            translation: CGSize(width: -60, height: 8)))
        XCTAssertFalse(IntatisSidebarGesturePolicy.shouldClose(
            translation: CGSize(width: -40, height: 4)))
        XCTAssertFalse(IntatisSidebarGesturePolicy.shouldClose(
            translation: CGSize(width: -60, height: 56)))
        XCTAssertFalse(IntatisSidebarGesturePolicy.shouldClose(
            translation: CGSize(width: 60, height: 4)))
    }

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

    func testOnlyUserConversationRowsUseNativeLiquidGlassBubble() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        func sourceSlice(
            _ source: String,
            from startMarker: String,
            to endMarker: String
        ) throws -> Substring {
            let start = try XCTUnwrap(source.range(of: startMarker))
            let end = try XCTUnwrap(source.range(
                of: endMarker,
                range: start.upperBound..<source.endIndex))
            return source[start.lowerBound..<end.lowerBound]
        }

        let sharedChatSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/Views.swift"),
            encoding: .utf8)
        let sharedMessageRow = try sourceSlice(
            sharedChatSource,
            from: "struct MessageRow: View",
            to: "struct ComposerView: View")
        XCTAssertTrue(sharedMessageRow.contains("if message.role == .user"))
        XCTAssertTrue(sharedMessageRow.contains(
            ".intatisLiquidGlass(cornerRadius: 10)"))
        XCTAssertFalse(sharedMessageRow.contains(".intatisContentSurface("))
        XCTAssertFalse(sharedMessageRow.contains("style.accent.opacity(0.64)"))
        XCTAssertFalse(sharedMessageRow.contains("isUninterruptedAgentReply"))

        let macChatSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent(
                    "Apps/IntatisMac/Sources/IntatisChatScreen.swift"),
            encoding: .utf8)
        let macMessageBubble = try sourceSlice(
            macChatSource,
            from: "struct IntatisMessageBubble: View",
            to: "struct IntatisComposer: View")
        XCTAssertTrue(macMessageBubble.contains("if isUser {"))
        XCTAssertTrue(macMessageBubble.contains(
            ".intatisLiquidGlass(cornerRadius: 16)"))
        XCTAssertFalse(macMessageBubble.contains(".intatisContentSurface("))
        XCTAssertFalse(macMessageBubble.contains("userSelectionStroke"))
        XCTAssertFalse(macMessageBubble.contains("isUninterruptedAgentReply"))

        let codeSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/CodeViews.swift"),
            encoding: .utf8)
        let codeBubbleContent = try sourceSlice(
            codeSource,
            from: "@ViewBuilder private func bubbleContent",
            to: "private func bubbleBody")
        XCTAssertTrue(codeBubbleContent.contains("if isUser {"))
        XCTAssertTrue(codeBubbleContent.contains(
            ".intatisLiquidGlass(cornerRadius: 16)"))
        XCTAssertFalse(codeBubbleContent.contains("item.isFailure"))
        XCTAssertFalse(codeBubbleContent.contains(".intatisContentSurface("))
        XCTAssertFalse(codeSource.contains("private func bubbleStroke(isUser:"))
    }

    func testThreadErrorsCollectEveryConversationSourceAndLeaveTranscriptClean() throws {
        let submissionID = SubmissionID(rawValue: "submission-timeout")
        let timeout = "Task timed out after 600 seconds."
        let items = [
            CodeItem(
                id: "user-timeout",
                kind: .user,
                title: "",
                body: "Read the PDF",
                isFailure: true,
                submissionID: submissionID,
                submissionStatus: .failed,
                submissionFailure: SubmissionFailure(
                    code: "timeout",
                    message: timeout,
                    retryable: true)),
            CodeItem(
                id: "partial-agent",
                kind: .agent,
                title: "main",
                body: "Partial answer remains visible.",
                complete: false,
                isFailure: true,
                recoveryAdvice: RuntimeRecoveryAdvice(
                    title: "Response stopped before completion",
                    detail: "Check endpoint compatibility before retrying.",
                    retryable: true)),
            CodeItem(
                id: "runtime-timeout",
                kind: .error,
                title: "main",
                body: timeout),
            CodeItem(
                id: "tool-failure",
                kind: .toolResult,
                title: "read_pdf",
                body: "Tool error: document could not be decoded.",
                isFailure: true,
                recoveryAdvice: RuntimeRecoveryAdvice(
                    title: "Inspect tool inputs and retry",
                    detail: "Check the selected file before retrying.",
                    retryable: true)),
            CodeItem(
                id: "normal-agent",
                kind: .agent,
                title: "main",
                body: "Normal answer."),
        ]

        let errors = IntatisThreadErrorPresentation.errors(
            items: items,
            errorTexts: [
                "Voice input failed.",
                "Projection unavailable.",
                "Projection unavailable.",
            ])

        XCTAssertEqual(errors.count, 5)
        let timeoutError = try XCTUnwrap(errors.first(where: {
            $0.details.contains(timeout)
        }))
        XCTAssertEqual(timeoutError.title, "main")
        XCTAssertEqual(timeoutError.retrySubmissionID, submissionID)
        XCTAssertTrue(errors.contains(where: {
            $0.details.contains("Check endpoint compatibility before retrying.")
        }))
        XCTAssertTrue(errors.contains(where: {
            $0.details.contains("Tool error: document could not be decoded.")
        }))
        XCTAssertTrue(errors.contains(where: {
            $0.details.contains("Voice input failed.")
        }))
        XCTAssertTrue(errors.contains(where: {
            $0.details.contains("Projection unavailable.")
        }))

        let transcript = IntatisThreadErrorPresentation.transcriptItems(items)
        XCTAssertEqual(transcript.map(\.id), [
            "user-timeout",
            "partial-agent",
            "normal-agent",
        ])
        let user = try XCTUnwrap(transcript.first)
        XCTAssertNil(user.submissionStatus)
        XCTAssertNil(user.submissionFailure)
        XCTAssertNil(user.recoveryAdvice)
        XCTAssertFalse(user.isFailure)
        let partialAgent = try XCTUnwrap(transcript.dropFirst().first)
        XCTAssertEqual(partialAgent.body, "Partial answer remains visible.")
        XCTAssertNil(partialAgent.recoveryAdvice)
        XCTAssertFalse(partialAgent.isFailure)
    }

    func testThreadErrorCardIsAbsentWhenEveryErrorSourceIsEmpty() {
        let items = [
            CodeItem(
                id: "user",
                kind: .user,
                title: "",
                body: "Hello"),
            CodeItem(
                id: "agent",
                kind: .agent,
                title: "main",
                body: "Hello back"),
        ]

        XCTAssertTrue(IntatisThreadErrorPresentation.errors(
            items: items,
            errorTexts: ["  ", "\n"]).isEmpty)
        XCTAssertEqual(
            IntatisThreadErrorPresentation.transcriptItems(items),
            items)

        let cancelledSubmission = CodeItem(
            id: "cancelled-user",
            kind: .user,
            title: "",
            body: "Stop this request",
            isFailure: true,
            submissionID: SubmissionID(rawValue: "cancelled-submission"),
            submissionStatus: .cancelled)
        XCTAssertTrue(IntatisThreadErrorPresentation.errors(
            items: [cancelledSubmission],
            errorTexts: []).isEmpty)
        XCTAssertEqual(
            IntatisThreadErrorPresentation
                .transcriptItems([cancelledSubmission])
                .first?
                .submissionStatus,
            .cancelled)
    }

    func testWorkspaceShellsUseOneConditionalRightRailErrorList() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let codeSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/CodeViews.swift"),
            encoding: .utf8)
        let coworkSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/CoworkViews.swift"),
            encoding: .utf8)

        XCTAssertTrue(codeSource.contains("if !errors.isEmpty"))
        XCTAssertTrue(codeSource.contains("IntatisThreadErrorList("))
        XCTAssertFalse(codeSource.contains("Recent Failures"))
        XCTAssertFalse(codeSource.contains(
            "case .error:\n            card("))
        XCTAssertTrue(coworkSource.contains("if !threadErrors.isEmpty"))
        XCTAssertTrue(coworkSource.contains("IntatisThreadErrorList("))
        XCTAssertFalse(coworkSource.contains("if let composerError"))
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
                    replayPolicy: .doNotReplay)))

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
            errors: [],
            colorScheme: .light)
        let afterSelection = CoworkStatusRailRenderSnapshot(
            agents: [],
            pending: nil,
            permissionNotice: nil,
            goal: nil,
            workTasks: CoworkWorkTaskSummary(),
            errors: [],
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
            errors: [],
            colorScheme: .light)
        let changedErrorState = CoworkStatusRailRenderSnapshot(
            agents: [],
            pending: nil,
            permissionNotice: nil,
            goal: nil,
            workTasks: CoworkWorkTaskSummary(),
            errors: IntatisThreadErrorPresentation.errors(
                items: [],
                errorTexts: ["Provider unavailable"]),
            colorScheme: .light)

        XCTAssertEqual(beforeSelection, afterSelection)
        XCTAssertNotEqual(beforeSelection, changedRailState)
        XCTAssertNotEqual(beforeSelection, changedErrorState)
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
