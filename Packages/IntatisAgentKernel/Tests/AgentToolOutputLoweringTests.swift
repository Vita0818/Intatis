import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisAgentKernel

final class AgentToolOutputLoweringTests: XCTestCase {
    func testStructuredResultLowersTextJSONAndImagesInSourceOrder() throws {
        let first = ArtifactID(rawValue: "art_first")
        let second = ArtifactID(rawValue: "art_second")
        let result = MCPStructuredToolResult(content: [
            MCPContentBlock(kind: .text, text: "observed"),
            MCPContentBlock(
                kind: .imageReference,
                artifactID: first,
                mimeType: "image/png",
                byteCount: 10,
                sha256: String(repeating: "a", count: 64)),
            MCPContentBlock(
                kind: .structuredJSON,
                structuredJSON: .object([
                    "z": .number(2),
                    "a": .number(1),
                ])),
            MCPContentBlock(
                kind: .imageReference,
                artifactID: second,
                mimeType: "image/jpeg",
                byteCount: 20,
                sha256: String(repeating: "b", count: 64)),
        ])

        let lowered = try AgentCanonicalToolOutput.lower(
            structuredResult: result,
            legacyObservation: "must not be used")

        XCTAssertEqual(lowered.output, "observed\n{\"a\":1,\"z\":2}")
        XCTAssertEqual(
            lowered.imageReferences.map(\.artifactID),
            [first, second])
    }

    func testPureImageOutputDoesNotInventPlaceholderText() throws {
        let result = MCPStructuredToolResult(content: [
            MCPContentBlock(
                kind: .imageReference,
                artifactID: ArtifactID(rawValue: "art_image"),
                mimeType: "image/png",
                byteCount: 1,
                sha256: String(repeating: "0", count: 64)),
        ])

        let lowered = try AgentCanonicalToolOutput.lower(
            structuredResult: result,
            legacyObservation: "[legacy image placeholder]")

        XCTAssertEqual(lowered.output, "")
        XCTAssertEqual(lowered.imageReferences.count, 1)
    }

    func testAudioFailsWithStableUnsupportedCode() {
        let result = MCPStructuredToolResult(content: [
            MCPContentBlock(
                kind: .audioReference,
                artifactID: ArtifactID(rawValue: "art_audio"),
                mimeType: "audio/wav",
                byteCount: 10,
                sha256: String(repeating: "c", count: 64)),
        ])

        XCTAssertThrowsError(try AgentCanonicalToolOutput.lower(
            structuredResult: result,
            legacyObservation: "audio")) { error in
            XCTAssertEqual(
                (error as? AgentToolOutputLoweringError)?.stableCode,
                "media_output_unsupported")
        }
    }

    func testStructuredEmptyResultUsesStableText() throws {
        let lowered = try AgentCanonicalToolOutput.lower(
            structuredResult: MCPStructuredToolResult(content: []),
            legacyObservation: "legacy placeholder")

        XCTAssertEqual(lowered.output, "MCP tool returned no content.")
        XCTAssertTrue(lowered.imageReferences.isEmpty)
    }
}
