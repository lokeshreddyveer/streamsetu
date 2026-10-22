import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - tools and messages, the same for every provider

/// What a tool is given.
enum AIArg: Sendable, Equatable {
    case string(String), strings([String]), bool(Bool), int(Int)
    var text: String? { if case .string(let s) = self { s } else { nil } }
    var list: [String] { if case .strings(let l) = self { l } else if case .string(let s) = self { [s] } else { [] } }
    var flag: Bool? { if case .bool(let b) = self { b } else if case .string(let s) = self { ["true": true, "yes": true, "on": true, "false": false, "no": false, "off": false][s.lowercased()] } else { nil } }
}
typealias AIArgs = [String: AIArg]

struct AIToolParam: Sendable {
    enum Kind: Sendable { case string, strings, boolean, oneOf([String]) }
    let name: String
    let kind: Kind
    let help: String
    var required = true
}

/// One thing the assistant can ask the app to do or look up. Described once, then sent in each provider's own format.
struct AITool: Sendable {
    let name: String
    let help: String
    let params: [AIToolParam]

    /// JSON Schema for the arguments (OpenAI, Claude, Ollama and Gemini all take this shape).
    var schema: [String: Any] {
        var props: [String: Any] = [:]
        for p in params {
            switch p.kind {
            case .string: props[p.name] = ["type": "string", "description": p.help]
            case .strings: props[p.name] = ["type": "array", "items": ["type": "string"], "description": p.help]
            case .boolean: props[p.name] = ["type": "boolean", "description": p.help]
            case .oneOf(let o): props[p.name] = ["type": "string", "enum": o, "description": p.help]
            }
        }
        var s: [String: Any] = ["type": "object", "properties": props]
        let req = params.filter(\.required).map(\.name)
        if !req.isEmpty { s["required"] = req }
        return s
    }
}

struct AICall: Sendable { let id: String; let name: String; let args: AIArgs }

/// One turn of the conversation. `raw` is the provider's own copy of an assistant turn, replayed as it came (some providers need parts such as thought signatures sent back unchanged).
struct AIMessage: @unchecked Sendable {
    enum Role: Sendable { case user, assistant, tool }
    var role: Role
    var text = ""
    var calls: [AICall] = []
    var results: [(id: String, name: String, text: String)] = []
    var raw: Any?
}

// MARK: - talking to each provider with tools

extension AIClient {
    /// One step: the conversation so far in, the assistant's next turn out (text, and/or tools it wants run). Not for Apple Intelligence: see `converseOnDevice`.
    func converse(system: String, messages: [AIMessage], tools: [AITool]) async throws -> AIMessage {
        guard config.isReady else { throw AIError.notConfigured }
        switch config.provider {
        case .apple: throw AIError.unavailable("Use the on-device path.")
        case .gemini: return try await geminiTurn(system, messages, tools)
        case .claude: return try await claudeTurn(system, messages, tools)
        case .ollama, .ollamaCloud: return try await ollamaTurn(system, messages, tools)
        case .openRouter: return try await openAITurn("https://openrouter.ai/api/v1/chat/completions", system, messages, tools, extra: ["X-Title": "StreamSetu"])
        case .groq: return try await openAITurn("https://api.groq.com/openai/v1/chat/completions", system, messages, tools)
        case .nvidia: return try await openAITurn("https://integrate.api.nvidia.com/v1/chat/completions", system, messages, tools)
        case .openAI: return try await openAITurn("https://api.openai.com/v1/chat/completions", system, messages, tools)
        }
    }

    // OpenAI and everything that speaks its chat format (Groq, NVIDIA, OpenRouter)
    private func openAITurn(_ url: String, _ system: String, _ messages: [AIMessage], _ tools: [AITool], extra: [String: String] = [:]) async throws -> AIMessage {
        var msgs: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            switch m.role {
            case .user: msgs.append(["role": "user", "content": m.text])
            case .assistant:
                if let raw = m.raw as? [String: Any] { msgs.append(raw) } else { msgs.append(["role": "assistant", "content": m.text]) }
            case .tool: for r in m.results { msgs.append(["role": "tool", "tool_call_id": r.id, "content": r.text]) }
            }
        }
        var body: [String: Any] = ["model": config.effectiveModel, "messages": msgs]
        if !tools.isEmpty { body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.help, "parameters": $0.schema]] } }
        var r = try request(url, body: body)
        r.setValue("Bearer \(config.key.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "Authorization")
        for (k, v) in extra { r.setValue(v, forHTTPHeaderField: k) }
        let j = try await json(r)
        guard let msg = ((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) else { throw AIError.unreadable }
        var out = AIMessage(role: .assistant, text: (msg["content"] as? String) ?? "", raw: msg)
        for c in (msg["tool_calls"] as? [[String: Any]]) ?? [] {
            guard let f = c["function"] as? [String: Any], let name = f["name"] as? String else { continue }
            let args = (f["arguments"] as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? (f["arguments"] as? [String: Any]) ?? [:]
            out.calls.append(AICall(id: (c["id"] as? String) ?? UUID().uuidString, name: name, args: Self.args(args)))
        }
        if out.text.isEmpty && out.calls.isEmpty { throw AIError.unreadable }
        return out
    }

    // Ollama (your own computer, or Ollama Cloud)
    private func ollamaTurn(_ system: String, _ messages: [AIMessage], _ tools: [AITool]) async throws -> AIMessage {
        var base = config.provider == .ollamaCloud ? "https://ollama.com" : config.effectiveBase
        if !base.contains("://") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        var msgs: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            switch m.role {
            case .user: msgs.append(["role": "user", "content": m.text])
            case .assistant: if let raw = m.raw as? [String: Any] { msgs.append(raw) } else { msgs.append(["role": "assistant", "content": m.text]) }
            case .tool: for r in m.results { msgs.append(["role": "tool", "tool_name": r.name, "content": r.text]) }
            }
        }
        var body: [String: Any] = ["model": config.effectiveModel, "stream": false, "messages": msgs]
        if !tools.isEmpty { body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.help, "parameters": $0.schema]] } }
        var r = try request(base + "/api/chat", body: body)
        if config.provider == .ollamaCloud { r.setValue("Bearer \(config.key.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "Authorization") }
        let j = try await json(r)
        guard let msg = j["message"] as? [String: Any] else { throw AIError.unreadable }
        var out = AIMessage(role: .assistant, text: (msg["content"] as? String) ?? "", raw: msg)
        for c in (msg["tool_calls"] as? [[String: Any]]) ?? [] {
            guard let f = c["function"] as? [String: Any], let name = f["name"] as? String else { continue }
            let args = (f["arguments"] as? [String: Any]) ?? ((f["arguments"] as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            out.calls.append(AICall(id: (c["id"] as? String) ?? UUID().uuidString, name: name, args: Self.args(args)))
        }
        if out.text.isEmpty && out.calls.isEmpty { throw AIError.unreadable }
        return out
    }

    // Anthropic Claude
    private func claudeTurn(_ system: String, _ messages: [AIMessage], _ tools: [AITool]) async throws -> AIMessage {
        var msgs: [[String: Any]] = []
        for m in messages {
            switch m.role {
            case .user: msgs.append(["role": "user", "content": m.text])
            case .assistant: if let raw = m.raw as? [[String: Any]] { msgs.append(["role": "assistant", "content": raw]) } else { msgs.append(["role": "assistant", "content": m.text]) }
            case .tool: msgs.append(["role": "user", "content": m.results.map { ["type": "tool_result", "tool_use_id": $0.id, "content": $0.text] as [String: Any] }])
            }
        }
        var body: [String: Any] = ["model": config.effectiveModel, "max_tokens": 1024, "system": system, "messages": msgs]
        if !tools.isEmpty { body["tools"] = tools.map { ["name": $0.name, "description": $0.help, "input_schema": $0.schema] } }
        var r = try request("https://api.anthropic.com/v1/messages", body: body)
        r.setValue(config.key.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let j = try await json(r)
        let blocks = (j["content"] as? [[String: Any]]) ?? []
        var out = AIMessage(role: .assistant, raw: blocks)
        out.text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        for b in blocks where (b["type"] as? String) == "tool_use" {
            if let name = b["name"] as? String { out.calls.append(AICall(id: (b["id"] as? String) ?? UUID().uuidString, name: name, args: Self.args((b["input"] as? [String: Any]) ?? [:]))) }
        }
        if out.text.isEmpty && out.calls.isEmpty { throw AIError.unreadable }
        return out
    }

    // Google Gemini
    private func geminiTurn(_ system: String, _ messages: [AIMessage], _ tools: [AITool]) async throws -> AIMessage {
        var contents: [[String: Any]] = []
        for m in messages {
            switch m.role {
            case .user: contents.append(["role": "user", "parts": [["text": m.text]]])
            case .assistant: if let raw = m.raw as? [[String: Any]] { contents.append(["role": "model", "parts": raw]) } else { contents.append(["role": "model", "parts": [["text": m.text]]]) }
            case .tool: contents.append(["role": "user", "parts": m.results.map { ["functionResponse": ["name": $0.name, "response": ["result": $0.text]]] as [String: Any] }])
            }
        }
        var body: [String: Any] = ["system_instruction": ["parts": [["text": system]]], "contents": contents]
        if !tools.isEmpty { body["tools"] = [["function_declarations": tools.map { ["name": $0.name, "description": $0.help, "parameters": $0.schema] as [String: Any] }]] }
        let model = config.effectiveModel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.effectiveModel
        var r = try request("https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent", body: body)
        r.setValue(config.key.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "x-goog-api-key")
        let j = try await json(r)
        let parts = (((j["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        var out = AIMessage(role: .assistant, raw: parts)
        out.text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        for p in parts { if let f = p["functionCall"] as? [String: Any], let name = f["name"] as? String { out.calls.append(AICall(id: UUID().uuidString, name: name, args: Self.args((f["args"] as? [String: Any]) ?? [:]))) } }
        if out.text.isEmpty && out.calls.isEmpty { throw AIError.unreadable }
        return out
    }

    static func args(_ d: [String: Any]) -> AIArgs {
        var out: AIArgs = [:]
        for (k, v) in d {
            if let s = v as? String { out[k] = .string(s) }
            else if let b = v as? Bool { out[k] = .bool(b) }
            else if let i = v as? Int { out[k] = .int(i) }
            else if let a = v as? [Any] { out[k] = .strings(a.compactMap { $0 as? String }) }
        }
        return out
    }
}

// MARK: - Apple Intelligence, with its own tool calling

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
private struct OnDeviceTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let spec: AITool
    let run: @Sendable (String, AIArgs) async -> String

    var name: String { spec.name }
    var description: String { spec.help }
    var parameters: GenerationSchema {
        let props = spec.params.map { p -> DynamicGenerationSchema.Property in
            let schema: DynamicGenerationSchema
            switch p.kind {
            case .strings: schema = DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
            case .boolean: schema = DynamicGenerationSchema(type: Bool.self)
            default: schema = DynamicGenerationSchema(type: String.self)
            }
            return .init(name: p.name, description: p.help, schema: schema, isOptional: !p.required)
        }
        let root = DynamicGenerationSchema(name: spec.name + "Arguments", description: spec.help, properties: props)
        return (try? GenerationSchema(root: root, dependencies: [])) ?? GenerationSchema(type: String.self, description: spec.help, properties: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        var args: AIArgs = [:]
        for p in spec.params {
            switch p.kind {
            case .strings: if let v = try? arguments.value([String].self, forProperty: p.name) { args[p.name] = .strings(v) }
            case .boolean: if let v = try? arguments.value(Bool.self, forProperty: p.name) { args[p.name] = .bool(v) }
            default: if let v = try? arguments.value(String.self, forProperty: p.name) { args[p.name] = .string(v) }
            }
        }
        return await run(spec.name, args)
    }
}
#endif

extension AIClient {
    /// The on-device model. It runs the tools itself, through Apple's tool calling, and returns only its final words. The conversation so far is given as text because the model's window is small.
    func converseOnDevice(system: String, messages: [AIMessage], tools: [AITool], run: @escaping @Sendable (String, AIArgs) async -> String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            let a = Self.appleAvailability()
            guard a.ok else { throw AIError.unavailable(a.why) }
            let earlier = messages.dropLast().suffix(6).map { ($0.role == .user ? "Person: " : "You: ") + String($0.text.prefix(400)) }.filter { $0.count > 8 }
            let latest = messages.last?.text ?? ""
            let prompt = (earlier.isEmpty ? "" : "Earlier in this chat:\n" + earlier.joined(separator: "\n") + "\n\n") + "Person now says: " + latest
            func attempt(_ set: [AITool]) async throws -> String {
                let session = LanguageModelSession(tools: set.map { OnDeviceTool(spec: $0, run: run) }, instructions: system)
                return try await session.respond(to: prompt).content
            }
            do { return try await attempt(tools) }
            catch {
                // A small window can be overrun by many tools: try again with fewer.
                if "\(error)".lowercased().contains("context") || "\(error)".lowercased().contains("window") { return try await attempt(Array(tools.prefix(8))) }
                throw AIError.unavailable("Apple Intelligence could not answer: \(error.localizedDescription)")
            }
        }
        #endif
        throw AIError.unavailable(Self.appleAvailability().why)
    }
}
