import Foundation

/// One pure function that turns a provider's title ("TELUGU | Pushpa The Rise (Telugu) FHD 2026") into the name TMDB knows.
/// The rules are shared with the Android and Windows apps; the cases live in artwork/fixtures/name-cleaning.json (see the README there).
/// The one source of the words the title-cleaning rules share. ArtworkNameCleaner (what TMDB is searched with and what tiles show), IdentityKey (the frozen "same title" key) and the channel
/// normalizer all read their word lists from here, so a language or quality word is added in one place. The identity lists are frozen subsets (changing the key's output needs
/// `IdentityKey.version` to go up, so stored keys are re-derived), and TitleVocabularyTests checks every list against this one and against artwork/fixtures/name-cleaning.json.
enum TitleVocabulary {
    /// Every language word (lower case) with the name shown for it. A superset of what any single rule needs; the aliases map to one name.
    static let languageNames: [String: String] = {
        var out: [String: String] = [:]
        for w in ["english", "hindi", "tamil", "telugu", "kannada", "malayalam", "urdu", "punjabi", "bengali", "marathi", "gujarati", "arabic", "spanish",
                  "french", "german", "korean", "japanese", "chinese", "turkish", "russian", "italian", "portuguese", "thai", "indonesian", "odia",
                  "assamese", "nepali", "sinhala", "persian", "hebrew", "vietnamese", "tagalog", "malay", "pashto", "dutch", "polish"] { out[w] = w.capitalized }
        out["bangla"] = "Bengali"; out["farsi"] = "Persian"; out["filipino"] = "Tagalog"; out["oriya"] = "Odia"; out["odiya"] = "Odia"
        return out
    }()
    static let languageWords: Set<String> = Set(languageNames.keys)

    /// The languages IdentityKey v1 removes from a key anywhere in a title. Frozen: "dutch" and "polish" are real title words ("Polish Wedding"), so they are deliberately not here.
    static let identityLanguageWords: Set<String> = languageWords.subtracting(["dutch", "polish"])
    /// The quality and release words IdentityKey v1 removes. Frozen with the key's version.
    static let identityNoise: Set<String> = ["hd", "fhd", "uhd", "4k", "sd", "hdcam", "cam", "webrip", "web", "dl", "bluray", "dvdrip", "hevc", "x264", "x265", "h264", "h265",
                                             "dubbed", "dub", "multi", "sub", "subs", "eng", "season", "episode"]
    /// Quality words dropped from a channel name to find its base name ("sky sports hd").
    static let channelQualityTokens: Set<String> = ["hd", "fhd", "uhd", "4k", "sd", "hevc", "h265", "h264", "1080p", "720p", "2160p", "50fps", "60fps"]
}

enum ArtworkNameCleaner {
    struct Parsed: Equatable, Sendable { var text: String; var year: Int? }

    /// Language words, from the one vocabulary (TitleVocabulary) shared with the identity rule; "multi" is a tag that only reads as a language in a title.
    static let languages: Set<String> = TitleVocabulary.languageWords.union(["multi"])
    /// Provider and country prefixes, only recognised when followed by a separator ("IN:", "NF |", "EN -").
    static let prefixes: Set<String> = ["in", "us", "uk", "en", "fr", "de", "es", "it", "pt", "tr", "ar", "hi", "te", "ta", "ml", "kn", "bn", "mr", "pa", "gu", "ur", "pk", "bd", "lk", "nl", "pl", "ru", "kr", "jp", "cn", "ir", "ca", "au", "mx", "br", "nf", "amzn", "dsnp", "hotstar", "zee5", "sonyliv", "jio", "atvp", "hulu", "max", "hbo", "ja", "ko", "zh", "th", "id", "vi", "fa", "he", "sv", "da", "fi", "el", "cs", "hu", "ro", "bg", "sr", "hr", "sk", "sl", "sa", "ae", "qa", "eg", "sg", "my", "ph", "za", "ng", "ke", "nz", "ie", "se", "dk", "gr", "at", "ch", "be", "prime", "netflix", "vod", "mov", "movie", "movies", "series", "new", "top"]
    /// Quality and release tags that are never part of a title: removed wherever they stand.
    static let strongTags: Set<String> = ["4k", "uhd", "fhd", "hevc", "x264", "x265", "h264", "h265", "avc", "hdr10", "hdr10+", "1080p", "720p", "480p", "360p", "1440p", "2160p", "1080i", "web-dl", "webdl", "webrip", "bluray", "blu-ray", "brrip", "bdrip", "dvdrip", "hdtv", "hdrip", "hdcam", "hdts", "10bit", "5.1", "atmos"]
    /// Tags that could be a word of a title: removed only at the start or end.
    static let weakTags: Set<String> = ["hd", "sd", "hq", "hdr", "cam", "dubbed", "dub", "subbed", "sub", "subs", "dual", "audio", "multi", "uncut", "extended", "remastered", "proper", "new", "dv", "vod", "original"]

    static func clean(_ title: String, year: Int? = nil) -> String { parse(title, year: year).text }

    /// The cleaned name and the year to search with (the library's, else one written in brackets).
    static func parse(_ title: String, year: Int? = nil) -> Parsed {
        var s = title.precomposedStringWithCompatibilityMapping
        for (a, b) in [("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{2012}", "-"), ("\u{00A0}", " "), ("_", " ")] { s = s.replacingOccurrences(of: a, with: b) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = s
        if !s.contains(where: \.isWhitespace) && s.contains(".") { s = s.replacingOccurrences(of: ".", with: " ") }   // The.Matrix.1999.1080p
        else if s.contains("..") == false, s.contains(".") { s = dotted(s) }
        var found = year
        s = stripBrackets(s, year: &found)
        s = s.replacingOccurrences(of: #"\s*-(yify|yts([. ]mx)?|rarbg|etrg|mkvcage|fgt|ntb|tgx|psa|evo|ntg|ion10|sparks|cmrg|galaxytv|eztv|ettv|rartv|mkvking|tigole|qxr|megusta|pahe)(?=[\s.\[\(]|$)"#, with: "", options: [.regularExpression, .caseInsensitive])   // an attached release group in the middle ("[2019]-TGx Season 5", "720p-EVO.S05E16")
        s = s.replacingOccurrences(of: #"[-.\s](yify|yts([. ]mx)?|rarbg|etrg|mkvcage|fgt|ntb|tgx|psa|evo|ntg|ion10|sparks|cmrg|galaxytv|eztv|ettv|rartv|mkvking|tigole|qxr|megusta|pahe)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])   // release group: "1080p-YIFY"
        s = s.replacingOccurrences(of: #"^\s*\|[A-Za-z0-9]{2,5}\|\s*"#, with: "", options: .regularExpression)       // "|FR| "
        s = s.replacingOccurrences(of: "|", with: " | ")
        // "Show.S03E17.1080p", "x265.S04E10": an episode marker glued to its neighbours with dots stands on its own, so the tail rules see it.
        s = s.replacingOccurrences(of: #"\.(?=S\d{1,2}E\d{1,3}\b)"#, with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"(\bS\d{1,2}E\d{1,3})\.(?=\S)"#, with: "$1 ", options: [.regularExpression, .caseInsensitive])
        var t = s.split(whereSeparator: \.isWhitespace).map(String.init)
        t = t.map { strongTags.contains($0.lowercased()) ? mark : $0 }
        // Surround-sound tag "5.1" / "7.1" (a name with dots reads it as "5" "1"): a tag, never part of a title, when something comes before it.
        var u: [String] = []
        var i = 0
        while i < t.count {
            let w = t[i].lowercased()
            if i > 0, ["5.1", "6.1", "7.1"].contains(w) { i += 1; continue }
            if i > 0, i + 1 < t.count, ["5", "6", "7"].contains(w), t[i + 1] == "1" { i += 2; continue }
            u.append(t[i]); i += 1
        }
        if !u.isEmpty { t = u }
        func isSep(_ x: String) -> Bool { ["-", "|", ":", "~", "/", mark].contains(x) }
        // Head: "IN:", "TELUGU |", "EN -", and a year that leads the name behind a separator ("2019 - Title").
        while let f = t.first {
            if t.count > 2, f.count == 4, let y = Int(f), (1900...2030).contains(y), t[1] == "-" || t[1] == "|" {
                if found == nil { found = y }
                t.removeFirst(2); continue
            }
            let word = f.trimmingCharacters(in: CharacterSet(charactersIn: ":-|")).lowercased()
            let endsSep = f.hasSuffix(":") || f.hasSuffix("|") || (f.hasSuffix("-") && f.count > 1 && !f.dropLast().isEmpty)
            let nextSep = t.count > 1 && isSep(t[1]) && t[1] != mark
            if isSep(f) { t.removeFirst(); continue }
            if (prefixes.contains(word) || languages.contains(word) || weakTags.contains(word)) && (endsSep || nextSep) && t.count > 1 { t.removeFirst(); if nextSep && !endsSep { t.removeFirst() }; continue }
            break
        }
        // Tail: separators, tags, languages after a separator or "dubbed", season markers, and a year that follows a tag (or equals the library's).
        var sawDub = false
        while t.count > 1, let l = t.last {
            let low = l.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.-:|"))
            let prev = t[t.count - 2]
            let prevLow = prev.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.-:|"))
            if isSep(l) || low.isEmpty { t.removeLast(); continue }
            if weakTags.contains(low) { if ["dubbed", "dub", "audio", "subbed", "sub", "subs"].contains(low) { sawDub = true }; t.removeLast(); continue }
            if languages.contains(low) && (isSep(prev) || sawDub || weakTags.contains(prevLow)) { t.removeLast(); continue }
            if low.range(of: #"^s\d{1,2}(e\d{1,3})?$"#, options: .regularExpression) != nil { t.removeLast(); continue }
            if low.range(of: #"^\d{1,2}x\d{1,3}$"#, options: .regularExpression) != nil { t.removeLast(); continue }                                            // 1x02
            if low.range(of: #"^\d{1,3}$"#, options: .regularExpression) != nil, ["episode", "ep", "episodio", "folge"].contains(prevLow), t.count > 2 { t.removeLast(2); continue }   // Episode 2
            if low.range(of: #"^\d{2,3}$"#, options: .regularExpression) != nil, prev == "-", t.count > 2 { t.removeLast(2); continue }   // "Naruto - 062"
            if low.range(of: #"^\d{1,2}$"#, options: .regularExpression) != nil, ["season", "series", "saison", "temporada"].contains(prevLow), t.count > 2 { t.removeLast(2); continue }
            if let y = Int(low), (1900...2030).contains(y), low.count == 4, y == year || weakTags.contains(prevLow) || languages.contains(prevLow) || prev == mark {
                if found == nil { found = y }
                t.removeLast(); continue
            }
            break
        }
        var text = t.filter { $0 != mark }.joined(separator: " ")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " -:|.,~/"))
        // "Matrix, The" -> "The Matrix"
        if let r = text.range(of: #",\s*(The|A|An)$"#, options: [.regularExpression, .caseInsensitive]) {
            let art = text[r].trimmingCharacters(in: CharacterSet(charactersIn: ", ")); text = art + " " + text[..<r.lowerBound]
        }
        // An episode title after the marker ("Some Show Season 2 Episode 5 Pilot"): the name ends where the marker starts, when a word comes before it.
        if let r = text.range(of: #"(?i)(?<=\S)\s+(?:(?:season|saison|temporada|staffel)\s*\d+|episode\s*\d+|s\d{1,2}\s?e\d{1,3})\b.*$"#, options: .regularExpression) { text = String(text[..<r.lowerBound]) }
        // A name made of brackets alone ("[REC] [2007]"): the first bracket group that is not a year is the title.
        if text.isEmpty, let m = original.range(of: #"[\(\[\{]([^\)\]\}]*[A-Za-z\p{L}][^\)\]\}]*)[\)\]\}]"#, options: .regularExpression) { text = String(original[m]).trimmingCharacters(in: CharacterSet(charactersIn: "()[]{} ")) }
        if text.isEmpty { text = original.trimmingCharacters(in: CharacterSet(charactersIn: " -:|.,~/")) }
        return Parsed(text: text, year: found)
    }

    /// A word run together with dots inside a name that has spaces ("KO.-.The.Delicious.Guys", "Show.Name.[2015] Season 5") reads as spaces; initials ("M.S.", "P.I.") stay.
    private static func dotted(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false).map { w -> String in
            let parts = w.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count >= 3 && parts.filter({ $0.count >= 2 }).count >= 2 && parts.filter({ $0.count == 1 }).count <= 1 { return parts.joined(separator: " ") }
            // A dot that glues a year, a quality tag or a language prefix to the name ("Chiquititas.2013", "Tomorrow.x265.5.1.10bit", "JP:.Bleach") is a space.
            guard parts.count >= 2, parts.contains(where: { $0.count >= 2 && $0.contains(where: \.isLetter) }) else { return String(w) }
            let glued = parts.contains { p in
                if p.count == 4, let y = Int(p), (1900...2030).contains(y) { return true }
                return strongTags.contains(p.lowercased())
            } || w.contains(":.")
            return glued ? parts.joined(separator: " ") : String(w)
        }.joined(separator: " ")
    }

    /// Stands where a bracket group or a quality tag was removed, so the rules at the end of a name can still see it.
    private static let mark = "\u{1}"

    /// Removes (...), [...] and {...} groups; the first year inside one is remembered. A leading number in brackets that is not a year ("(500) Days of Summer") stays.
    private static func stripBrackets(_ s: String, year: inout Int?) -> String {
        var out = "", depthOpen: Character? = nil, buf = ""
        let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
        for ch in s {
            if let open = depthOpen {
                if ch == pairs[open] {
                    let inner = buf.trimmingCharacters(in: .whitespaces)
                    let isYear = inner.count == 4 && Int(inner).map { (1900...2030).contains($0) } == true
                    if isYear, year == nil { year = Int(inner) }
                    if out.trimmingCharacters(in: .whitespaces).isEmpty && !inner.isEmpty && inner.allSatisfy(\.isNumber) && !isYear { out += "(\(inner))" } else { out += " \(mark) " }
                    depthOpen = nil; buf = ""
                } else { buf.append(ch) }
            } else if pairs[ch] != nil { depthOpen = ch } else { out.append(ch) }
        }
        if depthOpen != nil { out += " \(mark) " }                // an unclosed bracket drops its tail
        return out
    }
}
