import Foundation

// The shared vocabulary of the person completeness pass: one work (a film, an album, a song) a source says a person took part in, and the keys that
// let the same work from different sources become one graph entity. Pure values; nothing here reads the network or the store.

enum MusicPersonWorkKind: String, Sendable, Hashable { case film, album, work, recording }

/// What the person did on a work, as the source states it.
enum MusicPersonRelation: String, Sendable, Hashable, CaseIterable {
    case composer, cast, director, lyricist, performer, producer
}

struct MusicPersonWork: Sendable, Hashable {
    var kind: MusicPersonWorkKind
    var title: String
    var year: Int?
    /// Two-letter language code when the source gave one or the title carried a language tag.
    var lang: String?
    /// `MusicAlbumSubkind` raw value for albums.
    var subkind: String?
    var relations: Set<MusicPersonRelation>
    var ids: [ExternalID]
    var source: MusicSourceID
    var sourceRef: String?
    /// Artists the source credits on the work (never "Various Artists").
    var artists: [String] = []
    /// A soundtrack album the source states for this film (Wikidata P406): its title and Wikidata id.
    var soundtrackQID: String?
    var soundtrackTitle: String?
    /// For an album: the film the source states it belongs to (title), when it said so.
    var filmTitle: String?
    /// The source states this album is the soundtrack of the film in context (a film's own soundtrack-release statement).
    var statesFilm = false
    var imageHint: String?
    /// For a provider edition: the provider uid (`providerID:id`).
    var providerUID: String?

    init(kind: MusicPersonWorkKind, title: String, year: Int? = nil, lang: String? = nil, subkind: String? = nil, relations: Set<MusicPersonRelation> = [],
         ids: [ExternalID] = [], source: MusicSourceID, sourceRef: String? = nil) {
        self.kind = kind; self.title = title; self.year = year; self.lang = lang; self.subkind = subkind; self.relations = relations
        self.ids = ids; self.source = source; self.sourceRef = sourceRef
    }

    var isSoundtrack: Bool { subkind == MusicAlbumSubkind.soundtrack.rawValue || subkind == MusicAlbumSubkind.score.rawValue }
}

/// Identity keys for works. Editions ("Deluxe", "Original Motion Picture Soundtrack") and language tags are taken out of the title so the same album from
/// MusicBrainz, a catalogue and Wikidata gets one key; two different albums never share one because the language stays a separate part of the key.
enum MusicPersonWorkKey {
    struct Parsed: Sendable, Equatable {
        /// The folded Latin skeleton of the title with edition and language words removed.
        var key: String
        var lang: String?
        /// The film the title names (`From "X"`), if it does.
        var filmHint: String?
        /// What was taken out as an edition label ("Original Motion Picture Soundtrack"), original spelling.
        var editions: [String]
        var soundtrackWording: Bool
    }

    static let languageWords: [String: String] = ["tamil": "ta", "telugu": "te", "hindi": "hi", "malayalam": "ml", "kannada": "kn", "bengali": "bn", "marathi": "mr",
                                                  "punjabi": "pa", "gujarati": "gu", "english": "en", "korean": "ko", "urdu": "ur"]
    /// Words that make a bracket or suffix an edition label (every word of the label must be one of these).
    static let editionWords: Set<String> = ["original", "motion", "picture", "soundtrack", "soundtracks", "score", "music", "from", "the", "ost", "deluxe", "edition", "expanded",
                                            "remastered", "remaster", "bonus", "track", "tracks", "version", "special", "anniversary", "standard", "film", "movie", "of", "and", "ep",
                                            "album", "complete", "digital", "international", "reissue", "re", "issue"]
    private static let soundtrackWords: Set<String> = ["soundtrack", "soundtracks", "ost", "score"]

    private static func bracketGroups(_ s: String) -> (rest: String, groups: [String]) {
        var rest = "", groups: [String] = [], depth = 0, cur = ""
        for ch in s {
            if ch == "(" || ch == "[" { depth += 1; if depth == 1 { cur = ""; continue } }
            if (ch == ")" || ch == "]") && depth > 0 { depth -= 1; if depth == 0 { groups.append(cur); rest += " "; continue } }
            if depth > 0 { cur.append(ch) } else { rest.append(ch) }
        }
        if depth > 0 { rest += " " + cur }
        return (rest, groups)
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// `from "Vaathi"`, `from Vaathi`, `music from the motion picture Vaathi` -> the film name.
    private static func filmName(in label: String) -> String? {
        let l = label.lowercased()
        guard let r = l.range(of: "from ") else { return nil }
        let after = String(label[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"“”'‘’"))
        let lw = after.lowercased()
        if lw.hasPrefix("the motion picture") || lw.hasPrefix("the film") || lw.hasPrefix("the movie") || lw.isEmpty { return nil }
        return after
    }

    private static func isYear(_ w: String) -> Bool { w.count == 4 && (w.hasPrefix("19") || w.hasPrefix("20")) && Int(w) != nil }

    /// Splits a title into its identity part and the edition, language and film parts it carried.
    static func parse(_ title: String, stripLanguage: Bool = true) -> Parsed {
        var (base, groups) = bracketGroups(title)
        var lang: String?, hint: String?, editions: [String] = [], soundtrack = false
        var keptGroups: [String] = []
        func take(_ g: String) -> Bool {
            let w = words(g)
            guard !w.isEmpty else { return true }
            if let f = filmName(in: g) { hint = f; editions.append(g); soundtrack = true; return true }
            if w.count == 1, let l = languageWords[w[0]] { lang = l; return stripLanguage }
            if w.count == 2, w[1] == "film" || w[1] == "movie" || w[1] == "version", let l = languageWords[w[0]] { lang = l; return stripLanguage }
            if w.allSatisfy({ editionWords.contains($0) || isYear($0) }) { editions.append(g); if w.contains(where: soundtrackWords.contains) { soundtrack = true }; return true }
            return false
        }
        for g in groups where !take(g) { keptGroups.append(g) }
        // " - Original Motion Picture Soundtrack" style suffix, and an unbracketed trailing edition label.
        if let dash = base.range(of: " - ", options: .backwards) {
            let tail = String(base[dash.upperBound...])
            if take(tail) { base = String(base[..<dash.lowerBound]) }
        }
        var ws = base.split(separator: " ").map(String.init)
        // Longest trailing run made only of edition words (needs at least "soundtrack"/"ost"/"edition"-like content to be safe).
        var end = ws.count
        while end > 1, editionWords.contains(ws[end - 1].lowercased().trimmingCharacters(in: .punctuationCharacters)) { end -= 1 }
        if end < ws.count {
            let tail = ws[end...].map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            if tail.contains(where: { soundtrackWords.contains($0) || ["edition", "deluxe", "remastered", "version"].contains($0) }) {
                editions.append(ws[end...].joined(separator: " ")); if tail.contains(where: soundtrackWords.contains) { soundtrack = true }
                ws = Array(ws[..<end])
            }
        }
        var core = ws.joined(separator: " ")
        for g in keptGroups { core += " " + g }
        let key = MusicGraphText.latin(core)
        return Parsed(key: key, lang: lang, filmHint: hint, editions: editions, soundtrackWording: soundtrack)
    }

    /// Film keys also drop a trailing language word and year tags: "Vaathi (Tamil)" and "Vaathi" are one film.
    static func filmKey(_ title: String) -> String { parse(title).key }
    static func albumKey(_ title: String) -> Parsed { parse(title) }

    /// Years within a tolerance, an unknown year matching anything.
    static func yearsCompatible(_ a: Int?, _ b: Int?, tolerance: Int) -> Bool {
        guard let a, let b else { return true }
        return abs(a - b) <= tolerance
    }

    /// Languages match when equal or when either is unknown.
    static func langsCompatible(_ a: String?, _ b: String?) -> Bool { a == nil || b == nil || a == b }

    /// The stable local id of a work no source gave a strong id for. Deterministic from what identifies it.
    static func canon(_ w: MusicPersonWork) -> ExternalID {
        switch w.kind {
        case .film: return ExternalID(.canon, "pfilm|" + filmKey(w.title) + "|" + (w.year.map(String.init) ?? "-"))
        case .album:
            let p = parse(w.title)
            return ExternalID(.canon, "palbum|" + p.key + "|" + (w.lang ?? p.lang ?? "-") + "|" + (w.year.map(String.init) ?? "-"))
        case .work, .recording: return ExternalID(.canon, "pwork|" + parse(w.title).key + "|" + (w.artists.first.map(MusicGraphText.latin) ?? "-"))
        }
    }
}

/// An in-memory grouping of works by identity, used inside one pass so counts are honest before anything is written and so the soundtrack linker can
/// look at every film and album the pass found. Two works join one group when kind, key and language agree and their years are within a tolerance, or
/// when they share a strong id.
struct MusicPersonWorkLedger: Sendable {
    struct Group: Sendable {
        var kind: MusicPersonWorkKind
        var key: String
        var lang: String?
        var year: Int?
        var title: String
        var members: [MusicPersonWork]
        var strongIDs: Set<ExternalID> { Set(members.flatMap(\.ids).filter(\.isStrong)) }
        var isSoundtrack: Bool { members.contains(where: \.isSoundtrack) || MusicPersonWorkKey.parse(title).soundtrackWording }
        var sources: Set<MusicSourceID> { Set(members.map(\.source)) }
    }

    private(set) var groups: [Group] = []

    var films: [Group] { groups.filter { $0.kind == .film } }
    var albums: [Group] { groups.filter { $0.kind == .album } }

    private static func tolerance(_ k: MusicPersonWorkKind) -> Int { k == .film ? 1 : 2 }

    /// Adds a work; returns the index of its group.
    @discardableResult
    mutating func add(_ w: MusicPersonWork) -> Int {
        let p = MusicPersonWorkKey.parse(w.title)
        let lang = w.lang ?? p.lang
        let strong = Set(w.ids.filter(\.isStrong))
        for i in groups.indices where groups[i].kind == w.kind {
            let g = groups[i]
            let byID = !strong.isDisjoint(with: g.strongIDs)
            let byName = g.key == p.key && !p.key.isEmpty && MusicPersonWorkKey.langsCompatible(g.lang, lang) && MusicPersonWorkKey.yearsCompatible(g.year, w.year, tolerance: Self.tolerance(w.kind))
            if byID || byName {
                groups[i].members.append(w)
                if groups[i].year == nil || (w.year.map { $0 < (groups[i].year ?? Int.max) } ?? false) { groups[i].year = w.year ?? groups[i].year }
                if groups[i].lang == nil { groups[i].lang = lang }
                return i
            }
        }
        groups.append(Group(kind: w.kind, key: p.key, lang: lang, year: w.year, title: w.title, members: [w]))
        return groups.count - 1
    }

    mutating func add(contentsOf ws: [MusicPersonWork]) { for w in ws { add(w) } }

    /// Group counts by kind, for the honest "N films" the page shows.
    func count(_ k: MusicPersonWorkKind) -> Int { groups.filter { $0.kind == k }.count }
}
