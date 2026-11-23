import Foundation

/// The optional language-model layer. Setu answers every question without it; a model is asked only when the engine is unsure (or the person chose "model first"), and it can only
/// PICK among topics the engine already found and say what kind of question it is. It never names an id of its own, and everything it returns goes through `AtlasModelValidator`.

/// One topic the engine found. This is everything a model is ever shown about the app: no library titles, no history, no settings values.
struct AtlasCandidate: Sendable, Equatable {
    let id: String
    let title: String
    let path: String
    let summary: String
}

/// What a model returns for a question. Every field is untrusted until the validator accepts it.
struct AtlasQueryDraft: Sendable, Equatable {
    /// The id of the topic it chose. Must be one of the candidates it was shown.
    var pick: String?
    /// One of `AtlasIntent.rawValue`.
    var intent: String?
    /// A value the person named ("on", "off", "18", "english").
    var value: String?
    /// "ios", "mac" or nil.
    var platform: String?
    /// A cleaner wording of the question. Never trusted: it is only run through the engine again.
    var rewrite: String?
}

/// The facts of a composed answer; a model may phrase these and may not add to them.
struct AtlasFacts: Sendable, Equatable {
    var title: String
    var text: String
    var path: [String] = []
    var options: [String] = []
    var shortcut: String?
    var current: String?
    var steps: [String] = []
    /// What the person's own app says now about related settings, "Hardware decoding: off". Read from the app, never invented.
    var others: [String] = []
}

enum AtlasTone: String, Sendable { case short, friendly }

struct AtlasPhrasing: Sendable, Equatable {
    var text: String
    /// Titles, option names or path segments the text uses.
    var mentions: [String] = []
}

enum AtlasModelError: Error, Equatable { case unavailable, timedOut, unreadable, notAllowed, rateLimited }

protocol AtlasLanguageModel: Sendable {
    /// Shown in the answer's note when a model helped.
    var name: String { get }
    /// True when the words leave the device.
    var isRemote: Bool { get }
    /// Tokens the model can hold at once, read at runtime where the OS says; 4,096 when it does not.
    var contextWindow: Int { get }
    func interpret(_ text: String, candidates: [AtlasCandidate]) async throws -> AtlasQueryDraft
    func phrase(_ facts: AtlasFacts, tone: AtlasTone) async throws -> AtlasPhrasing
}

/// The words every adapter sends and the lenient reader of what comes back. Candidates are numbered so the model answers with a number, never an id.
extension AtlasLanguageModel { var contextWindow: Int { AtlasModelBudget.window } }

enum AtlasModelPrompt {
    static let interpretSystem = """
    You help someone find a screen, setting or how-to in a TV app. You are given their question and a numbered list of topics the app's own index found. \
    Reply with JSON only, shaped like {"pick": 2, "intent": "where-is", "value": "off", "platform": "mac"}. \
    "pick" is the number of the one listed topic that answers the question, or 0 if none does. Never invent a topic. \
    "intent" is one of: where-is, how-do-i, what-does, set-value, why-broken, shortcut-for, whats-new, other. \
    "value" is a value the person gave (such as on, off, 18, english) or null. "platform" is "ios", "mac" or null. Do not answer the question.
    """

    static let phraseSystem = """
    Rewrite the given answer in friendlier words. Use only the facts given: do not add steps, names, numbers, settings or links. Two sentences at most, or the same numbered steps. \
    Reply with JSON only: {"text": "...", "mentions": ["titles or option names you used"]}.
    """

    static func interpretPrompt(_ text: String, candidates: [AtlasCandidate]) -> String {
        "Question: \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))\nTopics:\n" + candidates.enumerated().map { "\($0.offset + 1). \($0.element.title) | \($0.element.path) | \($0.element.summary.prefix(160))" }.joined(separator: "\n")
    }

    static func phrasePrompt(_ f: AtlasFacts, tone: AtlasTone) -> String {
        var t = "Tone: \(tone.rawValue)\nTitle: \(f.title)\nAnswer: \(f.text)"
        if !f.options.isEmpty { t += "\nChoices: " + f.options.joined(separator: ", ") }
        if let c = f.current { t += "\nNow: \(c)" }
        if !f.others.isEmpty { t += "\nAlso now: " + f.others.joined(separator: "; ") }
        return t
    }

    private static func object(_ answer: String) -> [String: Any]? {
        guard let s = answer.firstIndex(of: "{"), let e = answer.lastIndex(of: "}"), s < e, let d = String(answer[s...e]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func parseDraft(_ answer: String, candidates: [AtlasCandidate]) -> AtlasQueryDraft? {
        guard let j = object(answer) else { return nil }
        var d = AtlasQueryDraft()
        if let n = (j["pick"] as? Int) ?? (j["pick"] as? Double).map(Int.init) ?? (j["pick"] as? String).flatMap(Int.init) {
            if n >= 1, n <= candidates.count { d.pick = candidates[n - 1].id }
        } else if let s = j["pick"] as? String, !s.isEmpty { d.pick = s }      // an id: the validator decides whether it is one of the candidates
        func str(_ k: String) -> String? { (j[k] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty || $0.lowercased() == "null" ? nil : $0 } }
        d.intent = str("intent"); d.value = str("value"); d.platform = str("platform"); d.rewrite = str("rewrite")
        return d
    }

    static func parsePhrasing(_ answer: String) -> AtlasPhrasing? {
        guard let j = object(answer), let t = j["text"] as? String else { return nil }
        return AtlasPhrasing(text: t, mentions: ((j["mentions"] as? [Any]) ?? []).compactMap { $0 as? String })
    }
}

/// The on-device model shares a small window (4,096 tokens in the worst case) between instructions, prompt and answer. Every request is trimmed to fit before it is sent.
enum AtlasModelBudget {
    static let window = 4096
    static let reservedForAnswer = 512
    /// A cheap, slightly pessimistic estimate (about three characters a token).
    static func tokens(_ s: String) -> Int { max(1, (s.utf8.count + 2) / 3) }

    /// Drops the weakest candidates (and shortens summaries) until instructions + question + candidates fit. Returns what fits and the estimated tokens used.
    static func trim(_ text: String, candidates: [AtlasCandidate], system: String = AtlasModelPrompt.interpretSystem, window: Int = AtlasModelBudget.window) -> (candidates: [AtlasCandidate], used: Int) {
        var c = candidates
        func used(_ c: [AtlasCandidate]) -> Int { tokens(system) + tokens(AtlasModelPrompt.interpretPrompt(text, candidates: c)) }
        let limit = max(256, window - reservedForAnswer)
        while used(c) > limit, c.count > 1 { c.removeLast() }
        if used(c) > limit { c = c.map { AtlasCandidate(id: $0.id, title: $0.title, path: $0.path, summary: String($0.summary.prefix(60))) } }
        return (c, used(c))
    }

    /// The model is used for English questions only (the engine alone answers the other languages).
    static func isEnglish(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return true }
        return Double(letters.filter { $0.isASCII || ($0.value >= 0xC0 && $0.value <= 0x24F) }.count) / Double(letters.count) > 0.9
    }
}

/// Calm words for the header chip when Apple Intelligence is or is not ready. Never an error.
enum AtlasModelStatus {
    static func chip(appleReady: Bool, why: String, providerReady: Bool, providerTitle: String) -> String {
        if appleReady { return "Apple Intelligence" }
        if providerReady { return providerTitle }
        return why.contains("getting ready") ? "Built-in help (Apple Intelligence is getting ready)" : "On device"
    }
}

/// What the device says about the on-device model, in words the code can branch on.
enum AtlasModelAvailability: Equatable, Sendable {
    case available, notEnabled, modelNotReady, deviceNotEligible, unsupportedOS
    static func from(ok: Bool, why: String) -> AtlasModelAvailability {
        if ok { return .available }
        if why.contains("Turn on Apple Intelligence") { return .notEnabled }
        if why.contains("getting ready") { return .modelNotReady }
        if why.contains("does not support") { return .deviceNotEligible }
        return .unsupportedOS
    }
    var usable: Bool { self == .available }
    /// Calm words for the header chip (never an error).
    var chip: String {
        switch self {
        case .available: "Apple Intelligence"
        case .notEnabled: "On device (Apple Intelligence is off)"
        case .modelNotReady: "Built-in help (Apple Intelligence is getting ready)"
        case .deviceNotEligible, .unsupportedOS: "On device"
        }
    }
}

/// After a rate limit or a timeout the model is left alone for a while: no retry storm, the engine answers meanwhile.
final class AtlasModelCooldown: @unchecked Sendable {
    private let lock = NSLock()
    private var until: Date = .distantPast
    static let shared = AtlasModelCooldown()
    func start(_ seconds: TimeInterval = 60, now: Date = Date()) { lock.lock(); until = now.addingTimeInterval(seconds); lock.unlock() }
    func isCooling(now: Date = Date()) -> Bool { lock.lock(); defer { lock.unlock() }; return now < until }
    func reset() { lock.lock(); until = .distantPast; lock.unlock() }
}
