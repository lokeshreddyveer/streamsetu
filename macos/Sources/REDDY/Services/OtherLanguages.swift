import Foundation

/// "Other languages": the same film or show in the other languages (and copies) the library holds, so the person can switch version.
/// Providers list a dub as its own title, and most say the language only in the folder: "Leo (2023) (Tamil) FHD", "Leo 2023 Hindi",
/// or "Leo (2023)" in "TELUGU | GENERAL" or "SOUTH INDIAN | HINDI DUBBED". The title matching starts from SimilarTitles.identity, so
/// there is one notion of "the same title" in the app. Shared by the Mac and the iPhone/iPad apps.
enum OtherLanguages {
    /// A title to compare, with what is needed beside it: its folder's name (it often carries the language) and which playlist it is
    /// in (only to recognise the same entry in two copies of one playlist; no playlist is ever named in the row).
    struct Candidate: Sendable {
        let item: LibraryItem
        let folder: String?
        let playlistID: UUID
    }

    /// One version, as the row shows it.
    struct Version: Identifiable, Equatable, Sendable {
        let item: LibraryItem
        /// The language in English ("Hindi"), or nil when neither the title nor the folder names one.
        let language: String?
        /// The language is a dub (the folder says "HINDI DUBBED" or "DUBBED IN HINDI").
        let dubbed: Bool
        /// When the language is unknown: the folder's own words in plain case ("Indian", "Multi language").
        let folderLabel: String?
        /// "4K", "FHD", "HD", "SD" or "CAM"; nil when the title says nothing.
        let quality: String?
        /// The chip's second line, chosen so that versions of one language can be told apart (see `captions`).
        let caption: String?
        let isCurrent: Bool
        var id: String { item.id }

        /// The chip's first line: the language, or the folder's words, or the quality.
        var title: String { language ?? folderLabel ?? quality ?? "Another copy" }
        /// The badge in the corner, unless the quality is already the title.
        var badge: String? { title == quality ? nil : quality }

        /// What VoiceOver reads: "Hindi, dubbed, FHD".
        var accessibilityLabel: String {
            ([title] + [dubbed ? "dubbed" : nil, caption == "Dubbed" || caption == OtherLanguages.nativeNames[title] ? nil : caption,
                        quality == title ? nil : quality].compactMap { $0 }).joined(separator: ", ")
        }
    }

    // MARK: Languages

    /// Every language a title or folder may name, by the word used, with the name shown for it.
    static let languageNames: [String: String] = {
        var out: [String: String] = [:]
        for w in ["english", "hindi", "tamil", "telugu", "kannada", "malayalam", "urdu", "punjabi", "bengali", "marathi", "gujarati", "arabic", "spanish",
                  "french", "german", "korean", "japanese", "chinese", "turkish", "russian", "italian", "portuguese", "thai", "indonesian", "odia",
                  "assamese", "nepali", "sinhala", "persian", "hebrew", "vietnamese", "tagalog", "malay", "pashto"] { out[w] = w.capitalized }
        out["bangla"] = "Bengali"; out["farsi"] = "Persian"; out["filipino"] = "Tagalog"; out["oriya"] = "Odia"; out["odiya"] = "Odia"
        return out
    }()

    /// Each language's name in its own script, for the chip's second line.
    static let nativeNames: [String: String] = [
        "Telugu": "తెలుగు", "Hindi": "हिन्दी", "Tamil": "தமிழ்", "Malayalam": "മലയാളം", "Kannada": "ಕನ್ನಡ", "Bengali": "বাংলা", "Marathi": "मराठी",
        "Gujarati": "ગુજરાતી", "Punjabi": "ਪੰਜਾਬੀ", "Urdu": "اردو", "Odia": "ଓଡ଼ିଆ", "Assamese": "অসমীয়া", "Nepali": "नेपाली", "Sinhala": "සිංහල",
        "Arabic": "العربية", "Persian": "فارسی", "Hebrew": "עברית", "Pashto": "پښتو", "Spanish": "Español", "French": "Français", "German": "Deutsch",
        "Italian": "Italiano", "Portuguese": "Português", "Russian": "Русский", "Turkish": "Türkçe", "Korean": "한국어", "Japanese": "日本語",
        "Chinese": "中文", "Thai": "ไทย", "Indonesian": "Bahasa Indonesia", "Vietnamese": "Tiếng Việt", "Malay": "Bahasa Melayu",
    ]

    private static let subtitleWords: Set<String> = ["subtitles", "subtitle", "subs", "sub", "subbed"]
    private static let tagPattern = try! NSRegularExpression(pattern: #"[\(\[]\s*([A-Za-z]+)\s*[\)\]]"#)

    private static func words(_ s: String) -> [String] { SimilarTitles.normalize(s).split(separator: " ").map(String.init) }

    /// The language of a title, in this order: a "(Lang)" or "[Lang]" tag in the title; a dub named by the folder ("HINDI DUBBED",
    /// "DUBBED IN HINDI"); the first language word of the folder that is not a subtitle language ("ENGLISH | ARABIC SUBTITLES" is
    /// English); a language word anywhere in the title. With none, the folder's own words are kept as a label.
    static func languageInfo(title: String, folder: String?) -> (language: String?, dubbed: Bool, folderLabel: String?) {
        for m in tagPattern.matches(in: title, range: NSRange(title.startIndex..., in: title)) {
            if let r = Range(m.range(at: 1), in: title), let name = languageNames[title[r].lowercased()] { return (name, false, nil) }
        }
        let f = folder.map(words) ?? []
        for (i, w) in f.enumerated() where w == "dubbed" {
            if i > 0, let name = languageNames[f[i - 1]] { return (name, true, nil) }
            if i + 2 < f.count, f[i + 1] == "in", let name = languageNames[f[i + 2]] { return (name, true, nil) }
        }
        for (i, w) in f.enumerated() {
            guard let name = languageNames[w] else { continue }
            if i + 1 < f.count, subtitleWords.contains(f[i + 1]) { continue }
            return (name, false, nil)
        }
        if let name = words(title).lazy.compactMap({ languageNames[$0] }).first { return (name, false, nil) }
        return (nil, false, folder.flatMap(folderLabel))
    }

    private static let genericFolderWords: Set<String> = ["general", "movies", "movie", "films", "film", "series", "shows", "show", "tv", "vod", "all",
                                                          "new", "latest", "hd", "fhd", "4k", "uhd", "sd", "the", "and"]

    /// "INDIAN | GENERAL" gives "Indian"; "(MULTI LANGUAGE)" gives "Multi language". Nil when nothing is left.
    static func folderLabel(_ folder: String) -> String? {
        for part in folder.split(whereSeparator: { "|:/–".contains($0) }) {
            let kept = words(String(part)).filter { !genericFolderWords.contains($0) }
            guard !kept.isEmpty else { continue }
            let text = kept.joined(separator: " ")
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        return nil
    }

    // MARK: Matching

    private static let leadingArticles: Set<String> = ["the", "a", "an"]

    /// The key two titles must share to be versions of each other: the identity (no year, quality or language), without a leading
    /// article, "and" or "&", and without any language word.
    static func matchKey(_ title: String) -> String {
        var w = SimilarTitles.identity(title).split(separator: " ").map(String.init).filter { $0 != "and" && $0 != "dubbed" && languageNames[$0] == nil }
        if let first = w.first, leadingArticles.contains(first), w.count > 1 { w.removeFirst() }
        return w.joined(separator: " ")
    }

    private static let yearInTitle = IdentityDerive.yearInTitle
    private static let cinemaCopy = try! NSRegularExpression(pattern: #"\b(cam|hdcam|hd-cam|camrip|ts|hdts|telesync|tc|telecine)\b"#, options: .caseInsensitive)

    /// The year from the metadata, or a 19xx/20xx written in the title.
    static func year(_ item: LibraryItem) -> Int? {
        if let y = item.year, y > 0 { return y }
        let t = item.title
        guard let m = yearInTitle.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range(at: 1), in: t) else { return nil }
        return Int(t[r])
    }

    /// The picture quality the title names, from the existing quality tags; a cinema recording is "CAM".
    static func quality(_ title: String, _ folder: String?) -> String? {
        let text = [title, folder].compactMap { $0 }.joined(separator: " ")
        if cinemaCopy.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return "CAM" }
        return MetadataNormalizer.qualityLabel(MetadataNormalizer.normalize(title))
    }

    private static func rating(_ i: LibraryItem) -> String? {
        let r: String? = { switch i { case .movie(let m): m.rating; case .series(let s): s.rating } }()
        guard let r, let v = Double(r), v > 0 else { return nil }
        return r
    }

    private static func providerID(_ i: LibraryItem) -> String { switch i { case .movie(let m): m.providerID; case .series(let s): s.providerID } }

    /// How many independent facts say two titles are the same film: running times within 8 %, the same rating, the same start of the
    /// story, or the same genres.
    static func corroboration(_ a: LibraryItem, _ b: LibraryItem) -> Int {
        var n = 0
        if let x = a.durationSeconds, let y = b.durationSeconds, x > 0, y > 0, abs(x - y) <= max(x, y) * 0.08 { n += 1 }
        if let x = rating(a), let y = rating(b), x == y { n += 1 }
        let ox = a.overview.map { String(SimilarTitles.normalize($0).prefix(40)) } ?? "", oy = b.overview.map { String(SimilarTitles.normalize($0).prefix(40)) } ?? ""
        if ox.count >= 20, ox == oy { n += 1 }
        let gx = SimilarTitles.genreSet(a.genre), gy = SimilarTitles.genreSet(b.genre)
        if !gx.isEmpty, gx == gy { n += 1 }
        return n
    }

    /// Whether `c` is another version of `target`: the same kind and key, and years that agree. Providers date one film a year apart in
    /// different languages, so a year's difference is accepted when another fact agrees (two facts for a short one-word title such as
    /// "Stolen" or "Tuesday"); a missing year is accepted for a title of two words or more, or when the facts agree.
    static func sameTitle(_ target: LibraryItem, _ c: LibraryItem, key: String) -> Bool {
        guard c.isSeries == target.isSeries, matchKey(c.title) == key else { return false }
        let short = !key.contains(" ") && key.count <= 7
        let needed = short ? 2 : 1
        switch (year(target), year(c)) {
        case let (x?, y?):
            if x == y { return true }
            return abs(x - y) == 1 && corroboration(target, c) >= needed
        default:
            return key.contains(" ") || corroboration(target, c) >= needed
        }
    }

    // MARK: Versions

    private struct Kept {
        let c: Candidate
        let language: String?
        let dubbed: Bool
        let folderLabel: String?
        let quality: String?
        func same(_ o: Kept) -> Bool { language == o.language && dubbed == o.dubbed && quality == o.quality && folderLabel == o.folderLabel }
    }

    /// The versions of `target` found in `pool`, the open one first; empty when there is no other version. `preferred` is the language
    /// the person listens to (from Settings), shown right after the open one's own language. Pure, so it can be tested.
    static func versions(of target: Candidate, in pool: [Candidate], preferred: String? = nil) -> [Version] {
        let key = matchKey(target.item.title)
        guard !key.isEmpty else { return [] }
        func kept(_ c: Candidate) -> Kept {
            let info = languageInfo(title: c.item.title, folder: c.folder)
            return Kept(c: c, language: info.language, dubbed: info.dubbed, folderLabel: info.folderLabel, quality: quality(c.item.title, c.folder))
        }
        var list = [kept(target)]
        // The open title's own playlist is looked at first, so a twin elsewhere is recognised as one.
        let matches = pool.filter { $0.item.id != target.item.id && sameTitle(target.item, $0.item, key: key) }
            .sorted { ($0.playlistID == target.playlistID ? 0 : 1) < ($1.playlistID == target.playlistID ? 0 : 1) }
        // Two playlists with the same content: an entry whose twin (same title, year and folder, or the same provider entry with the
        // same length) was already seen in another playlist is hidden, whether or not that twin was shown.
        func signatures(_ c: Candidate) -> [String] {
            ["t|\(c.item.title)|\(year(c.item) ?? 0)|\(c.folder ?? "")", "p|\(providerID(c.item))|\(c.item.durationSeconds ?? -1)"]
        }
        var seen: [String: UUID] = [:]
        for sig in signatures(target) { seen[sig] = target.playlistID }
        for c in matches {
            let k = kept(c)
            let sigs = signatures(c)
            let twin = sigs.contains { sig in seen[sig].map { $0 != c.playlistID } ?? false }
            for sig in sigs where seen[sig] == nil { seen[sig] = c.playlistID }
            if twin { continue }
            // One version per language, dub, quality and folder: another copy of the same in the same folder is not shown.
            if list.contains(where: { $0.same(k) && $0.c.folder == c.folder }) { continue }
            list.append(k)
        }
        guard list.count > 1 else { return [] }

        let versions = list.map { k in
            Version(item: k.c.item, language: k.language, dubbed: k.dubbed, folderLabel: k.folderLabel, quality: k.quality, caption: nil,
                    isCurrent: k.c.item.id == target.item.id)
        }
        let first = versions[0]
        // After the open one: other copies in its language, then the language the person listens to, then the rest alphabetically, best quality first.
        func rank(_ v: Version) -> (Int, String, Int, Double) {
            let group = v.language != nil && v.language == first.language ? 0 : (v.language != nil && v.language == preferred ? 1 : 2)
            return (group, v.title, -MetadataNormalizer.qualityRank(v.quality), v.item.durationSeconds ?? 0)
        }
        let ordered = [first] + versions.dropFirst().sorted { rank($0) < rank($1) }
        return zip(ordered, captions(for: ordered, folders: Dictionary(list.map { ($0.c.item.id, $0.c.folder) }, uniquingKeysWith: { a, _ in a }))).map { v, caption in
            Version(item: v.item, language: v.language, dubbed: v.dubbed, folderLabel: v.folderLabel, quality: v.quality, caption: caption, isCurrent: v.isCurrent)
        }
    }

    /// The second line of each chip, in this order: "Dubbed" for a dub; the language in its own script for the first version of a
    /// language; for further versions of the same language, the folder's own words without the language ("TELUGU | 2026" gives "2026");
    /// then the quality and running time ("FHD · 1h 48m"); finally "Version 2". A line already used by a chip with the same first line is
    /// not used again.
    static func captions(for versions: [Version], folders: [String: String?]) -> [String?] {
        var used: [String: Set<String>] = [:]
        var seenLanguage: [String: Int] = [:]
        return versions.map { v in
            let n = (seenLanguage[v.title] ?? 0) + 1
            seenLanguage[v.title] = n
            var options: [String?] = []
            if v.dubbed { options.append("Dubbed") }
            if n == 1, let language = v.language, let native = nativeNames[language], native != language { options.append(native) }
            if n == 1, v.language == nil || nativeNames[v.language ?? ""] == nil { options.append(nil) }
            if let folder = folders[v.item.id] ?? nil { options.append(cleanFolder(folder)) }
            let length = v.item.durationSeconds.flatMap { $0 > 0 ? DurationFormatter.short($0) : nil }
            options.append([v.badge, length].compactMap { $0 }.joined(separator: " · "))
            options.append(n == 1 ? "Another version" : "Version \(n)")
            for o in options {
                guard let o else { if n == 1 { return nil } else { continue } }
                guard !o.isEmpty, !(used[v.title]?.contains(o) ?? false) else { continue }
                used[v.title, default: []].insert(o)
                return o
            }
            return nil
        }
    }

    private static let qualityWords: Set<String> = ["fhd", "hd", "uhd", "sd", "4k", "hdr", "cam"]

    /// A folder's own words without the language or "dubbed": "ENGLISH | FHD 2025" gives "FHD 2025", "TAMIL | GENERAL" gives "General",
    /// "ENGLISH 1999-2020" gives "1999–2020". Nil when nothing is left.
    static func cleanFolder(_ folder: String) -> String? {
        let tokens = folder.replacingOccurrences(of: "|", with: " ").split(separator: " ").map(String.init).filter { token in
            let w = SimilarTitles.normalize(token)
            return !w.isEmpty && languageNames[w] == nil && w != "dubbed"
        }
        guard !tokens.isEmpty else { return nil }
        let text = tokens.map { t -> String in
            let w = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()[]:-–"))
            return qualityWords.contains(w) ? w.uppercased() : t.lowercased()
        }.joined(separator: " ")
            .replacingOccurrences(of: #"(\d)\s*-\s*(\d)"#, with: "$1–$2", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–:()[]"))
        guard let firstLetter = text.first else { return nil }
        return firstLetter.uppercased() + text.dropFirst()
    }

    /// The open version in words, for the pill under a title: "Hindi · Dubbed · FHD". Nil when the title and folder say nothing.
    static func versionLabel(title: String, folder: String?) -> String? {
        let info = languageInfo(title: title, folder: folder)
        let parts = [info.language ?? info.folderLabel, info.dubbed ? "Dubbed" : nil, quality(title, folder)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The preferred audio language from Settings ("te", "tel" or "Telugu") as the English name used on the chips.
    static func preferredName(_ setting: String) -> String? {
        let s = setting.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let name = languageNames[s.lowercased()] { return name }
        return Locale(identifier: "en").localizedString(forLanguageCode: s).flatMap { languageNames[$0.lowercased()] }
    }
}

/// Finds the other versions of an open title across every playlist on the device (the catalog's search covers them all in one query).
struct OtherLanguagesService: Sendable {
    let catalog: CatalogRepository
    var preferredLanguage = ""

    func versions(of item: LibraryItem) -> [OtherLanguages.Version] {
        let words = OtherLanguages.matchKey(item.title)
        guard !words.isEmpty else { return [] }
        let found: [LibraryItem]
        switch item {
        case .movie: found = ((try? catalog.movies(VODQuery(search: words, sort: .recentlyAdded, limit: 400))) ?? []).map { .movie($0) }
        case .series: found = ((try? catalog.series(VODQuery(search: words, sort: .recentlyAdded, limit: 400))) ?? []).map { .series($0) }
        }
        func candidate(_ i: LibraryItem) -> OtherLanguages.Candidate { .init(item: i, folder: i.categoryName, playlistID: i.sourceID) }
        return OtherLanguages.versions(of: candidate(item), in: found.map(candidate), preferred: OtherLanguages.preferredName(preferredLanguage))
    }
}
