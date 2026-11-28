import Foundation

/// The title a person sees for a video-style upload ("Apudo Ipudo Video Song (4K) | Bommarillu Movie Songs | Siddharth, Genelia | Devi Sri Prasad"):
/// a clean song title plus a short subtitle ("Bommarillu · Siddharth, Genelia"). The raw title stays on the model for matching and is the tooltip and
/// the accessibility label, so nothing is lost. Pure text work. Titles that carry no noise come back exactly as they were, and version words
/// (remix, live, cover, karaoke, instrumental, female version ...) are never removed.
enum MusicDisplayTitle {
    struct Result: Equatable, Sendable {
        /// What to draw as the title.
        var title: String
        /// "Film · Singer, Singer", nil when the title said nothing more with confidence.
        var subtitle: String?
        /// The exact title as the source gave it: tooltip, accessibility label, matching.
        var raw: String
        /// The film or album named in the title, when it was recognised.
        var film: String?
        /// True when the display title differs from the raw one.
        var isNoisy: Bool
    }

    // MARK: data

    /// A token that marks a title as video-style by itself.
    private static let signals: Set<String> = [
        "official", "lyrical", "lyric", "lyrics", "video", "videos", "audio", "4k", "8k", "hd", "hq", "uhd", "60fps", "promo", "teaser", "hdsong", "8k4k", "4k8k", "1080p", "2160p"
    ]
    /// Removed wherever they stand once a title is known to be video-style.
    private static let noiseAnywhere: Set<String> = ["official", "lyrical", "4k", "8k", "hd", "hq", "uhd", "60fps", "8k4k", "4k8k", "hdsong", "1080p", "2160p", "visualizer", "visualiser", "mv"]
    /// A language in brackets after a title ("(Telugu)") marks a dubbed or re-sung version and is kept.
    private static let languages: Set<String> = ["telugu", "hindi", "tamil", "kannada", "malayalam", "punjabi", "bengali", "marathi", "bhojpuri", "gujarati", "haryanvi"]
    /// Removed from the end, one by one.
    private static let noiseTrailing: Set<String> = [
        "song", "songs", "video", "videos", "promo", "teaser", "audio", "lyrics", "lyric", "full", "music", "movie", "film", "with", "ost", "out", "now", "new", "latest", "trending",
        "telugu", "hindi", "tamil", "kannada", "malayalam", "punjabi", "bengali", "marathi", "bhojpuri", "gujarati", "english", "korean", "japanese", "haryanvi",
        "2024", "2025", "2026", "2027", "official", "hd", "4k", "8k"
    ]
    /// A tail segment made only of these says nothing about the song.
    private static let descriptors: Set<String> = [
        "love", "hit", "hits", "super", "superhit", "sad", "melody", "trending", "folk", "new", "latest", "best", "evergreen", "old", "classic", "devotional", "songs", "song", "video", "audio",
        "lyrical", "lyrics", "lyric", "official", "full", "music", "movie", "indie", "pop", "tamilindie", "telugu", "hindi", "tamil", "kannada", "malayalam", "punjabi", "bengali", "marathi", "bhojpuri",
        "gujarati", "english", "haryanvi", "2024", "2025", "2026", "hd", "4k", "8k", "out", "now", "promo", "teaser", "ayyappa", "hits", "jukebox"
    ]
    /// Words that name a song's film or album inside a bar segment.
    private static let filmMarkers: [String] = [#"(?i)\b(movie songs?|movie|film songs?|film|ost|original soundtrack)\s*$"#]
    /// Whole phrases in Telugu, Hindi, Tamil and others that mean "lyrics", "video song", "audio" and so on.
    private static let foreignNoise: [String] = [
        "பாடல் வரிகளுடன்", "பாடல் வரிகள்", "வீடியோ பாடல்", "முழு வீடியோ", "லிரிக்கல்", "வீடியோ", "ஆடியோ",
        "वीडियो सॉन्ग", "वीडियो गाना", "ऑफिशियल वीडियो", "ऑफिशियल", "लिरिकल", "पूरा गाना", "वीडियो", "ऑडियो", "लिरिक्स",
        "పూర్తి వీడియో", "లిరికల్ వీడియో", "వీడియో సాంగ్", "లిరికల్", "లిరిక్స్", "వీడియో", "ఆడియో",
        "ವಿಡಿಯೋ ಸಾಂಗ್", "ಲಿರಿಕಲ್", "വീഡിയോ ഗാനം", "ലിറിക്കൽ", "ভিডিও গান", "ਵੀਡੀਓ ਗੀਤ"
    ]
    private static let prefixes = #"(?i)^\s*(full video|full song|full audio|video song|video|lyrical video|lyric video|official video|official audio|audio|lyrical|lyrics)\s*[:：\-–—]\s*"#

    // MARK: public

    private struct Ask: Hashable, Sendable { var title: String; var artists: [String] }
    /// The cleaning is a dozen text passes and a card asks for it on every redraw of its page; the answer for one title and credit line never changes.
    private static let remembered = MusicBoundedMemo<Ask, Result>(capacity: 4_096)

    static func clean(title: String, artists: [String] = []) -> Result {
        remembered.value(for: Ask(title: title, artists: artists)) { compute(title: title, artists: artists) }
    }

    private static func compute(title: String, artists: [String]) -> Result {
        let raw = title
        let source = title.trimmingCharacters(in: .whitespacesAndNewlines)
        func same() -> Result { Result(title: raw, subtitle: nil, raw: raw, film: nil, isNoisy: false) }
        guard !source.isEmpty else { return same() }

        var s = source.replacingOccurrences(of: "｜", with: "|").replacingOccurrences(of: "||", with: "|")
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        var foreign = false
        for p in foreignNoise where s.contains(p) { s = s.replacingOccurrences(of: p, with: " "); foreign = true }
        let barStyle = s.contains("|")
        let hashtag = s.split(separator: " ").contains { $0.hasPrefix("#") && $0.count > 1 }
        let anySignal = foreign || barStyle || hashtag || tokens(s).contains { signals.contains(key($0)) } || s.range(of: prefixes, options: .regularExpression) != nil
        guard anySignal else { return same() }

        let credited = Set(artists.map { MusicText.normalize($0) }.filter { !$0.isEmpty })
        let segments = s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }

        // Head: the first segment with something left after cleaning (a leading "#Video" is only noise).
        var headText = ""
        var headIndex = 0
        var headDash: (title: String, film: String?)?
        for (i, seg) in segments.enumerated() {
            let d = splitDash(seg, barStyle: barStyle, loneSongOK: segments.count >= 4 || foreign || hashtag)
            if !d.title.isEmpty { headText = d.title; headIndex = i; headDash = d; break }
        }
        guard !headText.isEmpty else { return same() }
        headText = fixCase(headText)

        // Tail: film and people.
        var film: String? = headDash?.film.map(fixCase)
        var plain: [String] = []
        for seg in segments.dropFirst(headIndex + 1) {
            var t = stripFeat(seg)
            let hadMarker = filmMarkers.contains { t.range(of: $0, options: .regularExpression) != nil }
            t = cleanPart(t, barStyle: true).text
            t = t.replacingOccurrences(of: #"(?i)^\s*(ft|feat|featuring)\.?\s+"#, with: "", options: .regularExpression).trimmingCharacters(in: Self.trimSet)
            guard !t.isEmpty else { continue }
            let nk = MusicText.normalize(t)
            if nk.isEmpty || credited.contains(nk) || nk == MusicText.normalize(headText) { continue }
            if MusicLyricsQueryBuilder.looksLikeChannel(t) { continue }
            let words = nk.split(separator: " ").map(String.init)
            if words.allSatisfy({ descriptors.contains($0) }) { continue }
            if hadMarker, film == nil, t.split(separator: ",").count == 1 { film = fixCase(t); continue }
            plain.append(t)
        }
        if film == nil, plain.count >= 2, !plain[0].contains(","), plain[0].split(separator: " ").count <= 5, MusicLyricsQueryBuilder.names(plain[1]).count >= 2 {
            film = fixCase(plain.removeFirst())
        }
        var names: [String] = []
        for p in plain {
            for n in MusicLyricsQueryBuilder.names(p) {
                let n = n.hasPrefix("@") ? String(n.dropFirst()) : n
                let nk = MusicText.normalize(n)
                if nk.isEmpty || credited.contains(nk) || MusicCompilationArtist.isCompilation(n) { continue }
                let f = fixCase(n)
                if !names.contains(where: { MusicText.normalize($0) == nk }) { names.append(f) }
            }
        }
        let subtitle: String?
        if let film, !film.isEmpty {
            subtitle = names.isEmpty ? film : film + " · " + names.prefix(2).joined(separator: ", ")
        } else {
            subtitle = names.isEmpty ? nil : names.prefix(3).joined(separator: ", ")
        }
        let changed = headText != source
        return Result(title: headText, subtitle: subtitle, raw: raw, film: film, isNoisy: changed)
    }

    /// The same with the credited artists as one string ("A, B & C").
    static func clean(title: String, artists: String) -> Result { clean(title: title, artists: MusicLyricsQueryBuilder.names(artists)) }

    /// How a track is shown, or nil when its own title is shown as it is: the person's own library and local files are never renamed, and a title
    /// without noise is kept exactly.
    static func display(for t: MusicTrack) -> Result? {
        guard t.providerID != "local" else { return nil }
        var r = clean(title: t.title, artists: t.artists.map(\.name))
        // The song's name in its own language and script, when the graph holds one (see MusicNativeNames).
        if let native = MusicNativeNames.shared.title(for: t) {
            r.title = native; r.isNoisy = true
            return r
        }
        return r.isNoisy ? r : nil
    }

    // MARK: pieces

    private static let trimSet = CharacterSet(charactersIn: " -–—~:,.;/_*\"|")

    private static func tokens(_ s: String) -> [String] { s.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
    private static func key(_ t: String) -> String { t.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted).replacingOccurrences(of: "/", with: "") }

    /// "Rathinamo - Official Music Video" -> the title; "Kinna Sona FULL VIDEO Song - Bhaag Johnny" -> title and film.
    private static func splitDash(_ seg: String, barStyle: Bool, loneSongOK: Bool) -> (title: String, film: String?) {
        var text = seg.split(separator: " ").joined(separator: " ")
        text = text.replacingOccurrences(of: #"(?<=\s)#(?=\S)|^#(?=\S)"#, with: "", options: .regularExpression)
        var prefixed = false
        if let r = text.range(of: prefixes, options: .regularExpression) { text = String(text[r.upperBound...]); prefixed = true }
        var parts = [text]
        for d in [" - ", " – ", " — "] where text.contains(d) { parts = text.components(separatedBy: d); break }
        var cleaned: [(text: String, noisy: Bool)] = []
        for (i, p) in parts.enumerated() {
            let c = cleanPart(p, barStyle: barStyle, loneSongOK: loneSongOK)
            if !c.text.isEmpty { cleaned.append((c.text, c.changed || (i == 0 && prefixed))) }
        }
        guard !cleaned.isEmpty else { return ("", nil) }
        if cleaned.count == 1 { return (cleaned[0].text, nil) }
        if cleaned.count == 2 {
            if cleaned[1].noisy && !cleaned[0].noisy { return (cleaned[1].text, cleaned[0].text) }
            if cleaned[0].noisy && !cleaned[1].noisy { return (cleaned[0].text, cleaned[1].text) }
        }
        return (cleaned.map(\.text).joined(separator: " - "), nil)
    }

    /// Cleans one piece of a title. Noise tokens go only when the piece is video-style itself or the whole title is (a bar title).
    private static func cleanPart(_ part: String, barStyle: Bool, loneSongOK: Bool = true) -> (text: String, changed: Bool) {
        var p = part.trimmingCharacters(in: .whitespaces)
        var bracketNoise = false
        let original = p
        p = p.replacingOccurrences(of: #"(?<=\s)#(?=\S)|^#(?=\S)"#, with: "", options: .regularExpression)
        // Bracketed groups made only of noise ("(Official Video)", "(4K)", "(Song)", "(Lyrical)").
        if let rx = try? NSRegularExpression(pattern: "[\\(\\[\\{（【][^\\)\\]\\}）】]*[\\)\\]\\}）】]") {
            let ns = p as NSString
            for m in rx.matches(in: p, range: NSRange(location: 0, length: ns.length)).reversed() {
                let inner = ns.substring(with: m.range).dropFirst().dropLast()
                let ws = tokens(String(inner)).map(key).filter { !$0.isEmpty }
                if ws.isEmpty || (ws.allSatisfy({ noiseAnywhere.contains($0) || noiseTrailing.contains($0) || signals.contains($0) }) && !ws.contains(where: { languages.contains($0) })) {
                    p = (p as NSString).replacingCharacters(in: m.range, with: " "); bracketNoise = true
                }
            }
        }
        var toks = tokens(p)
        let hasSignal = toks.contains { signals.contains(key($0)) } || p != original.replacingOccurrences(of: #"(?<=\s)#(?=\S)|^#(?=\S)"#, with: "", options: .regularExpression)
        if hasSignal || barStyle {
            toks.removeAll { noiseAnywhere.contains(key($0)) }
            // A single trailing "Song" can be the song's own word ("Love Song"): it goes only when something else says the title is video-style.
            let keepLoneSong = !(hasSignal || bracketNoise || loneSongOK) && toks.count > 1 && ["song", "songs"].contains(key(toks[toks.count - 1])) && !noiseTrailing.contains(key(toks[toks.count - 2])) && !noiseAnywhere.contains(key(toks[toks.count - 2]))
            while !keepLoneSong, let last = toks.last, (noiseTrailing.contains(key(last)) && !(languages.contains(key(last)) && last.contains(where: { "([)]".contains($0) }))) || key(last).isEmpty { toks.removeLast() }
        }
        var out = toks.joined(separator: " ").trimmingCharacters(in: trimSet)
        // A piece that is only noise ("Full Video Song", "Lyric") has nothing left.
        if toks.allSatisfy({ noiseTrailing.contains(key($0)) }) { out = "" }
        return (out, out != original)
    }

    private static func stripFeat(_ seg: String) -> String {
        seg.replacingOccurrences(of: #"(?i)\s*[\(\[]\s*(feat|ft|featuring)\.?\s+([^\)\]]*)[\)\]]"#, with: ", $2", options: .regularExpression)
    }

    /// ALL CAPS Latin text is shown in capitals-and-lower; short words (initials such as "GV", "SV") stay as they are.
    private static func fixCase(_ s: String) -> String {
        let letters = s.filter { $0.isLetter }
        guard letters.count >= 3, s.unicodeScalars.allSatisfy({ $0.isASCII }), letters.allSatisfy({ $0.isUppercase }) else { return s }
        return s.split(separator: " ", omittingEmptySubsequences: false).map { w -> String in
            let wl = w.filter { $0.isLetter }
            if wl.count <= 2 { return String(w) }
            return w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
