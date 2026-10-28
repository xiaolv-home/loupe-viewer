import Foundation

/// Claude's Messages API with tools, streamed.
struct AnthropicClient: AIClient {
    static let apiVersion = "2026-10-21"
    let endpoint: AIEndpoint
    let session: URLSession

    static func authorize(_ req: inout URLRequest, _ e: AIEndpoint) {
        req.setValue(e.apiKey ?? "", forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
    }

    func stream(system: String, messages: [AIMessage], tools: [AIToolSpec]) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let e = endpoint
        let s = session
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = URLRequest(url: e.baseURL.appendingPathComponent("v1/messages"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    Self.authorize(&req, e)
                    if AnthropicWire.isFirstPartyClaude(e) {
                        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                    }
                    req.httpBody = AnthropicWire.requestBody(endpoint: e, system: system, messages: messages, tools: tools).data()
                    var acc = AnthropicWire.Accumulator()
                    for try await payload in try await AIHTTP.events(req, session: s, endpoint: e) {
                        guard let ev = AIJSON.parse(payload) else { continue }
                        if ev["type"]?.string == "error" {
                            throw AIError(ev["error"]?["message"]?.string ?? "Claude 返回了错误")
                        }
                        for out in acc.consume(ev) { cont.yield(out) }
                    }
                    let (msg, stop) = acc.finish()
                    cont.yield(.finished(msg, stop))
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

public enum AnthropicWire {
    /// Claude models on Anthropic's own API get adaptive thinking, effort and refusal fallbacks;
    /// other Anthropic-compatible servers get the plain request.
    static func isClaude(_ e: AIEndpoint) -> Bool { e.model.lowercased().hasPrefix("claude-") }
    static func isFirstPartyClaude(_ e: AIEndpoint) -> Bool { isClaude(e) && e.baseURL.host == "api.anthropic.com" }

    public static func requestBody(endpoint: AIEndpoint, system: String, messages: [AIMessage], tools: [AIToolSpec]) -> AIJSON {
        var wire: [AIJSON] = []
        var pendingResults: [AIJSON] = []
        func flushResults() {
            guard !pendingResults.isEmpty else { return }
            wire.append(["role": "user", "content": .array(pendingResults)])
            pendingResults = []
        }
        for m in messages {
            switch m.role {
            case .tool:
                // All results of one assistant turn go back together in a single user message.
                let text = m.text.isEmpty ? "（无输出）" : m.text
                let body: AIJSON = (m.images ?? []).isEmpty ? .string(text)
                    : .array([["type": "text", "text": .string(text)]] + m.images!.map(imageBlock))
                var r: [String: AIJSON] = ["type": "tool_result", "tool_use_id": .string(m.toolCallID ?? ""), "content": body]
                if m.isError { r["is_error"] = true }
                pendingResults.append(.object(r))
            case .user:
                flushResults()
                if let images = m.images, !images.isEmpty {
                    wire.append(["role": "user", "content": .array(images.map(imageBlock) + [["type": "text", "text": .string(m.text)]])])
                } else {
                    wire.append(["role": "user", "content": .string(m.text)])
                }
            case .assistant:
                flushResults()
                if let blocks = m.anthropicBlocks, !blocks.isEmpty {
                    wire.append(["role": "assistant", "content": .array(blocks)])
                } else {
                    var blocks: [AIJSON] = []
                    if !m.text.isEmpty { blocks.append(["type": "text", "text": .string(m.text)]) }
                    for c in m.toolCalls {
                        blocks.append(["type": "tool_use", "id": .string(c.id), "name": .string(c.name),
                                       "input": c.parsedArguments ?? .object([:])])
                    }
                    if blocks.isEmpty { blocks.append(["type": "text", "text": "（空）"]) }
                    wire.append(["role": "assistant", "content": .array(blocks)])
                }
            }
        }
        flushResults()

        var body: [String: AIJSON] = [
            "model": .string(endpoint.model),
            "max_tokens": 32000,
            "stream": true,
            "system": [["type": "text", "text": .string(system), "cache_control": ["type": "ephemeral"]]],
            "messages": .array(wire)
        ]
        let claude = isClaude(endpoint)
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { t in
                var o: [String: AIJSON] = ["name": .string(t.name), "description": .string(t.description), "input_schema": t.parameters]
                if claude { o["eager_input_streaming"] = true }
                return .object(o)
            })
        }
        if claude {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
            body["output_config"] = ["effort": "high"]
            // Keep the history cached between the turns of a tool loop.
            body["cache_control"] = ["type": "ephemeral"]
        }
        if isFirstPartyClaude(endpoint) { body["fallbacks"] = "default" }
        return .object(body)
    }

    static func imageBlock(_ i: AIImage) -> AIJSON {
        ["type": "image", "source": ["type": "base64", "media_type": .string(i.mediaType), "data": .string(i.base64)]]
    }

    public struct Accumulator {
        var blocks: [Int: [String: AIJSON]] = [:]
        var partialJSON: [Int: String] = [:]
        var stopReason: String?

        public init() {}

        public mutating func consume(_ ev: AIJSON) -> [AIStreamEvent] {
            let index = ev["index"]?.int ?? 0
            switch ev["type"]?.string {
            case "content_block_start":
                guard let b = ev["content_block"]?.object else { return [] }
                blocks[index] = b
                if b["type"]?.string == "tool_use" {
                    partialJSON[index] = ""
                    return [.toolCallStarted(b["name"]?.string ?? "")]
                }
                return []
            case "content_block_delta":
                guard let d = ev["delta"], var b = blocks[index] else { return [] }
                switch d["type"]?.string {
                case "text_delta":
                    let t = d["text"]?.string ?? ""
                    b["text"] = .string((b["text"]?.string ?? "") + t)
                    blocks[index] = b
                    return t.isEmpty ? [] : [.text(t)]
                case "thinking_delta":
                    let t = d["thinking"]?.string ?? ""
                    b["thinking"] = .string((b["thinking"]?.string ?? "") + t)
                    blocks[index] = b
                    return t.isEmpty ? [] : [.reasoning(t)]
                case "signature_delta":
                    b["signature"] = .string((b["signature"]?.string ?? "") + (d["signature"]?.string ?? ""))
                    blocks[index] = b
                case "input_json_delta":
                    partialJSON[index, default: ""] += d["partial_json"]?.string ?? ""
                default: break
                }
                return []
            case "message_delta":
                if let r = ev["delta"]?["stop_reason"]?.string { stopReason = r }
                return []
            default:
                return []
            }
        }

        public mutating func finish() -> (AIMessage, AIStopReason) {
            var text = "", reasoning = ""
            var calls: [AIToolCall] = []
            var raw: [AIJSON] = []
            for i in blocks.keys.sorted() {
                var b = blocks[i]!
                switch b["type"]?.string {
                case "text": text += b["text"]?.string ?? ""
                case "thinking": reasoning += b["thinking"]?.string ?? ""
                case "tool_use":
                    let args = partialJSON[i] ?? ""
                    calls.append(AIToolCall(id: b["id"]?.string ?? "", name: b["name"]?.string ?? "", arguments: args))
                    // Tool inputs stream as text; the block sent back carries the parsed object.
                    b["input"] = AIJSON.parse(args.isEmpty ? "{}" : args) ?? .object([:])
                default: break
                }
                raw.append(.object(b))
            }
            var m = AIMessage(role: .assistant, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
            m.toolCalls = calls
            m.reasoning = reasoning.isEmpty ? nil : reasoning
            m.anthropicBlocks = raw
            let stop: AIStopReason
            switch stopReason {
            case "tool_use": stop = .toolUse
            case "max_tokens": stop = .maxTokens
            case "refusal": stop = .refused
            case "end_turn", "stop_sequence", nil: stop = calls.isEmpty ? .done : .toolUse
            default: stop = .other
            }
            return (m, stop)
        }
    }
}
