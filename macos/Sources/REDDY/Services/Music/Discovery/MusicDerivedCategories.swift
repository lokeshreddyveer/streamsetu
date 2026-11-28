import Foundation

// What Explore and Home offer as language, genre and mood tiles is DERIVED, never listed by the app: languages come from the device's preferred
// languages, from the person's own plays and likes, and from the songs of the chosen country's charts; genres come from the source's own category
// lists and from the genres the person's library states. A source that returns nothing and an empty library give an empty list: no fallback.

// MARK: - Language names (codes to names through Locale only)

/// Turns a language code or a source's wording ("te", "Telugu", "telugu") into one stable key (the lower-case English name) and the name in the person's language.
enum MusicLanguageNames {
    private static let english = Locale(identifier: "en")

    /// English name to ISO code, read from the system's own language list (nothing is typed in here). The shortest code wins when two share a name.
    private static let codeByEnglishName: [String: String] = {
        var out: [String: String] = [:]
        for c in Locale.LanguageCode.isoLanguageCodes {
            let id = c.identifier
            guard let n = english.localizedString(forLanguageCode: id)?.lowercased(), !n.isEmpty, n != id.lowercased() else { continue }
            if let have = out[n], have.count <= id.count { continue }
            out[n] = id
        }
        return out
    }()

    /// The two-letter or three-letter base code of a language tag ("te-IN" gives "te"), or nil.
    static func baseCode(_ tag: String) -> String? {
        let t = tag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return Locale.Language(identifier: t).languageCode?.identifier
    }

    /// A language's name in the app's language (not the device's): Explore and the pages around it follow the app's setting.
    nonisolated static func displayName(code: String) -> String? {
        let name = Locale(identifier: Localized.activeCode).localizedString(forLanguageCode: code)
        return name?.lowercased() == code.lowercased() ? nil : name
    }

    static func code(forEnglishName name: String) -> String? { codeByEnglishName[name.lowercased()] }

    static func englishName(code: String) -> String? {
        guard let n = english.localizedString(forLanguageCode: code), n.lowercased() != code.lowercased() else { return nil }
        return n
    }

    /// The language a raw word stands for: a code, an English name, or a name this app's detector uses. Plain Latin script is not a language.
    static func resolve(_ raw: String) -> (key: String, english: String, name: String)? {
        let w = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !w.isEmpty, w != MusicLanguage.latin.rawValue else { return nil }
        var englishNameFound: String?
        if let l = MusicLanguage(stated: w), l != .latin { englishNameFound = l.englishName }
        else if codeByEnglishName[w] != nil { englishNameFound = w.capitalized }
        else if w.count <= 3 || w.contains("-") || w.contains("_"), let code = baseCode(w.replacingOccurrences(of: "_", with: "-")), let n = englishName(code: code) { englishNameFound = n }
        guard let en = englishNameFound else { return nil }
        let code = codeByEnglishName[en.lowercased()]
        let shown = code.flatMap { displayName(code: $0) } ?? Localized.string(en)
        return (en.lowercased(), en, shown)
    }

    /// The languages the device is set to, in the person's order, each once ("en-US", "te-IN" give English, Telugu).
    static func deviceLanguages(preferred: [String] = Locale.preferredLanguages) -> [(key: String, english: String, name: String)] {
        var seen = Set<String>()
        return preferred.compactMap { tag -> (key: String, english: String, name: String)? in
            guard let code = baseCode(tag), let en = englishName(code: code), let r = resolve(en), seen.insert(r.key).inserted else { return nil }
            return r
        }
    }
}

// MARK: - Languages

/// One language tile's worth of facts, with where it was learned.
struct MusicDerivedLanguage: Equatable, Sendable, Identifiable {
    enum Origin: String, Sendable { case library, device, region, other }
    var key: String
    var english: String
    var name: String
    var origin: Origin
    var count: Int
    var id: String { key }
}

enum MusicDerivedLanguages {
    /// Everything the derivation reads. `region` and `other` map a language word (as the detector names it) to how many chart items were in it.
    struct Input: Sendable {
        var preferredLanguages: [String] = Locale.preferredLanguages
        var library: [MusicLibraryFacet] = []
        var region: [String: Int] = [:]
        var other: [String: Int] = [:]
    }

    /// The person's own languages first (what they play, then what the device is set to), then the chosen country's, then the rest by count.
    static func derive(_ input: Input) -> [MusicDerivedLanguage] {
        var out: [MusicDerivedLanguage] = []
        var seen = Set<String>()
        func add(_ raw: String, _ origin: MusicDerivedLanguage.Origin, _ count: Int) {
            guard let r = MusicLanguageNames.resolve(raw), seen.insert(r.key).inserted else { return }
            out.append(MusicDerivedLanguage(key: r.key, english: r.english, name: r.name, origin: origin, count: count))
        }
        for f in input.library.sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }) { add(f.key, .library, f.count); add(f.name, .library, f.count) }
        for d in MusicLanguageNames.deviceLanguages(preferred: input.preferredLanguages) { add(d.english, .device, 0) }
        for (k, n) in input.region.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) { add(k, .region, n) }
        for (k, n) in input.other.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) { add(k, .other, n) }
        return out
    }

    /// The languages Explore always lists, in this order, the same for everyone. Explore is the catalogue, not what the charts happen to hold today: a list built only from the
    /// languages found in the current charts showed a single tile (Korean) when the charts were mostly Korean.
    static let baseline = ["hi", "te", "ta", "ml", "kn", "bn", "mr", "pa", "gu", "en", "ko", "ja", "es", "ar"]

    /// The fixed list first, then any other language the charts held (by how many items).
    static func withBaseline(_ derived: [MusicDerivedLanguage]) -> [MusicDerivedLanguage] {
        var out: [MusicDerivedLanguage] = []
        var seen = Set<String>()
        for code in baseline {
            guard let r = MusicLanguageNames.resolve(code), seen.insert(r.key).inserted else { continue }
            let count = derived.first { $0.key == r.key }?.count ?? 0
            out.append(MusicDerivedLanguage(key: r.key, english: r.english, name: r.name, origin: .other, count: count))
        }
        for d in derived where seen.insert(d.key).inserted { out.append(d) }
        return out
    }

    /// How many items of the shelves are in each language (stated by the source first, else by writing system). Plain Latin script is left out.
    static func counts(in sections: [MusicBrowseSection]) -> [String: Int] {
        var out: [String: Int] = [:]
        for s in sections {
            for item in s.items {
                let l: MusicLanguage?
                switch item {
                case .track(let t): l = MusicLanguageDetector.language(of: t)
                case .album(let a): l = MusicLanguageDetector.language(of: ([a.title] + a.artists.map(\.name)).joined(separator: " "))
                case .artist(let a): l = MusicLanguageDetector.language(of: a.name)
                case .playlist(let p): l = MusicLanguageDetector.language(of: p.name)
                }
                if let l, l != .latin { out[l.rawValue, default: 0] += 1 }
            }
        }
        return out
    }

    /// The tiles: `cap` of them and a toggle tile when there are more; with `expanded`, all of them and a toggle back.
    static func tiles(_ list: [MusicDerivedLanguage], cap: Int = 8, expanded: Bool = false) -> [MusicCategory] {
        func tile(_ d: MusicDerivedLanguage) -> MusicCategory {
            MusicCategory(name: d.name, kind: .language, target: .search(MusicCategoryCatalogue.languageQuery(d.english)), language: MusicLanguage(stated: d.english), stableName: d.english)
        }
        if list.count <= cap { return list.map(tile) }
        if expanded { return list.map(tile) + [MusicCategory.toggle(Localized.string("Show fewer"))] }
        return list.prefix(cap - 1).map(tile) + [MusicCategory.toggle(Localized.string("More"))]
    }
}

extension MusicCategory {
    /// The "More" / "Show fewer" tile of a list: it has no search of its own and no cover.
    static func toggle(_ name: String) -> MusicCategory { MusicCategory(name: name, kind: .language, target: .search("")) }
    var isToggle: Bool { kind == .language && target == .search("") }
}

// MARK: - Genres and moods

enum MusicDerivedGenres {
    /// The source's own tiles with the person's genres worked in: tiles that match a genre of their library come first (most played first), library genres the source
    /// has no tile for follow as search tiles, and the rest keep the source's order. Nothing is added when the library states no genre; an empty source and an empty
    /// library give an empty list.
    static func arrange(provider: [MusicCategory], library: [MusicLibraryFacet], extraLimit: Int = 6) -> [MusicCategory] {
        let facets = library.filter { $0.count >= 1 }
        var rank: [String: Int] = [:]
        for (offset, facet) in facets.enumerated() {
            let key = MusicLibraryFacets.foldKey(facet.name)
            if rank[key] == nil { rank[key] = offset }
        }
        func personalRank(_ c: MusicCategory) -> Int? {
            guard c.kind == .genre else { return nil }
            let k = MusicLibraryFacets.foldKey(c.name)
            if let r = rank[k] { return r }
            var best: Int?
            for (key, value) in rank where k.contains(key) || key.contains(k) { best = min(best ?? value, value) }
            return best
        }
        var ranked: [(index: Int, category: MusicCategory, rank: Int)] = []
        for (i, c) in provider.enumerated() {
            if let r = personalRank(c) { ranked.append((i, c, r)) }
        }
        ranked.sort { a, b in a.rank != b.rank ? a.rank < b.rank : a.index < b.index }
        let personal: [MusicCategory] = ranked.map { $0.category }
        let personalIDs = Set(personal.map(\.id))
        let have = Set(provider.map { MusicLibraryFacets.foldKey($0.name) })
        var extras: [MusicCategory] = []
        for f in facets where extras.count < extraLimit && f.count >= 2 {
            let k = MusicLibraryFacets.foldKey(f.name)
            if have.contains(k) || provider.contains(where: { personalRank($0) != nil && MusicLibraryFacets.foldKey($0.name).contains(k) }) { continue }
            extras.append(MusicCategory(name: f.name, kind: .genre, target: .search(f.name + " music")))
        }
        let rest = provider.filter { !personalIDs.contains($0.id) }
        let out = MusicCategory.unique(personal + extras + rest)
        return out
    }
}
