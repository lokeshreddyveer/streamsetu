import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The AI the person has chosen to ask. They bring their own account: an API key from the provider (kept in the Keychain and sent only to that provider), or Apple Intelligence, which runs
/// on the device and needs no key, or a model of their own on their network (Ollama). Only the words the person types are sent: never a playlist address, a login, or what they have watched.
enum AIProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case apple, gemini, groq, nvidia, openRouter, claude, openAI, ollamaCloud, ollama
    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .gemini: "Google Gemini"
        case .groq: "Groq"
        case .nvidia: "NVIDIA"
        case .ollamaCloud: "Ollama Cloud"
        case .openRouter: "OpenRouter"
        case .claude: "Anthropic Claude"
        case .openAI: "OpenAI"
        case .ollama: "Ollama (your own computer)"
        }
    }
    var needsKey: Bool { self != .apple && self != .ollama }
    /// Where the person gets a key (or the model).
    var keyHelp: String {
        switch self {
        case .apple: "Nothing to add: it runs on this device."
        case .gemini: "Free key at aistudio.google.com/apikey"
        case .groq: "Free key at console.groq.com/keys"
        case .nvidia: "Free key at build.nvidia.com (sign in, then Get API Key)"
        case .ollamaCloud: "Key at ollama.com/settings/keys"
        case .openRouter: "Key at openrouter.ai/keys"
        case .claude: "Key at console.anthropic.com"
        case .openAI: "Key at platform.openai.com/api-keys"
        case .ollama: "Install Ollama on a computer on your network, and give its address."
        }
    }
    /// A model that exists today; the person can change it in Settings because model names change.
    var defaultModel: String {
        switch self {
        case .apple: ""
        case .gemini: "gemini-2.5-flash-lite"
        case .groq: "llama-3.3-70b-versatile"
        case .nvidia: "meta/llama-3.3-70b-instruct"
        case .ollamaCloud: "gpt-oss:120b"
        case .openRouter: "meta-llama/llama-3.3-70b-instruct:free"
        case .claude: "claude-haiku-5-5"
        case .openAI: "gpt-4o-mini"
        case .ollama: "llama3.2"
        }
    }
    var defaultBase: String { self == .ollama ? "http://localhost:11434" : "" }

    /// What it costs, as of the date in `PricingNote.asOf`. Prices change: the provider's own page is the truth.
    var pricing: String {
        switch self {
        case .apple: "Free. Runs on this device, so it needs a supported device with Apple Intelligence switched on. English and several other languages."
        case .gemini: "Free tier with no card (low limits: roughly a couple of requests a minute and tens to a thousand a day, depending on the model; Google may use free-tier data to improve its products). Paid: about $0.10 to $0.30 per million words in and $0.40 to $2.50 out for the small models."
        case .groq: "Free tier with no card, but with limits: about 30 requests a minute and roughly 1,000 a day on the 70B model (the smaller model allows more). Very fast. Paid: about $0.59 per million words in and $0.79 out for the 70B model."
        case .nvidia: "Free for trying things out: about 40 requests a minute, and the limit cannot be raised on the free tier. Your own limit is shown on build.nvidia.com once you are signed in. It is meant for testing, so use it lightly."
        case .ollamaCloud: "Has a free plan with light use (a limit on how much computer time you use, resetting every few hours and weekly, and one request at a time); paid plans from about $20 a month raise it. Billing details vary, so check ollama.com."
        case .openRouter: "Free models (names ending in :free): 20 requests a minute, and 50 a day, or 1,000 a day once you have bought $10 of credit. Paid models are billed at the price of the model you choose."
        case .claude: "No free API tier. Small model about $0.10 to $1 per million words in and $0.50 to $5 out; mid-size about $3 in and $15 out."
        case .openAI: "No free API tier. Small models about $0.15 to $0.75 per million words in and $0.60 to $4.50 out."
        case .ollama: "Free. Runs on your own computer; speed depends on that computer."
        }
    }
    var pricingURL: String {
        switch self {
        case .apple: "https://www.apple.com/apple-intelligence/"
        case .gemini: "https://ai.google.dev/gemini-api/docs/pricing"
        case .groq: "https://console.groq.com/docs/rate-limits"
        case .nvidia: "https://build.nvidia.com"
        case .ollamaCloud: "https://ollama.com/pricing"
        case .openRouter: "https://openrouter.ai/docs/api/reference/limits"
        case .claude: "https://docs.anthropic.com/en/docs/about-claude/pricing"
        case .openAI: "https://openai.com/api/pricing/"
        case .ollama: "https://ollama.com"
        }
    }
}

enum PricingNote {
    /// When the figures above were last checked. Shown next to them.
    static let asOf = "October 2026"
    static let footer = "Prices and free limits change. A typical question uses a few hundred words, a fraction of a cent on a small model."
}

struct AIConfig: Equatable, Sendable {
    var provider: AIProvider = .apple
    var model = ""
    var base = ""
    var key = ""

    var effectiveModel: String { model.trimmingCharacters(in: .whitespaces).isEmpty ? provider.defaultModel : model.trimmingCharacters(in: .whitespaces) }
    var effectiveBase: String { base.trimmingCharacters(in: .whitespaces).isEmpty ? provider.defaultBase : base.trimmingCharacters(in: .whitespaces) }
    var isReady: Bool {
        switch provider {
        case .apple: true
        case .ollama: !effectiveBase.isEmpty
        default: !key.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

enum AIError: LocalizedError, Equatable {
    case notConfigured, unavailable(String), rejected(String), network(String), unreadable
    var errorDescription: String? {
        switch self {
        case .notConfigured: "Choose an AI in Settings first."
        case .unavailable(let m): m
        case .rejected(let m): m
        case .network(let m): m
        case .unreadable: "The AI's answer could not be read. Try asking again."
        }
    }
}

struct AIClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let config: AIConfig
    var transport: Transport = AIClient.live
    /// Replaced in tests; the real one asks the on-device model.
    var onDevice: @Sendable (_ system: String, _ prompt: String) async throws -> String = AIClient.askAppleIntelligence

    static let live: Transport = { request in
        let cfg = URLSessionConfiguration.ephemeral; cfg.timeoutIntervalForRequest = 60
        let (data, response) = try await URLSession(configuration: cfg).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.network("No answer.") }
        return (data, http)
    }

    /// Asks one question and returns the text of the answer.
    func ask(system: String, prompt: String) async throws -> String {
        guard config.isReady else { throw AIError.notConfigured }
        switch config.provider {
        case .apple: return try await onDevice(system, prompt)
        case .gemini: return try await gemini(system, prompt)
        case .openRouter: return try await chatCompletions("https://openrouter.ai/api/v1/chat/completions", system, prompt, extra: ["X-Title": "StreamSetu"])
        case .groq: return try await chatCompletions("https://api.groq.com/openai/v1/chat/completions", system, prompt)
        case .nvidia: return try await chatCompletions("https://integrate.api.nvidia.com/v1/chat/completions", system, prompt)
        case .ollamaCloud: return try await ollama(system, prompt, base: "https://ollama.com", bearer: config.key.trimmingCharacters(in: .whitespaces))
        case .openAI: return try await chatCompletions("https://api.openai.com/v1/chat/completions", system, prompt)
        case .claude: return try await claude(system, prompt)
        case .ollama: return try await ollama(system, prompt)
        }
    }

    // MARK: providers

    private func gemini(_ system: String, _ prompt: String) async throws -> String {
        let model = config.effectiveModel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.effectiveModel
        var r = try request("https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent",
                            body: ["system_instruction": ["parts": [["text": system]]], "contents": [["role": "user", "parts": [["text": prompt]]]]])
        r.setValue(config.key.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "x-goog-api-key")
        let j = try await json(r)
        let parts = (((j["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError.unreadable }
        return text
    }

    private func chatCompletions(_ url: String, _ system: String, _ prompt: String, extra: [String: String] = [:]) async throws -> String {
        var r = try request(url, body: ["model": config.effectiveModel, "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]])
        r.setValue("Bearer \(config.key.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "Authorization")
        for (k, v) in extra { r.setValue(v, forHTTPHeaderField: k) }
        let j = try await json(r)
        let text = (((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
        guard !text.isEmpty else { throw AIError.unreadable }
        return text
    }

    private func claude(_ system: String, _ prompt: String) async throws -> String {
        var r = try request("https://api.anthropic.com/v1/messages", body: ["model": config.effectiveModel, "max_tokens": 700, "system": system, "messages": [["role": "user", "content": prompt]]])
        r.setValue(config.key.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let j = try await json(r)
        let text = ((j["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError.unreadable }
        return text
    }

    private func ollama(_ system: String, _ prompt: String, base fixedBase: String? = nil, bearer: String? = nil) async throws -> String {
        var base = fixedBase ?? config.effectiveBase
        if !base.contains("://") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        var r = try request(base + "/api/chat", body: ["model": config.effectiveModel, "stream": false, "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]])
        if let bearer { r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let j = try await json(r)
        let text = ((j["message"] as? [String: Any])?["content"] as? String) ?? ""
        guard !text.isEmpty else { throw AIError.unreadable }
        return text
    }

    // MARK: plumbing

    func request(_ url: String, body: [String: Any]) throws -> URLRequest {
        guard let u = URL(string: url) else { throw AIError.network("That address is not valid.") }
        var r = URLRequest(url: u, timeoutInterval: 60)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("StreamSetu", forHTTPHeaderField: "User-Agent")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    func json(_ r: URLRequest) async throws -> [String: Any] {
        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await transport(r) } catch let e as AIError { throw e } catch { throw AIError.network(error.localizedDescription) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (200..<300).contains(http.statusCode) { return obj }
        let name = config.provider.title
        switch http.statusCode {
        case 401, 403: throw AIError.rejected("\(name) did not accept the key.")
        case 404: throw AIError.rejected("\(name) does not know the model \"\(config.effectiveModel)\". Change the model name in Settings.")
        case 429: throw AIError.rejected("\(name) says you have used up its limit for now. Wait a little, or change provider.")
        case 500...: throw AIError.network("\(name) is not answering (\(http.statusCode)).")
        default: throw AIError.rejected(Self.reason(obj) ?? "\(name) answered \(http.statusCode).")
        }
    }

    /// The provider's own explanation of a refusal, when it gives one.
    static func reason(_ j: [String: Any]) -> String? {
        if let e = j["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let e = j["error"] as? String { return e }
        return nil
    }

    // MARK: Apple Intelligence

    /// Whether the on-device model can be used here, and if not, why in plain words.
    static func appleAvailability() -> (ok: Bool, why: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return (true, "Ready. It runs on this device.")
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return (false, "This device does not support Apple Intelligence.")
                case .appleIntelligenceNotEnabled: return (false, "Turn on Apple Intelligence in System Settings.")
                case .modelNotReady: return (false, "Apple Intelligence is still getting ready. Try again soon.")
                @unknown default: return (false, "Apple Intelligence is not available right now.")
                }
            }
        }
        #endif
        return (false, "Apple Intelligence needs macOS, iOS or iPadOS 26 or newer.")
    }

    @Sendable static func askAppleIntelligence(system: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            let a = appleAvailability()
            guard a.ok else { throw AIError.unavailable(a.why) }
            do {
                let session = LanguageModelSession(instructions: system)
                return try await session.respond(to: prompt).content
            } catch { throw AIError.unavailable("Apple Intelligence could not answer: \(error.localizedDescription)") }
        }
        #endif
        throw AIError.unavailable(appleAvailability().why)
    }
}

// MARK: - what is asked

/// "What should I watch?": the person's words in, a search for the library and some ideas out.
struct WatchSuggestion: Equatable, Sendable {
    var search = ""
    var titles: [String] = []
    var note = ""
}

enum WatchAdvisor {
    static let system = """
    You help someone choose something to watch from their own library of films and series. Reply with JSON only, no other text, shaped like:
    {"search": "...", "titles": ["Title (Year)", ...], "note": "..."}
    "search" is a short search sentence using only these kinds of words: a language (such as telugu, hindi, english), a four-digit year or a decade like 2010s, "under 2 hours" or "over 2 hours", "unwatched", "favourites", "4K", "top rated", and at most three words of a title. Leave out anything else, and use an empty string if nothing fits.
    "titles" is up to 8 real films or series that match what they ask for, with the year. Never invent a title.
    "note" is one friendly sentence, no spoilers.
    """

    static func prompt(_ request: String) -> String { "What I feel like watching: " + request.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Reads the answer even when the AI wraps it in a code block or adds a sentence around it.
    static func parse(_ answer: String) -> WatchSuggestion? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let data = String(answer[start...end]).data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let titles = ((j["titles"] as? [Any]) ?? []).compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let s = WatchSuggestion(search: ((j["search"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), titles: Array(titles.prefix(8)), note: ((j["note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        return s.search.isEmpty && s.titles.isEmpty ? nil : s
    }

    /// "Inception (2010)" -> ("Inception", 2010)
    static func split(_ title: String) -> (name: String, year: Int?) {
        (TraktItem.cleanTitle(title), MetadataNormalizer.year(from: title))
    }
}

// MARK: - settings storage

/// The AI choice (provider, model, address) is a preference; the key is a secret and lives in the Keychain, one per provider.
struct AIStore: @unchecked Sendable {
    let defaults: UserDefaults
    let credentials: CredentialStore
    private let providerKey = "ai.provider"
    private func modelKey(_ p: AIProvider) -> String { "ai.model." + p.rawValue }
    private let baseKey = "ai.ollama.base"
    private func ref(_ p: AIProvider) -> String { "ai.key." + p.rawValue }

    var provider: AIProvider {
        get { AIProvider(rawValue: defaults.string(forKey: providerKey) ?? "") ?? .apple }
        nonmutating set { defaults.set(newValue.rawValue, forKey: providerKey) }
    }

    func load(_ p: AIProvider? = nil) -> AIConfig {
        let p = p ?? provider
        return AIConfig(provider: p, model: defaults.string(forKey: modelKey(p)) ?? "", base: p == .ollama ? (defaults.string(forKey: baseKey) ?? "") : "",
                        key: p.needsKey ? ((try? credentials.load(ref: ref(p)))?.password ?? "") : "")
    }

    func save(_ c: AIConfig) {
        provider = c.provider
        defaults.set(c.model.trimmingCharacters(in: .whitespaces), forKey: modelKey(c.provider))
        if c.provider == .ollama { defaults.set(c.base.trimmingCharacters(in: .whitespaces), forKey: baseKey) }
        if c.provider.needsKey {
            let k = c.key.trimmingCharacters(in: .whitespaces)
            if k.isEmpty { try? credentials.delete(ref: ref(c.provider)) } else { try? credentials.save(Credentials(username: c.provider.rawValue, password: k), ref: ref(c.provider)) }
        }
    }
}
