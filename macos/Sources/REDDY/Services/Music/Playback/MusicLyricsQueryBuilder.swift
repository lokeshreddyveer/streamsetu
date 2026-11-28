import Foundation

/// One way of asking the lyrics sources about a track: a cleaned title, the artist when it is a person, and an album or film hint.
struct MusicLyricsQueryVariant: Hashable, Sendable {
    var title: String
    var artists: String
    var album: String?
    /// Why this variant exists, for tests and the picker's footnote.
    var kind: Kind

    enum Kind: String, Sendable { case cleanWithArtist, cleanTitleOnly, spelling, withFilm, original }
}

/// Turns what a streaming site calls a track ("Dakko Dakko Meka song (from pushpa telugu)" by the channel "LOOP Studio") into the queries a
/// lyrics database can answer. Video titles carry noise words and the uploader is often a channel rather than a singer, so asking with them
/// as they are finds nothing. Pure text work; nothing here touches the network.
enum MusicLyricsQueryBuilder {
    /// At most this many different questions are asked per song.
    static let maxVariants = 5

    struct CleanTitle: Equatable, Sendable {
        var title: String
        var film: String?
        var featured: [String]
        /// "Artist" when the title had the "Artist - Title" shape and the left part was taken as the artist.
        var leadingArtist: String?
    }

    // MARK: variants

    static func variants(for request: MusicLyricsRequest) -> [MusicLyricsQueryVariant] {
        let rawTitle = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = cleanTitle(rawTitle)
        var title = cleaned.title.isEmpty ? rawTitle : cleaned.title
        var artist = cleanArtists(request.artists)
        var swapped: String?
        // "Artist - Title" or "Title - Film": the uploader decides which reading comes first.
        if let lead = cleaned.leadingArtist, !title.isEmpty {
            if artist.isEmpty {
                artist = cleanArtists(lead)
                if !artist.isEmpty { swapped = lead }
            } else if !(sameName(lead, artist) || artist.localizedCaseInsensitiveContains(lead) || lead.localizedCaseInsensitiveContains(artist)) {
                swapped = title
                title = lead
            }
        }
        if title.isEmpty { title = rawTitle }
        let album = cleaned.film ?? request.album

        var out: [MusicLyricsQueryVariant] = []
        func add(_ title: String, _ artists: String, _ album: String?, _ kind: MusicLyricsQueryVariant.Kind) {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            let v = MusicLyricsQueryVariant(title: t, artists: artists, album: album, kind: kind)
            if !out.contains(where: { key($0) == key(v) }) { out.append(v) }
        }
        func key(_ v: MusicLyricsQueryVariant) -> String { (v.title + "|" + v.artists).lowercased() }

        add(title, artist, album, artist.isEmpty ? .cleanTitleOnly : .cleanWithArtist)
        if !artist.isEmpty { add(title, "", album, .cleanTitleOnly) }
        // "Film Movie | Song" and "Song Full Video Song | Film": either side of a bar can be the song, so each is asked on its own.
        for segment in barSegments(rawTitle) { add(segment, "", album, .original) }
        // The film name beside the title is the best artist-less question for a film song; spelling variants follow.
        if let film = cleaned.film { add("\(title) \(film)", "", nil, .withFilm) }
        for alt in MusicTransliterationKey.alternates(of: title, limit: 2) { add(alt, "", album, .spelling) }
        if let other = swapped { add(other, "", album, .original) }
        add(rawTitle, request.artists, request.album, .original)
        return MusicCatalogLyricsHook.apply(Array(out.prefix(maxVariants)), request: request, limit: maxVariants)
    }

    /// The cleaned parts of a title written with bars ("Surya Son of Krishnan Movie | Nalone Pongenu" gives both), leaving out channel names and "lyrics" parts.
    static func barSegments(_ raw: String) -> [String] {
        guard raw.contains("|") else { return [] }
        let parts = raw.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var out: [String] = []
        for p in parts {
            let c = stripNoise(cleanTitle(p).title)
            guard !c.isEmpty, c.split(separator: " ").count <= 6, !looksLikeChannel(c), !c.lowercased().contains("lyric"), !out.contains(c) else { continue }
            out.append(c)
        }
        return Array(out.prefix(2))
    }

    // MARK: titles

    private static let noiseAnywhere: Set<String> = [
        "official", "lyrical", "4k", "8k", "hd", "hq", "uhd", "1080p", "720p", "2160p", "remastered", "remaster", "mv", "visualizer", "visualiser"]
    private static let noiseTrailing: Set<String> = [
        "song", "songs", "video", "videos", "promo", "teaser", "audio", "lyrics", "lyric", "full", "version", "new", "latest", "music", "movie", "film", "with", "ost",
        "telugu", "hindi", "tamil", "kannada", "malayalam", "punjabi", "bengali", "marathi", "bhojpuri", "gujarati", "english", "korean", "japanese"]
    private static let openers: Set<Character> = ["(", "[", "【", "（", "{"]
    private static let closers: Set<Character> = [")", "]", "】", "）", "}"]
    private static let dashes = [" - ", " – ", " — ", " ~ ", " : "]

    static func cleanTitle(_ raw: String) -> CleanTitle {
        var text = raw
        // "Title Full Video Song | Film | Singer": what follows the bar is often the film (a hint, never the title).
        var barFilm: String?
        if let bar = text.firstIndex(of: "|") {
            let tail = String(text[text.index(after: bar)...])
            barFilm = tail.split(separator: "|").map { cleanFilm(String($0)) }.first {
                !$0.isEmpty && $0.split(separator: " ").count <= 5 && !looksLikeChannel($0) && !$0.lowercased().contains("lyric")
            }
            text = String(text[..<bar])
        }
        text = text.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"").replacingOccurrences(of: "’", with: "'")
        // Hashtags are never part of a title.
        text = text.split(separator: " ").filter { !$0.hasPrefix("#") }.joined(separator: " ")

        var film: String?
        var featured: [String] = []

        // Bracketed asides: collect the film and any featured artist, drop the rest.
        var kept = ""
        var inner = ""
        var depth = 0
        for ch in text {
            if openers.contains(ch) { depth += 1; if depth == 1 { inner = "" }; continue }
            if closers.contains(ch) {
                if depth > 0 {
                    depth -= 1
                    if depth == 0 { absorb(aside: inner, film: &film, featured: &featured) }
                }
                continue
            }
            if depth == 0 { kept.append(ch) } else { inner.append(ch) }
        }
        if depth > 0 { absorb(aside: inner, film: &film, featured: &featured) }
        text = kept

        if film == nil { film = barFilm }
        // Unbracketed "feat." and "from".
        if let r = text.range(of: #"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+"#, options: .regularExpression) {
            featured.append(contentsOf: names(String(text[r.upperBound...])))
            text = String(text[..<r.lowerBound])
        }
        if let r = text.range(of: #"(?i)\s+(?:from|movie|film)\s*[:\-]?\s+"#, options: .regularExpression), r.lowerBound > text.startIndex {
            let rest = String(text[r.upperBound...])
            let before = String(text[..<r.lowerBound])
            if !before.trimmingCharacters(in: .whitespaces).isEmpty {
                if film == nil { film = cleanFilm(rest) }
                text = before
            }
        }
        // `"Title"` in straight quotes: the quoted part is the title.
        if let r = text.range(of: #""([^"]+)""#, options: .regularExpression) {
            let quoted = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let rest = text.replacingCharacters(in: r, with: " ")
            if !quoted.isEmpty, rest.split(separator: " ").count <= 4 { text = quoted }
        }
        text = text.replacingOccurrences(of: "\"", with: "")

        // "Artist - Title" and "Title - Official Video".
        var leading: String?
        var parts = [text]
        for d in dashes where text.contains(d) { parts = text.components(separatedBy: d); break }
        parts = parts.map { stripNoise($0) }.filter { !$0.isEmpty }
        if parts.count >= 2 {
            leading = parts[0]
            text = parts[1]
        } else { text = parts.first ?? "" }

        return CleanTitle(title: stripNoise(text), film: film.flatMap { $0.isEmpty ? nil : $0 }, featured: featured,
                          leadingArtist: leading)
    }

    private static func absorb(aside: String, film: inout String?, featured: inout [String]) {
        let a = aside.trimmingCharacters(in: .whitespaces)
        let lower = a.lowercased()
        if let r = lower.range(of: #"^(?:from|movie|film|ost|soundtrack)\b\s*[:\-]?\s*"#, options: .regularExpression) {
            if film == nil { film = cleanFilm(String(a[r.upperBound...])) }
        } else if let r = lower.range(of: #"^(?:feat\.?|ft\.?|featuring|with)(?=\s|$)\s*"#, options: .regularExpression) {
            featured.append(contentsOf: names(String(a[r.upperBound...])))
        }
    }

    /// "pushpa telugu" -> "pushpa"; quotes and a trailing "movie" go.
    private static func cleanFilm(_ s: String) -> String {
        stripNoise(s.replacingOccurrences(of: "\"", with: "")).trimmingCharacters(in: .whitespaces)
    }

    private static func stripNoise(_ s: String) -> String {
        var tokens = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        tokens.removeAll { noiseAnywhere.contains(strip($0)) }
        while let last = tokens.last, noiseTrailing.contains(strip(last)) { tokens.removeLast() }
        // "Video Song", "Lyrical Video" can also lead a short remainder.
        while tokens.count > 1, let first = tokens.first, ["official", "lyrical"].contains(strip(first)) { tokens.removeFirst() }
        let joined = tokens.joined(separator: " ")
        return joined.trimmingCharacters(in: CharacterSet(charactersIn: " -–—~:,.;/_*\"'!"))
    }

    private static func strip(_ t: String) -> String {
        t.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    // MARK: artists

    private static let knownLabels: Set<String> = [
        "t-series", "tseries", "t series", "zee music company", "zee music", "sony music", "sony music india", "sony music south", "saregama",
        "saregama music", "aditya music", "lahari music", "lahari", "times music", "universal music", "warner music", "think music", "think music india",
        "speed records", "mango music", "tips official", "tips music", "yrf", "eros now", "eros music", "anand audio", "mythri music", "vevo", "youtube",
        "various artists", "unknown artist", "unknown", "jukebox", "tseries regional", "t-series telugu", "t-series tamil", "muzik247", "muzik 247",
        "sun tv", "star maa", "zee telugu", "gemini music", "volga videos", "silly monks", "lyrical", "t series telugu"]
    private static let channelSuffix: Set<String> = [
        "studio", "studios", "records", "record", "recordings", "tv", "channel", "entertainment", "entertainments", "productions", "production", "films",
        "film", "series", "lyrics", "audio", "audios", "network", "media", "label", "company", "covers", "cover", "songs", "hub", "world", "club",
        "movies", "pictures", "cinemas", "originals", "official", "music", "vevo", "topic", "digital", "creations", "tunes", "beats", "jukebox"]

    /// Splits "A, B & C" style credit lines into single names.
    static func names(_ s: String) -> [String] {
        var t = s
        for sep in [" & ", " and ", " x ", " X ", ";", "/", " feat. ", " ft. ", " feat ", " ft "] { t = t.replacingOccurrences(of: sep, with: ",") }
        return t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// True for uploaders and labels ("LOOP Studio", "T-Series", "Zee Music Company", "Aditya Music").
    static func looksLikeChannel(_ s: String) -> Bool {
        let t = channelCore(s)
        guard !t.isEmpty else { return false }
        let lower = t.lowercased()
        if knownLabels.contains(lower) { return true }
        let tokens = lower.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let last = tokens.last else { return false }
        if tokens.count == 1 { return channelSuffix.contains(last) && last != "official" }
        // "Taylor Swift Official" is a person once the suffix goes; "LOOP Studio" is not.
        if ["official", "vevo", "topic", "music"].contains(last) {
            let rest = tokens.dropLast().joined(separator: " ")
            return knownLabels.contains(rest) || (last == "music" && tokens.count >= 2 && channelSuffix.contains(tokens[tokens.count - 2]))
        }
        return channelSuffix.contains(last)
    }

    /// The name with " - Topic" and a trailing VEVO or "Official" taken off.
    static func channelCore(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Topic", " – Topic", "- Topic"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasSuffix("vevo"), t.count > 4 { t = String(t.dropLast(4)) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// The people in a credit line, or "" when it only names channels.
    static func cleanArtists(_ raw: String) -> String {
        var people: [String] = []
        for part in names(raw) {
            var n = channelCore(part)
            if n.lowercased().hasSuffix(" official") { n = String(n.dropLast(9)).trimmingCharacters(in: .whitespaces) }
            guard !n.isEmpty, !looksLikeChannel(n) else { continue }
            if !people.contains(where: { sameName($0, n) }) { people.append(n) }
        }
        return people.joined(separator: ", ")
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    // MARK: spelling

    /// Indian-language titles are spelled many ways in Latin letters. This offers the longer vowel form of the first vowel when it is an
    /// "a" ("Dakko" -> "Daakko"), the most common difference between a video title and a lyrics database.
    static func spellingAlternate(_ title: String) -> String? {
        let words = title.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.allSatisfy({ $0.unicodeScalars.allSatisfy { $0.isASCII } }) else { return nil }
        var changed = false
        let out = words.map { w -> String in
            let chars = Array(w)
            guard let i = chars.firstIndex(where: { "aeiouAEIOU".contains($0) }), chars[i].lowercased() == "a" else { return w }
            if i + 1 < chars.count, "aeiouAEIOU".contains(chars[i + 1]) { return w }
            guard w.count >= 4 else { return w }
            changed = true
            var c = chars
            c.insert(chars[i], at: i + 1)
            return String(c)
        }
        return changed ? out.joined(separator: " ") : nil
    }
}

extension MusicLyricsRequest {
    /// The same track asked about in another way. The video id and length stay (sources use them for exact matches); the album is the
    /// variant's hint.
    func applying(_ v: MusicLyricsQueryVariant) -> MusicLyricsRequest {
        var r = self
        r.title = v.title
        r.artists = v.artists
        r.album = v.album
        return r
    }
}
