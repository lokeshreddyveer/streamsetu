import Foundation

/// A request to be shown something to watch, not the name of a title: "play something", "play somwthing", "play something best series", "put on a movie", "watch a good series". It is recognised by plain rules,
/// with a tolerance for typing slips in the vague word, so it works with no AI, and what it asks for (series, movies, best, newest, anything else said) is passed to the library search.
struct DiscoveryRequest: Equatable {
    var kind: WatchIntent.Kind = .any
    var best = false
    var newest = false
    /// What is left of the sentence once the verb, the vague word and the generic words are removed: "funny", "with prabhas", "telugu". Read by the library search as it is.
    var rest = ""

    /// What is being looked for, in a few words for the reply.
    var label: String { kind == .series ? "series" : kind == .movie ? "movies" : "titles" }

    /// The sentence the library's own understanding reads.
    var query: String {
        var parts: [String] = []
        if best { parts.append("top rated") }
        if newest { parts.append("newest") }
        if !rest.isEmpty { parts.append(rest) }
        if kind == .series { parts.append("series") } else if kind == .movie { parts.append("movies") }
        if parts.isEmpty || (parts.count == 1 && kind != .any) { return parts.isEmpty ? "surprise me" : "surprise me " + parts[0] }
        return parts.joined(separator: " ")
    }
}

enum AssistantDiscovery {
    private static let verbs: Set<String> = ["play", "watch", "put", "start", "stream", "show", "find", "give", "pick", "choose", "queue", "get", "recommend", "suggest"]
    private static let fillers: Set<String> = ["me", "us", "a", "an", "some", "any", "the", "one", "good", "nice", "great", "decent", "random", "interesting", "please", "pls", "on", "for", "to", "tonight", "now", "just", "something", "anything"]
    private static let kinds: [String: WatchIntent.Kind] = ["series": .series, "serial": .series, "serials": .series, "show": .series, "shows": .series, "episode": .series, "episodes": .series,
                                                           "movie": .movie, "movies": .movie, "film": .movie, "films": .movie]
    private static let best: Set<String> = ["best", "top", "highest", "popular", "greatest", "finest", "rated"]
    private static let newest: Set<String> = ["new", "newest", "latest", "recent", "recently", "fresh"]

    /// "something", "anything" and the slips people make typing them ("somwthing", "someting", "sumthing", "anythng").
    static func isVague(_ word: String) -> Bool {
        guard word.count >= 6, word.count <= 11 else { return false }
        // "something" may be mistyped by up to two letters (it starts the same); "anything" by one, so that real words like "nothing" are left alone
        return (word.hasPrefix("s") && distance(word, "something") <= 2) || (word.hasPrefix("an") && distance(word, "anything") <= 1)
    }

    static func parse(_ raw: String) -> DiscoveryRequest? {
        let words = raw.lowercased().replacingOccurrences(of: "’", with: "'").split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
        guard let first = words.first, verbs.contains(first) else { return nil }
        var rest = Array(words.dropFirst())
        if first == "put", rest.first == "on" { rest.removeFirst() }
        var request = DiscoveryRequest(), vague = false, left: [String] = []
        for w in rest {
            if isVague(w) { vague = true; continue }
            if fillers.contains(w) { continue }
            if let k = kinds[w] { request.kind = k; continue }
            if best.contains(w) { request.best = true; continue }
            if newest.contains(w) { request.newest = true; continue }
            left.append(w)
        }
        request.rest = left.joined(separator: " ")
        if vague { return request }
        // no vague word: "play a movie", "watch the best series" are requests; "play Bigg Boss" is a title
        return left.isEmpty && (request.kind != .any || request.best || request.newest) ? request : nil
    }

    /// Edit distance between two short words.
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var row = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var prev = row[0]; row[0] = i
            for j in 1...max(y.count, 1) where !y.isEmpty {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[y.count]
    }
}
