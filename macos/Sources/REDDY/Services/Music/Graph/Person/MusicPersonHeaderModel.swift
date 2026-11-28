import Foundation

// The header of a person page as plain data: names in both scripts, life dates, the short bio line with its source, the portrait with its credit,
// the disambiguator line. Everything comes from the snapshot, its aliases and its attributes; a field with no data is nil and the page leaves it out.

enum MusicPersonText {
    /// True when every letter of the text is Latin script (digits, spaces and punctuation are neutral). Empty text counts as Latin.
    static func isLatin(_ text: String) -> Bool {
        for s in text.unicodeScalars where CharacterSet.letters.contains(s) {
            switch s.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: continue
            default: return false
            }
        }
        return true
    }

    /// Up to two letters for the circle that stands in for a missing portrait. Works for any script (first letter of the first two words).
    static func initials(_ name: String) -> String {
        name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }
}

/// The two spellings of a name the header shows: the display name and, when the person is also known in another script, that other spelling.
struct MusicPersonNames: Hashable, Sendable {
    var display: String
    /// The same name in the other script ("राज कपूर" under "Raj Kapoor"), nil when the graph knows none.
    var otherScript: String?

    /// `display` is the entity's own name. The aliases are the entity's own (the store keeps them per entity), so the other spelling is simply the
    /// first alias in the opposite script, preferring a primary one. (A transliteration check is not used: schwa deletion makes "कपूर" and "Kapoor" fold apart.)
    static func resolve(snapshot s: MusicEntitySnapshot, aliases: [NameAlias], languages: [String] = []) -> MusicPersonNames {
        let displayIsLatin = MusicPersonText.isLatin(s.name)
        let candidates = aliases.filter { a in a.text != s.name && !a.text.isEmpty && MusicPersonText.isLatin(a.text) != displayIsLatin }
        // The other spelling is in a language that is the person's or the reader's: the languages asked for first (the person's native language, once known), then the entity's own
        // language, then the languages the reader uses. A spelling that is in some other language (the Russian or Thai form a wiki happens to store) is never picked for being first.
        let wanted = (languages + [s.lang].compactMap { $0 } + MusicPersonNames.readerLanguages).map { $0.lowercased() }
        for l in wanted { if let a = candidates.first(where: { ($0.lang ?? "").lowercased() == l }) { return MusicPersonNames(display: s.name, otherScript: a.text) } }
        // A spelling nobody tagged with a language says nothing against itself: the primary one, else the first.
        let untagged = candidates.filter { ($0.lang ?? "").isEmpty }
        let pick = untagged.first(where: \.isPrimary) ?? untagged.first
        return MusicPersonNames(display: s.name, otherScript: pick?.text)
    }

    /// The language codes the reader uses ("en", "hi"...), from the system's preferred languages.
    static var readerLanguages: [String] {
        Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
    }
}

/// "1924–1988", "b. 1924", "d. 1988"; for a group "Active 1949–1971" or "Since 1949" (the label words come from the page).
struct MusicPersonLife: Hashable, Sendable {
    enum Shape: Hashable, Sendable { case span(Int, Int), born(Int), died(Int), activeSpan(Int, Int), since(Int), until(Int) }
    var shape: Shape

    static func resolve(snapshot s: MusicEntitySnapshot) -> MusicPersonLife? {
        let y = s.year.flatMap { (1000...2999).contains($0) ? $0 : nil }
        let e = s.yearEnd.flatMap { (1000...2999).contains($0) ? $0 : nil }
        if s.kind == .group {
            switch (y, e) {
            case let (a?, b?) where b >= a: return MusicPersonLife(shape: .activeSpan(a, b))
            case let (a?, nil): return MusicPersonLife(shape: .since(a))
            case let (nil, b?): return MusicPersonLife(shape: .until(b))
            default: return nil
            }
        }
        switch (y, e) {
        case let (a?, b?) where b >= a: return MusicPersonLife(shape: .span(a, b))
        case let (a?, nil): return MusicPersonLife(shape: .born(a))
        case let (nil, b?): return MusicPersonLife(shape: .died(b))
        default: return nil
        }
    }
}

/// The one line under the name and where it came from. `required` is true when the source's licence asks for the credit to be shown.
struct MusicPersonBio: Hashable, Sendable {
    var text: String
    var source: String
    var licence: String?
    var attributionRequired: Bool

    /// The text is the entity's `bio` (a Wikipedia extract or TMDB biography) when a source wrote one, else its `description` (Wikidata's short
    /// description, CC0). `attrs["bioSource"]` names the source; without it a `bio` is not shown (we do not guess whose words they are).
    static func resolve(snapshot s: MusicEntitySnapshot, maxLength: Int = 280) -> MusicPersonBio? {
        func clean(_ t: String?) -> String? {
            guard let t = t?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t.count > maxLength ? String(t.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…" : t
        }
        if let bio = clean(s.attrs["bio"]), let src = s.attrs["bioSource"]?.lowercased() {
            switch src {
            case "wikipedia": return MusicPersonBio(text: bio, source: "Wikipedia", licence: "CC BY-SA", attributionRequired: true)
            case "tmdb": return MusicPersonBio(text: bio, source: "TMDB", licence: nil, attributionRequired: true)
            case "wikidata": return MusicPersonBio(text: bio, source: "Wikidata", licence: "CC0", attributionRequired: false)
            default: break
            }
        }
        if let d = clean(s.attrs["description"]) { return MusicPersonBio(text: d, source: "Wikidata", licence: "CC0", attributionRequired: false) }
        return nil
    }
}

/// Where a portrait comes from and what must be shown with it.
struct MusicPortraitRef: Hashable, Sendable {
    enum Origin: Hashable, Sendable { case commons(file: String), tmdb, provider, other }
    var url: URL
    var origin: Origin
    /// "Wikimedia Commons", "TMDB" or nil for a provider's own picture.
    var creditSource: String?
    /// The Commons file page, for the licence and author.
    var creditURL: URL?

    /// `commons:File.jpg` (Wikidata P18), an https address (TMDB, a provider), or nothing. Anything else is ignored (no initials-only guessing here: the page shows initials).
    static func resolve(imageRef: String?, width: Int = 400) -> MusicPortraitRef? {
        guard let ref = imageRef?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty else { return nil }
        if ref.hasPrefix("commons:") {
            let file = String(ref.dropFirst("commons:".count))
            guard !file.isEmpty, let url = commonsThumbnailURL(file: file, width: width) else { return nil }
            let page = URL(string: "https://commons.wikimedia.org/wiki/File:" + (file.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file))
            return MusicPortraitRef(url: url, origin: .commons(file: file), creditSource: "Wikimedia Commons", creditURL: page)
        }
        guard let url = URL(string: ref), url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("tmdb.org") { return MusicPortraitRef(url: url, origin: .tmdb, creditSource: "TMDB", creditURL: nil) }
        if host.hasSuffix("wikimedia.org") { return MusicPortraitRef(url: url, origin: .other, creditSource: "Wikimedia Commons", creditURL: nil) }
        return MusicPortraitRef(url: url, origin: .provider, creditSource: nil, creditURL: nil)
    }

    /// A Commons thumbnail address from a file name alone (`Special:FilePath`, the same form the metadata layer uses).
    static func commonsThumbnailURL(file: String, width: Int) -> URL? {
        var c = URLComponents(string: "https://commons.wikimedia.org/wiki/Special:FilePath/")
        c?.path = "/wiki/Special:FilePath/" + file.replacingOccurrences(of: " ", with: "_")
        c?.queryItems = [URLQueryItem(name: "width", value: String(width))]
        return c?.url
    }

    /// The licence record of a Commons picture, when the page has fetched one (author, licence short name, whether the licence asks for a credit).
    struct Licence: Hashable, Sendable {
        var author: String?
        var licence: String?
        var attributionRequired: Bool
        init(author: String? = nil, licence: String? = nil, attributionRequired: Bool = false) { self.author = author; self.licence = licence; self.attributionRequired = attributionRequired }
    }

    /// The line under the portrait: author, licence and source when we have the licence record, else just the source for the origins that require naming one.
    func creditLine(licence: Licence?) -> String? {
        if let r = licence {
            let parts = [r.author, r.licence, creditSource].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty, r.attributionRequired || r.licence != nil { return parts.joined(separator: " · ") }
        }
        return creditSource
    }
}

/// Everything the header shows, built once from the entity and the role summary.
struct MusicPersonHeaderData: Hashable, Sendable {
    var id: MusicEntityID
    var names: MusicPersonNames
    var isGroup: Bool
    var groupKind: String?
    var life: MusicPersonLife?
    var bio: MusicPersonBio?
    var portrait: MusicPortraitRef?
    var initials: String
    var disambiguator: String?
    var provisional: Bool
    /// The Wikidata item the person is linked to and the article titles of its wikis, for the opening of the Wikipedia article and the portrait.
    var wikidataID: String? = nil
    var sitelinks: String? = nil
    var tmdbPersonID: String? = nil
    /// Every spelling of the name the graph holds, for choosing the one in the person's own script.
    var aliases: [NameAlias] = []
    var entityLanguage: String? = nil

    static func build(snapshot s: MusicEntitySnapshot, aliases: [NameAlias], externalIDs: [ExternalID] = []) -> MusicPersonHeaderData {
        MusicPersonHeaderData(id: s.id, names: .resolve(snapshot: s, aliases: aliases), isGroup: s.kind == .group, groupKind: s.kind == .group ? s.subkind : nil,
                              life: .resolve(snapshot: s), bio: .resolve(snapshot: s), portrait: .resolve(imageRef: s.imageRef),
                              initials: MusicPersonText.initials(s.name), disambiguator: MusicPersonDisambiguation.line(for: s), provisional: s.provisional,
                              wikidataID: externalIDs.first(where: { $0.scheme == .wikidata })?.value, sitelinks: s.attrs["sitelinks"], tmdbPersonID: externalIDs.first(where: { $0.scheme == .tmdbPerson })?.value, aliases: aliases, entityLanguage: s.lang)
    }
}
