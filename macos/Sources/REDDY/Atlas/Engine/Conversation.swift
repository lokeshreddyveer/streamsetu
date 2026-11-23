import Foundation

/// Step 2: what the last answer was about, so "and on iphone" or "show me" can be resolved. In memory only; forgotten after ten idle minutes.
struct AtlasConversation: Sendable {
    var lastEntries: [String] = []
    var lastIntent: AtlasIntent?
    var lastPlatform: AtlasPlatforms?
    var lastActivity: Date?
    var turns = 0
    static let idleLimit: TimeInterval = 600

    var isEmpty: Bool { lastEntries.isEmpty }
    mutating func reset() { self = AtlasConversation() }
    mutating func expireIfIdle(now: Date) { if let t = lastActivity, now.timeIntervalSince(t) > Self.idleLimit { reset() } }
    mutating func remember(entries: [String], intent: AtlasIntent, platform: AtlasPlatforms?, now: Date) {
        lastEntries = entries; lastIntent = intent; if let platform { lastPlatform = platform }; lastActivity = now; turns += 1
    }
}

enum AtlasFollowUp: Sendable, Equatable {
    case otherPlatform(AtlasPlatforms), howToChange, choices, showMe, why, otherOne(Int)

    /// Recognises a short follow-up that only makes sense after an answer.
    static func parse(_ raw: String) -> AtlasFollowUp? {
        let t = Normalise.clean(raw)
        func any(_ c: [String]) -> Bool { c.contains(t) }
        if t.hasPrefix("and on ") || t.hasPrefix("what about ") || t.hasPrefix("same for ") || t.hasPrefix("and for ") {
            if t.contains("iphone") { return .otherPlatform(.iPhone) }
            if t.contains("ipad") { return .otherPlatform(.iPad) }
            if t.contains("mac") { return .otherPlatform(.mac) }
        }
        if any(["how do i change it", "how do i turn it on", "how do i turn it off", "how do i change that", "how can i change it", "change it", "how do i set it", "how do i do that", "how do i use it", "how do i open it"]) { return .howToChange }
        if any(["what are the choices", "what are the options", "what can i pick", "what are my options", "what are the choices for it", "what options"]) { return .choices }
        if any(["show me", "show me how", "show me where", "show me please", "where is it", "where is that", "open it", "take me there"]) { return .showMe }
        if any(["why", "why is that", "why is that so", "but why", "why does it do that"]) { return .why }
        if any(["the other one", "the second one", "no i meant the second", "no the second", "the other", "second one", "no the other one"]) { return .otherOne(1) }
        if any(["the third one", "no i meant the third", "third one"]) { return .otherOne(2) }
        return nil
    }
}

extension AtlasFollowUp {
    /// A short question whose only subject is "it", "that" or "this" ("what does it do").
    static func isPronounOnly(_ raw: String) -> Bool {
        let w = Normalise.words(raw)
        guard w.count <= 7, w.contains(where: { ["it", "that", "this", "them"].contains($0) }) else { return false }
        return w.allSatisfy { Normalise.stopWords.contains($0) || ["it", "that", "this", "them", "do", "mean", "does", "work", "works", "for", "turn", "off", "on"].contains($0) }
    }
}
