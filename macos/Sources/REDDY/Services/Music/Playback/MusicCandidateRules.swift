import Foundation

// Which candidate recordings may be played for a wanted track, and which search texts are tried to find them. Everything here is pure.
// A candidate that breaks one hard rule is dropped before any scoring happens; the soft score then only orders what survived.

enum MusicCandidateRules {
    enum Reason: String, Sendable, Equatable { case version, artist, duration, explicit }

    enum Verdict: Sendable, Equatable {
        /// `penalty` is subtracted from the soft score (a candidate that only passed on the runtime exception).
        case accepted(penalty: Float)
        case rejected(Reason)
        var isAccepted: Bool { if case .accepted = self { return true } else { return false } }
    }

    static let maxDriftMs: Int64 = 30_000
    static let videoDriftMs: Int64 = 90_000
    static let exceptionDriftMs: Int64 = 2_000
    static let exceptionPenalty: Float = 0.2
    /// Services whose explicit flag is trustworthy when it says "not explicit".
    static let explicitKnownProviders: Set<String> = ["spotify", "itunes"]

    // MARK: version words

    private static let neutralPhrases = [
        "album version", "original version", "single version", "radio edit", "stereo version", "mono version", "explicit version",
        "deluxe version", "original track", "original mix", "remastered", "remaster", "official audio", "official video", "official music video",
        "official lyric video", "lyric video", "lyrics", "visualizer", "audio", "hd", "hq", "4k", "explicit", "clean", "topic"
    ]

    /// Words that make a recording a different version wherever they appear.
    private static let strong: [String: String] = [
        "remix": "remix", "rmx": "remix", "refix": "remix", "flip": "flip", "bootleg": "bootleg", "mashup": "mashup", "medley": "medley",
        "live": "live", "concert": "live", "unplugged": "unplugged", "acoustic": "acoustic", "instrumental": "instrumental", "karaoke": "karaoke",
        "vocals": "vocals", "acapella": "acapella", "acappella": "acapella", "backing": "backing", "stems": "stems", "cover": "cover", "covered": "cover",
        "demo": "demo", "reprise": "reprise", "remake": "remake", "rework": "rework", "extended": "extended", "vip": "vip", "sped": "sped",
        "slowed": "slowed", "reverb": "reverb", "nightcore": "nightcore", "lofi": "lofi", "orchestral": "orchestral", "symphonic": "symphonic", "8d": "8d"
    ]

    /// Words that are ordinary inside a title and only count as a version inside a bracket or after a dash.
    private static let weak: [String: String] = ["edit": "edit", "version": "version", "mix": "mix", "dub": "dub", "session": "session", "sessions": "session"]

    private static let languages: Set<String> = [
        "hindi", "tamil", "telugu", "malayalam", "kannada", "punjabi", "bengali", "marathi", "gujarati", "bhojpuri", "urdu", "english", "spanish",
        "korean", "japanese", "chinese", "mandarin", "cantonese", "arabic", "french", "german", "portuguese", "turkish", "thai", "indonesian"
    ]

    private static let foreignVersionWords: [(String, String)] = [
        ("ライブ", "live"), ("リミックス", "remix"), ("カバー", "cover"), ("インスト", "instrumental"), ("カラオケ", "karaoke"),
        ("现场", "live"), ("現場", "live"), ("翻唱", "cover"), ("伴奏", "instrumental"), ("混音", "remix"),
        ("라이브", "live"), ("커버", "cover"), ("인스트", "instrumental"), ("리믹스", "remix"), ("노래방", "karaoke")
    ]

    /// Splits a title into its main text and the clutter segments (bracketed text and anything after a spaced dash).
    static func segments(_ title: String) -> (main: String, aside: [String]) {
        var aside: [String] = []
        var main = title
        if let r = try? NSRegularExpression(pattern: "[\\(\\[\\{（【][^\\)\\]\\}）】]*[\\)\\]\\}）】]") {
            let ns = main as NSString
            for m in r.matches(in: main, range: NSRange(location: 0, length: ns.length)).reversed() {
                aside.append(ns.substring(with: m.range))
            }
            main = r.stringByReplacingMatches(in: main, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        }
        for sep in [" - ", " – ", " — ", " | "] {
            if let r = main.range(of: sep) {
                aside.append(String(main[r.upperBound...]))
                main = String(main[..<r.lowerBound])
            }
        }
        return (main, aside)
    }

    private static func stripNeutral(_ s: String) -> String {
        var t = " " + MusicText.normalize(s) + " "
        for p in neutralPhrases { t = t.replacingOccurrences(of: " " + p + " ", with: " ") }
        for p in neutralPhrases { t = t.replacingOccurrences(of: " " + p + " ", with: " ") }
        return t
    }

    private static func canonical(_ text: String) -> String {
        var t = " " + text + " "
        for (a, b) in [(" sped up ", " sped "), (" speed up ", " sped "), (" speedup ", " sped "), (" lo fi ", " lofi "), (" bass boosted ", " reverb "),
                       (" en vivo ", " live "), (" 8d audio ", " 8d "), (" slowed and reverb ", " slowed reverb ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    /// The version tags a title (and optionally an album name) carries. Two recordings are the same version only when these sets are equal.
    static func versionTags(title: String, album: String? = nil) -> Set<String> {
        var tags = Set<String>()
        for text in [title, album].compactMap({ $0 }) {
            for (w, k) in foreignVersionWords where text.contains(w) { tags.insert(k) }
            let parts = segments(text)
            let mainTokens = canonical(stripNeutral(parts.main)).split(separator: " ").map(String.init)
            for tok in mainTokens { if let k = strong[tok] { tags.insert(k) } }
            for a in parts.aside {
                let toks = canonical(stripNeutral(a)).split(separator: " ").map(String.init)
                for (i, tok) in toks.enumerated() {
                    if let k = strong[tok] { tags.insert(k) }
                    else if let k = weak[tok] { tags.insert(k) }
                    else if languages.contains(tok) { tags.insert("lang:" + tok) }
                    else if ["part", "pt", "chapter"].contains(tok), i + 1 < toks.count, Int(toks[i + 1]) != nil { tags.insert("part" + toks[i + 1]) }
                }
            }
        }
        // A trailing version word after a plain title ("Song Instrumental") counts as well.
        let tail = canonical(stripNeutral(segments(title).main)).split(separator: " ").map(String.init)
        if let last = tail.last, ["instrumental", "karaoke", "acapella", "remix", "rmx", "nightcore"].contains(last), let k = strong[last] { tags.insert(k) }
        return tags
    }

    // MARK: artists

    private static let artistNoise: Set<String> = ["topic", "vevo", "official", "music", "records", "channel", "the"]
    private static let artistSeparators: [String] = [",", "&", "/", ";", "·", "|", "、", "×", " and ", " x ", " vs ", " vs. ", " feat. ", " feat ", " ft. ", " ft ", " featuring ", " with "]

    static func latin(_ s: String) -> String {
        let t = s.applyingTransform(.toLatin, reverse: false) ?? s
        return (t.applyingTransform(.stripDiacritics, reverse: false) ?? t)
    }

    static func hasNonLatinScript(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value > 0x24F && !(0x1E00...0x1EFF).contains($0.value) }
    }

    /// The credited names in a credit line as word lists.
    static func nameTokens(_ credit: String) -> [[String]] {
        var parts = [" " + credit + " "]
        for sep in artistSeparators { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        return parts.compactMap { p -> [String]? in
            let toks = MusicText.normalize(latin(p)).split(separator: " ").map(String.init).filter { !artistNoise.contains($0) }
            return toks.isEmpty ? nil : toks
        }
    }

    private static func containsRun(_ big: [String], _ small: [String]) -> Bool {
        guard !small.isEmpty, small.count <= big.count else { return false }
        for i in 0...(big.count - small.count) where Array(big[i..<(i + small.count)]) == small { return true }
        return false
    }

    static func namesOverlap(_ a: [[String]], _ b: [[String]]) -> Bool {
        for x in a { for y in b {
            if x.joined().count < 2 || y.joined().count < 2 { continue }
            if containsRun(x, y) || containsRun(y, x) { return true }
        } }
        return false
    }

    /// True when some credited name of the track is also credited on the candidate (channel name or the title's own "Artist - Song" text).
    /// Nil when the candidate says nothing about who made it.
    static func sharesArtist(track: MusicTrack, candidateArtist: String?, candidateTitle: String) -> Bool? {
        let wanted = track.artists.flatMap { nameTokens($0.name) }
        guard !wanted.isEmpty else { return nil }
        let channel = candidateArtist.map(nameTokens) ?? []
        if namesOverlap(wanted, channel) { return true }
        let titleTokens = MusicText.normalize(latin(candidateTitle)).split(separator: " ").map(String.init)
        for w in wanted where w.joined().count >= 3 && containsRun(titleTokens, w) { return true }
        if channel.isEmpty { return nil }
        return false
    }

    // MARK: explicit marker

    static func explicitMarker(in title: String) -> Bool? {
        let t = " " + MusicText.normalize(title) + " "
        if t.contains(" explicit ") { return true }
        if t.contains(" clean ") || t.contains(" censored ") || t.contains(" radio edit ") || t.contains(" edited ") { return false }
        return nil
    }

    // MARK: verdict

    static func evaluate(track: MusicTrack, candidate: MusicAudioSource) -> Verdict {
        let wantedTags = versionTags(title: track.title, album: track.album?.title)
        let candTags = versionTags(title: candidate.title, album: candidate.album)
        // Version words must match both ways. A language tag only vetoes when the candidate names a language the catalogue row does not:
        // the row's own "(Telugu)" is information, and the original upload usually carries no tag.
        func plain(_ t: Set<String>) -> Set<String> { t.filter { !$0.hasPrefix("lang:") } }
        if plain(wantedTags) != plain(candTags) { return .rejected(.version) }
        if !candTags.filter({ $0.hasPrefix("lang:") }).isSubset(of: wantedTags) { return .rejected(.version) }

        var penalty: Float = 0
        let share = sharesArtist(track: track, candidateArtist: candidate.artist, candidateTitle: candidate.title)
        let wantedMs = track.durationMs, candMs = candidate.durationMs ?? 0
        let known = wantedMs > 0 && candMs > 0
        let drift = known ? abs(wantedMs - candMs) : 0
        if share == false, wantedTags.contains("cover") {
            // The catalogue row is itself a cover: someone other than the credited artist is who made it.
            penalty = 0.1
        } else if share == false {
            let excepted = known && drift <= exceptionDriftMs && track.isVideo != true
            if !excepted { return .rejected(.artist) }
            penalty = exceptionPenalty
        }
        if known, drift > maxDriftMs {
            let videoLike = track.isVideo == true || videoMarker(candidate.title)
            if !(videoLike && share == true && drift <= videoDriftMs) { return .rejected(.duration) }
        }
        if let flag = explicitMarker(in: candidate.title) {
            if flag != track.explicit {
                if track.explicit || explicitKnownProviders.contains(track.providerID) { return .rejected(.explicit) }
            }
        }
        return .accepted(penalty: penalty)
    }

    private static func videoMarker(_ title: String) -> Bool {
        let t = " " + MusicText.normalize(title) + " "
        return t.contains(" official video ") || t.contains(" music video ") || t.contains(" mv ")
    }

    /// Survivors of the hard rules with their soft score, best first, at or above `minimum`.
    static func rank(track: MusicTrack, candidates: [MusicAudioSource], minimum: Float, limit: Int,
                     score: (MusicTrack, MusicAudioSource) -> Float) -> [(source: MusicAudioSource, score: Float)] {
        var out: [(MusicAudioSource, Float)] = []
        for c in candidates {
            guard case .accepted(let penalty) = evaluate(track: track, candidate: c) else { continue }
            let s = score(track, c) - penalty
            if s >= minimum { out.append((c, s)) }
        }
        return out.sorted { $0.1 > $1.1 }.prefix(limit).map { (source: $0.0, score: $0.1) }
    }

    // MARK: search variants

    private static let typeLabels: Set<String> = ["song", "video", "album", "artist", "single", "ep", "playlist"]

    /// The title without credits and clutter, keeping any bracket or dash text that names a version.
    static func cleanTitle(_ title: String, dropLanguages: Bool = false) -> String {
        var t = title
        if let r = try? NSRegularExpression(pattern: "[\\(\\[\\{（【][^\\)\\]\\}）】]*[\\)\\]\\}）】]") {
            let ns = t as NSString
            var out = t
            for m in r.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
                let seg = ns.substring(with: m.range)
                let tags = versionTags(title: "x " + seg)
                if tags.isEmpty || (dropLanguages && tags.allSatisfy { $0.hasPrefix("lang:") }), let rr = Range(m.range, in: out) { out.replaceSubrange(rr, with: " ") }
            }
            t = out
        }
        for sep in [" - ", " – ", " — "] {
            if let r = t.range(of: sep), versionTags(title: "x - " + String(t[r.upperBound...])).isEmpty { t = String(t[..<r.lowerBound]) }
        }
        if let r = try? NSRegularExpression(pattern: "\\s+(feat\\.?|ft\\.?|featuring)\\s+.*$", options: [.caseInsensitive]) {
            t = r.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
        }
        let cleaned = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? title.trimmingCharacters(in: .whitespaces) : cleaned
    }

    static func primaryArtist(_ track: MusicTrack) -> String? {
        for a in track.artists {
            let n = a.name.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty, !typeLabels.contains(n.lowercased()) { return n }
        }
        return nil
    }

    /// A movie or album named in the title ("From \"Film\"") or the track's album, when it adds something to the title.
    static func hint(_ track: MusicTrack, clean: String) -> String? {
        if let r = try? NSRegularExpression(pattern: "from\\s+[\"“”']([^\"“”']+)[\"“”']", options: [.caseInsensitive]),
           let m = r.firstMatch(in: track.title, range: NSRange(location: 0, length: (track.title as NSString).length)), m.numberOfRanges > 1 {
            return (track.title as NSString).substring(with: m.range(at: 1))
        }
        if let a = track.album?.title.trimmingCharacters(in: .whitespaces), !a.isEmpty,
           MusicText.normalize(a) != MusicText.normalize(clean) { return cleanTitle(a) }
        return nil
    }

    private struct Plan { var title: String; var artists: [MusicArtistRef] }

    private static func plans(for track: MusicTrack) -> [Plan] {
        let clean = cleanTitle(track.title, dropLanguages: true)
        let artist = primaryArtist(track)
        let first = track.artists.first { $0.name.trimmingCharacters(in: .whitespaces) == artist } ?? track.artists.first
        let withArtist = first.map { [$0] } ?? []
        var list: [Plan] = [Plan(title: clean, artists: withArtist), Plan(title: clean, artists: [])]
        let nonLatin = hasNonLatinScript(clean) || (artist.map(hasNonLatinScript) ?? false)
        if nonLatin {
            var r = first
            r?.name = latin(first?.name ?? "")
            list.append(Plan(title: latin(clean), artists: r.map { [$0] } ?? []))
        } else if let alt = MusicTransliterationKey.alternates(of: clean, limit: 1).first, MusicText.normalize(alt) != MusicText.normalize(clean) {
            list.append(Plan(title: alt, artists: []))
        } else if let h = hint(track, clean: clean) {
            list.append(Plan(title: clean + " " + h, artists: []))
        }
        var seen = Set<String>()
        var out: [Plan] = []
        for p in list {
            let key = MusicText.normalize(([p.title] + p.artists.prefix(1).map(\.name)).joined(separator: " "))
            if !key.isEmpty, seen.insert(key).inserted { out.append(p) }
        }
        return Array(out.prefix(3))
    }

    /// Up to three search texts, in order: title and artist, title alone, then the romanised form (non-Latin scripts) or the movie/album hint.
    static func queries(for track: MusicTrack) -> [String] {
        plans(for: track).map { ([$0.title] + $0.artists.prefix(1).map(\.name)).joined(separator: " ") }
    }

    /// The same track with each search text in place, in the form providers read: their query is built from the title and the first artist.
    static func variants(for track: MusicTrack) -> [MusicTrack] {
        plans(for: track).map { p in var t = track; t.title = p.title; t.artists = p.artists; return t }
    }
}
