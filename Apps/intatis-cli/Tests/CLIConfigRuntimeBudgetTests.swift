import Foundation
import IntatisAgentKernel
import XCTest
@testable import IntatisCLI

final class CLIConfigRuntimeBudgetTests: XCTestCase {
    func testDefaultBudgetsKeepCodeAtFiftyAndRaiseCoworkToSixtyFour() throws {
        let fixture = try makeModernConfigFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let config = try CLIConfig.load(
            configurationFileURL: fixture.file,
            environment: [:])

        XCTAssertEqual(config.maxSteps, AgentRuntime.defaultCodeMaxIterations)
        XCTAssertEqual(
            config.coworkMaxSteps,
            AgentRuntime.defaultCoworkMaxIterations)
        XCTAssertEqual(config.maxSteps, 50)
        XCTAssertEqual(config.coworkMaxSteps, 64)
    }

    func testExplicitMaxStepsStillOverridesBothCodeAndCowork() throws {
        let fixture = try makeModernConfigFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let config = try CLIConfig.load(
            configurationFileURL: fixture.file,
            environment: ["INTATIS_MAX_STEPS": "37"])

        XCTAssertEqual(config.maxSteps, 37)
        XCTAssertEqual(config.coworkMaxSteps, 37)
    }

    private func makeModernConfigFixture() throws
        -> (directory: URL, file: URL)
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-cli-runtime-budget-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("intatis.json")
        let object: [String: Any] = [
            "model": "test/model",
            "provider": [
                "test": [
                    "options": [
                        "baseURL": "https://example.invalid/v1",
                        "apiKey": "{env:INTATIS_TEST_API_KEY}",
                    ],
                    "models": [
                        "model": ["name": "Test Model"],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
        return (directory, file)
    }
}
