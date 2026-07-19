#if canImport(SwiftUI)
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisSharedUI

final class CoworkInferencePresentationTests: XCTestCase {
    func testLegacyInitializerKeepsPermissionProfileCompatibility() {
        let agent = CoworkAgentInfo(
            id: "main",
            name: "main",
            workspace: "/workspace",
            model: "gpt-test",
            profile: "reviewed")

        XCTAssertEqual(agent.permissionProfile, "reviewed")
        XCTAssertEqual(agent.profile, "reviewed")
        XCTAssertEqual(agent.inferenceResolution, .legacy)
        XCTAssertTrue(agent.inferenceResolution.requiresAttention)
        XCTAssertEqual(agent.inferenceDisplayLabel, "Legacy · gpt-test")
    }

    func testResolvedInferencePresentationKeepsOnlySafeLabels() {
        let ref = InferenceProfileRef(
            inferenceProfileID: InferenceProfileID(rawValue: "profile-safe"),
            inferenceProfileRevision: InferenceProfileRevision(rawValue: "rev-1"))
        let agent = CoworkAgentInfo(
            id: "worker",
            name: "worker",
            workspace: "/workspace",
            model: "gpt-test",
            permissionProfile: "read_only",
            inferenceProfileLabel: "Local · GPT Test · high",
            inferenceProfileRef: ref,
            inferenceConnectionLabel: "Local",
            inferenceVariant: "high",
            inferenceResolution: .resolved)

        XCTAssertEqual(agent.inferenceProfileRef, ref)
        XCTAssertEqual(agent.inferenceDisplayLabel, "Local · GPT Test · high")
    }

    func testURLAndCredentialShapedValuesNeverReachRosterLabel() {
        let agent = CoworkAgentInfo(
            id: "worker",
            name: "worker",
            workspace: "/workspace",
            model: "sk-sensitive-token-value",
            permissionProfile: "reviewed",
            inferenceProfileLabel: "https://private.example/v1",
            inferenceConnectionLabel: "Bearer sensitive-token",
            inferenceVariant: "high",
            inferenceResolution: .resolved)

        XCTAssertEqual(agent.inferenceDisplayLabel, "high")
        XCTAssertFalse(agent.inferenceDisplayLabel?.contains("https://") == true)
        XCTAssertFalse(agent.inferenceDisplayLabel?.lowercased().contains("bearer") == true)
        XCTAssertFalse(agent.inferenceDisplayLabel?.contains("sk-sensitive") == true)
    }

    func testUnresolvedPresentationDoesNotEchoUnsafeConfiguration() {
        let agent = CoworkAgentInfo(
            id: "worker",
            name: "worker",
            workspace: "/workspace",
            model: "https://private.example/model",
            permissionProfile: "reviewed",
            inferenceProfileLabel: "sk-sensitive-token-value",
            inferenceConnectionLabel: "https://private.example/v1",
            inferenceVariant: "secret",
            inferenceResolution: .unresolved)

        XCTAssertEqual(agent.inferenceDisplayLabel, "Inference unavailable")
        XCTAssertTrue(agent.inferenceResolution.requiresAttention)
    }
}
#endif
