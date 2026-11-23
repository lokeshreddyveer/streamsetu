import Foundation

/// Everything a model returns is checked here, in code. A model is never trusted to say what is safe: `AtlasEntry.mayPropose`, the settings catalogue and `AssistantAuthorizer` decide that.
/// Nothing is repaired: a field that fails is dropped, and when the pick fails the deterministic answer stands.
enum AtlasModelValidator {
    struct Verdict: Equatable {
        var entryID: String?
        var intent: AtlasIntent?
        var value: String?
        var platform: AtlasPlatforms?
        var rewrite: String?
        var rejected: [String] = []
    }

    static let platforms: [String: AtlasPlatforms] = ["mac": .mac, "ios": [.iPhone, .iPad], "iphone": .iPhone, "ipad": .iPad]

    /// `candidates` are the entries the engine found. `accepts` says whether a value is allowed for an entry's setting (the settings catalogue's own rule).
    static func validate(_ d: AtlasQueryDraft, candidates: [AtlasEntry], accepts: (AtlasEntry, String) -> Bool) -> Verdict {
        var v = Verdict()
        var entry: AtlasEntry?
        if let p = d.pick {
            if let e = candidates.first(where: { $0.id == p }) { v.entryID = e.id; entry = e } else { v.rejected.append("pick: \(p) is not one of the topics the engine found") }
        }
        if let i = d.intent {
            if let t = AtlasIntent(rawValue: i.lowercased()), t != .chat { v.intent = t } else { v.rejected.append("intent: \(i)") }
        }
        if let value = d.value {
            if let e = entry, e.mayPropose, accepts(e, value) { v.value = value.lowercased() } else { v.rejected.append("value: \(value)") }
        }
        if let p = d.platform {
            if let k = platforms[p.lowercased()] { v.platform = k } else { v.rejected.append("platform: \(p)") }
        }
        if let r = d.rewrite?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
            if r.count <= 200, !r.contains("http") { v.rewrite = r } else { v.rejected.append("rewrite") }
        }
        return v
    }

    /// Strips from an answer every action a model-chosen entry may not offer: a change on a guide-only or non-changeable entry, an action naming an entry that is not the pick, a value the catalogue refuses.
    /// Used on every answer that came through a model, as a second line after Compose's own rules.
    static func sanitise(_ a: AtlasAnswer, allowed: [AtlasEntry], kids: Bool, accepts: (AtlasEntry, String) -> Bool) -> AtlasAnswer {
        var out = a
        let byID = Dictionary(allowed.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        out.actions = a.actions.filter { act in
            guard !kids, let e = byID[act.entryID] else { return false }
            switch act.kind {
            case .changeIt:
                guard e.mayPropose, !e.guideOnly, let v = act.value, accepts(e, v) else { return false }
                return true
            case .openThis: return e.reach != .none
            case .showMe, .pick: return true
            }
        }
        return out
    }

    // MARK: phrasing

    private static func norm(_ s: String) -> String { Normalise.clean(s) }

    /// The phrasing is used only when nothing in it is new: every number, every quoted or Title-Case phrase and every `mentions` item is in the facts; no link; not longer than 1.5x; no refusal.
    /// Returns the text to show, or nil to keep the template text.
    static func validate(_ p: AtlasPhrasing, facts f: AtlasFacts) -> String? {
        let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.contains("http") || lower.contains("www.") || lower.contains("as an ai") || lower.contains("i cannot") || lower.contains("i can't") { return nil }
        guard Double(text.count) <= 1.5 * Double(max(f.text.count, 40)) else { return nil }
        let pool = norm(([f.title, f.text, f.current ?? "", f.shortcut ?? ""] + f.path + f.options + f.steps + f.others).joined(separator: " "))
        let poolWords = Set(pool.split(separator: " ").map(String.init))
        func inFacts(_ s: String) -> Bool { let n = norm(s); return n.isEmpty || pool.contains(n) }
        for m in p.mentions where !inFacts(m) { return nil }
        // numbers
        for w in norm(text).split(separator: " ") where w.contains(where: \.isNumber) { if !poolWords.contains(String(w)) { return nil } }
        // quoted and Title-Case runs (not at the start of a sentence)
        for q in quoted(text) where !inFacts(q) { return nil }
        for run in titleCaseRuns(text) where !inFacts(run) { return nil }
        // key symbols
        for ch in text where "⌘⌥⌃⇧".contains(ch) { if !(f.text + (f.shortcut ?? "")).contains(ch) { return nil } }
        return text
    }

    static func quoted(_ s: String) -> [String] {
        var out: [String] = [], cur = "", open = false
        for ch in s {
            if ch == "\"" || ch == "\u{201C}" || ch == "\u{201D}" { if open { if !cur.isEmpty { out.append(cur) }; cur = "" }; open.toggle() } else if open { cur.append(ch) }
        }
        return out
    }

    /// Runs of two or more capitalised words that do not begin a sentence ("Hardware Decoding"), plus single capitalised words in mid-sentence.
    static func titleCaseRuns(_ s: String) -> [String] {
        var out: [String] = [], run: [String] = []
        var atStart = true
        func flush() { if !run.isEmpty { out.append(run.joined(separator: " ")); run = [] } }
        for raw in s.split(separator: " ") {
            let w = raw.trimmingCharacters(in: .punctuationCharacters)
            let endsSentence = raw.last.map { ".!?:".contains($0) } ?? false
            if !atStart, let f = w.first, f.isUppercase, w.count > 1 { run.append(w) } else { flush() }
            if endsSentence { flush() }
            atStart = endsSentence
        }
        flush()
        return out
    }
}
