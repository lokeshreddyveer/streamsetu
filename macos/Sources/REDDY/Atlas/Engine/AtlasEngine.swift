import Foundation

/// The deterministic answer engine. Pure value type: build it once from entries (cold index), optionally attach embeddings later, then ask.
struct SetuEngine: Sendable {
    struct Hit: Sendable { let entry: AtlasEntry; let score: Double; let bm25Rank: Int?; let embeddingRank: Int? }
    struct Retrieval: Sendable { let hits: [Hit]; let confidence: Double; let ratio: Double; let decision: AtlasDecision; let intent: AtlasIntent; let correctedQuery: String }

    /// Set from the bank (AtlasBankTests prints the distribution these came from).
    static let confidentThreshold = 0.55
    static let ratioThreshold = 1.25
    /// Below the confident ratio but still a clear lead: the top candidate is answered, the rest become chips.
    /// Calibrated on the 460 tuning questions only (the 51 held-out ones were not used): at 1.08 with the title-words "settled" shortcut, 12.6% of the answers given were wrong at top 1 (36 of 286);
    /// at 1.20 with the narrowed shortcut below it is 4.8% (10 of 207). Everything below these lines is shown as "Did you mean" choices instead.
    static let leadRatio = 1.20
    /// A tie is still answered at confidence >= 0.85 when the top entry is the how-to for a "how do I", or a setting whose title carries every word asked ("show subtitles"). The same shortcut for any other kind
    /// of entry is gone: with both halves for settings and how-tos the tuning questions give 4.8% wrong answers (10 of 207); with the old all-kinds version 12.6%.
    static let settledConfidence = 0.85

    let entries: [AtlasEntry]
    let embeddings: AtlasEmbeddings?
    var embeddingWeight = Fusion.embeddingWeight
    private let index: BM25Index
    private let spell: SpellCorrector
    private let byID: [String: Int]
    /// Aliases made only of common words, by their words: the only way such a question can be found (see `retrieve`).
    private let aliasKeys: [String: [Int]]

    init(entries: [AtlasEntry], embeddings: AtlasEmbeddings? = nil) {
        self.entries = entries
        self.embeddings = embeddings
        index = BM25Index(entries: entries)
        spell = SpellCorrector(vocabulary: index.vocabulary)
        byID = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var keys: [String: [Int]] = [:]
        for (i, e) in entries.enumerated() {
            for alias in e.aliases {
                let words = Normalise.words(alias)
                guard !words.isEmpty, words.allSatisfy({ Normalise.stopWords.contains($0) }) else { continue }
                keys[words.joined(separator: " "), default: []].append(i)
            }
        }
        aliasKeys = keys
    }

    func with(embeddings e: AtlasEmbeddings?) -> SetuEngine { var c = SetuEngine(entries: entries, embeddings: e, index: index, spell: spell, byID: byID, aliasKeys: aliasKeys); c.embeddingWeight = embeddingWeight; return c }
    private init(entries: [AtlasEntry], embeddings: AtlasEmbeddings?, index: BM25Index, spell: SpellCorrector, byID: [String: Int], aliasKeys: [String: [Int]]) {
        self.entries = entries; self.embeddings = embeddings; self.index = index; self.spell = spell; self.byID = byID; self.aliasKeys = aliasKeys
    }

    func entry(_ id: String) -> AtlasEntry? { byID[id].map { entries[$0] } }
    var vocabularySize: Int { spell.size }

    // MARK: retrieval

    /// Steps 4 to 8: correct, expand, BM25, embeddings, fuse, boost.
    func retrieve(_ text: String, platform: AtlasPlatforms = .mac, appStore: Bool = false, related: [String] = [], limit: Int = 10, embeddingWeight override: Double? = nil) -> Retrieval {
        let intent = IntentDetector.detect(text).intent
        let raw = Normalise.words(text)
        let keep = raw.filter { !Normalise.stopWords.contains($0) || Synonyms.keyWords.contains($0) }
        let corrected = keep.map { Synonyms.keyWords.contains($0) ? $0 : spell.correct($0) }
        let content = corrected.filter { !Normalise.stopWords.contains($0) }
        // A question made only of common words ("can Setu change my settings") has no word the index holds. It matches an entry's alias written the same way, word for word.
        if content.isEmpty, let hit = aliasKeys[raw.joined(separator: " ")], !hit.isEmpty {
            let hits = hit.prefix(limit).map { Hit(entry: entries[$0], score: 1, bm25Rank: nil, embeddingRank: nil) }
            return Retrieval(hits: hits, confidence: 1, ratio: 99, decision: .confident, intent: intent, correctedQuery: raw.joined(separator: " "))
        }
        var terms: [(term: String, weight: Double)] = content.map { (Normalise.stem($0), 1.0) }
        let seen = Set(terms.map(\.term))
        for x in Set(Synonyms.expansions(for: corrected)) where !seen.contains(Normalise.stem(x)) { terms.append((Normalise.stem(x), 0.6)) }
        let queryText = (content.isEmpty ? corrected : content).joined(separator: " ")

        let visible: (Int) -> Bool = { i in
            let p = entries[i].platforms
            return !p.isDisjoint(with: platform) && !(appStore && p.contains(.dmgOnly))
        }
        let bm = index.score(terms).filter { visible($0.key) }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(50).map { $0 }
        let bmRank = bm.map(\.key)
        var embRank: [Int] = []
        if let embeddings, !queryText.isEmpty { embRank = embeddings.rank(queryText, limit: 200).map(\.index).filter(visible).prefix(50).map { $0 } }
        let w = override ?? embeddingWeight
        let fused = Fusion.rrf([(bmRank, 1.0), (embRank, embRank.isEmpty ? 0 : w)])

        let bmPos = Dictionary(bmRank.enumerated().map { ($1, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        let emPos = Dictionary(embRank.enumerated().map { ($1, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        var scored = fused.map { f -> (Int, Double) in
            var s = f.score * IntentDetector.kindAffinity(intent, entries[f.index].kind)
            if related.contains(entries[f.index].id) { s *= 1.05 }
            return (f.index, s)
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        // Entries whose word-match scores are tied say nothing about which one the person meant; the one whose title carries the question's own words (or, for "how do I", the how-to) goes first.
        if scored.count > 1 {
            let bmAll = Dictionary(bm.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
            let best = scored.compactMap { bmAll[$0.0] }.max() ?? 0
            let tied = scored.prefix(8).filter { (bmAll[$0.0] ?? 0) >= best * 0.97 && best > 0 }.map(\.0)
            if tied.count > 1, scored.prefix(tied.count).map(\.0).allSatisfy({ tied.contains($0) }) {
                let trivial: Set<String> = ["how", "do", "i", "can", "to", "the", "a", "my", "me", "you", "it", "is", "get", "what", "where", "does", "make", "want", "on"]
                let q = Set(raw.filter { !trivial.contains($0) }.map(Normalise.stem))
                func cover(_ i: Int) -> Int { let e = entries[i]; return q.intersection(Set(Normalise.words(e.title).map(Normalise.stem))).count }
                func pref(_ i: Int) -> Int { intent == .howDoI && entries[i].kind == .recipe ? 0 : entries[i].kind == .diagnosis && intent != .whyBroken ? 2 : 1 }
                let order = Dictionary(tied.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
                let reordered = tied.sorted { (pref($0), -cover($0), order[$0]!) < (pref($1), -cover($1), order[$1]!) }
                var byIndex = Dictionary(scored.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
                let topScore = scored[0].1
                scored = reordered.enumerated().map { ($1, byIndex[$1] ?? topScore) } + scored.dropFirst(tied.count)
                byIndex = [:]
            }
        }
        // Confidence is read from the word-match score (RRF only has ranks, so its top-to-second ratio is always about 1): how much of the best possible BM25 score the top entry earned,
        // and how far it is ahead of the runner-up.
        let ceiling = terms.reduce(0) { $0 + $1.weight * index.idf($1.term) }
        let bmMap = Dictionary(bm.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        let bmTop = scored.first.flatMap { bmMap[$0.0] } ?? 0, bmSecond = scored.dropFirst().first.flatMap { bmMap[$0.0] } ?? 0
        let confidence = ceiling > 0 ? bmTop / ceiling : 0, ratio = bmSecond > 0 ? bmTop / bmSecond : 99
        // An embedding-only match (nothing shared in words) is never confident.
        let lexical = scored.first.map { bmPos[$0.0] != nil } ?? false
        let decision: AtlasDecision = lexical && confidence >= Self.confidentThreshold ? (ratio >= Self.ratioThreshold ? .confident : .ambiguous) : .weak
        let hits = scored.prefix(limit).map { Hit(entry: entries[$0.0], score: $0.1, bm25Rank: bmPos[$0.0], embeddingRank: emPos[$0.0]) }
        return Retrieval(hits: hits, confidence: confidence, ratio: ratio, decision: decision, intent: intent, correctedQuery: content.joined(separator: " "))
    }

    // MARK: answering

    func answer(_ text: String, conversation: inout AtlasConversation, platform: AtlasPlatforms = .mac, appStore: Bool = false, now: Date = Date(), current: (AtlasEntry) -> String? = { _ in nil }) -> AtlasAnswer {
        conversation.expireIfIdle(now: now)
        let detected = IntentDetector.detect(text)

        func finish(_ a: AtlasAnswer, _ p: AtlasPlatforms? = nil) -> AtlasAnswer {
            if a.decision == .confident { conversation.remember(entries: a.entryIDs, intent: a.intent, platform: p ?? platform, now: now) }
            else if a.decision == .ambiguous { conversation.remember(entries: a.entryIDs, intent: a.intent, platform: p ?? platform, now: now) }
            return a
        }

        if let f = AtlasFollowUp.parse(text) {
            guard let id = conversation.lastEntries.first, let e = entry(id) else {
                return AtlasAnswer(text: "Which setting do you mean?", entryIDs: [], actions: [], decision: .weak, intent: .other)
            }
            switch f {
            case .otherPlatform(let p):
                if e.platforms.isDisjoint(with: p) { return finish(AtlasAnswer(text: "\(e.title) is not available on \(Self.name(p)).", entryIDs: [e.id], actions: [], decision: .confident, intent: .whereIs), p) }
                return finish(Compose.compose(intent: conversation.lastIntent ?? .whereIs, entry: e, platform: p, current: current(e), value: nil), p)
            case .howToChange: return finish(Compose.compose(intent: .howDoI, entry: e, platform: platform, current: current(e), value: nil))
            case .choices:
                let o = e.value?.options ?? []
                let t = o.isEmpty ? "\(e.title) has no fixed list of choices." : "\(e.title) choices: \(o.joined(separator: ", "))."
                return finish(AtlasAnswer(text: t, entryIDs: [e.id], actions: [], decision: .confident, intent: .whatDoes))
            case .showMe: return finish(AtlasAnswer(text: "Here is \(e.title).", entryIDs: [e.id], actions: [AtlasAction(kind: .showMe, entryID: e.id, label: "Show me")], decision: .confident, intent: .whereIs))
            case .why: return finish(Compose.compose(intent: .whyBroken, entry: e, platform: platform, current: current(e), value: nil))
            case .otherOne(let n):
                guard conversation.lastEntries.indices.contains(n), let o = entry(conversation.lastEntries[n]) else {
                    return AtlasAnswer(text: "There is no other topic from my last answer.", entryIDs: [], actions: [], decision: .weak, intent: .other)
                }
                return finish(Compose.compose(intent: conversation.lastIntent ?? .whereIs, entry: o, platform: platform, current: current(o), value: nil))
            }
        }
        if AtlasFollowUp.isPronounOnly(text) {
            guard let id = conversation.lastEntries.first, let e = entry(id) else {
                return AtlasAnswer(text: "Which setting do you mean?", entryIDs: [], actions: [], decision: .weak, intent: .other)
            }
            let i = detected.intent == .other ? AtlasIntent.whatDoes : detected.intent
            return finish(Compose.compose(intent: i, entry: e, platform: platform, current: current(e), value: detected.value))
        }

        if detected.intent == .chat {
            return AtlasAnswer(text: "Hello. " + Compose.capabilities, entryIDs: [], actions: [], decision: .confident, intent: .chat)
        }
        let r = retrieve(text, platform: platform, appStore: appStore, related: conversation.lastEntries)
        guard let top = r.hits.first else { return Compose.fallback([], intent: detected.intent) }
        switch r.decision {
        case .confident:
            return finish(Compose.compose(intent: detected.intent, entry: top.entry, platform: platform, current: current(top.entry), value: detected.value))
        case .ambiguous:
            // "turn off reminders": the person named a value and the best match is a setting that clearly leads, so the change is offered instead of a list.
            if detected.intent == .setValue, detected.value != nil, top.entry.kind == .setting, r.ratio >= 1.05 {
                return finish(Compose.compose(intent: detected.intent, entry: top.entry, platform: platform, current: current(top.entry), value: detected.value))
            }
            // A clear how-to about an obvious setting or screen is answered with the top candidate; the others are offered as chips. The list alone is for queries whose top candidates are nearly tied.
            // A tie that the title-word rule settled (the top title carries every word asked, or it is the how-to for a "how do I") is answered as well.
            let titleWords = Set(Normalise.words(text).filter { !Normalise.stopWords.contains($0) || Synonyms.keyWords.contains($0) || $0 == "show" }.map(Normalise.stem))
            let covers = !titleWords.isEmpty && titleWords.isSubset(of: Set(Normalise.words(top.entry.title).map(Normalise.stem)))
            let settled = r.confidence >= Self.settledConfidence && ((detected.intent == .howDoI && top.entry.kind == .recipe) || (covers && top.entry.kind == .setting))
            if [.howDoI, .whereIs, .whatDoes, .setValue, .whyBroken, .other].contains(detected.intent), (detected.intent != .other && r.ratio >= Self.leadRatio) || settled {
                var a = Compose.compose(intent: detected.intent, entry: top.entry, platform: platform, current: current(top.entry), value: detected.value)
                a.actions += Compose.chips(r.hits.dropFirst().prefix(3).map(\.entry))
                a.entryIDs += r.hits.dropFirst().prefix(3).map(\.entry.id)
                return finish(a)
            }
            return finish(Compose.ambiguous(r.hits.prefix(3).map(\.entry), intent: detected.intent))
        case .weak:
            return Compose.fallback(r.hits.prefix(3).map(\.entry), intent: detected.intent)
        }
    }

    static func name(_ p: AtlasPlatforms) -> String { p.contains(.iPhone) ? "iPhone" : p.contains(.iPad) ? "iPad" : "Mac" }
}
