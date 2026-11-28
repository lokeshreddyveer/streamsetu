import Foundation

// Lyrics value types and the pure rules around them (normalisation, matching tolerances, duet layout, source ordering).
// Nothing here touches the network or the disk, so every rule can be tested with canned data.

/// One timed piece of a word: the characters `startChar..<endChar` of the word's text are sung between `startMs` and `endMs`.
struct MusicLyricSyllable: Codable, Hashable, Sendable {
    var startMs: Int64
    var endMs: Int64
    var startChar: Int
    var endChar: Int
}

/// One word of a line. `text` keeps its trailing space when a space follows it, so "ends with a space" means "the word ends here".
/// A word sung over several beats carries `syllables`; a word with fewer than two usable syllables has none.
struct MusicLyricWord: Codable, Hashable, Sendable {
    var text: String
    var startMs: Int64
    var endMs: Int64
    var background: Bool = false
    var syllables: [MusicLyricSyllable]? = nil

    init(text: String, startMs: Int64, endMs: Int64, background: Bool = false, syllables: [MusicLyricSyllable]? = nil) {
        self.text = text; self.startMs = startMs; self.endMs = endMs; self.background = background; self.syllables = syllables
    }

    private enum CodingKeys: String, CodingKey { case text, startMs, endMs, background, syllables }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        startMs = try c.decodeIfPresent(Int64.self, forKey: .startMs) ?? 0
        endMs = try c.decodeIfPresent(Int64.self, forKey: .endMs) ?? startMs
        background = try c.decodeIfPresent(Bool.self, forKey: .background) ?? false
        syllables = try c.decodeIfPresent([MusicLyricSyllable].self, forKey: .syllables)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(startMs, forKey: .startMs)
        try c.encode(endMs, forKey: .endMs)
        if background { try c.encode(true, forKey: .background) }
        if let syllables, !syllables.isEmpty { try c.encode(syllables, forKey: .syllables) }
    }
}

/// Where a source stands for the song on screen, as the source picker shows it. A walk cancelled by an earlier winner returns to `notFetched`.
enum MusicLyricsSourceState: String, Sendable, Codable {
    case notFetched, fetching, found, notFound, unavailable

    var label: String {
        switch self {
        case .notFetched: "Tap to fetch"
        case .fetching: "Fetching lyrics..."
        case .found: "Lyrics found. Tap to use"
        case .notFound: "Lyrics not found"
        case .unavailable: "Unavailable right now"
        }
    }
}

enum MusicLyricsKind: String, Sendable, Codable {
    case instrumental, plain, synced, wordSynced
    var label: String {
        switch self {
        case .instrumental: "Instrumental"
        case .plain: "Plain text"
        case .synced: "Synced"
        case .wordSynced: "Word by word"
        }
    }
}

extension MusicLyrics {
    /// True when any line carries a start time.
    var isSynced: Bool { !(synced?.isEmpty ?? true) }
    var isWordTimed: Bool { synced?.contains { !($0.words?.isEmpty ?? true) } ?? false }
    var hasTranslation: Bool { synced?.contains { !($0.translation ?? "").isEmpty } ?? false }
    var hasRomanization: Bool { synced?.contains { !($0.romanized ?? "").isEmpty } ?? false }
    var kind: MusicLyricsKind {
        if instrumental { return .instrumental }
        if !isSynced { return .plain }
        return isWordTimed ? .wordSynced : .synced
    }
}

/// What a provider is asked. `searched` is true when the person typed a title and artist in the source picker, so the video id
/// no longer describes what to look up.
struct MusicLyricsRequest: Hashable, Sendable {
    var videoID: String?
    var title: String
    var artists: String
    var album: String?
    var durationSeconds: Double?
    var searched: Bool = false
    var isLocal: Bool = false
    var localFileURL: URL? = nil
    /// Filled by the walk's preface from the YouTube "next" call.
    var youTubeBrowseID: String? = nil
    var factsFailed: Bool = false
    /// The recording code, from the track's tags or found by the identification step. Always upper case and shaped like an ISRC.
    var isrc: String? = nil
    /// What the identification step already learned from BiniLyrics, so that source need not search twice.
    var identified: MusicLyricsIdentified? = nil

    var hasDuration: Bool { (durationSeconds ?? 0) > 0 && (durationSeconds ?? 0).isFinite }
    var roundedDuration: Int? { hasDuration ? Int((durationSeconds ?? 0).rounded()) : nil }
    var searchTitle: String {
        let cleaned = MusicLyricsText.searchTitle(title)
        return cleaned.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    static let youTubeProviderIDs: Set<String> = ["youtube-music", "ytmusic", "youtube", "piped", "invidious"]

    static func make(track: MusicTrack, videoID override: String? = nil) -> MusicLyricsRequest {
        let local = track.providerID == "local"
        var file: URL?
        if local, let s = track.directStreams?.first?.url, let u = URL(string: s), u.isFileURL { file = u }
        let vid = local ? nil : (override.flatMap { MusicLyricsText.plausibleVideoID($0) ? $0 : nil } ?? inferVideoID(track))
        let album = track.album?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return MusicLyricsRequest(
            videoID: vid, title: track.title,
            artists: track.artists.map(\.name).joined(separator: ", "),
            album: (album ?? "").isEmpty ? nil : album,
            durationSeconds: track.durationMs > 0 ? Double(track.durationMs) / 1000 : nil,
            isLocal: local, localFileURL: file, isrc: MusicISRC.normalize(track.isrc))
    }

    static func inferVideoID(_ track: MusicTrack) -> String? {
        if youTubeProviderIDs.contains(track.providerID), MusicLyricsText.plausibleVideoID(track.id) { return track.id }
        if let s = track.externalURL, let u = URL(string: s), let host = u.host?.lowercased() {
            if host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") {
                let v = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
                if let v, MusicLyricsText.plausibleVideoID(v) { return v }
            } else if host == "youtu.be" {
                let v = u.lastPathComponent
                if MusicLyricsText.plausibleVideoID(v) { return v }
            }
        }
        return nil
    }
}

/// What the identification step found: the recording code and, when BiniLyrics already named it, the lyrics document address.
struct MusicLyricsIdentified: Hashable, Sendable {
    var isrc: String
    var documentURL: String?
}

enum MusicISRC {
    /// Two letters, three letters or digits, seven digits; nil when the text is not one. Hyphens and spaces are ignored.
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard t.count == 12 else { return nil }
        let a = Array(t)
        guard a[0].isLetter, a[1].isLetter, a[0].isASCII, a[1].isASCII,
              a[2...4].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), a[5...].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return t
    }
}

/// A provider's answer to one request, as the walk sees it.
enum MusicLyricsAnswer: Sendable {
    case hit(MusicLyrics)
    case none
    case error(String)
}

// MARK: text helpers

enum MusicLyricsText {
    static func plausibleVideoID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.unicodeScalars.allSatisfy { ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    private static let openers: Set<Character> = ["(", "[", "【", "（"]
    private static let closers: Set<Character> = [")", "]", "】", "）"]

    /// A title fit for free-text search: everything before the first `|`, bracketed asides removed (nesting aware), whitespace collapsed.
    static func searchTitle(_ raw: String) -> String {
        let head = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        var out = ""
        var depth = 0
        for ch in head {
            if openers.contains(ch) { depth += 1; continue }
            if closers.contains(ch) { if depth > 0 { depth -= 1 }; continue }
            if depth == 0 { out.append(ch) }
        }
        return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Decodes the five named XML entities plus numeric references. Unknown names stay as written.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                if let r = decodeEntity(name) { out += r; i = s.index(after: semi); continue }
            }
            out.append(ch); i = s.index(after: i)
        }
        return out
    }

    private static func decodeEntity(_ name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            guard name.hasPrefix("#") else { return nil }
            let body = name.dropFirst()
            let v: UInt32? = body.lowercased().hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
            return v.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }

    /// Collapses whitespace for "is the text unchanged" comparisons.
    static func collapsed(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }

    static func hasLatinOnly(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { sc in
            if sc.value < 0x250 { return true }
            if sc.value >= 0x1E00 && sc.value < 0x1F00 { return true }
            return !CharacterSet.letters.contains(sc)
        }
    }
}

// MARK: normalisation

enum MusicLyricsNormalizer {
    /// Applied once to every provider answer: derives `synced`, demotes "flat" lyrics (every start the same) to plain text,
    /// and drops empty results. Returns nil when nothing is left.
    static func normalize(_ input: MusicLyrics) -> MusicLyrics? {
        var l = input
        if l.instrumental { l.synced = nil; l.plain = nil; return l }
        if let p = l.plain, p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { l.plain = nil }
        if let s = l.synced, s.isEmpty { l.synced = nil }
        if let lines = l.synced, isFlat(lines) {
            if (l.plain ?? "").isEmpty { l.plain = lines.map(\.text).joined(separator: "\n") }
            l.synced = nil
        }
        if l.synced == nil, let p = l.plain, p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { l.plain = nil }
        return l.isEmpty ? nil : l
    }

    /// Synced lyrics whose line starts AND word starts are one single value are plain text dressed as synced.
    static func isFlat(_ lines: [MusicLyricLine]) -> Bool {
        // One timed line cannot be told apart from a real one-line lyric, so it is never demoted.
        guard lines.count >= 2 else { return false }
        var seen = Set<Int64>()
        for l in lines {
            seen.insert(l.timeMs)
            for w in l.words ?? [] { seen.insert(w.startMs) }
            if seen.count > 1 { return false }
        }
        return seen.count == 1
    }

    /// Re-reads an old cache row: entities decoded again (the apostrophe bug), then normalised.
    static func repairLegacy(_ input: MusicLyrics) -> MusicLyrics? {
        var l = input
        l.synced = l.synced?.map { line in
            var x = line; x.text = MusicLyricsText.decodeEntities(line.text); return x
        }
        if let p = l.plain { l.plain = MusicLyricsText.decodeEntities(p) }
        return normalize(l)
    }
}

// MARK: matching tolerances

enum MusicLyricsMatch {
    static let lengthWindow = 5.0

    /// Closest-length rule used by Netease, QQ and Kugou. Unknown wanted length: first hit. Otherwise candidates within the window
    /// plus candidates with no length (ranked last), smallest difference wins.
    /// Every usable candidate, nearest length first (unknown lengths last). A source walks this list until one has lyrics, because the
    /// nearest cut is often an entry with no lyric text.
    static func ordered<T>(_ items: [T], wanted: Double?, window: Double = lengthWindow, length: (T) -> Double?) -> [T] {
        guard let want = wanted, want > 0, want.isFinite else { return items }
        var near: [(T, Double)] = [], unknown: [T] = []
        for it in items {
            guard let len = length(it), len > 0 else { unknown.append(it); continue }
            let d = abs(len - want)
            if d <= window { near.append((it, d)) }
        }
        return near.sorted { $0.1 < $1.1 }.map(\.0) + unknown
    }

    static func closest<T>(_ items: [T], wanted: Double?, window: Double = lengthWindow, length: (T) -> Double?) -> T? {
        guard let want = wanted, want > 0, want.isFinite else { return items.first }
        var best: (T, Double)?
        var unknown: T?
        for it in items {
            guard let len = length(it), len > 0 else { if unknown == nil { unknown = it }; continue }
            let d = abs(len - want)
            if d <= window, best == nil || d < (best?.1 ?? .infinity) { best = (it, d) }
        }
        return best?.0 ?? unknown
    }
}

// MARK: line lookup and duet layout

enum MusicLyricsLookup {
    /// Last line that starts at or before `ms`. Nil before the first line.
    static func lineIndex(in lines: [MusicLyricLine], at ms: Int64) -> Int? {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].timeMs <= ms { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    static let scrollLookaheadMs: Int64 = 500
    static let maxOffsetMs: Int64 = 15_000

    /// The line the view should scroll to: the same lookup half a second early.
    static func scrollTarget(in lines: [MusicLyricLine], at ms: Int64) -> Int? { lineIndex(in: lines, at: ms + scrollLookaheadMs) }

    /// A line before the active one (looking back up to 3 lines) whose latest background word is still sounding stays lit. Nearest only.
    static func lingeringIndex(in lines: [MusicLyricLine], active: Int, at ms: Int64) -> Int? {
        guard active > 0, active < lines.count else { return nil }
        for back in 1...min(3, active) {
            let i = active - back
            let until = lines[i].words?.filter(\.background).map(\.endMs).max()
            if let until, until > ms { return i }
        }
        return nil
    }

    static func clampOffset(_ ms: Int64) -> Int64 { min(maxOffsetMs, max(-maxOffsetMs, ms)) }

    /// The one offset for every song: plus or minus 5 s in 100 ms steps.
    static let maxGlobalOffsetMs: Int64 = 5_000
    static let globalOffsetStepMs: Int64 = 100
    static func clampGlobalOffset(_ ms: Int64) -> Int64 {
        let c = min(maxGlobalOffsetMs, max(-maxGlobalOffsetMs, ms))
        return Int64((Double(c) / Double(globalOffsetStepMs)).rounded()) * globalOffsetStepMs
    }

    /// Where the lyrics are, given where the audio is: playback minus the global shift minus the song's own nudge, never below 0.
    static func lyricPosition(playbackMs: Int64, globalOffsetMs: Int64, songOffsetMs: Int64 = 0) -> Int64 {
        max(0, playbackMs - globalOffsetMs - songOffsetMs)
    }

    /// Tapping a line seeks to its time plus the shifts, never below 0.
    static func seekTarget(lineMs: Int64, globalOffsetMs: Int64, songOffsetMs: Int64 = 0) -> Int64 {
        max(0, lineMs + globalOffsetMs + songOffsetMs)
    }

    /// "+1.5 s" style text for the offset sheet.
    static func offsetLabel(_ ms: Int64) -> String {
        let v = Double(ms) / 1000
        return (v >= 0 ? "+" : "-") + String(format: "%.1f s", abs(v))
    }
}

struct MusicLyricLineLayout: Hashable, Sendable {
    var far: Bool
    var lead: [MusicLyricWord]
    var background: [MusicLyricWord]
    /// The line stays lit until this time (end of its last background word, else its own end).
    var untilMs: Int64?
}

enum MusicLyricsVoices {
    /// `v` plus one to four digits is a singer; `v1000` and anything else is not.
    static func singer(_ id: String?) -> Int? {
        guard let id, id.count >= 2, id.count <= 5, id.first == "v" else { return nil }
        let digits = id.dropFirst()
        guard digits.allSatisfy({ $0 >= "0" && $0 <= "9" }), let n = Int(digits), n != 1000 else { return nil }
        return n
    }

    /// Alternation rule for sources that give a singer id per line but no numbering: the side changes every time the voice changes
    /// (the first voice starts near, unless it is of type "other"); a group line is near and does not disturb whose turn it is; a line
    /// with no singer is near. When at least 85% of the placed lines came out far, the whole song is flipped.
    /// Nil when fewer than two distinct voices occur (no duet).
    static func alternationSides(_ voices: [String?], types: [String: String] = [:]) -> [Bool]? {
        let named = Set(voices.compactMap { $0 }.filter { !$0.isEmpty && $0 != "v1000" })
        guard named.count >= 2 else { return nil }
        func type(_ id: String) -> String {
            if id == "v1000" { return "group" }
            if id == "v2000" { return "other" }
            return types[id] ?? "person"
        }
        var far = Array(repeating: false, count: voices.count)
        var placed = 0, placedFar = 0
        var lastVoice: String?
        var onFar = false
        for (i, v) in voices.enumerated() {
            guard let v, !v.isEmpty else { continue }
            if type(v) == "group" { continue }
            if let last = lastVoice {
                if v != last { onFar.toggle() }
            } else { onFar = type(v) == "other" }
            lastVoice = v
            far[i] = onFar
            placed += 1
            if onFar { placedFar += 1 }
        }
        if placed > 0, Double(placedFar) / Double(placed) >= 0.85 { far = far.enumerated().map { (i, f) in voices[i] != nil && !(voices[i] ?? "").isEmpty && type(voices[i] ?? "") != "group" ? !f : f } }
        return far
    }

    static func isValidAgent(_ id: String) -> Bool {
        id.count >= 2 && id.count <= 5 && id.first == "v" && id.dropFirst().allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    /// Per line layout, or nil when there is no second singer and no background word (draw as before).
    /// Sides are by singer NUMBER: sorted ascending, even index near, odd index far; unnamed lines stay near.
    static func layout(_ lines: [MusicLyricLine], types: [String: String] = [:]) -> [MusicLyricLineLayout]? {
        let numbers = Set(lines.compactMap { singer($0.voice) }).sorted()
        // Sources that name singers some other way (Apple's agent ids) get the alternation rule below.
        let alternation: [Bool]? = numbers.count >= 2 ? nil : alternationSides(lines.map(\.voice), types: types)
        let duet = numbers.count >= 2 || alternation != nil
        let anyBackground = lines.contains { $0.words?.contains(where: \.background) ?? false }
        guard duet || anyBackground else { return nil }
        return lines.enumerated().map { (i, line) in
            var far = false
            if let alternation { far = alternation[i] } else if duet, let n = singer(line.voice), let idx = numbers.firstIndex(of: n) { far = idx % 2 == 1 }
            let words = line.words ?? []
            let lead = words.filter { !$0.background }
            let bg = words.filter(\.background)
            let until = bg.map(\.endMs).max().map { max($0, line.endMs ?? $0) } ?? line.endMs
            return MusicLyricLineLayout(far: far, lead: lead, background: bg, untilMs: until)
        }
    }
}

// MARK: sources

enum MusicLyricsSources {
    static let community = "community-lyrics", boidu = "boidu", unison = "unison", lyricsPlus = "lyricsplus", lrclib = "lrclib"
    static let youtube = "youtube", netease = "netease", qq = "qq", kugou = "kugou"
    static let lrcRed = "lrcred", bini = "bini", portato = "portato", paxSenix = "paxsenix", simpMusic = "simpmusic"
    static let megalobiz = "megalobiz", musixmatch = "musixmatch", genius = "genius", ytCaptions = "ytcaptions"
    static let jioSaavn = "jiosaavn-lyrics"
    /// Reads lyrics files next to local audio and sidecar tags. Not part of the person's ordering; always first.
    static let localOwn = "local-lyrics"

    /// Apple-timed sources lead because that catalogue has the singers; Genius is plain text and only asked when everything above missed.
    static let defaultOrder = [community, lrcRed, bini, boidu, portato, paxSenix, unison, lyricsPlus, simpMusic, lrclib, jioSaavn, youtube, ytCaptions,
                               netease, qq, kugou, megalobiz, musixmatch, genius]
    static let wordKind: Set<String> = [community, boidu, unison, lyricsPlus, lrcRed, bini, portato, paxSenix, simpMusic]
    static let idMatchedProviders: Set<String> = [youtube, unison, community, simpMusic, ytCaptions]
    /// Asked only when every source above them missed.
    static let lazyProviders: Set<String> = [genius]
    /// Unofficial access to a third party's web client; the settings page flags these for App Review.
    static let unofficial: Set<String> = [jioSaavn, paxSenix, musixmatch, genius, megalobiz, lrcRed, bini, portato, simpMusic, netease, qq, kugou]

    static let names: [String: String] = [
        community: "Community lyrics", boidu: "Boidu", unison: "Unison", lyricsPlus: "LyricsPlus", lrclib: "LRCLIB",
        youtube: "YouTube Music", netease: "Netease Cloud Music", qq: "QQ Music", kugou: "Kugou", localOwn: "Local lyrics",
        lrcRed: "lrc.red", bini: "BiniLyrics", portato: "BetterLyrics Portato", paxSenix: "PaxSenix", simpMusic: "SimpMusic",
        megalobiz: "Megalobiz", musixmatch: "Musixmatch", genius: "Genius", ytCaptions: "YouTube captions", jioSaavn: "JioSaavn lyrics", "ytmusic": "YouTube Music (this song)"]

    static let about: [String: String] = [
        community: "own lyrics, always word by word, timed to the exact video",
        boidu: "Better Lyrics database, word by word, for songs someone has looked up before",
        unison: "community lyrics, mostly word by word, timed to the exact video",
        lyricsPlus: "Apple Music lyrics, word by word, with Apple's own romanization",
        lrclib: "open library of synced lyrics, widest coverage",
        youtube: "own lyrics, where licensed",
        netease: "large Chinese catalogue, adds Chinese translations",
        qq: "Mandopop/Cantopop",
        kugou: "rarer tracks",
        lrcRed: "Apple timings by recording, syllable by syllable",
        bini: "The same Apple timings, matched on the recording itself",
        portato: "QQ Music karaoke timings through BetterLyrics",
        paxSenix: "Apple Music timings through a public proxy, no key needed",
        simpMusic: "community lyrics timed to the exact video",
        megalobiz: "whole lines from a lyrics website",
        musixmatch: "whole lines, or word by word where it has them, from a very large lyrics database",
        genius: "plain text fallback, massive web catalogue",
        ytCaptions: "timed captions matched to the exact playing video",
        jioSaavn: "plain lyrics for Hindi, Telugu, Tamil, Kannada, Malayalam and Punjabi songs, from JioSaavn's public web address"]

    static func name(_ id: String) -> String { names[id] ?? id }

    struct Entry: Hashable, Sendable { var id: String; var enabled: Bool }

    static var defaultEnabled: [String: Bool] { Dictionary(uniqueKeysWithValues: defaultOrder.map { ($0, true) }) }

    /// The saved order and switches turned into the full list. Unknown and repeated ids are dropped; ids not named follow in default
    /// order and are ON, except when the person named some ids and ALL of them are off (then new ids come in OFF). Community, when not
    /// named, goes first. `extra` are other registered lyrics providers (plugins), appended after the built-ins.
    static func resolve(order: [String], enabled: [String: Bool], extra: [String] = []) -> [Entry] {
        let known = Set(defaultOrder).union(extra)
        var seen = Set<String>()
        let named = order.filter { known.contains($0) && seen.insert($0).inserted }
        let allNamedOff = !named.isEmpty && named.allSatisfy { enabled[$0] == false }
        var list = named.map { Entry(id: $0, enabled: enabled[$0] ?? true) }
        let newOn = !allNamedOff
        if !seen.contains(community) { list.insert(Entry(id: community, enabled: newOn), at: 0); seen.insert(community) }
        for id in defaultOrder + extra where seen.insert(id).inserted { list.append(Entry(id: id, enabled: newOn)) }
        return list
    }
}
