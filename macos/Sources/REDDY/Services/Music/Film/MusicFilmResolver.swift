import Foundation

// ARCHITECTURE NOTE (seams for a wider music/cinema graph)
// - Values: MusicFilmIdentity (what the music side says), MusicFilmInfo / MusicFilmPerson / MusicFilmCredit (what a source says; external ids tmdbID,
//   wikidataID (QID), imdbID; provenance = source + retrievedAt + confidence). All are Codable value types with no view or hub dependency.
// - Sources: `MusicFilmSource` (MusicFilmService.swift) is the one protocol a film source implements; TMDB, Wikidata and the provider's names
//   are three small structs. The TMDB transport is `MusicFilmTMDBGate` (the app's client, installed once); Wikidata goes through MusicHTTP.
//   A metadata layer can host these structs and add MusicBrainz or Discogs by adding sources.
// - Cache: `MusicFilmCache` stores the plain info values by key (30 days found, 2 days missed); the format is the model's own Codable, not the UI's.
// - Views (MusicFilmInfoView) only read MusicFilmInfo and call MusicFilmResolver/MusicFilmService; this file never imports them.

// Film identification: from an album or a song, decide whether it is a film's soundtrack and which film. Music catalogues credit only music people,
// so the film is found from the evidence the catalogue DOES give: the title wording, the album type, the catalogue's own film field and, for
// JioSaavn, the "starring" credits its album reply carries. Weak evidence never counts: an ordinary album or single is never a film.

/// The film a soundtrack belongs to.
struct MusicFilmIdentity: Codable, Hashable, Sendable {
    /// How the film was recognised, strongest evidence last used; every case is strong enough on its own.
    enum Evidence: String, Codable, Sendable { case provider, titlePattern, soundtrackType, catalogue }
    var title: String
    var year: Int?
    /// ISO 639-1 ("te", "hi", "ta", "kn", "ml", "en"), when known.
    var language: String?
    var evidence: Evidence
    /// Names the music source itself gave for the film (JioSaavn): the last-resort cast, and a check on a TMDB match.
    var starring: [String] = []
    var musicBy: [String] = []
    var singers: [String] = []

    /// One key per film for caching, whatever the spelling.
    var cacheKey: String { "film." + MusicTransliterationKey.key(title).replacingOccurrences(of: " ", with: "-") + "." + (year.map(String.init) ?? "x") + "." + (language ?? "x") }
}

/// What a music source said about an album that is not in `MusicAlbum` itself (JioSaavn's per-song roles).
struct MusicFilmProviderFacts: Codable, Hashable, Sendable {
    var title: String?
    var year: Int?
    var language: String?
    var label: String?
    var starring: [String] = []
    var musicBy: [String] = []
    var singers: [String] = []
    var isEmpty: Bool { starring.isEmpty && musicBy.isEmpty && singers.isEmpty }
}

/// Everything the resolver may look at. Built by `MusicFilmResolver.signals`, or by hand in tests.
struct MusicFilmSignals: Sendable {
    var albumTitle: String?
    var albumType: String?
    var albumYear: Int?
    var albumArtists: [String] = []
    var genres: [String] = []
    var trackTitle: String?
    /// Titles of the album's songs (most albums name the film in each: `(From "Film")`).
    var songTitles: [String] = []
    var trackArtists: [String] = []
    /// The catalogue's film name for each song of the album (nil where it has none).
    var catalogueFilms: [String?] = []
    var catalogueYear: Int?
    var catalogueLanguage: String?
    var facts: MusicFilmProviderFacts?
}

enum MusicFilmResolver {
    // MARK: entry points

    /// From a screen's values: asks the catalogue for the film of each song. Main-actor free; it only reads the catalogue's store.
    static func signals(album: MusicAlbum?, track: MusicTrack?, albumTracks: [MusicTrack] = [], genres: [String] = [], facts: MusicFilmProviderFacts? = nil) -> MusicFilmSignals {
        var s = MusicFilmSignals()
        s.albumTitle = album?.title ?? track?.album?.title
        s.albumType = album?.albumType ?? track?.album?.albumType
        s.albumYear = year(of: album?.releaseDate ?? track?.album?.releaseDate)
        s.albumArtists = (album?.artists ?? track?.album?.artists ?? []).map(\.name)
        s.genres = genres
        s.trackTitle = track?.title
        s.songTitles = albumTracks.prefix(12).map(\.title)
        s.trackArtists = track?.artists.map(\.name) ?? []
        let rt = MusicCatalogRuntime.shared
        if rt.isEnabled {
            let sample = ([track].compactMap { $0 } + albumTracks).prefix(12)
            s.catalogueFilms = sample.map { MusicCatalogNames.film(for: $0) }
            if let t = track ?? albumTracks.first, let c = rt.store.canonical(for: t) { s.catalogueYear = c.year; s.catalogueLanguage = c.language }
        }
        s.facts = facts
        return s
    }

    static func identify(album: MusicAlbum?, track: MusicTrack?, albumTracks: [MusicTrack] = [], genres: [String] = [], facts: MusicFilmProviderFacts? = nil) -> MusicFilmIdentity? {
        identify(signals(album: album, track: track, albumTracks: albumTracks, genres: genres, facts: facts))
    }

    /// The film, or nil when the evidence is not strong. The order is the strength of the evidence.
    static func identify(_ s: MusicFilmSignals) -> MusicFilmIdentity? {
        let language = s.catalogueLanguage.flatMap(languageCode) ?? s.facts?.language.flatMap(languageCode)
        func make(_ title: String, _ year: Int?, _ evidence: MusicFilmIdentity.Evidence) -> MusicFilmIdentity? {
            let parts = clean(title)
            guard isPlausibleFilmTitle(parts.title, artists: s.albumArtists + s.trackArtists) else { return nil }
            var id = MusicFilmIdentity(title: parts.title, year: year ?? parts.year ?? s.facts?.year ?? s.albumYear ?? s.catalogueYear, language: language ?? parts.language, evidence: evidence)
            if let f = s.facts { id.starring = f.starring; id.musicBy = f.musicBy; id.singers = f.singers }
            return id
        }

        // 1. The music source itself credits actors for the album: it is a film.
        if let f = s.facts, !f.starring.isEmpty, let t = f.title ?? s.albumTitle, let id = make(t, f.year, .provider) { return id }
        // 2. "(Original Motion Picture Soundtrack)", "- OST", "(Music from the Motion Picture)" on the album.
        if let t = s.albumTitle, let film = soundtrackFilm(inAlbumTitle: t), let id = make(film, nil, .titlePattern) { return id }
        // 3. The album type or genre says soundtrack.
        let kinds = ([s.albumType].compactMap { $0 } + s.genres).map { $0.lowercased() }
        if let t = s.albumTitle, kinds.contains(where: { $0.contains("soundtrack") || $0 == "ost" || $0.contains("original score") || $0.contains("motion picture") }),
           let id = make(t, nil, .soundtrackType) { return id }
        // 4. The catalogue's own film field: most songs of the album agree, and the film is the album's name (a film's album), or a single song names its film.
        let known = s.catalogueFilms.compactMap { $0 }.filter { !$0.isEmpty }
        if let album = s.albumTitle {
            let counts = Dictionary(grouping: known, by: { MusicTransliterationKey.key($0) }).mapValues(\.count)
            if let top = counts.max(by: { $0.value < $1.value }), top.value >= 2 || (s.catalogueFilms.count == 1 && top.value == 1),
               top.value * 2 >= max(1, min(s.catalogueFilms.count, 12)),
               let name = known.first(where: { MusicTransliterationKey.key($0) == top.key }),
               MusicTransliterationKey.similarity(clean(album).title, name) >= 0.85, let id = make(name, s.catalogueYear, .catalogue) { return id }
        }
        // 4b. Two or more songs of the album name the same film in their titles.
        let named = s.songTitles.compactMap { fromFilm(inSongTitle: $0) }
        if named.count >= 2, let first = named.first, named.filter({ MusicTransliterationKey.sameKey($0, first) }).count >= 2, let id = make(first, nil, .titlePattern) { return id }
        // 5. A single song: "(From "Film")" in its title, or the catalogue's film for it.
        if let t = s.trackTitle, let film = fromFilm(inSongTitle: t), let id = make(film, nil, .titlePattern) { return id }
        if s.albumTitle == nil, let film = known.first, let id = make(film, s.catalogueYear, .catalogue) { return id }
        return nil
    }

    // MARK: title patterns

    /// "Pushpa - The Rise (Original Motion Picture Soundtrack)" -> "Pushpa - The Rise". Nil when the album title carries no soundtrack wording.
    static func soundtrackFilm(inAlbumTitle raw: String) -> String? {
        let t = normalizeQuotes(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        var out = t
        for p in albumMarkers {
            if let r = out.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                out = out.replacingCharacters(in: r, with: " ")
                let cleaned = out.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:~,"))
                return cleaned.isEmpty ? nil : cleaned
            }
        }
        // "Music from the Motion Picture Top Gun" / "Music From \"Film\"".
        if let r = t.range(of: #"^(?:original\s+)?music\s+from\s+(?:the\s+)?(?:(?:motion\s+picture|movie|film)\s+)?"#, options: [.regularExpression, .caseInsensitive]) {
            let rest = String(t[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'-–:"))
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    /// Bracketed or dashed soundtrack wording at the end of an album title.
    private static let albumMarkers: [String] = [
        #"\s*[\(\[]\s*(?:the\s+)?(?:original|official|music\s+from|motion\s+picture|film|movie)[^\)\]]*?(?:soundtrack|score|\bost\b|motion\s+picture|film|movie)[^\)\]]*[\)\]]"#,
        #"\s*[\(\[]\s*(?:ost|soundtrack|original\s+score)\s*[\)\]]"#,
        #"\s+[-–—:]\s*(?:the\s+)?(?:original\s+)?(?:(?:[a-z]+\s+)?(?:motion\s+picture|movie|film)\s+)?(?:soundtrack|score|ost)\s*$"#,
        #"\s+[-–—:]\s*(?:music\s+from\s+)?(?:the\s+)?(?:motion\s+picture|movie|film)\s*$"#
    ]

    /// The film named in a song title: `Kaavaalaa (From "Jailer")`, `[From the movie Pushpa]`. Nil when it names none.
    static func fromFilm(inSongTitle raw: String) -> String? {
        let t = normalizeQuotes(raw)
        let pattern = #"[\(\[]\s*(?:from|music\s+from|taken\s+from|picked\s+from)\s+(?:the\s+)?(?:(?:original\s+)?(?:motion\s+picture|movie|film)\s*)?[:\-]?\s*"?([^\)\]]+?)"?\s*[\)\]]"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: t) else { return nil }
        let text = String(t[r]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'-–:"))
        return text.isEmpty ? nil : text
    }

    struct CleanFilm: Equatable, Sendable { var title: String; var year: Int?; var language: String? }

    /// A film name without the language, year and "movie" words that sources add: `"Awaara (2013) [Telugu]"` -> Awaara, 2013, te.
    static func clean(_ raw: String) -> CleanFilm {
        var t = normalizeQuotes(raw).replacingOccurrences(of: "\"", with: "")
        var year: Int?
        var language: String?
        if let r = t.range(of: #"[\(\[]\s*((?:19|20)\d\d)\s*[\)\]]"#, options: .regularExpression) {
            year = Int(t[r].filter(\.isNumber)); t.removeSubrange(r)
        }
        let langs = languageNames.keys.joined(separator: "|")
        if let r = t.range(of: "[\\(\\[]\\s*(" + langs + ")(?:\\s+(?:version|movie|film|dubbed))?\\s*[\\)\\]]", options: [.regularExpression, .caseInsensitive]) {
            language = languageNames.first { t[r].lowercased().contains($0.key) }?.value; t.removeSubrange(r)
        } else if let r = t.range(of: "\\s+[-–—]\\s*(" + langs + ")\\s*$", options: [.regularExpression, .caseInsensitive]) {
            language = languageNames.first { t[r].lowercased().contains($0.key) }?.value; t.removeSubrange(r)
        }
        t = t.replacingOccurrences(of: #"(?i)\s+(?:full\s+)?(?:movie|film)\s*$"#, with: "", options: .regularExpression)
        let words = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return CleanFilm(title: words.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:~,.")), year: year, language: language)
    }

    /// A film name must be a name: not empty, not one letter, not an artist's own name, and not a generic album word.
    static func isPlausibleFilmTitle(_ title: String, artists: [String]) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.contains(where: \.isLetter) else { return false }
        let key = MusicTransliterationKey.key(t)
        guard !key.isEmpty else { return false }
        if artists.contains(where: { MusicTransliterationKey.key($0) == key }) { return false }
        let generic: Set<String> = ["greatest hits", "best of", "hits", "singles", "unknown", "various artists", "soundtrack", "original soundtrack", "unplugged", "live"]
        return !generic.contains(MusicText.normalize(t))
    }

    // MARK: helpers

    static func year(of date: String?) -> Int? {
        guard let d = date, d.count >= 4, let y = Int(d.prefix(4)), (1900...2100).contains(y) else { return nil }
        return y
    }

    static let languageNames: [String: String] = [
        "telugu": "te", "hindi": "hi", "tamil": "ta", "kannada": "kn", "malayalam": "ml", "bengali": "bn", "marathi": "mr", "punjabi": "pa",
        "gujarati": "gu", "bhojpuri": "bh", "english": "en", "korean": "ko", "japanese": "ja", "urdu": "ur", "odia": "or"]

    static func languageCode(_ name: String) -> String? {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let c = languageNames[n] { return c }
        return languageNames.values.contains(n) ? n : nil
    }

    private static func normalizeQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"").replacingOccurrences(of: "’", with: "'")
    }
}

// MARK: JioSaavn's film credits

/// JioSaavn's album reply names, per song, the people by role: `music`, `singer`, `lyricist` and `starring`. `MusicTrack` keeps only the song's
/// artists, so the film credits come from this one extra read of the same public web API (no key, nothing about the person is sent).
enum MusicFilmProviderFactsFetcher {
    static func fetch(album: MusicAlbum, http: MusicHTTP = MusicHTTP()) async -> MusicFilmProviderFacts? {
        guard album.providerID == "jiosaavn" else { return nil }
        let q = ["__call": "content.getAlbumDetails", "albumid": album.id, "_format": "json", "_marker": "0", "api_version": "4", "ctx": "web6dot0"]
        guard let obj = try? await http.getObject(JioSaavnProvider.base, query: q), let d = obj as? [String: Any] else { return nil }
        return parse(d)
    }

    /// The film facts of a `content.getAlbumDetails` reply (or one `list` element). Pure.
    static func parse(_ d: [String: Any]) -> MusicFilmProviderFacts? {
        var f = MusicFilmProviderFacts()
        f.title = d.str("title").map(JioSaavnProvider.clean)
        f.year = MusicFilmResolver.year(of: d.str("year"))
        f.language = d.str("language")
        f.label = d.dict("more_info")?.str("label")
        var starring: [String: Int] = [:], order: [String] = [], music: [String] = [], singers: [String] = []
        func add(_ n: String, to list: inout [String]) { if !list.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { list.append(n) } }
        for song in d.array("list") {
            for a in (song.dict("more_info")?.dict("artistMap") ?? [:]).array("artists") {
                guard let raw = a.str("name") else { continue }
                let name = JioSaavnProvider.clean(raw).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                switch a.str("role")?.lowercased() {
                case "starring": if starring[name] == nil { order.append(name) }; starring[name, default: 0] += 1
                case "music": add(name, to: &music)
                case "singer": add(name, to: &singers)
                default: break
                }
            }
        }
        // The people billed on most songs come first.
        f.starring = order.sorted { (starring[$0] ?? 0) > (starring[$1] ?? 0) || ((starring[$0] ?? 0) == (starring[$1] ?? 0) && order.firstIndex(of: $0)! < order.firstIndex(of: $1)!) }
        f.musicBy = (d.dict("more_info")?.str("music")).map { MusicLyricsQueryBuilder.names(JioSaavnProvider.clean($0)) } ?? music
        if f.musicBy.isEmpty { f.musicBy = music }
        f.singers = singers
        return f.isEmpty && f.title == nil ? nil : f
    }
}
