import Foundation

// Genre and language facets for the Library tabs. Pure: items in, a count-sorted list of facets out, then a filter. Names are never listed here:
// they come from what the library holds (the genre a source or a file's tags state, the language a source states or the writing system of the
// title). A song with no such data is simply in no facet.

/// One choice in a facet row: `key` is the folded identity (so "Rock", "rock" and "ROCK " are one), `name` the spelling to show.
struct MusicLibraryFacet: Hashable, Sendable, Identifiable {
    var key: String
    var name: String
    var count: Int
    var id: String { key }
}

/// What the person chose in the genre and language rows of one tab. Nil means "all".
struct MusicFacetSelection: Codable, Equatable, Sendable {
    var genre: String?
    var language: String?
    var isActive: Bool { genre != nil || language != nil }
    init(genre: String? = nil, language: String? = nil) { self.genre = genre; self.language = language }
}

/// The facets of one list, built once per change of the list.
struct MusicFacetSet: Equatable, Sendable {
    var genres: [MusicLibraryFacet] = []
    var languages: [MusicLibraryFacet] = []
    var isEmpty: Bool { genres.isEmpty && languages.isEmpty }
    /// Drops a stored choice that no longer exists in the list (the last song of a genre was removed), so the list never filters to nothing silently.
    func valid(_ s: MusicFacetSelection) -> MusicFacetSelection {
        MusicFacetSelection(genre: s.genre.flatMap { k in genres.contains { $0.key == k } ? k : nil },
                            language: s.language.flatMap { k in languages.contains { $0.key == k } ? k : nil })
    }
}

enum MusicLibraryFacets {
    // MARK: folding

    /// The identity of a name: case, accents, spacing and punctuation do not matter ("R&B", "r & b" and "R B" are one). Letters outside the
    /// Latin range are kept as they are (folding accents could merge different Indic words).
    static func foldKey(_ raw: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in raw {
            let first = ch.unicodeScalars.first?.value ?? 0
            let isWord = ch.isLetter || ch.isNumber || ch.unicodeScalars.contains { $0.properties.isAlphabetic }
            if !isWord { pendingSpace = !out.isEmpty; continue }
            if pendingSpace { out += " "; pendingSpace = false }
            out += first < 0x370 ? String(ch).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) : String(ch).lowercased()
        }
        return out
    }

    /// Words a source writes when it does not know. Not a list of genres: a list of "no answer" spellings.
    private static let placeholders: Set<String> = ["unknown", "other", "others", "none", "na", "n a", "unspecified", "undefined", "not set", "no genre",
                                                    "genre", "misc", "miscellaneous", "untitled", "null", "nil", "various"]

    /// True for text that says nothing: empty, a placeholder, or only digits (an ID3 genre number such as "(17)").
    static func isUnknown(_ raw: String) -> Bool {
        let k = foldKey(raw)
        if k.isEmpty || placeholders.contains(k) { return true }
        return k.allSatisfy { $0.isNumber || $0 == " " }
    }

    /// Splits a tag that holds several genres ("Pop; Rock", "Pop, Rock"). A slash stays inside a name ("R&B/Soul").
    static func splitGenres(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == "\u{0}" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !isUnknown($0) }
    }

    // MARK: generic core

    /// Counts names per item (an item counts once for a key even when it names it twice), merges spellings, drops unknown ones and sorts by count,
    /// then by name. The shown spelling is the commonest one (ties: the one that sorts first), so the result does not depend on list order.
    static func facets(names perItem: [[(key: String, name: String)]]) -> [MusicLibraryFacet] {
        var counts: [String: Int] = [:]
        var spellings: [String: [String: Int]] = [:]
        for names in perItem {
            var seen = Set<String>()
            for n in names where !n.key.isEmpty {
                spellings[n.key, default: [:]][n.name, default: 0] += 1
                if seen.insert(n.key).inserted { counts[n.key, default: 0] += 1 }
            }
        }
        let out = counts.map { key, count -> MusicLibraryFacet in
            let best = spellings[key]?.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key ?? key
            return MusicLibraryFacet(key: key, name: best, count: count)
        }
        return out.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            let c = a.name.compare(b.name, options: [.caseInsensitive, .diacriticInsensitive, .numeric])
            return c != .orderedSame ? c == .orderedAscending : a.key < b.key
        }
    }

    static func genreNames(_ raws: [String]) -> [(key: String, name: String)] {
        raws.flatMap { splitGenres($0) }.map { (key: foldKey($0), name: $0) }
    }

    // MARK: per kind of item

    static func genres(of t: MusicTrack) -> [(key: String, name: String)] { genreNames([t.hints?.genre].compactMap { $0 }) }
    static func genres(of a: MusicArtist) -> [(key: String, name: String)] { genreNames(a.genres) }
    static func genres(of a: MusicAlbum) -> [(key: String, name: String)] { genreNames([a.creditBundle?.hints?.genre].compactMap { $0 }) }

    /// The language a source states (a name or a code), else the writing system of the text. Latin letters alone say nothing, so such a song has no language.
    static func language(stated: String?, text: String) -> (key: String, name: String)? {
        if let s = stated?.trimmingCharacters(in: .whitespacesAndNewlines), !isUnknown(s) {
            if let l = MusicLanguage(stated: s), l != .latin { return (l.rawValue, l.displayName) }
            let code = MusicLanguageNames.displayName(code: s)
            let name = code ?? (s.count <= 3 ? s.uppercased() : s.prefix(1).uppercased() + s.dropFirst())
            return (foldKey(s), name)
        }
        if let l = MusicLanguageDetector.language(of: text), l != .latin { return (l.rawValue, l.displayName) }
        return nil
    }

    static func languages(of t: MusicTrack) -> [(key: String, name: String)] {
        language(stated: t.hints?.language, text: t.title + " " + (t.album?.title ?? "")).map { [$0] } ?? []
    }
    static func languages(of a: MusicAlbum) -> [(key: String, name: String)] {
        language(stated: a.creditBundle?.hints?.language, text: a.title).map { [$0] } ?? []
    }

    static func build(tracks: [MusicTrack]) -> MusicFacetSet {
        MusicFacetSet(genres: facets(names: tracks.map { genres(of: $0) }), languages: facets(names: tracks.map { languages(of: $0) }))
    }
    static func build(albums: [MusicAlbum]) -> MusicFacetSet {
        MusicFacetSet(genres: facets(names: albums.map { genres(of: $0) }), languages: facets(names: albums.map { languages(of: $0) }))
    }
    static func build(artists: [MusicArtist]) -> MusicFacetSet {
        MusicFacetSet(genres: facets(names: artists.map { genres(of: $0) }), languages: [])
    }

    // MARK: filtering

    private static func has(_ names: [(key: String, name: String)], _ key: String?) -> Bool {
        guard let key else { return true }
        return names.contains { $0.key == key }
    }

    static func filter(_ tracks: [MusicTrack], _ s: MusicFacetSelection) -> [MusicTrack] {
        guard s.isActive else { return tracks }
        return tracks.filter { has(genres(of: $0), s.genre) && has(languages(of: $0), s.language) }
    }
    static func filter(_ albums: [MusicAlbum], _ s: MusicFacetSelection) -> [MusicAlbum] {
        guard s.isActive else { return albums }
        return albums.filter { has(genres(of: $0), s.genre) && has(languages(of: $0), s.language) }
    }
    static func filter(_ artists: [MusicArtist], _ s: MusicFacetSelection) -> [MusicArtist] {
        guard s.genre != nil else { return artists }
        return artists.filter { has(genres(of: $0), s.genre) }
    }
}

/// The chosen facets per tab, kept for the session only (a new launch starts showing everything).
enum MusicFacetSession {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var chosen: [String: MusicFacetSelection] = [:]
    }
    private static let box = Box()

    static func selection(_ tab: String) -> MusicFacetSelection {
        box.lock.lock(); defer { box.lock.unlock() }
        return box.chosen[tab] ?? MusicFacetSelection()
    }
    static func set(_ s: MusicFacetSelection, for tab: String) {
        box.lock.lock()
        box.chosen[tab] = s.isActive ? s : nil
        box.lock.unlock()
        MusicDebugLog.log("library", "facet choice \(tab): genre=\(s.genre ?? "all") language=\(s.language ?? "all")")
    }
}
