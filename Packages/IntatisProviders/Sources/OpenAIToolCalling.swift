import Foundation
import IntatisCore
import IntatisProtocol
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Streaming DTOs (internal)

private struct OAAgentStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let tool_calls: [ToolCallFragment]?
        }
        struct ToolCallFragment: Decodable {
            struct Fn: Decodable { let name: String?; let arguments: String? }
            let index: Int
            let id: String?
            let function: Fn?
        }
        let delta: Delta?
        let finish_reason: String?
    }
    struct UsageDTO: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
    }
    let choices: [Choice]
    let usage: UsageDTO?
}

private struct ToolCallAccum {
    var id = ""
    var name = ""
    var args = ""
}

// MARK: - ToolCallingProvider conformance

extension OpenAIWireProvider: ToolCallingProvider {

    public func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildAgentRequest(request)
                    let parser = SSEParser()
                    var acc: [Int: ToolCallAccum] = [:]
                    var finished = false

                    func handle(_ payload: String) {
                        if payload == "[DONE]" { return }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(OAAgentStreamChunk.self, from: data) else {
                            return
                        }
                        if let u = chunk.usage {
                            continuation.yield(.usage(Usage(promptTokens: u.prompt_tokens,
                                                            completionTokens: u.completion_tokens,
                                                            totalTokens: u.total_tokens)))
                        }
                        guard let choice = chunk.choices.first else { return }
                        if let content = choice.delta?.content, !content.isEmpty {
                            continuation.yield(.textDelta(content))
                        }
                        if let frags = choice.delta?.tool_calls {
                            for f in frags {
                                var e = acc[f.index] ?? ToolCallAccum()
                                if let id = f.id { e.id = id }
                                if let fn = f.function {
                                    if let n = fn.name { e.name = n }
                                    if let a = fn.arguments { e.args += a }
                                }
                                acc[f.index] = e
                            }
                        }
                        if let reason = choice.finish_reason {
                            let calls: [ToolCall] = acc.keys.sorted().compactMap { idx in
                                guard let e = acc[idx], !e.name.isEmpty else { return nil }
                                return ToolCall(id: e.id.isEmpty ? "call_\(idx)" : e.id,
                                                name: e.name, arguments: e.args)
                            }
                            if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                            continuation.yield(.done(finishReason: reason))
                            finished = true
                        }
                    }

                    for try await chunk in http.stream(urlRequest) {
                        for payload in parser.consume(chunk) {
                            handle(payload)
                            if finished { continuation.finish(); return }
                        }
                    }
                    for payload in parser.flush() {
                        handle(payload)
                        if finished { continuation.finish(); return }
                    }
                    if !finished { continuation.yield(.done(finishReason: nil)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func buildAgentRequest(_ request: AgentRequest) throws -> URLRequest {
        var root: [String: JSONValue] = [
            "model": .string(request.model.rawValue),
            "messages": .array(request.messages.map(Self.messageJSON)),
            "stream": .bool(true),
        ]
        if !request.tools.isEmpty {
            root["tools"] = .array(request.tools.map(Self.toolJSON))
        }
        if let t = request.temperature {
            root["temperature"] = .number(t)
        }
        if let r = request.reasoningEffort {
            root["reasoning_effort"] = .string(r.rawValue)
        }
        if request.includeUsage {
            root["stream_options"] = .object(["include_usage": .bool(true)])
        }

        let url = endpoint.baseURL.appendingPathComponent("chat/completions")
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.httpBody = try JSONEncoder().encode(JSONValue.object(root))
        return r
    }

    static func messageJSON(_ m: AgentMessage) -> JSONValue {
        var obj: [String: JSONValue] = ["role": .string(m.role.rawValue)]
        if !m.images.isEmpty {
            var parts: [JSONValue] = []
            if let c = m.content, !c.isEmpty {
                parts.append(.object(["type": .string("text"), "text": .string(c)]))
            }
            for image in m.images {
                parts.append(.object(["type": .string("image_url"),
                                      "image_url": .object(["url": .string(image.url)])]))
            }
            obj["content"] = .array(parts)
        } else if let content = m.content {
            obj["content"] = .string(content)
        } else if m.role == .assistant {
            obj["content"] = .null   // assistant-with-tool_calls requires explicit null content
        }
        if let toolCalls = m.toolCalls {
            obj["tool_calls"] = .array(toolCalls.map { tc in
                .object([
                    "id": .string(tc.id),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(tc.name),
                        "arguments": .string(tc.arguments),
                    ]),
                ])
            })
        }
        if let toolCallId = m.toolCallId {
            obj["tool_call_id"] = .string(toolCallId)
        }
        return .object(obj)
    }

    static func toolJSON(_ t: ToolSpec) -> JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(t.name),
                "description": .string(t.description),
                "parameters": t.parameters,
            ]),
        ])
    }
}
