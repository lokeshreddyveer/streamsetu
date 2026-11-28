import Foundation
import Observation

// Pure rules the artist page added after its first round: the kind of recording and who sang it (from what the graph states), the personal slice of the Songs list
// (plays and likes on this Mac), the latest release, the career milestones, the film credit filter, the link a Share gives, what a role switch or Back keeps of the
// page, and the summary of a Combine answer. Plain Sendable values only, so each rule is checked on its own. Nothing here reads the network or the player.

// MARK: recording type and performance

/// What a song is, when the graph says so: a live recording, an acoustic or unplugged one, a remix, an instrumental, or one the person is only featured on.
/// Never guessed: a live recording is typed only by a source's own tag or an edge (a word in the title is not evidence of a live performance), and a song the graph
/// says nothing about has no kind and is simply not offered under any of these filters.
enum MusicSongPerformance: String, CaseIterable, Sendable, Hashable {
    case live, acoustic, remix, instrumental, featured

    /// The kind a recording row carries, trusted for the Songs filter. A kind worked out only from the title is not used for `live`.
    static func trustedVersionKind(_ attrs: [String: String]) -> String? {
        guard let raw = attrs["versionKind"], !raw.isEmpty else { return nil }
        let evidence = (attrs["versionEvidence"] ?? "").split(separator: ",").map(String.init)
        if raw == MusicVersionKind.live.rawValue, evidence.contains(where: { $0.hasPrefix("title-") }) { return nil }
        return raw
    }

    static func of(_ e: MusicPersonEntry) -> Set<MusicSongPerformance> {
        var out = Set<MusicSongPerformance>()
        switch e.versionKind ?? "" {
        case MusicVersionKind.live.rawValue: out.insert(.live)
        case MusicVersionKind.acoustic.rawValue: out.insert(.acoustic)
        case MusicVersionKind.remix.rawValue: out.insert(.remix)
        case MusicVersionKind.instrumental.rawValue: out.insert(.instrumental)
        default: break
        }
        if e.roles.contains(.featured) { out.insert(.featured) }
        return out
    }

    /// The kinds that at least one of the songs has, in a fixed order, each with its count.
    static func facets(in entries: [MusicPersonEntry]) -> [(kind: MusicSongPerformance, count: Int)] {
        var n: [MusicSongPerformance: Int] = [:]
        for e in entries { for k in of(e) { n[k, default: 0] += 1 } }
        return allCases.compactMap { k in n[k].map { (kind: k, count: $0) } }
    }
}

// MARK: personal slice of the Songs list

/// What this Mac knows about the person's songs: how often each was played and which are liked. Keyed by the folded title, the same key Your listening uses
/// (the history holds provider tracks and the page's songs are graph recordings; the title is the one thing both have). Private: it only orders and narrows the
/// list the person looks at and never changes a credit.
struct MusicArtistPersonal: Equatable, Sendable {
    var plays: [String: Int] = [:]
    var liked: Set<String> = []
    /// The same plays and likes by the provider's own track id (`MusicTrack.uid`).
    var playsByUID: [String: Int] = [:]
    var likedUIDs: Set<String> = []
    /// The provider ids each catalog recording carries in the graph. A recording with ids is matched by them first, so a live or remixed take with the same title is not counted as the studio song.
    var uids: [MusicEntityID: [String]] = [:]

    static let empty = MusicArtistPersonal()

    static func key(_ title: String) -> String { HomeKeys.fold(title) }

    /// The title stands in only for a recording that does not state a version (a live, acoustic or remix take is told apart by its id, never by its title).
    static func titleMayStandIn(_ e: MusicPersonEntry) -> Bool { e.versionKind == nil }

    func playCount(_ e: MusicPersonEntry) -> Int {
        if let u = uids[e.id], !u.isEmpty {
            let byID = u.reduce(0) { $0 + (playsByUID[$1] ?? 0) }
            if byID > 0 || !Self.titleMayStandIn(e) { return byID }
        }
        return Self.titleMayStandIn(e) || (uids[e.id]?.isEmpty ?? true) ? (plays[Self.key(e.name)] ?? 0) : 0
    }

    func isLiked(_ e: MusicPersonEntry) -> Bool {
        if let u = uids[e.id], !u.isEmpty {
            if u.contains(where: { likedUIDs.contains($0) }) { return true }
            if !Self.titleMayStandIn(e) { return false }
        }
        return Self.titleMayStandIn(e) || (uids[e.id]?.isEmpty ?? true) ? liked.contains(Self.key(e.name)) : false
    }
    var hasPlays: Bool { !plays.isEmpty }
    var hasLikes: Bool { !liked.isEmpty }


    /// Counted plays (the rule Home uses) and liked tracks of this artist, matched the way Your listening matches them (the provider artist's id first).
    static func build(history: [PlayRecord], liked: [MusicTrack], identity: MusicArtistIdentity, uids: [MusicEntityID: [String]] = [:]) -> MusicArtistPersonal {
        var p = MusicArtistPersonal()
        p.uids = uids
        for r in history where !(r.track.isPodcast ?? false) && HomeTaste.counts(r) && MusicArtistListening.matches(r.track, identity: identity) {
            p.plays[key(r.track.title), default: 0] += 1
            p.playsByUID[r.track.uid, default: 0] += 1
        }
        for t in liked where MusicArtistListening.matches(t, identity: identity) { p.liked.insert(key(t.title)); p.likedUIDs.insert(t.uid) }
        return p
    }
}

// MARK: favorite artists

/// The people the person marked as favorite, by entity id. Kept apart from Follow (which belongs to a service's artist and shows new releases): a favorite is a
/// private mark on a person of the graph and needs no provider.
struct MusicFavoriteArtistSet: Equatable, Sendable {
    private(set) var ids: [String] = []
    static let capacity = 500

    init(ids: [String] = []) {
        var seen = Set<String>()
        self.ids = ids.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(Self.capacity).map { $0 }
    }

    func contains(_ id: MusicEntityID) -> Bool { ids.contains(id.rawValue) }

    /// The same favorites with merged-away ids swapped for the entity that now stands for them (order kept, no id twice).
    func replacing(_ moved: [String: String]) -> MusicFavoriteArtistSet {
        MusicFavoriteArtistSet(ids: ids.map { moved[$0] ?? $0 })
    }

    /// Newest favorite first; marking one again moves nothing.
    mutating func toggle(_ id: MusicEntityID) {
        if let i = ids.firstIndex(of: id.rawValue) { ids.remove(at: i) } else { ids.insert(id.rawValue, at: 0); if ids.count > Self.capacity { ids.removeLast() } }
    }
}

@MainActor @Observable
final class MusicFavoriteArtists {
    static let shared = MusicFavoriteArtists()
    static let key = "music.favoriteArtists"
    private(set) var favorites: MusicFavoriteArtistSet
    @ObservationIgnored private let defaults: UserDefaults
    nonisolated static let adoptInterval: TimeInterval = 120
    @ObservationIgnored private var adoptRunning = false
    @ObservationIgnored private var adoptedSignature: [String] = []
    @ObservationIgnored private var adoptedAt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = MusicFavoriteArtistSet(ids: defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isFavorite(_ id: MusicEntityID) -> Bool { favorites.contains(id) }

    func toggle(_ id: MusicEntityID) {
        favorites.toggle(id)
        if favorites.ids.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(favorites.ids, forKey: Self.key) }
    }

    nonisolated static func needsAdopt(signature: [String], lastSignature: [String], lastAt: Date?, now: Date) -> Bool {
        guard let at = lastAt else { return true }
        return signature != lastSignature || now.timeIntervalSince(at) >= adoptInterval
    }

    /// A merge during a page visit leaves a favorite filed under the loser id: ask the graph who stands for each stored id now and store that one instead.
    func adoptMerges(in graph: any MusicGraphStoring, now: Date = Date()) async {
        // The same stored set was checked a moment ago, or a check is already running: nothing new to find.
        let signature = favorites.ids
        if adoptRunning || !Self.needsAdopt(signature: signature, lastSignature: adoptedSignature, lastAt: adoptedAt, now: now) { return }
        adoptRunning = true
        defer { adoptRunning = false }
        adoptedSignature = signature; adoptedAt = now
        var moved: [String: String] = [:]
        for raw in favorites.ids {
            guard let id = MusicEntityID(rawValue: raw), let live = try? await graph.resolve(id), live != id else { continue }
            moved[raw] = live.rawValue
        }
        guard !moved.isEmpty else { return }
        favorites = favorites.replacing(moved)
        if favorites.ids.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(favorites.ids, forKey: Self.key) }
    }

    /// Empties the in-memory set and the saved list (the wipe of listening activity calls this).
    func reset() {
        favorites = MusicFavoriteArtistSet()
        defaults.removeObject(forKey: Self.key)
    }
}

// MARK: latest release

enum MusicArtistSpotlight {
    /// The newest release of the catalog: the album, soundtrack, single or compilation with the highest year (an album before a single of the same year). Nil when
    /// no release states a year.
    static func latest(_ c: MusicArtistCatalog) -> MusicArtistAlbum? {
        c.albums.filter { $0.entry.year != nil }.min { a, b in
            let ya = a.entry.year ?? 0, yb = b.entry.year ?? 0
            if ya != yb { return ya > yb }
            if a.type != b.type { return a.type.rawValue < b.type.rawValue }
            return a.entry.name < b.entry.name
        }
    }
}

// MARK: career milestones

struct MusicArtistMilestone: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case careerStart, earliestSong, earliestAlbum, earliestFilm, award, latestRelease, newLanguage }
    var year: Int
    var kind: Kind
    var title: String
    /// The entity the row opens (an album or a film); nil for a plain fact.
    var entity: MusicEntityID?
    var id: String { "\(year)|\(kind.rawValue)|\(title)" }
}

enum MusicArtistMilestones {
    static let maxAwards = 8
    static let maxLanguages = 3

    /// The first work in each language other than the one the catalog has most of (at most three): "first work in another language", from the language each song or film
    /// states and the year it states. Nothing is placed for a work with no language or no year.
    static func newLanguageMilestones(_ c: MusicArtistCatalog) -> [MusicArtistMilestone] {
        let pool = c.songs + c.films
        let langs = MusicArtistFacets.languages(in: pool)
        guard langs.count > 1, let home = langs.first?.code else { return [] }
        var out: [MusicArtistMilestone] = []
        for l in langs.dropFirst() {
            let hits = pool.filter { MusicPersonReader.languageCode($0.lang) == l.code && ($0.year).map { (1850...2100).contains($0) } ?? false }
            guard let e = hits.min(by: { ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) < ($1.year ?? 0) : $0.name < $1.name }), let y = e.year, l.code != home else { continue }
            out.append(MusicArtistMilestone(year: y, kind: .newLanguage, title: e.name + " · " + MusicPersonReader.languageName(l.code), entity: e.id))
        }
        return Array(out.sorted { $0.year < $1.year }.prefix(maxLanguages))
    }

    /// Milestones from what the catalog holds and the awards Wikidata lists, oldest first. "Earliest" is the earliest the catalog found, not a claim about a debut
    /// (the catalog is what Music has loaded). The career start is the stated start of the person's active years.
    static func build(catalog c: MusicArtistCatalog, awards: [MusicPersonAward], activeFrom: Int?) -> [MusicArtistMilestone] {
        var out: [MusicArtistMilestone] = []
        func earliest(_ list: [MusicPersonEntry]) -> MusicPersonEntry? {
            list.filter { ($0.year).map { (1850...2100).contains($0) } ?? false }.min { ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) < ($1.year ?? 0) : $0.name < $1.name }
        }
        if let y = activeFrom { out.append(MusicArtistMilestone(year: y, kind: .careerStart, title: "", entity: nil)) }
        if let e = earliest(c.songs), let y = e.year { out.append(MusicArtistMilestone(year: y, kind: .earliestSong, title: e.name, entity: e.id)) }
        let firstAlbum = earliest(c.albums.filter { $0.type == .album || $0.type == .single }.map(\.entry))
        if let e = firstAlbum, let y = e.year { out.append(MusicArtistMilestone(year: y, kind: .earliestAlbum, title: e.name, entity: e.id)) }
        if let e = earliest(c.films), let y = e.year { out.append(MusicArtistMilestone(year: y, kind: .earliestFilm, title: e.name, entity: e.id)) }
        // An actor's or director's page has no release of its own (a film's soundtrack is not theirs), as the Overview card also says.
        let ownsReleases = c.view != .actor && c.view != .director
        if ownsReleases, let l = MusicArtistSpotlight.latest(c), let y = l.entry.year, l.entry.id != firstAlbum?.id { out.append(MusicArtistMilestone(year: y, kind: .latestRelease, title: l.entry.name, entity: l.entry.id)) }
        out += newLanguageMilestones(c)
        for a in awards.filter({ $0.year != nil }).sorted(by: { ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) > ($1.year ?? 0) : $0.label < $1.label }).prefix(maxAwards) {
            if let y = a.year { out.append(MusicArtistMilestone(year: y, kind: .award, title: a.label, entity: nil)) }
        }
        let rank: [MusicArtistMilestone.Kind: Int] = [.careerStart: 0, .earliestSong: 1, .earliestAlbum: 2, .earliestFilm: 3, .newLanguage: 4, .award: 5, .latestRelease: 6]
        return out.sorted { $0.year != $1.year ? $0.year < $1.year : (rank[$0.kind] ?? 9) < (rank[$1.kind] ?? 9) }
    }
}

// MARK: film credit filter

/// The Films pill's filter by the credit the person holds on the film and by whether the catalog has that film's soundtrack.
struct MusicArtistFilmFilter: Equatable, Sendable {
    var role: MusicRole?
    var withSoundtrack = false
    /// The film's director or genre, as the graph states them for the film.
    var director: MusicEntityID?
    var genre: MusicEntityID?

    var isActive: Bool { role != nil || withSoundtrack || director != nil || genre != nil }

    /// The films of the catalog whose soundtrack album is also in the catalog.
    static func soundtrackFilms(_ c: MusicArtistCatalog) -> Set<MusicEntityID> {
        Set(c.albums.filter { $0.type == .soundtrack || $0.type == .score }.compactMap { $0.entry.filmID })
    }

    /// The credits the films carry, most films first.
    static func roles(in films: [MusicPersonEntry]) -> [(role: MusicRole, count: Int)] {
        var n: [MusicRole: Int] = [:]
        for f in films { for r in Set(f.roles) { n[r, default: 0] += 1 } }
        return n.map { (role: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.role.rawValue < $1.role.rawValue }
    }

    func apply(to films: [MusicPersonEntry], soundtracks: Set<MusicEntityID>, facts: MusicArtistFilmFacts = .empty) -> [MusicPersonEntry] {
        films.filter { f in
            if let r = role, !f.roles.contains(r) { return false }
            if withSoundtrack, !soundtracks.contains(f.id) { return false }
            if let d = director, !(facts.directors[f.id] ?? []).contains(where: { $0.id == d }) { return false }
            if let g = genre, !(facts.genres[f.id] ?? []).contains(where: { $0.id == g }) { return false }
            return true
        }
    }
}

// MARK: share

enum MusicArtistShareLink {
    /// The link to hand out: the app's own artist link when the person has a provider artist, else their Wikipedia article (the first wiki the graph lists, English
    /// first), else their Wikidata page. Nil when none of them is known.
    static func url(appLink: URL?, sitelinks: String?, wikidataID: String?) -> URL? {
        if let appLink { return appLink }
        let titles = MusicPersonWikiRules.titles(sitelinks: sitelinks)
        if let lang = (titles["en"] != nil ? "en" : titles.keys.sorted().first), let title = titles[lang] {
            var c = URLComponents()
            c.scheme = "https"; c.host = "\(lang).wikipedia.org"; c.path = "/wiki/" + title.replacingOccurrences(of: " ", with: "_")
            if let u = c.url { return u }
        }
        if let q = wikidataID, q.hasPrefix("Q"), q.dropFirst().allSatisfy(\.isNumber) { return URL(string: "https://www.wikidata.org/wiki/" + q) }
        return nil
    }
}

// MARK: what Back keeps of the page

/// The artist page's pill and filters as the short strings page memory holds (every value at most 64 characters, at most 12 keys per page). Free text (the search
/// box) and the film choice are not kept: they are cheap to type again and may be long.
struct MusicArtistPageSnapshot: Equatable, Sendable {
    var pill: MusicArtistPill = .overview
    var songLanguage: String?
    var songDecade: Int?
    var songSort: MusicArtistSongSort?
    var songPerformance: MusicSongPerformance?
    var yearFrom: Int?
    var yearTo: Int?
    var likedOnly = false
    var year: Int?
    var albumType: MusicAlbumType?
    var albumDecade: Int?
    var filmLanguage: String?
    var filmDecade: Int?
    var filmRole: MusicRole?
    var filmSoundtrack = false
    /// The Films pill's director and genre choices (entity ids), kept under their own key so each value stays within the 64-character limit.
    var filmDirector: MusicEntityID?
    var filmGenre: MusicEntityID?

    static let songsKey = "artist.songs", listsKey = "artist.lists", filmsKey = "artist.films"

    /// (selected tab, filters) as page memory stores them; empty values leave the key out.
    func encoded() -> (tab: String?, filters: [String: String]) {
        var songs: [String] = []
        if let v = songLanguage { songs.append("l=" + v) }
        if let v = songDecade { songs.append("d=\(v)") }
        if let v = songSort { songs.append("s=" + v.rawValue) }
        if let v = songPerformance { songs.append("p=" + v.rawValue) }
        if let v = yearFrom { songs.append("a=\(v)") }
        if let v = yearTo { songs.append("b=\(v)") }
        if likedOnly { songs.append("k=1") }
        var lists: [String] = []
        if let v = year { lists.append("y=\(v)") }
        if let v = albumType { lists.append("t=\(v.rawValue)") }
        if let v = albumDecade { lists.append("ad=\(v)") }
        if let v = filmLanguage { lists.append("fl=" + v) }
        if let v = filmDecade { lists.append("fd=\(v)") }
        if let v = filmRole { lists.append("fr=" + v.rawValue) }
        if filmSoundtrack { lists.append("fs=1") }
        var f: [String: String] = [:]
        if !songs.isEmpty { f[Self.songsKey] = songs.joined(separator: "|") }
        if !lists.isEmpty { f[Self.listsKey] = lists.joined(separator: "|") }
        var films: [String] = []
        if let v = filmDirector { films.append("d=" + v.rawValue) }
        if let v = filmGenre { films.append("g=" + v.rawValue) }
        if !films.isEmpty { f[Self.filmsKey] = films.joined(separator: "|") }
        return (pill == .overview ? nil : pill.rawValue, f)
    }

    static func decode(tab: String?, filters: [String: String]) -> MusicArtistPageSnapshot {
        var s = MusicArtistPageSnapshot()
        s.pill = tab.flatMap(MusicArtistPill.init(rawValue:)) ?? .overview
        func parts(_ key: String) -> [String: String] {
            var out: [String: String] = [:]
            for p in (filters[key] ?? "").split(separator: "|") {
                guard let i = p.firstIndex(of: "=") else { continue }
                out[String(p[..<i])] = String(p[p.index(after: i)...])
            }
            return out
        }
        let a = parts(songsKey), b = parts(listsKey), c = parts(filmsKey)
        s.songLanguage = a["l"].flatMap { $0.isEmpty ? nil : $0 }
        s.songDecade = a["d"].flatMap { Int($0) }
        s.songSort = a["s"].flatMap(MusicArtistSongSort.init(rawValue:))
        s.songPerformance = a["p"].flatMap(MusicSongPerformance.init(rawValue:))
        s.yearFrom = a["a"].flatMap { Int($0) }; s.yearTo = a["b"].flatMap { Int($0) }
        s.likedOnly = a["k"] == "1"
        s.year = b["y"].flatMap { Int($0) }
        s.albumType = b["t"].flatMap { Int($0) }.flatMap(MusicAlbumType.init(rawValue:))
        s.albumDecade = b["ad"].flatMap { Int($0) }
        s.filmLanguage = b["fl"].flatMap { $0.isEmpty ? nil : $0 }
        s.filmDecade = b["fd"].flatMap { Int($0) }
        s.filmRole = b["fr"].flatMap(MusicRole.init(rawValue:))
        s.filmSoundtrack = b["fs"] == "1"
        s.filmDirector = c["d"].flatMap { MusicEntityID(rawValue: $0) }
        s.filmGenre = c["g"].flatMap { MusicEntityID(rawValue: $0) }
        return s
    }
}

// MARK: Combine summary

/// What a Combine answer says about the people together: the years of their songs, and the films those songs belong to (most songs first).
struct MusicCombineSummary: Equatable, Sendable {
    struct Film: Equatable, Sendable, Identifiable { var id: MusicEntityID; var title: String; var songs: Int }
    var firstYear: Int?
    var lastYear: Int?
    var films: [Film] = []
    /// The languages the shared songs state, most songs first (a song with no language is not counted).
    var languages: [String] = []

    var isEmpty: Bool { firstYear == nil && films.isEmpty && languages.isEmpty }

    static func build(_ songs: [MusicPersonEntry], maxFilms: Int = 8) -> MusicCombineSummary {
        var s = MusicCombineSummary()
        let years = songs.compactMap(\.year).filter { (1850...2100).contains($0) }
        s.firstYear = years.min(); s.lastYear = years.max()
        var byFilm: [MusicEntityID: Film] = [:]
        for e in songs { if let f = e.filmID, let t = e.filmTitle, !t.isEmpty { byFilm[f, default: Film(id: f, title: t, songs: 0)].songs += 1 } }
        s.films = byFilm.values.sorted { $0.songs != $1.songs ? $0.songs > $1.songs : $0.title < $1.title }.prefix(maxFilms).map { $0 }
        s.languages = MusicArtistFacets.languages(in: songs).prefix(4).map(\.code)
        return s
    }
}
