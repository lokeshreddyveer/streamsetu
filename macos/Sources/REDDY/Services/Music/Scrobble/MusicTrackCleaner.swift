import Foundation

// The "cleaned-up track": one pure function that turns what the player knows about a song into exactly what every scrobbling service receives.
// No I/O, no settings lookups: the caller passes the config, so the settings preview and the real send use the very same code.

/// What the cleaner reads about a track.
struct ScrobbleTrackInfo: Hashable, Sendable {
    var uid: String
    var title: String
    /// One name per credited artist, in order.
    var artists: [String]
    var album: String
    /// True for music-video uploads (as opposed to the audio song); only these get their title split.
    var isVideo: Bool = false
    var durationMs: Int64 = 0
    var isLocal: Bool = false

    var artistLine: String { artists.joined(separator: ", ") }

    init(uid: String, title: String, artists: [String], album: String = "", isVideo: Bool = false, durationMs: Int64 = 0, isLocal: Bool = false) {
        self.uid = uid; self.title = title; self.artists = artists; self.album = album
        self.isVideo = isVideo; self.durationMs = durationMs; self.isLocal = isLocal
    }

    /// Sources that serve video uploads rather than album tracks.
    static let videoProviders: Set<String> = ["piped", "invidious"]

    init(_ t: MusicTrack) {
        self.init(uid: t.uid, title: t.title, artists: t.artists.map(\.name), album: t.album?.title ?? "",
                  isVideo: Self.videoProviders.contains(t.providerID), durationMs: t.durationMs, isLocal: t.providerID == "local")
    }
}

enum ScrobbleField: String, Codable, CaseIterable, Sendable { case title, artist, album }

/// A user rule: a regular expression applied to one field.
struct ScrobbleRule: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var enabled = true
    var field: ScrobbleField = .title
    var find = ""
    var replace = ""
}

/// A fix for one track (keyed by its uid) or for every track whose original metadata matches (keyless).
struct ScrobbleEdit: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var key = ""
    var fromArtist = ""
    var fromTitle = ""
    var fromAlbum = ""
    var artist = ""
    var title = ""
    var album = ""
    var skip = false
}

enum ScrobbleSkip: String, Sendable, Equatable { case edit, incomplete }

struct ScrobbleRuleError: Error, Sendable, Equatable { var index: Int; var message: String }

struct CleanedTrack: Sendable, Equatable {
    var artist: String
    var title: String
    var album: String
    var skip: ScrobbleSkip?
    var editIndex: Int?
    var splitFired = false
    var rulesApplied: [Int] = []
    var ruleErrors: [ScrobbleRuleError] = []
}

/// The cleaning settings only (the rest of the scrobble config is about timing and services).
struct ScrobbleCleanSettings: Codable, Equatable, Sendable {
    var splitVideoTitles = false
    var primaryArtist = false
    var primaryStrict = false
    var rules: [ScrobbleRule] = []
    var edits: [ScrobbleEdit] = []
}

enum MusicTrackCleaner {
    static let unknownArtist = "Unknown artist"
    /// Guards against runaway matching: the engine backtracks, so overlong patterns and inputs are skipped.
    static let maxPatternLength = 500
    static let maxFieldLength = 2000

    /// Every step in the order the spec fixes: edits, title split, primary artist, rules, finish.
    static func clean(_ info: ScrobbleTrackInfo, _ s: ScrobbleCleanSettings) -> CleanedTrack {
        var artist = info.artistLine
        var title = info.title
        var album = info.album
        var out = CleanedTrack(artist: artist, title: title, album: album, skip: nil)

        // 1. Edits: first match wins and the result is final.
        if let (i, e) = s.edits.enumerated().first(where: { matches($0.element, info) }) {
            out.editIndex = i
            if e.skip { out.skip = .edit; out.artist = artist; out.title = title; out.album = album; return out }
            if !blank(e.artist) { artist = trim(e.artist) }
            if !blank(e.title) { title = trim(e.title) }
            if !blank(e.album) { album = trim(e.album) }
            return finish(&out, artist, title, album)
        }

        // 2. Title split, videos only.
        var artistIsString = false
        if s.splitVideoTitles, info.isVideo, let (a, t) = splitTitle(title) {
            artist = a; title = t; out.splitFired = true; artistIsString = true
        }

        // 3. Primary artist.
        if s.primaryArtist {
            if artistIsString || info.artists.isEmpty {
                artist = cutPrimary(artist, strict: s.primaryStrict)
            } else if info.artists.count > 1 {
                artist = info.artists[0]
            } else if info.artists.count == 1, s.primaryStrict {
                artist = cutPrimary(artist, strict: true)
            }
        }

        // 4. Rules.
        for (i, r) in s.rules.enumerated() where r.enabled && !r.find.isEmpty {
            let current: String
            switch r.field { case .title: current = title; case .artist: current = artist; case .album: current = album }
            switch applyRule(r, to: current) {
            case .failed(let m): out.ruleErrors.append(ScrobbleRuleError(index: i, message: m))
            case .unchanged: break
            case .plain(let v):
                set(r.field, v, &title, &artist, &album); out.rulesApplied.append(i)
            case .extracted(let a, let t, let al):
                var changed = false
                if let a, a != artist { artist = a; changed = true }
                if let t, t != title { title = t; changed = true }
                if let al, al != album { album = al; changed = true }
                if changed { out.rulesApplied.append(i) }
            }
        }
        return finish(&out, artist, title, album)
    }

    // MARK: steps

    private static func finish(_ out: inout CleanedTrack, _ artist: String, _ title: String, _ album: String) -> CleanedTrack {
        out.artist = trim(artist); out.title = trim(title); out.album = trim(album)
        if out.title.isEmpty || out.artist.isEmpty || out.artist.caseInsensitiveCompare(unknownArtist) == .orderedSame {
            out.skip = .incomplete
        }
        return out
    }

    private static func set(_ f: ScrobbleField, _ v: String, _ title: inout String, _ artist: inout String, _ album: inout String) {
        switch f { case .title: title = v; case .artist: artist = v; case .album: album = v }
    }

    static func matches(_ e: ScrobbleEdit, _ info: ScrobbleTrackInfo) -> Bool {
        if !e.key.isEmpty { return e.key == info.uid }
        guard !blank(e.fromArtist) || !blank(e.fromTitle) || !blank(e.fromAlbum) else { return false }
        func same(_ from: String, _ value: String) -> Bool {
            blank(from) || trim(from).caseInsensitiveCompare(trim(value)) == .orderedSame
        }
        return same(e.fromArtist, info.artistLine) && same(e.fromTitle, info.title) && same(e.fromAlbum, info.album)
    }

    /// Splits "Artist - Title" at the earliest spaced hyphen, en dash or em dash; both halves must be non-empty.
    static func splitTitle(_ s: String) -> (artist: String, title: String)? {
        var best: Range<String.Index>?
        for sep in [" - ", " \u{2013} ", " \u{2014} "] {
            if let r = s.range(of: sep), best == nil || r.lowerBound < best!.lowerBound { best = r }
        }
        guard let r = best else { return nil }
        let a = trim(String(s[..<r.lowerBound])), t = trim(String(s[r.upperBound...]))
        return a.isEmpty || t.isEmpty ? nil : (a, t)
    }

    /// Keeps the first credit of a joined byline: "," always, "&" only in strict mode. A leading separator keeps the whole text.
    static func cutPrimary(_ s: String, strict: Bool) -> String {
        let seps: [Character] = strict ? [",", "&"] : [","]
        guard let i = s.firstIndex(where: { seps.contains($0) }) else { return s }
        let left = trim(String(s[..<i]))
        return left.isEmpty ? s : left
    }

    // MARK: rules

    enum RuleOutcome: Equatable { case unchanged, failed(String), plain(String), extracted(artist: String?, title: String?, album: String?) }

    private static let namedGroup = try? NSRegularExpression(pattern: #"\(\?(?:P)?<([A-Za-z][A-Za-z0-9_]*)>"#)

    static func compile(_ pattern: String) -> Result<(NSRegularExpression, [String]), ScrobbleRuleError> {
        guard pattern.count <= maxPatternLength else { return .failure(ScrobbleRuleError(index: 0, message: "The pattern is too long.")) }
        let ns = pattern as NSString
        let normalised = pattern.replacingOccurrences(of: "(?P<", with: "(?<")
        var names: [String] = []
        for m in namedGroup?.matches(in: pattern, range: NSRange(location: 0, length: ns.length)) ?? [] where m.numberOfRanges > 1 {
            names.append(ns.substring(with: m.range(at: 1)))
        }
        do { return .success((try NSRegularExpression(pattern: normalised, options: [.caseInsensitive]), names)) }
        catch { return .failure(ScrobbleRuleError(index: 0, message: "This pattern is not a valid regular expression.")) }
    }

    static func applyRule(_ r: ScrobbleRule, to input: String) -> RuleOutcome {
        guard input.count <= maxFieldLength else { return .unchanged }
        switch compile(r.find) {
        case .failure(let e): return .failed(e.message)
        case .success(let (re, names)):
            let ns = input as NSString
            let whole = NSRange(location: 0, length: ns.length)
            let extractNames = Set(names).intersection(["artist", "title", "album"])
            if !extractNames.isEmpty {
                guard let m = re.firstMatch(in: input, range: whole) else { return .unchanged }
                func grab(_ n: String) -> String? {
                    guard extractNames.contains(n) else { return nil }
                    let range = m.range(withName: n)
                    guard range.location != NSNotFound else { return nil }
                    let v = trim(ns.substring(with: range))
                    return v.isEmpty ? nil : v
                }
                return .extracted(artist: grab("artist"), title: grab("title"), album: grab("album"))
            }
            var out = ""
            var last = 0
            for m in re.matches(in: input, range: whole) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += expand(r.replace, match: m, in: ns, names: names)
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            return out == input ? .unchanged : .plain(out)
        }
    }

    /// Replacement text: `$1`, `${1}`, `$name`, `${name}` and `$$` for a literal dollar sign.
    static func expand(_ template: String, match m: NSTextCheckingResult, in ns: NSString, names: [String]) -> String {
        let t = Array(template)
        var out = ""
        var i = 0
        func group(_ ref: String) -> String {
            if let n = Int(ref) {
                guard n < m.numberOfRanges, m.range(at: n).location != NSNotFound else { return "" }
                return ns.substring(with: m.range(at: n))
            }
            guard names.contains(ref) else { return "" }
            let r = m.range(withName: ref)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        while i < t.count {
            let c = t[i]
            guard c == "$", i + 1 < t.count else { out.append(c); i += 1; continue }
            let n = t[i + 1]
            if n == "$" { out.append("$"); i += 2 }
            else if n == "{", let close = t[(i + 2)...].firstIndex(of: "}") {
                out += group(String(t[(i + 2)..<close])); i = close + 1
            } else if n.isLetter || n.isNumber || n == "_" {
                var j = i + 1
                while j < t.count, t[j].isLetter || t[j].isNumber || t[j] == "_" { j += 1 }
                out += group(String(t[(i + 1)..<j])); i = j
            } else { out.append(c); i += 1 }
        }
        return out
    }

    // MARK: presets

    struct Preset: Sendable, Identifiable {
        var id: String { name }
        var name: String; var field: ScrobbleField; var find: String; var replace: String
        var rule: ScrobbleRule { ScrobbleRule(enabled: true, field: field, find: find, replace: replace) }
    }

    static let presets: [Preset] = [
        Preset(name: "Remove (Official Video), (Lyrics) and the like", field: .title,
               find: #"\s*[(\[]\s*(?:official\s+)?(?:(?:music|lyrics?)\s+)?(?:video|audio|lyrics?|visuali[sz]er|hd|hq|4k)\s*[)\]]"#, replace: ""),
        Preset(name: "Remove \"Remastered\" from titles", field: .title,
               find: #"^(.+) [(\[/-][^()\[\]]*re-?master(?:ed)?[^()\[\]]*(?:[)\]/-]|$)"#, replace: "$1"),
        Preset(name: "Remove \"(Explicit)\" and \"(Clean)\"", field: .title,
               find: #"^(.*) (?:- |[(\[/])(?:explicit|clean)(?: [^()\[\]]*version| edit(?:ed)?)?[)\]]?$"#, replace: "$1"),
        Preset(name: "Remove \" - Topic\" from artists", field: .artist, find: #"\s+-\s+topic$"#, replace: ""),
        Preset(name: "Remove \"VEVO\" from artists", field: .artist, find: #"vevo$"#, replace: ""),
    ]

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func blank(_ s: String) -> Bool { trim(s).isEmpty }
}
