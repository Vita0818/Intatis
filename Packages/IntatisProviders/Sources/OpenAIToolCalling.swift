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
            struct Fn: Decodable {
                let name: String?
                let arguments: String?

                enum CodingKeys: String, CodingKey {
                    case name
                    case arguments
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    name = try container.decodeIfPresent(String.self, forKey: .name)
                    if let stringArguments = try? container.decodeIfPresent(String.self, forKey: .arguments) {
                        arguments = stringArguments
                    } else if container.contains(.arguments) {
                        let value = try container.decode(JSONValue.self, forKey: .arguments)
                        arguments = try Self.argumentString(from: value)
                    } else {
                        arguments = nil
                    }
                }

                private static func argumentString(from value: JSONValue) throws -> String? {
                    if value == .null { return nil }
                    let data = try JSONEncoder().encode(value)
                    return String(data: data, encoding: .utf8)
                }
            }
            let index: Int?
            let id: String?
            let function: Fn?

            enum CodingKeys: String, CodingKey {
                case index
                case id
                case function
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let intIndex = try? container.decodeIfPresent(Int.self, forKey: .index) {
                    index = intIndex
                } else if let stringIndex = try? container.decodeIfPresent(String.self, forKey: .index),
                          let parsed = Int(stringIndex) {
                    index = parsed
                } else {
                    index = nil
                }
                id = try container.decodeIfPresent(String.self, forKey: .id)
                function = try container.decodeIfPresent(Fn.self, forKey: .function)
            }
        }
        let index: Int?
        let delta: Delta?
        let finish_reason: String?

        enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finish_reason
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let intIndex = try? container.decodeIfPresent(Int.self, forKey: .index) {
                index = intIndex
            } else if let stringIndex = try? container.decodeIfPresent(String.self, forKey: .index),
                      let parsed = Int(stringIndex) {
                index = parsed
            } else {
                index = nil
            }
            delta = try container.decodeIfPresent(Delta.self, forKey: .delta)
            finish_reason = try container.decodeIfPresent(String.self, forKey: .finish_reason)
        }
    }
    struct UsageDTO: Decodable {
        struct PromptTokensDetailsDTO: Decodable {
            let cached_tokens: Int?
        }
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
        let prompt_tokens_details: PromptTokensDetailsDTO?

        var usage: Usage {
            Usage(promptTokens: prompt_tokens,
                  cachedPromptTokens: prompt_tokens_details?.cached_tokens,
                  completionTokens: completion_tokens,
                  totalTokens: total_tokens)
        }
    }
    let choices: [Choice]?
    let usage: UsageDTO?
}

private struct ToolCallAccum {
    var id = ""
    var name = ""
    var args = ""
}

private struct ToolCallAccumKey: Comparable, Hashable {
    var choiceIndex: Int
    var toolIndex: Int

    static func < (lhs: ToolCallAccumKey, rhs: ToolCallAccumKey) -> Bool {
        if lhs.choiceIndex != rhs.choiceIndex {
            return lhs.choiceIndex < rhs.choiceIndex
        }
        return lhs.toolIndex < rhs.toolIndex
    }
}

private func preferredToolFinishReason(_ current: String?, _ candidate: String) -> String {
    if candidate == "tool_calls" || candidate == "function_call" {
        return candidate
    }
    return current ?? candidate
}

private func validatedToolCallArguments(_ arguments: String,
                                        key: ToolCallAccumKey,
                                        reason: String) throws -> String {
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return arguments }
    guard let data = trimmed.data(using: .utf8) else {
        throw ProviderErrorFormatting.invalidToolCallStream(
            "The provider finished with \(reason) but emitted non-UTF-8 arguments for choice/tool index \(key.choiceIndex):\(key.toolIndex).")
    }
    do {
        _ = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
        throw ProviderErrorFormatting.invalidToolCallStream(
            "The provider finished with \(reason) but emitted invalid JSON arguments for choice/tool index \(key.choiceIndex):\(key.toolIndex).")
    }
    return arguments
}

// MARK: - ToolCallingProvider conformance

extension OpenAIWireProvider: ToolCallingProvider {

    public func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildAgentRequest(request)
                    var attempt = 1

                    while true {
                        let parser = SSEParser()
                        var acc: [ToolCallAccumKey: ToolCallAccum] = [:]
                        var finished = false
                        var receivedResponseBytes = false

                        func handle(_ payload: String) throws -> Bool {
                            if payload == "[DONE]" {
                                if !finished {
                                    continuation.yield(.done(finishReason: nil))
                                    finished = true
                                }
                                continuation.finish()
                                return true
                            }
                            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
                                return false
                            }
                            if let providerError = ProviderErrorFormatting.streamErrorPayload(data) {
                                throw providerError
                            }
                            let chunk: OAAgentStreamChunk
                            do {
                                chunk = try JSONDecoder().decode(OAAgentStreamChunk.self, from: data)
                            } catch {
                                throw ProviderErrorFormatting.invalidStreamPayload(trimmed, underlying: error)
                            }
                            if let u = chunk.usage {
                                continuation.yield(.usage(u.usage))
                            }
                            var finishReason: String?
                            if let choices = chunk.choices {
                                for (choiceOffset, choice) in choices.enumerated() {
                                    let choiceIndex = choice.index ?? choiceOffset
                                    if let content = choice.delta?.content, !content.isEmpty {
                                        continuation.yield(.textDelta(content))
                                    }
                                    if let frags = choice.delta?.tool_calls {
                                        for (toolOffset, f) in frags.enumerated() {
                                            let key = ToolCallAccumKey(choiceIndex: choiceIndex,
                                                                       toolIndex: f.index ?? toolOffset)
                                            var e = acc[key] ?? ToolCallAccum()
                                            if let id = f.id { e.id = id }
                                            if let fn = f.function {
                                                if let n = fn.name { e.name = n }
                                                if let a = fn.arguments { e.args += a }
                                            }
                                            acc[key] = e
                                        }
                                    }
                                    if let reason = choice.finish_reason {
                                        finishReason = preferredToolFinishReason(finishReason, reason)
                                    }
                                }
                            }
                            if let reason = finishReason, !finished {
                                let toolCallKeys = acc.keys.sorted()
                                let incomplete = toolCallKeys.filter { key in
                                    guard let entry = acc[key] else { return true }
                                    return entry.name.isEmpty
                                }
                                if reason == "tool_calls" || reason == "function_call" {
                                    if toolCallKeys.isEmpty {
                                        throw ProviderErrorFormatting.invalidToolCallStream(
                                            "The provider finished with \(reason) but did not emit any tool call deltas.")
                                    }
                                }
                                if !incomplete.isEmpty {
                                    let indexes = incomplete
                                        .map { "\($0.choiceIndex):\($0.toolIndex)" }
                                        .joined(separator: ", ")
                                    throw ProviderErrorFormatting.invalidToolCallStream(
                                        "The provider finished with \(reason) but omitted tool names for choice/tool index \(indexes).")
                                }
                                let calls: [ToolCall] = try toolCallKeys.map { key in
                                    guard let e = acc[key], !e.name.isEmpty else {
                                        throw ProviderErrorFormatting.invalidToolCallStream(
                                            "The provider finished with \(reason) but omitted tool names for choice/tool index \(key.choiceIndex):\(key.toolIndex).")
                                    }
                                    let fallbackID = key.choiceIndex == 0
                                        ? "call_\(key.toolIndex)"
                                        : "call_\(key.choiceIndex)_\(key.toolIndex)"
                                    let arguments = try validatedToolCallArguments(e.args, key: key, reason: reason)
                                    return ToolCall(id: e.id.isEmpty ? fallbackID : e.id,
                                                    name: e.name, arguments: arguments)
                                }
                                if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                                continuation.yield(.done(finishReason: reason))
                                finished = true
                            }
                            return false
                        }

                        do {
                            for try await chunk in http.stream(urlRequest) {
                                receivedResponseBytes = true
                                for payload in parser.consume(chunk) {
                                    if try handle(payload) { return }
                                }
                            }
                            for payload in parser.flush() {
                                if try handle(payload) { return }
                            }
                            guard finished else {
                                continuation.finish(throwing: ProviderErrorFormatting.incompleteStream(
                                    operation: "tool-calling streaming request"))
                                return
                            }
                            continuation.finish()
                            return
                        } catch {
                            if ProviderRuntime.shouldRetry(error: error,
                                                           attempt: attempt,
                                                           policy: runtimePolicy,
                                                           receivedResponseBytes: receivedResponseBytes) {
                                attempt += 1
                                try await ProviderRuntime.sleepBeforeRetry(
                                    nextAttempt: attempt,
                                    policy: runtimePolicy,
                                    retryHint: ProviderErrorFormatting.retryHint(from: error))
                                continue
                            }
                            continuation.finish(throwing: ProviderRuntime.exhausted(
                                error,
                                attempts: attempt,
                                operation: "tool-calling streaming request"))
                            return
                        }
                    }
                } catch {
                    continuation.finish(throwing: ProviderErrorFormatting.transport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func buildAgentRequest(_ request: AgentRequest) throws -> URLRequest {
        var root = Self.configuredRequestBody(endpoint: endpoint, model: request.model)
        root["model"] = .string(request.model.rawValue)
        root["messages"] = .array(request.messages.map(Self.messageJSON))
        root["stream"] = .bool(true)
        root["n"] = .number(1)
        if !request.tools.isEmpty {
            root["tools"] = .array(request.tools.map(Self.toolJSON))
        }
        if let t = request.temperature {
            root["temperature"] = .number(t)
        }
        if let r = request.reasoningEffort {
            root["reasoning_effort"] = .string(r.rawValue)
        }
        if let maxOutputTokens = request.maxOutputTokens {
            // The invocation ceiling is host-owned. A durable inference profile
            // may carry a provider-native limit when no host ceiling is set,
            // but it must not leave a competing alias that an upstream could
            // prefer over the narrower runtime value.
            for key in Array(root.keys) where Self.isOutputTokenCeilingKey(key) {
                root.removeValue(forKey: key)
            }
            root["max_tokens"] = .number(Double(maxOutputTokens))
        }
        if request.includeUsage {
            root["stream_options"] = .object(["include_usage": .bool(true)])
        }

        var r = URLRequest(url: try endpoint.validatedChatCompletionsURL(operation: "tool-calling streaming request"))
        ProviderRuntime.apply(runtimePolicy, to: &r)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue(ProviderAuthorization.bearerHeaderValue(apiKey: apiKey),
                   forHTTPHeaderField: "Authorization")
        r.httpBody = try JSONEncoder().encode(JSONValue.object(root))
        return r
    }

    private static func isOutputTokenCeilingKey(_ rawKey: String) -> Bool {
        let normalized = rawKey.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        return [
            "maxtokens",
            "maxcompletiontokens",
            "maxoutputtokens",
            "maxnewtokens",
        ].contains(normalized)
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
