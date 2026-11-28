import Foundation

/// The rules that decide whether a picture offered by a source belongs to the thing we asked about. Pure and total. Every source goes through
/// these, so "never show a different person's photo" is one place to test.
enum MusicArtworkMatch {
    /// People and groups need more proof than works: a face is never guessed from a name alone.
    static let personThreshold = 0.75
    static let workThreshold = 0.70

    static func minimumConfidence(for kind: MusicEntityKind) -> Double { kind.isAgent ? personThreshold : workThreshold }

    // MARK: names

    /// The folded Latin skeleton of a name (same across scripts and spellings).
    static func key(_ text: String) -> String { MusicGraphText.latin(text) }

    /// The skeleton with no spaces, so "G. V. Prakash" and "GV Prakash" meet. "Mst.G.V.Prakash Kumar" does not meet "G.V. Prakash Kumar".
    static func compact(_ text: String) -> String { key(text).replacingOccurrences(of: " ", with: "") }

    static func namesMatch(_ a: String, _ b: String) -> Bool {
        let x = compact(a), y = compact(b)
        return !x.isEmpty && x == y
    }

    /// Up to two letters for the circle that stands in for a missing portrait (any script).
    static func initials(_ name: String) -> String {
        name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    private static let titleNoise: [String] = [
        "original motion picture soundtrack", "motion picture soundtrack", "original soundtrack", "original score", "original background score",
        "original film soundtrack", "soundtrack", "ost", "deluxe edition", "deluxe", "remastered", "single", "ep",
    ]

    /// A title with the parts that differ between stores removed: brackets and what is in them ("(From "Master")"), "- Single", "Original Motion
    /// Picture Soundtrack"... "Master (Original Motion Picture Soundtrack)" and "Master" meet.
    /// One pattern for every noise phrase, longest first, built once (it used to be thirteen patterns built again on every call).
    private static let noisePattern: NSRegularExpression? = {
        let phrases = titleNoise.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return try? NSRegularExpression(pattern: "\\b(?:" + phrases + ")\\b")
    }()
    private static let workKeys = MusicBoundedMemo<String, String>(capacity: 8_192)

    static func workKey(_ title: String) -> String {
        workKeys.value(for: title) { computeWorkKey(title) }
    }

    private static func computeWorkKey(_ title: String) -> String {
        var t = title.lowercased()
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
            while let a = t.firstIndex(of: Character(open)), let b = t[a...].firstIndex(of: Character(close)) { t.removeSubrange(a...b) }
        }
        t = t.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        if let rx = noisePattern { t = rx.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ") }
        return key(t)
    }

    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let x = workKey(a), y = workKey(b)
        return !x.isEmpty && x == y
    }

    /// The individual artist names in a credit line ("Anirudh Ravichander & Gana Balachandar", "A, B feat. C"), compacted.
    static func creatorNames(_ credit: String) -> [String] {
        var s = credit
        for sep in [" feat. ", " feat ", " ft. ", " ft ", " featuring ", " & ", " and ", " x ", " / ", ";", ",", " with "] { s = s.replacingOccurrences(of: sep, with: "|", options: .caseInsensitive) }
        return s.split(separator: "|").map { compact(String($0)) }.filter { !$0.isEmpty }
    }

    /// True when two credit lines share at least one artist.
    static func creatorsOverlap(_ a: String, _ b: String) -> Bool {
        let x = Set(creatorNames(a)), y = Set(creatorNames(b))
        return !x.isDisjoint(with: y)
    }

    /// True when a free-text line ("Master · Anirudh Ravichander, Gana Balachandar") names at least one artist of the credit.
    static func lineMentions(_ line: String, creator: String) -> Bool {
        let l = compact(line)
        return creatorNames(creator).contains { !$0.isEmpty && l.contains($0) }
    }

    // MARK: roles and years

    /// Does a one-line description ("Indian actor and music director") fit one of the person's jobs? With no known job, any creative job fits.
    static func roleFits(description: String, roles: [MusicArtworkRole]) -> Bool {
        let d = description.lowercased()
        let words = roles.isEmpty ? MusicArtworkRole.anyWords : roles.flatMap(\.words)
        return words.contains { d.contains($0) }
    }

    /// True when the text states this year as a whole number ("2020 Tamil film"), not as part of a longer number.
    static func mentionsYear(_ text: String, _ year: Int) -> Bool {
        text.range(of: "(?<![0-9])" + String(year) + "(?![0-9])", options: .regularExpression) != nil
    }

    // MARK: addresses

    /// iTunes: the same file at a larger size (600 px). The size swap is not documented by Apple, so callers keep the 100 px address as a second candidate.
    static func iTunesLarge(_ url: String) -> String {
        url.replacingOccurrences(of: "/100x100bb", with: "/600x600bb").replacingOccurrences(of: "/60x60bb", with: "/600x600bb")
    }

    /// JioSaavn: the size is part of the file name (`-50x50.jpg` on albums, `_50x50.jpg` on artists; 150 and 500 likewise).
    static func saavnLarge(_ url: String) -> String {
        var u = url
        for small in ["-50x50.", "-150x150.", "_50x50.", "_150x150."] { u = u.replacingOccurrences(of: small, with: String(small.first!) + "500x500.") }
        return u.hasPrefix("http://") ? "https://" + u.dropFirst(7) : u
    }

    /// TMDB image address: `h632` for a profile (official profile size), `w500` for a poster.
    static func tmdbProfile(_ path: String) -> String { "https://image.tmdb.org/t/p/h632" + path }
    static func tmdbPoster(_ path: String) -> String { "https://image.tmdb.org/t/p/w500" + path }

    /// Cover Art Archive: a release group's front cover at 500 px, then the unsized front (thumbnails can lag behind).
    static func coverArtArchive(releaseGroup mbid: String) -> [String] {
        ["https://coverartarchive.org/release-group/\(mbid)/front-500", "https://coverartarchive.org/release-group/\(mbid)/front"]
    }
    static func coverArtArchive(release mbid: String) -> [String] {
        ["https://coverartarchive.org/release/\(mbid)/front-500", "https://coverartarchive.org/release/\(mbid)/front"]
    }

    /// A Commons file at a standard width (500). Wikimedia refuses other widths on direct addresses (see the research notes).
    static func commonsFilePath(_ file: String) -> String? {
        var c = URLComponents(string: "https://commons.wikimedia.org/wiki/Special:FilePath/")
        c?.path = "/wiki/Special:FilePath/" + file.replacingOccurrences(of: " ", with: "_")
        c?.queryItems = [URLQueryItem(name: "width", value: "500")]
        return c?.url?.absoluteString
    }

    /// A graph `imageRef` as a picture address: `commons:File.jpg` (Wikidata P18) or an https address; anything else is refused.
    static func address(fromImageRef ref: String?) -> String? {
        guard let r = ref?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
        if r.hasPrefix("commons:") { return commonsFilePath(String(r.dropFirst("commons:".count))) }
        return r.hasPrefix("https://") ? r : nil
    }

    /// Deezer answers a generic grey picture for an artist with none; its address has an empty hash segment.
    static func isDeezerPlaceholder(_ url: String) -> Bool { url.contains("/artist//") || url.contains("/cover//") || url.contains("/images//") }
}
