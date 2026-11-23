import Foundation

/// The adapter for the provider the person already set up (their own key, or their own Ollama). It goes through the same `AIClient` as the assistant, so keys stay in the Keychain and nothing new is stored.
/// What it sends: the question and the candidate topics' titles, paths and summaries. Never library titles, history, addresses or logins.
struct ProviderAtlasLanguageModel: AtlasLanguageModel {
    let client: AIClient
    init(config: AIConfig, client: AIClient? = nil) { self.client = client ?? AIClient(config: config) }
    var name: String { client.config.provider.title }
    var isRemote: Bool { client.config.provider != .apple && client.config.provider != .ollama }

    func interpret(_ text: String, candidates: [AtlasCandidate]) async throws -> AtlasQueryDraft {
        guard client.config.isReady else { throw AtlasModelError.unavailable }
        let a = try await client.ask(system: AtlasModelPrompt.interpretSystem, prompt: AtlasModelPrompt.interpretPrompt(text, candidates: candidates))
        guard let d = AtlasModelPrompt.parseDraft(a, candidates: candidates) else { throw AtlasModelError.unreadable }
        return d
    }

    func phrase(_ facts: AtlasFacts, tone: AtlasTone) async throws -> AtlasPhrasing {
        guard client.config.isReady else { throw AtlasModelError.unavailable }
        let a = try await client.ask(system: AtlasModelPrompt.phraseSystem, prompt: AtlasModelPrompt.phrasePrompt(facts, tone: tone))
        guard let p = AtlasModelPrompt.parsePhrasing(a) else { throw AtlasModelError.unreadable }
        return p
    }
}
