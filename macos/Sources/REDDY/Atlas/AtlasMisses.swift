import Foundation

/// A count, kept on this device only, of questions Setu could not answer with confidence, so the next round of entries can be written from them. Nothing here is sent anywhere. What is kept is
/// the content words of the question after spelling correction (never a title search, never a pasted address), the newest fifty, and a running total.
@MainActor final class AtlasMisses {
    static let shared = AtlasMisses(defaults: .standard)
    private let defaults: UserDefaults
    private let totalKey = "atlas.misses.total", answeredKey = "atlas.answered.total", recentKey = "atlas.misses.recent"
    static let keep = 50

    init(defaults: UserDefaults) { self.defaults = defaults }

    var total: Int { defaults.integer(forKey: totalKey) }
    var answered: Int { defaults.integer(forKey: answeredKey) }
    var recent: [String] { defaults.stringArray(forKey: recentKey) ?? [] }

    func recordAnswered() { defaults.set(answered + 1, forKey: answeredKey) }

    func recordMiss(words: String) {
        defaults.set(total + 1, forKey: totalKey)
        let w = words.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, w.count <= 80, !w.contains("://"), !w.contains("@") else { return }
        var r = recent
        r.append(w)
        if r.count > Self.keep { r.removeFirst(r.count - Self.keep) }
        defaults.set(r, forKey: recentKey)
    }

    func clear() { for k in [totalKey, answeredKey, recentKey] { defaults.removeObject(forKey: k) } }
}
