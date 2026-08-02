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
                items: [],
                presentationScope: IntatisThreadPresentationScope(
                    kind: "cowork",
                    sessionID: "layout-stress-cowork"),
                sessionTitle: "Cowork",
                agents: [],
                pending: nil,
                summary: CoworkStatusSummary(),
                composerError: nil,
                isWorking: false,
                showsInspector: Binding(
                    get: { model.coworkInspector },
                    set: { model.coworkInspector = $0 }),
                input: $coworkInput,
                onSend: {},
                onResolve: { _ in })
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
            XCTAssertTrue(
                source.contains("IntatisWorkspaceInspectorLayoutPolicy.resolve("),
                filename)
        }

        let coworkSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/CoworkViews.swift"),
            encoding: .utf8)
        XCTAssertTrue(coworkSource.contains("ZStack(alignment: .trailing)"))
        XCTAssertTrue(coworkSource.contains("dividerWidth: 0"))
        XCTAssertTrue(coworkSource.contains("for: .scrollContent"))
        XCTAssertTrue(coworkSource.contains("primaryScrollerClearance"))
        XCTAssertTrue(coworkSource.contains(".allowsHitTesting(false)"))

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
