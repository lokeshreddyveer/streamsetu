import Foundation

/// Pure text and duration scoring used to pick the right recording on YouTube-family services for a track that came from somewhere else.
enum MusicTextMatch {
    /// Things that make a recording a different version of the song. They only count against a candidate when the wanted track does not carry them too.
    enum Marker: String, CaseIterable, Sendable {
        case live, remix, cover, karaoke, spedUp, other

        var phrases: [String] {
            switch self {
            case .live: [" live ", " concert ", " en vivo ", " unplugged "]
            case .remix: [" remix ", " rmx ", " mashup ", " bootleg ", " flip "]
            case .cover: [" cover ", " covered by ", " tribute "]
            case .karaoke: [" karaoke ", " instrumental ", " backing track ", " minus one "]
            case .spedUp: [" sped up ", " speed up ", " speedup ", " slowed ", " nightcore ", " reverb ", " 8d audio ", " 8d ", " bass boosted ", " pitched "]
            case .other: [" reaction ", " tutorial ", " lesson "]
            }
        }
        var penalty: Float { self == .cover || self == .karaoke ? 0.4 : 0.55 }
    }

    private static let noise: Set<String> = [
        "official", "audio", "video", "lyrics", "lyric", "hd", "hq", "music", "visualizer", "remastered", "remaster", "mv", "topic", "vevo", "explicit"
    ]

    // MARK: normalising

    /// Lower case, accent free, punctuation free, single spaced. The rule lives in `MusicText`.
    static func normalize(_ s: String) -> String { MusicText.normalize(s) }

    static func tokens(_ normalized: String) -> [String] { normalized.split(separator: " ").map(String.init) }

    /// Title tokens with brackets, "feat." tails and filler words (official, audio, remastered...) removed.
    static func coreTokens(_ title: String) -> [String] {
        let noBrackets = title.replacingOccurrences(of: "[\\(\\[\\{][^\\)\\]\\}]*[\\)\\]\\}]", with: " ", options: .regularExpression)
        var n = normalize(noBrackets)
        n = n.replacingOccurrences(of: "\\b(feat|ft|featuring)\\b.*$", with: "", options: .regularExpression)
        let all = tokens(n)
        let kept = all.filter { !noise.contains($0) }
        return kept.isEmpty ? all : kept
    }

    static func markers(in text: String) -> Set<Marker> {
        let padded = " " + normalize(text) + " "
        var out = Set<Marker>()
        for m in Marker.allCases where m.phrases.contains(where: { padded.contains($0) }) { out.insert(m) }
        return out
    }

    // MARK: similarity

    /// 0...1. Word overlap, softened by character pairs so small typos still match.
    static func similarity(_ a: [String], _ b: [String]) -> Float {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let sa = Set(a), sb = Set(b)
        let dice = Float(2 * sa.intersection(sb).count) / Float(sa.count + sb.count)
        return max(dice, 0.9 * bigramDice(a.joined(), b.joined()))
    }

    private static func bigramDice(_ a: String, _ b: String) -> Float {
        func pairs(_ s: String) -> [String] {
            let c = Array(s)
            guard c.count > 1 else { return c.map { String($0) } }
            return (0..<(c.count - 1)).map { String(c[$0...($0 + 1)]) }
        }
        let pa = pairs(a), pb = pairs(b)
        guard !pa.isEmpty, !pb.isEmpty else { return 0 }
        var counts: [String: Int] = [:]
        for p in pb { counts[p, default: 0] += 1 }
        var hits = 0
        for p in pa { if let n = counts[p], n > 0 { hits += 1; counts[p] = n - 1 } }
        return Float(2 * hits) / Float(pa.count + pb.count)
    }

    /// 1 inside the 5 second window, falling to 0 at 30 seconds. Unknown durations get a neutral 0.5.
    static func durationScore(_ a: Int64, _ b: Int64?) -> Float {
        guard a > 0, let b, b > 0 else { return 0.5 }
        let d = Float(abs(a - b)) / 1000
        if d <= 5 { return 1 }
        if d <= 15 { return 1 - (d - 5) / 10 * 0.6 }
        if d <= 30 { return 0.4 - (d - 15) / 15 * 0.3 }
        return 0
    }

    static func isTopicChannel(_ channel: String?) -> Bool {
        guard let channel else { return false }
        return normalize(channel).hasSuffix(" topic")
    }

    private static func isOfficialChannel(_ channel: String?) -> Bool {
        guard let c = channel.map(normalize) else { return false }
        return c.hasSuffix("vevo") || c.hasSuffix(" official") || c.hasSuffix("official")
    }

    // MARK: scoring

    /// How likely a candidate recording is the wanted track. 0...1.
    static func score(trackTitle: String, artists: [String], durationMs: Int64,
                      candidateTitle: String, candidateArtist: String?, candidateDurationMs: Int64?) -> Float {
        let wantedTitle = coreTokens(trackTitle)
        let artistNorms = artists.map(normalize).filter { !$0.isEmpty }
        let artistTokenSet = Set(artistNorms.flatMap(tokens))

        // "Artist - Title" style names: the artist words are not part of the song name unless the song itself uses them.
        let extraArtistWords = artistTokenSet.subtracting(wantedTitle)
        var candTitle = coreTokens(candidateTitle)
        let stripped = candTitle.filter { !extraArtistWords.contains($0) }
        if !stripped.isEmpty { candTitle = stripped }
        let titleSim = similarity(wantedTitle, candTitle)

        var artistSim: Float = 0
        let candChannel = candidateArtist.map { tokens(normalize($0)).filter { !noise.contains($0) } } ?? []
        let candTitleAll = Set(tokens(normalize(candidateTitle)))
        for a in artistNorms {
            let at = tokens(a)
            guard !at.isEmpty else { continue }
            if !candChannel.isEmpty {
                artistSim = max(artistSim, similarity(at, candChannel))
                if Set(at).isSubset(of: Set(candChannel)) { artistSim = max(artistSim, 1) }
            }
            if Set(at).isSubset(of: candTitleAll) { artistSim = max(artistSim, 0.9) }
        }
        if artistNorms.isEmpty { artistSim = 0.5 }

        var s = 0.5 * titleSim + 0.3 * artistSim + 0.2 * durationScore(durationMs, candidateDurationMs)
        if titleSim < 0.4 { s *= 0.5 }

        let wantedMarkers = markers(in: trackTitle)
        for m in markers(in: candidateTitle).subtracting(wantedMarkers) { s *= m.penalty }

        if isTopicChannel(candidateArtist) { s += 0.06 }
        else if isOfficialChannel(candidateArtist) { s += 0.03 }
        if normalize(candidateTitle).contains("official audio") { s += 0.04 }
        return min(1, max(0, s))
    }
}
