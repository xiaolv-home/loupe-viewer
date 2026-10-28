import Foundation

/// Chat Completions with tools, streamed. Spoken by LM Studio, Ollama, llama.cpp, vLLM and most
/// cloud APIs; the differences between them (reasoning fields, <think> tags, missing call ids)
/// are absorbed by `OpenAIWire.Accumulator`.
struct OpenAIClient: AIClient {
    let endpoint: AIEndpoint
    let session: URLSession

    func stream(system: String, messages: [AIMessage], tools: [AIToolSpec]) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let e = endpoint
        let s = session
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = URLRequest(url: e.baseURL.appendingPathComponent("chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let k = e.apiKey, !k.isEmpty { req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
                    req.httpBody = OpenAIWire.requestBody(endpoint: e, system: system, messages: messages, tools: tools).data()
                    var acc = OpenAIWire.Accumulator()
                    for try await payload in try await AIHTTP.events(req, session: s, endpoint: e) {
                        guard let chunk = AIJSON.parse(payload) else { continue }
                        if let err = chunk["error"] {
                            throw AIError(err["message"]?.string ?? err.string ?? "模型返回了错误")
                        }
                        for ev in acc.consume(chunk) { cont.yield(ev) }
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

public enum OpenAIWire {
    public static func requestBody(endpoint: AIEndpoint, system: String, messages: [AIMessage], tools: [AIToolSpec]) -> AIJSON {
        // DeepSeek's thinking mode wants its reasoning back while a tool loop is running.
        let echoReasoning = endpoint.baseURL.host?.contains("deepseek") == true
        var wire: [AIJSON] = [["role": "system", "content": .string(system)]]
        // Tool messages carry text only; pictures a tool returned follow in a user message
        // right after that turn's results.
        var pendingImages: [AIImage] = []
        func flushImages() {
            guard !pendingImages.isEmpty else { return }
            wire.append(["role": "user", "content": content("（以上工具返回的图片）", pendingImages)])
            pendingImages = []
        }
        for m in messages {
            if m.role != .tool { flushImages() }
            switch m.role {
            case .user:
                wire.append(["role": "user", "content": m.images.map { content(m.text, $0) } ?? .string(m.text)])
            case .assistant:
                var o: [String: AIJSON] = ["role": "assistant", "content": m.text.isEmpty ? .null : .string(m.text)]
                if !m.toolCalls.isEmpty {
                    o["tool_calls"] = .array(m.toolCalls.map { c in
                        ["id": .string(c.id), "type": "function",
                         "function": ["name": .string(c.name), "arguments": .string(c.arguments.isEmpty ? "{}" : c.arguments)]]
                    })
                }
                if echoReasoning, let r = m.reasoning { o["reasoning_content"] = .string(r) }
                wire.append(.object(o))
            case .tool:
                wire.append(["role": "tool", "tool_call_id": .string(m.toolCallID ?? ""), "content": .string(m.text)])
                pendingImages += m.images ?? []
            }
        }
        flushImages()
        var body: [String: AIJSON] = ["model": .string(endpoint.model), "messages": .array(wire), "stream": true]
        // Local models can fall into endless reasoning; cap one reply. (Cloud reasoning models
        // such as OpenAI's reject max_tokens, and their providers cap replies themselves.)
        if endpoint.isLocal { body["max_tokens"] = 16384 }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { t in
                ["type": "function", "function": ["name": .string(t.name), "description": .string(t.description), "parameters": t.parameters]]
            })
        }
        return .object(body)
    }

    /// Text plus pictures, in the content-parts form vision models take.
    static func content(_ text: String, _ images: [AIImage]) -> AIJSON {
        guard !images.isEmpty else { return .string(text) }
        var parts: [AIJSON] = images.map { ["type": "image_url", "image_url": ["url": .string($0.dataURL)]] }
        parts.append(["type": "text", "text": .string(text)])
        return .array(parts)
    }

    /// Builds the assistant message from streamed chunks.
    public struct Accumulator {
        var text = ""
        var reasoning = ""
        var calls: [Int: (id: String, name: String, args: String)] = [:]
        var finishReason: String?
        /// Inside a <think>…</think> block that a server left in the content.
        var inThink = false
        var pending = ""

        public init() {}

        public mutating func consume(_ chunk: AIJSON) -> [AIStreamEvent] {
            guard let choice = chunk["choices"]?[0] else { return [] }
            var out: [AIStreamEvent] = []
            let delta = choice["delta"] ?? choice["message"] ?? .null
            if let r = delta["reasoning_content"]?.string ?? delta["reasoning"]?.string, !r.isEmpty {
                reasoning += r
                out.append(.reasoning(r))
            }
            if let c = delta["content"]?.string, !c.isEmpty { out += splitThink(c) }
            for tc in delta["tool_calls"]?.array ?? [] {
                let i = tc["index"]?.int ?? calls.count
                var cur = calls[i] ?? (id: "", name: "", args: "")
                if let id = tc["id"]?.string, !id.isEmpty { cur.id = id }
                if let n = tc["function"]?["name"]?.string, !n.isEmpty {
                    if cur.name.isEmpty { out.append(.toolCallStarted(n)) }
                    cur.name += cur.name == n ? "" : n
                }
                if let a = tc["function"]?["arguments"]?.string { cur.args += a }
                calls[i] = cur
            }
            if let f = choice["finish_reason"]?.string { finishReason = f }
            return out
        }

        /// Routes text inside <think>…</think> to reasoning.
        private mutating func splitThink(_ s: String) -> [AIStreamEvent] {
            var out: [AIStreamEvent] = []
            var rest = pending + s
            pending = ""
            while !rest.isEmpty {
                let tag = inThink ? "</think>" : "<think>"
                if let r = rest.range(of: tag) {
                    let before = String(rest[..<r.lowerBound])
                    emit(before, &out)
                    inThink.toggle()
                    rest = String(rest[r.upperBound...])
                } else {
                    // Keep a possible partial tag for the next chunk.
                    var keep = 0
                    for k in stride(from: min(tag.count - 1, rest.count), to: 0, by: -1) where tag.hasPrefix(String(rest.suffix(k))) {
                        keep = k
                        break
                    }
                    emit(String(rest.dropLast(keep)), &out)
                    pending = String(rest.suffix(keep))
                    rest = ""
                }
            }
            return out
        }

        private mutating func emit(_ s: String, _ out: inout [AIStreamEvent]) {
            guard !s.isEmpty else { return }
            if inThink { reasoning += s; out.append(.reasoning(s)) } else { text += s; out.append(.text(s)) }
        }

        public mutating func finish() -> (AIMessage, AIStopReason) {
            if !pending.isEmpty { var o: [AIStreamEvent] = []; emit(pending, &o); pending = "" }
            var m = AIMessage(role: .assistant, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
            m.reasoning = reasoning.isEmpty ? nil : reasoning
            m.toolCalls = calls.keys.sorted().compactMap { i in
                let c = calls[i]!
                guard !c.name.isEmpty else { return nil }
                return AIToolCall(id: c.id.isEmpty ? "call_\(i)_\(UUID().uuidString.prefix(8))" : c.id, name: c.name, arguments: c.args)
            }
            let stop: AIStopReason
            switch finishReason {
            case "length": stop = .maxTokens
            case "content_filter": stop = .refused
            default: stop = m.toolCalls.isEmpty ? .done : .toolUse
            }
            return (m, stop)
        }
    }
}
