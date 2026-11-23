import Foundation

/// The shared name and id rules of channel-to-guide matching. Pure; the Kotlin port matches these byte for byte through `epg/fixtures/mapping-cases.json`.
enum ChannelNormalizer {
    /// A channel name reduced for comparison. `variant` is "+1", "+2"... (time-shifted copies) or "": a variant never matches a different variant.
    struct NameKey: Sendable, Hashable {
        var base: String
        var variant: String
        var countryPrefix: String?
        var tokens: [String] { base.split(separator: " ").map(String.init) }
        var isEmpty: Bool { base.isEmpty }
        /// Comparison key used for equality lookups.
        var key: String { variant.isEmpty ? base : base + " " + variant }
    }

    /// Words that only say how a channel is delivered, not which channel it is.
    static let qualityTokens: Set<String> = ["hd", "fhd", "uhd", "4k", "sd", "hevc", "h265", "h264", "1080p", "720p", "2160p", "50fps", "60fps", "hdr"]
    /// Country codes accepted as a "UK | Name" style prefix (only these, so "AMC | ..." or "ESPN: ..." keep their first word).
    static let prefixCodes: Set<String> = ["uk", "gb", "us", "usa", "ca", "au", "nz", "ie", "de", "at", "ch", "fr", "be", "nl", "lu", "es", "pt", "it", "gr", "tr", "ru", "ua", "pl", "cz", "sk", "hu", "ro", "bg", "rs", "hr", "si", "ba", "mk", "al", "se", "no", "dk", "fi", "is", "ee", "lv", "lt", "in", "pk", "bd", "lk", "np", "ae", "sa", "qa", "kw", "eg", "ma", "dz", "tn", "il", "ir", "iq", "jo", "lb", "sy", "cn", "jp", "kr", "tw", "hk", "sg", "my", "th", "vn", "id", "ph", "br", "ar", "mx", "co", "cl", "pe", "ve", "za", "ng", "ke", "gh", "et", "cu", "do", "pr", "uy", "py", "bo", "ec"]

    /// A trailing word that only names which feed of a channel it is ("CNN East", "BBC One London"). Used as a second try, never to merge two names the guide lists apart.
    static let feedWords: Set<String> = ["east", "west", "north", "south", "london", "live"]
    /// The name without its trailing feed word, or nil when it has none (or nothing else would be left).
    static func withoutFeedWord(_ k: NameKey) -> NameKey? {
        let t = k.tokens
        guard t.count >= 2, let l = t.last, feedWords.contains(l) else { return nil }
        var o = k; o.base = t.dropLast().joined(separator: " "); return o
    }

    static func foldedLowercase(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// Splits letters and digits into space separated words; everything else is a separator. "&" is "and".
    static func words(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var lastSpace = true
        for u in foldedLowercase(s).replacingOccurrences(of: "&", with: " and ").unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) { out.append(u); lastSpace = false }
            else if !lastSpace { out.append(" "); lastSpace = true }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    private static let plusVariant = try! NSRegularExpression(pattern: #"(?:^|[\s(\[])(?:\+|plus\s?)(\d{1,2})(?:h|\s?hours?)?(?=$|[\s)\]])"#, options: [.caseInsensitive])

    static func name(_ raw: String) -> NameKey {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var prefix: String?
        // "UK | BBC One", "[UK] BBC One", "UK: BBC One", "UK - BBC One"
        func isDelimiter(_ i: String.Index) -> Bool {
            let c = s[i]
            if "|:»>])".contains(c) { return true }
            // A bare hyphen is part of a name ("Al-Jazeera"); only " - " separates a prefix.
            guard c == "-" || c == "–", i > s.startIndex, s[s.index(before: i)] == " ", s.index(after: i) < s.endIndex, s[s.index(after: i)] == " " else { return false }
            return true
        }
        // Providers sometimes stack two ("US| US: MTV"): up to two are read, the first one is kept.
        for _ in 0..<2 {
            guard let r = s.indices.first(where: isDelimiter), s.distance(from: s.startIndex, to: r) <= 6 else { break }
            let head = s[s.startIndex..<r].trimmingCharacters(in: CharacterSet(charactersIn: " []()"))
            guard head.count >= 2, head.count <= 3, prefixCodes.contains(head.lowercased()), head.allSatisfy({ $0.isLetter }) else { break }
            if prefix == nil { prefix = head.lowercased() == "gb" ? "uk" : (head.lowercased() == "usa" ? "us" : head.lowercased()) }
            s = String(s[s.index(after: r)...])
        }
        // A copy marker is not part of the name: "ESPN HD (backup)", "[Alt 2]", "CNN (mirror)".
        s = s.replacingOccurrences(of: #"[\(\[]\s*(?:backup|back-up|alt|alternate|mirror|raw|reserve)\s*\d{0,2}\s*[\)\]]"#, with: " ", options: [.regularExpression, .caseInsensitive])
        var variant = ""
        let ns = s as NSString
        if let m = plusVariant.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            variant = "+" + ns.substring(with: m.range(at: 1))
            s = ns.replacingCharacters(in: m.range, with: " ")
        }
        let cleaned = words(s).split(separator: " ").filter { !qualityTokens.contains(String($0)) }.joined(separator: " ")
        return NameKey(base: cleaned, variant: variant, countryPrefix: prefix)
    }

    /// An id split into the part that names the channel and its country suffix: "BBCOne.uk@SD" -> ("bbcone", "uk"). A feed suffix (@SD, @HD, @East) is dropped.
    static func idParts(_ raw: String) -> (base: String, country: String?) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let at = s.firstIndex(of: "@") { s = String(s[..<at]) }
        s = s.replacingOccurrences(of: " ", with: "")
        if let dot = s.lastIndex(of: "."), s.distance(from: dot, to: s.endIndex) == 3 {
            let cc = String(s[s.index(after: dot)...])
            if cc.allSatisfy({ $0.isLetter }) { return (String(s[..<dot]), cc) }
        }
        return (s, nil)
    }

    /// Two ids name the same channel when their bases are equal and their country suffixes do not disagree.
    static func idsEqualNormalised(_ a: String, _ b: String) -> Bool {
        let x = idParts(a), y = idParts(b)
        guard !x.base.isEmpty, x.base == y.base else { return false }
        if let c = x.country, let d = y.country { return c == d }
        return true
    }

    /// "uk"/"gb" and "us"/"usa" are one country.
    static func countryKey(_ raw: String?) -> String? {
        guard let r = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !r.isEmpty else { return nil }
        switch r { case "gb", "uk": return "uk"; case "usa", "us": return "us"; default: return r }
    }
    static func languageKey(_ raw: String?) -> String? {
        guard let r = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !r.isEmpty else { return nil }
        return String((r.split(separator: "-").first ?? Substring(r)).prefix(2))
    }
}
