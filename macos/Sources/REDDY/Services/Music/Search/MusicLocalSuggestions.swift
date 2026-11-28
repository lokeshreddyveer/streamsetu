import Foundation

/// What the search box can offer the moment a key is pressed, with no network at all: names Music has already seen (the person's library and history,
/// their earlier searches, every result list, the starter names) matched as a start, as the start of any word, by how they sound, and after fixing the
/// spelling. Remote songs are added to these when they arrive; they never delay them.
///
/// One actor owns the phrases and the spelling index. A phrase is stored once however many times it is added (the weight grows instead), the store is
/// bounded (`maxPhrases`; the lightest are dropped first), and `suggest` is a single pass over plain strings, so it answers in a few milliseconds.
actor MusicLocalSuggestions {
    static let shared = MusicLocalSuggestions()

    enum Kind: Int, Sendable { case recent = 0, song, artist, album, film, playlist, other }

    struct Suggestion: Hashable, Sendable {
        var text: String
        var kind: Kind
        /// Why it matched: a start of the phrase, a word inside it, the same sound, or only after the spelling was fixed.
        var how: Match
    }
    enum Match: Int, Sendable { case start = 0, word, sound, fixed }

    struct Answer: Sendable, Equatable {
        var suggestions: [Suggestion]
        /// The typed words with the wrong ones replaced by known ones; nil when they were fine.
        var correction: String?
    }

    private struct Phrase { var text: String; var norm: String; var key: String; var tokens: [String]; var kind: Kind; var weight: Int }

    static let maxPhrases = 40_000
    private var phrases: [Phrase] = []
    private var index: [String: Int] = [:]
    private var spell = MusicSpellIndex()
    private var spellDirty = false
    /// Sorted lookups, rebuilt only after phrases were added: whole phrases, their words, the sound of whole phrases and of their words. A prefix is
    /// then one binary search, however many phrases there are.
    private var byNorm: [(String, Int)] = []
    private var byToken: [(String, Int)] = []
    private var byKey: [(String, Int)] = []
    private var byTokenKey: [(String, Int)] = []
    private var lookupsDirty = false

    // MARK: feeding

    func add(_ text: String, kind: Kind, weight: Int = 1) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t.count <= 120 else { return }
        let norm = MusicText.normalize(t)
        guard !norm.isEmpty else { return }
        if let i = index[norm] {
            phrases[i].weight += max(1, weight)
            if kind.rawValue < phrases[i].kind.rawValue { phrases[i].kind = kind }
            return
        }
        if phrases.count >= Self.maxPhrases { trim() }
        index[norm] = phrases.count
        phrases.append(Phrase(text: t, norm: norm, key: MusicTransliterationKey.key(t), tokens: norm.split(separator: " ").map(String.init), kind: kind, weight: max(1, weight)))
        spell.add(text: t, weight: weight)
        spellDirty = true; lookupsDirty = true
    }

    func add(_ texts: [String], kind: Kind, weight: Int = 1) { for t in texts { add(t, kind: kind, weight: weight) } }

    /// Adds many names at once, then builds the lookups so the first keystroke does not pay for them.
    func feed(_ groups: [(kind: Kind, names: [String], weight: Int)]) {
        for g in groups { add(g.names, kind: g.kind, weight: g.weight) }
        warm()
    }

    func warm() {
        if spellDirty { spell.prepare(); spellDirty = false }
        rebuildLookups()
    }

    func forgetRecents() {
        phrases.removeAll { $0.kind == .recent }
        reindex()
    }

    /// The privacy wipe: nothing the person did survives (the starter names are added again by the next feed).
    func reset() { phrases = []; index = [:]; spell = MusicSpellIndex(); spellDirty = false; byNorm = []; byToken = []; byKey = []; byTokenKey = []; lookupsDirty = false }

    var count: Int { phrases.count }

    private func trim() {
        phrases.sort { $0.weight > $1.weight }
        phrases.removeLast(phrases.count / 4)
        reindex()
    }

    private func reindex() {
        index = [:]
        for (i, p) in phrases.enumerated() { index[p.norm] = i }
        lookupsDirty = true
    }

    private func rebuildLookups() {
        guard lookupsDirty else { return }
        lookupsDirty = false
        var n: [(String, Int)] = [], t: [(String, Int)] = [], k: [(String, Int)] = [], tk: [(String, Int)] = []
        n.reserveCapacity(phrases.count); k.reserveCapacity(phrases.count)
        for (i, p) in phrases.enumerated() {
            n.append((p.norm, i))
            if !p.key.isEmpty { k.append((p.key, i)) }
            for tok in p.tokens {
                t.append((tok, i))
                let key = MusicTransliterationKey.key(word: tok)
                if !key.isEmpty { tk.append((key, i)) }
            }
        }
        byNorm = n.sorted { $0.0 < $1.0 }; byToken = t.sorted { $0.0 < $1.0 }
        byKey = k.sorted { $0.0 < $1.0 }; byTokenKey = tk.sorted { $0.0 < $1.0 }
    }

    /// The phrase numbers whose sorted string starts with `prefix`, at most `cap`.
    private static func starting(with prefix: String, in sorted: [(String, Int)], cap: Int = 600) -> [Int] {
        guard !prefix.isEmpty else { return [] }
        var lo = 0, hi = sorted.count
        while lo < hi { let mid = (lo + hi) / 2; if sorted[mid].0 < prefix { lo = mid + 1 } else { hi = mid } }
        var out: [Int] = []
        var i = lo
        while i < sorted.count, sorted[i].0.hasPrefix(prefix), out.count < cap { out.append(sorted[i].1); i += 1 }
        return out
    }

    // MARK: answering

    /// Up to `limit` offers for what is typed, best first; the typed words themselves are never offered back.
    func suggest(_ typed: String, limit: Int = 6) -> Answer {
        let n = MusicText.normalize(typed)
        guard n.count >= 2 else { return Answer(suggestions: [], correction: nil) }
        if spellDirty { spell.prepare(); spellDirty = false }
        rebuildLookups()
        var found: [(Suggestion, Int, Int)] = []   // suggestion, weight, length
        var seen: Set<String> = [n]
        func scan(_ query: String, fixed: Bool) {
            let q = MusicText.normalize(query)
            let qTokens = q.split(separator: " ").map(String.init)
            guard let lastToken = qTokens.last else { return }
            let earlier = Array(qTokens.dropLast())
            let qKey = MusicTransliterationKey.key(q)
            var how: [Int: Match] = [:]
            for i in Self.starting(with: q, in: byNorm) { how[i] = .start }
            for i in Self.starting(with: lastToken, in: byToken) where how[i] == nil {
                let tokens = phrases[i].tokens
                if earlier.allSatisfy({ e in tokens.contains { $0.hasPrefix(e) } }) { how[i] = .word }
            }
            if qKey.count >= 3 {
                for i in Self.starting(with: qKey, in: byKey) where how[i] == nil { how[i] = .sound }
                if qTokens.count == 1 { for i in Self.starting(with: qKey, in: byTokenKey) where how[i] == nil { how[i] = .sound } }
            }
            for (i, h) in how {
                let p = phrases[i]
                guard !seen.contains(p.norm) else { continue }
                seen.insert(p.norm)
                found.append((Suggestion(text: p.text, kind: p.kind, how: fixed ? .fixed : h), p.weight, p.norm.count))
            }
        }
        scan(n, fixed: false)
        var correction: String?
        let fixed = spell.corrected(query: n)
        if fixed.changed, fixed.text != n {
            correction = fixed.text
            if found.count < limit { scan(fixed.text, fixed: true) }
        }
        // Earlier searches first, then how the phrase matched, then how often it has been seen, then the shorter one.
        let sorted = found.sorted { a, b in
            if (a.0.kind == .recent) != (b.0.kind == .recent) { return a.0.kind == .recent }
            if a.0.how != b.0.how { return a.0.how.rawValue < b.0.how.rawValue }
            if a.1 != b.1 { return a.1 > b.1 }
            return a.2 < b.2
        }
        return Answer(suggestions: Array(sorted.prefix(limit).map(\.0)), correction: correction)
    }

    /// The corrected spelling of a whole query for the results page, or nil when it needs none.
    func didYouMean(_ query: String) -> String? {
        if spellDirty { spell.prepare(); spellDirty = false }
        let r = spell.corrected(query: query, typingLastWord: false)
        let n = MusicText.normalize(query)
        return r.changed && r.text != n ? r.text : nil
    }
}
