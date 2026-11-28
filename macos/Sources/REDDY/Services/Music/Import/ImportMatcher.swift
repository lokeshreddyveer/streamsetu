import Foundation

// Matching a Spotify track to a track from the person's own music source. The score, the version-word rule and the tiers are fixed numbers so the
// result is the same for everyone and can be tested without a network.

enum ImportTier: String, Codable, Sendable { case matched, check, missing }

struct ImportDressing: Equatable, Sendable { var base: String; var dressing: String }

enum ImportMatcher {
    static let titleWeight = 0.45, artistWeight = 0.35, durationWeight = 0.2
    static let matchedAt: Float = 0.80, checkAt: Float = 0.55
    static let maxCandidates = 6
    static let firstResultBonus: Float = 0.02

    /// Words that make a recording a different version; both sides must agree on them. "Remastered", "radio edit" and "mono" are not on the list.
    static let versionWords: Set<String> = ["live", "acoustic", "remix", "instrumental", "karaoke", "cover", "demo", "sped", "slowed", "reverb", "nightcore", "8d",
                                            "acapella", "cappella", "unplugged", "orchestral", "piano", "lofi", "extended", "reprise"]

    // MARK: text

    /// The shared text rule (`MusicText`): accents, case, apostrophes and punctuation do not matter; "&" reads as "and"; all scripts survive.
    static func norm(_ s: String) -> String { MusicText.normalize(s) }

    /// Splits the bracketed parts (any depth of ( [ {), a " - xxx" / en dash / em dash tail and a bare "feat./ft./featuring X" tail off the title.
    static func dressing(_ title: String) -> ImportDressing {
        var base = "", dress = "", depth = 0
        for ch in title {
            if "([{".contains(ch) { depth += 1; dress.append(" "); continue }
            if ")]}".contains(ch) { depth = max(0, depth - 1); dress.append(" "); continue }
            if depth > 0 { dress.append(ch) } else { base.append(ch) }
        }
        for sep in [" - ", " \u{2013} ", " \u{2014} "] {
            if let r = base.range(of: sep) { dress += " " + base[r.upperBound...]; base = String(base[..<r.lowerBound]); break }
        }
        if let r = base.range(of: #"\s(feat\.?|ft\.?|featuring)\s.*$"#, options: [.regularExpression, .caseInsensitive]) {
            dress += " " + base[r]; base.removeSubrange(r)
        }
        base = base.trimmingCharacters(in: .whitespaces)
        if norm(base).isEmpty { return ImportDressing(base: title.trimmingCharacters(in: .whitespaces), dressing: "") }
        return ImportDressing(base: base, dressing: dress.trimmingCharacters(in: .whitespaces))
    }

    static func versionSet(_ dressing: String) -> Set<String> {
        Set(norm(dressing).split(separator: " ").map(String.init).filter { versionWords.contains($0) })
    }

    /// Base title, any version words from the dressing, and the first artist.
    static func searchQuery(for t: ImportSourceTrack) -> String {
        let d = dressing(t.title)
        let versions = norm(d.dressing).split(separator: " ").map(String.init).filter { versionWords.contains($0) }
        return ([d.base] + versions + [t.artists.first ?? ""]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: similarity

    /// Sorensen-Dice on character bigrams of the normalised strings, whitespace ignored.
    static func dice(_ a: String, _ b: String) -> Double {
        let x = Array(norm(a).filter { $0 != " " }), y = Array(norm(b).filter { $0 != " " })
        if x.isEmpty && y.isEmpty { return 1 }
        guard x.count > 1, y.count > 1 else { return x == y ? 1 : 0 }
        var counts: [String: Int] = [:]
        for i in 0..<(x.count - 1) { counts[String(x[i...(i + 1)]), default: 0] += 1 }
        var hits = 0
        for i in 0..<(y.count - 1) {
            let k = String(y[i...(i + 1)])
            if let c = counts[k], c > 0 { counts[k] = c - 1; hits += 1 }
        }
        return Double(2 * hits) / Double(x.count + y.count - 2)
    }

    static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let s = Array(a), t = Array(b)
        if s.isEmpty || t.isEmpty { return s.isEmpty && t.isEmpty ? 1 : 0 }
        let window = max(0, max(s.count, t.count) / 2 - 1)
        var sm = [Bool](repeating: false, count: s.count), tm = [Bool](repeating: false, count: t.count)
        var matches = 0
        for i in 0..<s.count {
            let lo = max(0, i - window), hi = min(t.count - 1, i + window)
            guard lo <= hi else { continue }
            for j in lo...hi where !tm[j] && s[i] == t[j] { sm[i] = true; tm[j] = true; matches += 1; break }
        }
        guard matches > 0 else { return 0 }
        var trans = 0, k = 0
        for i in 0..<s.count where sm[i] { while !tm[k] { k += 1 }; if s[i] != t[k] { trans += 1 }; k += 1 }
        let m = Double(matches)
        let jaro = (m / Double(s.count) + m / Double(t.count) + (m - Double(trans / 2)) / m) / 3
        var prefix = 0
        for i in 0..<min(4, min(s.count, t.count)) { if s[i] == t[i] { prefix += 1 } else { break } }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    // MARK: score

    static func titleScore(_ source: String, _ candidate: String) -> Double {
        max(dice(dressing(source).base, dressing(candidate).base), dice(source, candidate))
    }

    /// No source artists -> 0.5. If the first source artist is found (as whole words in the candidate's artists and title, or Jaro-Winkler >= 0.92 against a
    /// piece of the candidate's artist line): 0.7 + 0.3 x the fraction of the others found. Otherwise 0.35 x the fraction of the others found.
    static func artistScore(source: [String], candidateArtists: [String], candidateTitle: String) -> Double {
        guard !source.isEmpty else { return 0.5 }
        let line = candidateArtists.joined(separator: ", ")
        let hay = " " + norm(line) + " " + norm(candidateTitle) + " "
        let pieces = line.replacingOccurrences(of: "&", with: ",").split(separator: ",").map { norm(String($0)) }.filter { !$0.isEmpty }
        func found(_ name: String) -> Bool {
            let n = norm(name)
            guard !n.isEmpty else { return false }
            return hay.contains(" " + n + " ") || pieces.contains { jaroWinkler(n, $0) >= 0.92 }
        }
        let others = Array(source.dropFirst())
        let frac = others.isEmpty ? 1 : Double(others.filter(found).count) / Double(others.count)
        if found(source[0]) { return 0.7 + 0.3 * frac }
        return others.isEmpty ? 0 : 0.35 * frac
    }

    /// Full marks within 3 s, zero at 20 s.
    static func durationScore(_ a: Int64, _ b: Int64) -> Double {
        let diff = Double(abs(a - b)) / 1000
        return max(0, 1 - max(0, diff - 3) / 17)
    }

    static func score(source s: ImportSourceTrack, candidate c: MusicTrack) -> Float {
        var num = titleWeight * titleScore(s.title, c.title) + artistWeight * artistScore(source: s.artists, candidateArtists: c.artists.map(\.name), candidateTitle: c.title)
        var den = titleWeight + artistWeight
        var farOff = false
        if let sd = s.durationMs, sd > 0, c.durationMs > 0 {
            num += durationWeight * durationScore(sd, c.durationMs); den += durationWeight
            farOff = abs(sd - c.durationMs) > 20_000
        }
        var r = num / den
        if let a = s.album, let ca = c.album?.title {
            let x = norm(dressing(a).base), y = norm(dressing(ca).base)
            if !x.isEmpty, !y.isEmpty, x == y || x.contains(y) || y.contains(x) { r += 0.05 }
        }
        if versionSet(dressing(s.title).dressing) != versionSet(dressing(c.title).dressing) { r -= 0.35 }
        if farOff { r -= 0.15 }
        if let e = s.explicit, e != c.explicit { r -= 0.04 }
        return Float(min(1, max(0, r)))
    }

    static func tier(_ best: Float) -> ImportTier { best >= matchedAt ? .matched : best >= checkAt ? .check : .missing }

    struct Ranked: Sendable { var track: MusicTrack; var score: Float }

    /// Candidates best first, at most 6; the service's first result gets +0.02 to break near-ties; duplicates are ignored.
    static func rank(source: ImportSourceTrack, results: [MusicTrack]) -> [Ranked] {
        var seen = Set<String>(), out: [Ranked] = []
        for (i, t) in results.enumerated() where seen.insert(t.uid).inserted {
            out.append(Ranked(track: t, score: min(1, score(source: source, candidate: t) + (i == 0 ? firstResultBonus : 0))))
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(maxCandidates))
    }
}
