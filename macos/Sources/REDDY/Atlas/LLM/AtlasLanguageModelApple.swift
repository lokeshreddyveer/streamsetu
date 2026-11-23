import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The on-device adapter: Apple's model, asked with guided generation so the answer always has the shape of `AtlasGenDraft` (a number from the list, one of a fixed set of intents, an optional value).
/// Availability, errors and the plain-text fallback go through the app's existing `AIClient`. Nothing leaves the device.
struct AppleAtlasLanguageModel: AtlasLanguageModel {
    var client = AIClient(config: AIConfig(provider: .apple))
    var name: String { "Apple Intelligence" }
    var isRemote: Bool { false }

    /// False on an older OS, on a device without the feature, or while it is not ready: the engine's own answer is then the only one.
    static var isAvailable: Bool { AIClient.appleAvailability().ok }
    static var availability: AtlasModelAvailability { let a = AIClient.appleAvailability(); return .from(ok: a.ok, why: a.why) }

    /// The window the system reports (OS 26.4 and later); 4,096 otherwise, which is the smallest known.
    var contextWindow: Int {
        #if canImport(FoundationModels)
        if #available(macOS 26.4, iOS 26.4, *) { return max(1024, SystemLanguageModel.default.contextSize) }
        #endif
        return AtlasModelBudget.window
    }

    func interpret(_ text: String, candidates: [AtlasCandidate]) async throws -> AtlasQueryDraft {
        guard Self.isAvailable else { throw AtlasModelError.unavailable }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            do {
                let session = LanguageModelSession(instructions: AtlasModelPrompt.guidedSystem)
                let r = try await session.respond(to: AtlasModelPrompt.interpretPrompt(text, candidates: candidates), generating: AtlasGenDraft.self, options: GenerationOptions(sampling: .greedy))
                let g = r.content
                return AtlasQueryDraft(pick: g.pick >= 1 && g.pick <= candidates.count ? candidates[g.pick - 1].id : nil, intent: g.intent.tag, value: g.value, platform: nil, rewrite: nil)
            } catch let e as LanguageModelSession.GenerationError {
                switch e {
                case .rateLimited: throw AtlasModelError.rateLimited
                case .exceededContextWindowSize, .guardrailViolation, .refusal, .assetsUnavailable: throw AtlasModelError.unavailable
                default: break          // anything else: try the plain-text route below once
                }
            } catch { if Task.isCancelled { throw CancellationError() } }
        }
        #endif
        let a = try await client.ask(system: AtlasModelPrompt.interpretSystem, prompt: AtlasModelPrompt.interpretPrompt(text, candidates: candidates))
        guard let d = AtlasModelPrompt.parseDraft(a, candidates: candidates) else { throw AtlasModelError.unreadable }
        return d
    }

    func phrase(_ facts: AtlasFacts, tone: AtlasTone) async throws -> AtlasPhrasing {
        guard Self.isAvailable else { throw AtlasModelError.unavailable }
        let a = try await client.ask(system: AtlasModelPrompt.phraseSystem, prompt: AtlasModelPrompt.phrasePrompt(facts, tone: tone))
        guard let p = AtlasModelPrompt.parsePhrasing(a) else { throw AtlasModelError.unreadable }
        return p
    }
}

#if canImport(FoundationModels)
/// What the on-device model must fill in. Decoding is constrained to this shape: no free text can come back for the pick or the intent.
@available(macOS 26, iOS 26, *)
@Generable enum AtlasGenIntent {
    case whereIs, howDoI, whatDoes, setValue, whyBroken, shortcutFor, whatsNew, other
    var tag: String {
        switch self {
        case .whereIs: "where-is"
        case .howDoI: "how-do-i"
        case .whatDoes: "what-does"
        case .setValue: "set-value"
        case .whyBroken: "why-broken"
        case .shortcutFor: "shortcut-for"
        case .whatsNew: "whats-new"
        case .other: "other"
        }
    }
}

@available(macOS 26, iOS 26, *)
@Generable struct AtlasGenDraft {
    @Guide(description: "The number of the listed topic that answers the question, or 0 if none does")
    var pick: Int
    @Guide(description: "What kind of question it is")
    var intent: AtlasGenIntent
    @Guide(description: "A value the person gave, such as on, off, 18 or english. Empty if none")
    var value: String?
}
#endif

extension AtlasModelPrompt {
    /// Instructions for guided generation: the shape is enforced by the framework, so the words only say what the fields mean.
    static let guidedSystem = "You help someone find a screen, setting or how-to in a TV app. You are given their question and a numbered list of topics from the app's own index. Choose the one topic that answers it; never invent a topic. Do not answer the question itself."
}
