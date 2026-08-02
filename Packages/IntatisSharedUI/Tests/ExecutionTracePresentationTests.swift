import XCTest
import IntatisConversation
@testable import IntatisSharedUI

final class ExecutionTracePresentationTests: XCTestCase {
    func testExecutionTraceDefaultsToHidden() {
        XCTAssertFalse(
            IntatisExecutionTracePresentation.resolve(
                arguments: ["Intatis"],
                environment: [:]))
    }

    func testLaunchArgumentEnablesExecutionTrace() {
        XCTAssertTrue(
            IntatisExecutionTracePresentation.resolve(
                arguments: ["Intatis", IntatisExecutionTracePresentation.launchArgument],
                environment: [:]))
    }

    func testTruthyEnvironmentValueEnablesExecutionTrace() {
        for value in ["1", "true", " YES ", "On", "enabled"] {
            XCTAssertTrue(
                IntatisExecutionTracePresentation.resolve(
                    arguments: ["Intatis"],
                    environment: [IntatisExecutionTracePresentation.environmentVariable: value]),
                "Expected \(value) to enable the execution trace")
        }
    }

    func testFalseOrUnknownEnvironmentValueKeepsExecutionTraceHidden() {
        for value in ["0", "false", "off", "unexpected", ""] {
            XCTAssertFalse(
                IntatisExecutionTracePresentation.resolve(
                    arguments: ["Intatis"],
                    environment: [IntatisExecutionTracePresentation.environmentVariable: value]),
                "Expected \(value) to keep the execution trace hidden")
        }
    }

    func testDefaultProjectionKeepsConversationAgentTrafficAndErrors() {
        let items = makeItems()

        let displayed = IntatisExecutionTracePresentation.displayedItems(
            items,
            showExecutionTrace: false)

        XCTAssertEqual(displayed.map(\.kind), [.user, .agentToAgent, .agent, .error])
        XCTAssertEqual(displayed.map(\.id), ["user", "agent-to-agent", "agent", "error"])
    }

    func testEnabledProjectionRestoresCompletePreviousTranscript() {
        let items = makeItems()

        XCTAssertEqual(
            IntatisExecutionTracePresentation.displayedItems(
                items,
                showExecutionTrace: true),
            items)
    }

    func testTaskCompletionFallbackRemainsVisibleWithoutMatchingMessage() {
        let fallback = CodeItem(
            id: "task-fallback",
            kind: .agent,
            title: "worker",
            body: "Only durable result")

        XCTAssertEqual(
            IntatisExecutionTracePresentation.displayedItems(
                [fallback],
                showExecutionTrace: false),
            [fallback])
    }

    private func makeItems() -> [CodeItem] {
        [
            CodeItem(id: "user", kind: .user, title: "You", body: "request"),
            CodeItem(id: "tool-call", kind: .toolCall, title: "read_file", body: "{}"),
            CodeItem(id: "tool-result", kind: .toolResult, title: "result", body: "large output", isFailure: true),
            CodeItem(id: "patch", kind: .patch, title: "patch", body: "diff"),
            CodeItem(id: "note", kind: .note, title: "task", body: "started"),
            CodeItem(id: "agent-to-agent", kind: .agentToAgent, title: "main → worker", body: "internal"),
            CodeItem(id: "agent", kind: .agent, title: "Agent", body: "answer"),
            CodeItem(
                id: "task-completion-mirror",
                kind: .agent,
                title: "Agent",
                body: "answer",
                presentationSource: .executionTrace),
            CodeItem(id: "error", kind: .error, title: "error", body: "actionable failure"),
        ]
    }
}
