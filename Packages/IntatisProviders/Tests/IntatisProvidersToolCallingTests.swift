import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisProviders

private struct FakeHTTP2: HTTPByteStreaming {
    let chunks: [Data]
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private func fragment(_ s: String, size: Int) -> [Data] {
    let bytes = Array(s.utf8)
    var out: [Data] = []
    var i = 0
    while i < bytes.count {
        let end = min(i + size, bytes.count)
        out.append(Data(bytes[i..<end]))
        i = end
    }
    return out
}

private let endpoint = ProviderEndpoint(
    id: "e",
    baseURL: URL(string: "https://example.test/v1")!,
    apiKeyRef: KeychainRef(service: "s", account: "a"),
    wire: .openai
)

final class IntatisProvidersToolCallingTests: XCTestCase {

    func testToolCallStreamingAssemblesAcrossFragments() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"pa"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"a.swift\"}"}}]}}]}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP2(chunks: fragment(sse, size: 8)))
        var calls: [ToolCall] = []
        var sawDone = false
        var finish: String?
        for try await chunk in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")],
                                                            tools: [])) {
            switch chunk {
            case .textDelta: break
            case .toolCalls(let c): calls = c
            case .usage: break
            case .done(let r): sawDone = true; finish = r
            }
        }
        XCTAssertEqual(calls, [ToolCall(id: "call_1", name: "read_file", arguments: #"{"path":"a.swift"}"#)])
        XCTAssertTrue(sawDone)
        XCTAssertEqual(finish, "tool_calls")
    }

    func testTextOnlyStreaming() async throws {
        let sse = #"""
        data: {"choices":[{"delta":{"content":"Hi"}}]}

        data: {"choices":[{"delta":{"content":" there"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """#
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP2(chunks: fragment(sse, size: 6)))
        var text = ""
        var finish: String?
        for try await chunk in provider.stream(AgentRequest(model: ModelID(rawValue: "m"),
                                                            messages: [.user("hi")], tools: [])) {
            switch chunk {
            case .textDelta(let d): text += d
            case .toolCalls: XCTFail("unexpected tool call")
            case .usage: break
            case .done(let r): finish = r
            }
        }
        XCTAssertEqual(text, "Hi there")
        XCTAssertEqual(finish, "stop")
    }

    func testMessageJSONShapes() {
        let assistant = OpenAIWireProvider.messageJSON(
            .assistant(toolCalls: [ToolCall(id: "c1", name: "f", arguments: "{}")]))
        guard case .object(let o) = assistant else { return XCTFail("not object") }
        XCTAssertEqual(o["role"], .string("assistant"))
        XCTAssertEqual(o["content"], JSONValue.null)
        XCTAssertNotNil(o["tool_calls"])

        let toolMsg = OpenAIWireProvider.messageJSON(.tool(id: "c1", content: "obs"))
        guard case .object(let t) = toolMsg else { return XCTFail("not object") }
        XCTAssertEqual(t["tool_call_id"], .string("c1"))
        XCTAssertEqual(t["content"], .string("obs"))
    }

    func testReasoningEffortInRequestBody() throws {
        let provider = OpenAIWireProvider(endpoint: endpoint, apiKey: "k", http: FakeHTTP2(chunks: []))

        let withEffort = try provider.buildAgentRequest(
            AgentRequest(model: ModelID(rawValue: "m"), messages: [.user("hi")], tools: [], reasoningEffort: .high))
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(withEffort.httpBody)) as! [String: Any]
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")

        let without = try provider.buildAgentRequest(
            AgentRequest(model: ModelID(rawValue: "m"), messages: [.user("hi")], tools: []))
        let body2 = try JSONSerialization.jsonObject(with: XCTUnwrap(without.httpBody)) as! [String: Any]
        XCTAssertNil(body2["reasoning_effort"])
    }

    func testAgentMessageWithImageEncodesAsContentArray() {
        let message = AgentMessage.user("what is this?",
                                        images: [ImageAttachment(url: "data:image/png;base64,QUJD")])
        guard case .object(let obj) = OpenAIWireProvider.messageJSON(message),
              case .array(let parts)? = obj["content"] else { return XCTFail("content should be an array") }
        XCTAssertEqual(parts.count, 2)
        guard case .object(let text) = parts[0] else { return XCTFail() }
        XCTAssertEqual(text["type"], .string("text"))
        guard case .object(let img) = parts[1] else { return XCTFail() }
        XCTAssertEqual(img["type"], .string("image_url"))
        guard case .object(let imageURL)? = img["image_url"] else { return XCTFail() }
        XCTAssertEqual(imageURL["url"], .string("data:image/png;base64,QUJD"))
    }

    func testChatMessageWithImageEncodesAsContentArray() {
        let m = ChatMessage(role: .user, content: "hi", images: [ImageAttachment(url: "https://x/a.png")])
        guard case .object(let obj) = OpenAIWireProvider.chatMessageJSON(m),
              case .array(let parts)? = obj["content"] else { return XCTFail("content should be an array") }
        XCTAssertEqual(parts.count, 2)
    }

    func testPlainMessageStaysString() {
        guard case .object(let obj) = OpenAIWireProvider.chatMessageJSON(ChatMessage(role: .user, content: "hi")) else {
            return XCTFail()
        }
        XCTAssertEqual(obj["content"], .string("hi"))
    }
}
