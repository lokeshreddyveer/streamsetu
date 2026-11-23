import Foundation

struct AtlasModelOptions: Sendable {
    /// The person chose "model first" (or asked for friendly wording): the model is asked even when the engine is confident.
    var optedIn = false
    /// Friendly wording: a validated rephrasing replaces the template text.
    var friendly = false
    /// The existing online-services switch. A remote provider is used only when it is on.
    var remoteAllowed = false
    var kids = false
    var timeout: Double = 3
    var candidateLimit = 8
    /// The model may only override the engine when the engine's lead over its runner-up is below this (conservative: a clear lead is never second-guessed).
    var overrideBelowRatio = SetuEngine.leadRatio
    /// The pick must be within the engine's own top-K.
    var pickWindow = 5
    var cooldown: AtlasModelCooldown = .shared
    /// The model's context window in tokens (from the model itself).
    var window = AtlasModelBudget.window
    var availability: AtlasModelAvailability = .available
}

struct AtlasModelResult: Sendable {
    var answer: AtlasAnswer
    /// A model contributed (a pick, a rewrite or wording).
    var assisted: Bool
    var note: String?
    var rejected: [String]
}

/// Runs the deterministic engine first, then (only when allowed and useful) a model that picks among what the engine found. Any failure leaves the deterministic answer in place.
enum AtlasModelAssist {
    static func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await op() }
            g.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw AtlasModelError.timedOut }
            defer { g.cancelAll() }
            guard let first = try await g.next() else { throw AtlasModelError.unavailable }
            return first
        }
    }

    /// `isStillOn` is read again after the model answers: turning the model off while a question is in flight drops its result.
    @MainActor static func resolve(_ text: String, engine: SetuEngine, conversation: AtlasConversation, platform: AtlasPlatforms, appStore: Bool, model: (any AtlasLanguageModel)?,
                        options: AtlasModelOptions, isStillOn: @Sendable () -> Bool = { true }, accepts: (AtlasEntry, String) -> Bool = { _, _ in false },
                        current: (AtlasEntry) -> String? = { _ in nil }) async -> AtlasModelResult {
        var scratch = conversation
        let baseline = engine.answer(text, conversation: &scratch, platform: platform, appStore: appStore, current: current)
        func plain(_ rejected: [String] = []) -> AtlasModelResult { AtlasModelResult(answer: baseline, assisted: false, note: nil, rejected: rejected) }
        guard !options.kids, let model, isStillOn(), options.availability.usable, !options.cooldown.isCooling(), !Task.isCancelled, AtlasModelBudget.isEnglish(text) else { return plain() }
        if model.isRemote && !options.remoteAllowed { return plain() }
        let r = engine.retrieve(text, platform: platform, appStore: appStore, related: conversation.lastEntries, limit: options.candidateLimit)
        guard !r.hits.isEmpty else { return plain() }
        // Conservative: a model may help only when the engine is unsure and its lead is thin; a clear engine answer stands.
        let confident = baseline.decision == .confident || (r.ratio >= options.overrideBelowRatio && r.decision != .weak)
        guard options.optedIn || !confident else { return plain() }
        let found = r.hits.map(\.entry)
        let cands = AtlasModelBudget.trim(text, candidates: found.map { AtlasCandidate(id: $0.id, title: $0.title, path: $0.path.joined(separator: " > "), summary: $0.summary) }, window: options.window).candidates
        var rejected: [String] = []
        var result = plain()

        if !confident {
            let draft: AtlasQueryDraft
            do { draft = try await withTimeout(options.timeout) { try await model.interpret(text, candidates: cands) } }
            catch let e as AtlasModelError { if e == .rateLimited || e == .timedOut { options.cooldown.start() }; return plain() }
            catch { return plain() }
            guard !Task.isCancelled else { return plain() }
            guard isStillOn() else { return plain() }
            let v = AtlasModelValidator.validate(draft, candidates: Array(found.prefix(options.pickWindow)), accepts: accepts)
            rejected = v.rejected
            if let id = v.entryID, let e = found.first(where: { $0.id == id }) {
                let detected = IntentDetector.detect(text)
                let intent = v.intent ?? (detected.intent == .other ? .whatDoes : detected.intent)
                let p = v.platform.flatMap { $0.isDisjoint(with: e.platforms) ? nil : $0 } ?? platform
                var a = Compose.compose(intent: intent, entry: e, platform: p, current: current(e), value: v.value ?? detected.value)
                a = AtlasModelValidator.sanitise(a, allowed: found, kids: options.kids, accepts: accepts)
                result = AtlasModelResult(answer: a, assisted: true, note: "\(model.name) picked this from the app's own list.", rejected: rejected)
            } else if let rewrite = v.rewrite {
                // The rewrite is only a new question for the same deterministic engine; whatever it finds there is all that counts.
                var s2 = conversation
                let a = engine.answer(rewrite, conversation: &s2, platform: platform, appStore: appStore, current: current)
                if a.decision != .weak { result = AtlasModelResult(answer: AtlasModelValidator.sanitise(a, allowed: engine.entries, kids: options.kids, accepts: accepts), assisted: true, note: "\(model.name) reworded the question.", rejected: rejected) }
            }
            if !result.assisted { result.rejected = rejected; return result }
        }

        if options.friendly, result.answer.decision != .weak, let id = result.answer.entryIDs.first, let e = engine.entry(id), result.answer.entryIDs.count == 1 {
            let facts = AtlasFacts(title: e.title, text: result.answer.text, path: e.path, options: e.value?.options ?? [], shortcut: e.shortcut, current: current(e), steps: (e.recipe ?? []).map(\.say), others: e.related.compactMap { engine.entry($0) }.filter { $0.id != e.id }.prefix(3).compactMap { r in current(r).map { "\(r.title): \($0)" } })
            if let p = try? await withTimeout(options.timeout, { try await model.phrase(facts, tone: .friendly) }), isStillOn(), let text = AtlasModelValidator.validate(p, facts: facts) {
                result.answer.text = text; result.assisted = true; result.note = result.note ?? "\(model.name) phrased this."
            }
        }
        return result
    }
}
