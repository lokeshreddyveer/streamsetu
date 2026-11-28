import Foundation

// The artist page's pure logic: which pills a person has, the catalog the pills list, their filters and sorts, the timeline, the radio sets, the A x B preset.
// Plain Sendable values only, so each rule is checked on its own. Nothing here reads the graph, the player or the network; the views draw what these return.
// Design notes (from how the big players do it): Apple Music splits releases by type (albums, singles and EPs, compilations) and Spotify has no complete, searchable
// song list on the artist page, so the Songs pill is a full list with search, filters and sort; the Albums pill groups by type; a role page never lists work the
// role did not do (an actor has no singing credits, a composer has "Compositions").

/// The pills under the header. `overview` is the page as it always was.
enum MusicArtistPill: String, CaseIterable, Sendable, Hashable {
    case overview, songs, albums, films, collaborators, timeline, listening, about
}

/// The release types the graph states: from the subkind each release carries (album, soundtrack, single or EP, compilation, score).
enum MusicAlbumType: Int, CaseIterable, Sendable, Hashable { case album, soundtrack, single, compilation, score }

/// One album row after regional editions are folded together: the earliest edition stands for the group.
struct MusicArtistAlbum: Hashable, Sendable, Identifiable {
    var entry: MusicPersonEntry
    var type: MusicAlbumType
    /// How many editions the graph holds under this one (Telugu, Tamil and Hindi versions of a soundtrack are one film's soundtrack).
    var editions: Int
    var id: MusicEntityID { entry.id }
}

/// What the pills list for the active role view.
struct MusicArtistCatalog: Hashable, Sendable {
    var view: MusicPersonView
    var songs: [MusicPersonEntry] = []
    /// The first song-bearing section in the page's own order: the top songs.
    var primarySongs: [MusicPersonEntry] = []
    var albums: [MusicArtistAlbum] = []
    var films: [MusicPersonEntry] = []
    var collaborators: [MusicPersonEntry] = []

    static let songKinds: Set<MusicEntityKind> = [.recording, .track, .work]

    /// The sections of each view that list recordings. A role gets only its own: an actor's are songs from their films, never songs they sang.
    static func songSections(for view: MusicPersonView) -> [MusicPersonSectionID] {
        switch view {
        case .singer: [.topSongs, .filmSongs, .playbackSongs]
        case .composer: [.popularCompositions]
        case .lyricist: [.songsWritten]
        case .actor: [.songsFromMovies]
        case .director: []
        case .producer: [.producedSongs]
        case .instrumentalist: [.instrumentSongs]
        case .conductor: [.conductedSongs]
        case .label: [.labelCatalogue]
        }
    }

    static let filmSections: [MusicPersonSectionID] = [.films, .filmography, .popularMovies]
    static let albumSections: [MusicPersonSectionID] = [.albums, .singles, .soundtracks, .movieSoundtracks, .filmSoundtracks, .soloCareers]

    static func build(_ data: MusicPersonViewData) -> MusicArtistCatalog {
        var c = MusicArtistCatalog(view: data.view)
        var seen = Set<MusicEntityID>()
        let order = songSections(for: data.view)
        for id in order {
            guard let s = data.section(id) else { continue }
            let songs = s.entries.filter { songKinds.contains($0.kind) }
            if c.primarySongs.isEmpty { c.primarySongs = songs }
            for e in songs where seen.insert(e.id).inserted { c.songs.append(e) }
        }
        var filmSeen = Set<MusicEntityID>()
        for id in filmSections {
            for e in data.section(id)?.entries ?? [] where MusicPersonReader.filmKinds.contains(e.kind) && filmSeen.insert(e.id).inserted { c.films.append(e) }
        }
        c.films.sort { ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) > ($1.year ?? 0) : $0.name < $1.name }
        c.albums = foldAlbums(sections: data.sections)
        c.collaborators = MusicPersonViewData.condensed(data.sections).first { $0.id == .collaborations }?.entries.filter { $0.kind.isAgent } ?? []
        return c
    }

    /// Albums, soundtracks and singles with regional editions of one release folded into one row: the key is the film when the graph names one, else the title
    /// without its bracketed words ("(Original Motion Picture Soundtrack)") and punctuation. The earliest edition is shown.
    static func foldAlbums(sections: [MusicPersonSection]) -> [MusicArtistAlbum] {
        var byKey: [String: MusicArtistAlbum] = [:]
        var order: [String] = []
        for s in sections where albumSections.contains(s.id) {
            for e in s.entries where MusicPersonReader.albumKinds.contains(e.kind) {
                let type = albumType(of: e, in: s.id)
                let title = normalizedTitle(e.name)
                // The same film's soundtrack in several languages is one row; otherwise two releases share a row only with the same words, the same language and years close together.
                var key = "\(type.rawValue)|" + (e.filmID?.rawValue ?? (title.isEmpty ? "id:" + e.id.rawValue : title + "|" + (e.lang ?? "")))
                if e.filmID == nil, let have = byKey[key], let a = have.entry.year, let b = e.year, abs(a - b) > 2 { key += "|\(b)" }
                if var have = byKey[key] {
                    // The same album in two sections is one edition, not two.
                    if have.entry.id == e.id { continue }
                    have.editions += 1
                    if let y = e.year, y < (have.entry.year ?? Int.max) { have.entry = e }
                    byKey[key] = have
                } else { byKey[key] = MusicArtistAlbum(entry: e, type: type, editions: 1); order.append(key) }
            }
        }
        // Two entries with the same id (the same album in two sections) are one, whichever key they met under.
        var ids = Set<MusicEntityID>()
        return order.compactMap { byKey[$0] }.filter { ids.insert($0.entry.id).inserted }
            .sorted { ($0.entry.year ?? 0) != ($1.entry.year ?? 0) ? ($0.entry.year ?? 0) > ($1.entry.year ?? 0) : $0.entry.name < $1.entry.name }
    }

    static func albumType(of e: MusicPersonEntry, in section: MusicPersonSectionID) -> MusicAlbumType {
        switch section {
        case .singles: return .single
        case .soundtracks, .movieSoundtracks, .filmSoundtracks:
            return (e.subkind ?? "").lowercased() == MusicAlbumSubkind.score.rawValue ? .score : .soundtrack
        default: break
        }
        let sub = (e.subkind ?? "").lowercased()
        if sub.contains("soundtrack") || sub == "ost" { return .soundtrack }
        if sub == "single" || sub == "ep" || sub.contains("single") { return .single }
        if sub == MusicAlbumSubkind.compilation.rawValue { return .compilation }
        if sub == MusicAlbumSubkind.score.rawValue { return .score }
        return .album
    }

    static func normalizedTitle(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    var years: [Int] { (songs + albums.map(\.entry) + films).compactMap(\.year).filter { (1850...2100).contains($0) } }
    var yearSpan: ClosedRange<Int>? { years.min().flatMap { lo in years.max().map { lo...$0 } } }

    /// Distinct language codes of the songs and films, most songs first.
    var languages: [(code: String, count: Int)] { MusicArtistFacets.languages(in: songs.isEmpty ? films : songs) }
}

// MARK: pills

enum MusicArtistPills {
    /// The pills this person has. A pill shows only when it has content for the active role; Overview always does.
    /// The pill that is shown: the chosen one when it is available, else Overview (the bar highlights the same one).
    static func active(_ chosen: MusicArtistPill, in pills: [MusicArtistPill]) -> MusicArtistPill { pills.contains(chosen) ? chosen : .overview }

    static func available(_ catalog: MusicArtistCatalog?, hasListening: Bool, hasAbout: Bool) -> [MusicArtistPill] {
        var out: [MusicArtistPill] = [.overview]
        guard let c = catalog else { return hasAbout ? out + [.about] : out }
        if !c.songs.isEmpty { out.append(.songs) }
        if !c.albums.isEmpty { out.append(.albums) }
        if !c.films.isEmpty { out.append(.films) }
        if !c.collaborators.isEmpty { out.append(.collaborators) }
        if MusicArtistTimeline.build(c).count >= 2 { out.append(.timeline) }
        if hasListening { out.append(.listening) }
        if hasAbout { out.append(.about) }
        return out
    }
}

// MARK: facets and filters

enum MusicArtistFacets {
    static func languages(in entries: [MusicPersonEntry]) -> [(code: String, count: Int)] {
        var n: [String: Int] = [:]
        for e in entries { if let c = MusicPersonReader.languageCode(e.lang) { n[c, default: 0] += 1 } }
        return n.map { (code: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.code < $1.code }
    }

    static func decades(in entries: [MusicPersonEntry]) -> [(decade: Int, count: Int)] {
        var n: [Int: Int] = [:]
        for e in entries { if let y = e.year, (1850...2100).contains(y) { n[y / 10 * 10, default: 0] += 1 } }
        return n.map { (decade: $0.key, count: $0.value) }.sorted { $0.decade > $1.decade }
    }

    /// The key a song's film is told apart by: the film's id (two films with one title, a remake, are two), the title only for a song whose film has no id.
    static func filmKey(_ e: MusicPersonEntry) -> String? {
        if let f = e.filmID { return f.rawValue }
        if let t = e.filmTitle, !t.isEmpty { return t }
        return nil
    }

    /// Films the songs belong to, most songs first (at most `limit`). `key` is what the filter compares (`filmKey`); `title` is what the chip says. Two films that
    /// share a title (a remake) stay two chips, each told apart by its id; their chips then carry the film's year.
    static func films(in entries: [MusicPersonEntry], limit: Int = 40) -> [(key: String, title: String, count: Int)] {
        var n: [String: (title: String, year: Int?, count: Int)] = [:]
        for e in entries {
            guard let k = filmKey(e), let t = e.filmTitle, !t.isEmpty else { continue }
            var v = n[k] ?? (title: t, year: nil, count: 0)
            v.count += 1
            if v.year == nil { v.year = e.filmID == nil ? nil : (e.filmYear ?? e.year) }
            n[k] = v
        }
        let titleCount = Dictionary(grouping: Array(n.values), by: { $0.title }).mapValues { $0.count }
        var chips: [(key: String, title: String, count: Int)] = []
        for (key, v) in n {
            var title = v.title
            if (titleCount[v.title] ?? 0) > 1, let y = v.year { title += " (\(y))" }   // told apart by year when two films share a title
            chips.append((key: key, title: title, count: v.count))
        }
        chips.sort { x, y in
            if x.count != y.count { return x.count > y.count }
            if x.title != y.title { return x.title < y.title }
            return x.key < y.key
        }
        return Array(chips.prefix(limit))
    }

    /// Film industries by language, from the languages the entries state (a film of two languages is in both).
    static func industries(in entries: [MusicPersonEntry]) -> [(name: String, code: String, count: Int)] {
        languages(in: entries).compactMap { l in MusicCombineRules.industry(forLanguage: l.code).map { (name: $0, code: l.code, count: l.count) } }
    }
}

enum MusicArtistSongSort: String, CaseIterable, Sendable, Hashable { case title, newest, oldest, duration, mostPlayed }

/// The Songs pill's filters. Empty means "everything". The year is the timeline's scope and applies on every pill.
struct MusicArtistSongFilter: Equatable, Sendable {
    var query = ""
    var language: String?
    var decade: Int?
    /// The film's key (`MusicArtistFacets.filmKey`): its id, or its title when the song's film has no id.
    var film: String?
    var sort: MusicArtistSongSort?
    /// Live, acoustic, remix, instrumental or featured, only where the graph says so.
    var performance: MusicSongPerformance?
    /// A first and last year, either of which may be open.
    var yearFrom: Int?
    var yearTo: Int?
    /// Only the songs liked on this Mac.
    var likedOnly = false

    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || language != nil || decade != nil || film != nil || performance != nil || yearFrom != nil || yearTo != nil || likedOnly
    }

    func apply(to entries: [MusicPersonEntry], year: Int? = nil, personal: MusicArtistPersonal = .empty) -> [MusicPersonEntry] {
        let q = Self.fold(query)
        // A range given backwards still means the span between the two years.
        let range = Self.span(yearFrom, yearTo)
        var out = entries.filter { e in
            if let l = language, MusicPersonReader.languageCode(e.lang) != l { return false }
            if let d = decade, (e.year.map { $0 / 10 * 10 }) != d { return false }
            if let y = year, e.year != y { return false }
            if range.lo != nil || range.hi != nil {
                // A song with no year is not placed in a range (nothing is guessed).
                guard let y = e.year else { return false }
                if let lo = range.lo, y < lo { return false }
                if let hi = range.hi, y > hi { return false }
            }
            if let f = film, MusicArtistFacets.filmKey(e) != f { return false }
            if let p = performance, !MusicSongPerformance.of(e).contains(p) { return false }
            if likedOnly, !personal.isLiked(e) { return false }
            if !q.isEmpty {
                let hay = Self.fold([e.name, e.detail ?? "", e.filmTitle ?? ""].joined(separator: " "))
                if !hay.contains(q) { return false }
            }
            return true
        }
        if let sort { out = Self.sorted(out, by: sort, personal: personal) }
        return out
    }

    /// The first and last year of a range; two years given the wrong way round are swapped.
    static func span(_ from: Int?, _ to: Int?) -> (lo: Int?, hi: Int?) {
        if let a = from, let b = to, a > b { return (b, a) }
        return (from, to)
    }

    static func sorted(_ list: [MusicPersonEntry], by sort: MusicArtistSongSort, personal: MusicArtistPersonal = .empty) -> [MusicPersonEntry] {
        let indexed = Array(list.enumerated())
        func by(_ less: @escaping (MusicPersonEntry, MusicPersonEntry) -> Bool?) -> [MusicPersonEntry] {
            indexed.sorted { a, b in less(a.element, b.element) ?? (a.offset < b.offset) }.map(\.element)
        }
        switch sort {
        case .title: return by { let x = fold($0.name), y = fold($1.name); return x == y ? nil : x < y }
        case .newest: return by { a, b in
            switch (a.year, b.year) { case let (x?, y?): return x == y ? nil : x > y; case (nil, nil): return nil; case (_?, nil): return true; case (nil, _?): return false } }
        case .oldest: return by { a, b in
            switch (a.year, b.year) { case let (x?, y?): return x == y ? nil : x < y; case (nil, nil): return nil; case (_?, nil): return true; case (nil, _?): return false } }
        case .duration: return by { a, b in
            switch (a.durationMs, b.durationMs) { case let (x?, y?): return x == y ? nil : x > y; case (nil, nil): return nil; case (_?, nil): return true; case (nil, _?): return false } }
        case .mostPlayed: return by { a, b in
            let x = personal.playCount(a), y = personal.playCount(b)
            return x == y ? nil : x > y }
        }
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Years, decades and languages for lists of albums and films (the Songs pill has its own filter above).
struct MusicArtistListScope: Equatable, Sendable {
    var decade: Int?
    var language: String?
    var year: Int?
    func apply(to entries: [MusicPersonEntry]) -> [MusicPersonEntry] {
        entries.filter { e in
            if let d = decade, (e.year.map { $0 / 10 * 10 }) != d { return false }
            if let y = year, e.year != y { return false }
            if let l = language, MusicPersonReader.languageCode(e.lang) != l { return false }
            return true
        }
    }
}

// MARK: bounded play sets

enum MusicArtistPlayCap {
    /// The most recordings one "Play these", "Shuffle these" or radio mode resolves. Each is fetched from its provider, so the set stays small and the page says the number.
    static let songs = 50
    /// The top songs a "Play next" or "Add to queue" from the header takes.
    static let queue = 10
    /// Artist essentials: the first this many top songs.
    static let essentials = 25
    static let pageSize = 100

    static func play(_ entries: [MusicPersonEntry], cap: Int = songs) -> [MusicEntityID] { Array(entries.prefix(cap).map(\.id)) }

    static func sample<G: RandomNumberGenerator>(_ entries: [MusicPersonEntry], cap: Int = songs, using g: inout G) -> [MusicEntityID] {
        Array(entries.shuffled(using: &g).prefix(cap).map(\.id))
    }
}

/// The radio modes of the header menu; each resolves a bounded set of recordings that the player then shuffles.
enum MusicArtistRadioMode: Hashable, Sendable {
    case essentials, deepCuts, catalog, language(String), decade(Int)
    /// Songs from films (each song names its film), recent songs (the newest years), one kind of recording the graph states, and songs liked on this Mac.
    case filmMusic, recent, performance(MusicSongPerformance), liked
    /// Discovery: the songs of the catalog never played on this Mac (offered only once there is a play history to tell them from).
    case unplayed

    struct Option: Hashable, Sendable { var mode: MusicArtistRadioMode; var count: Int }

    /// How many of the newest songs the Recent mode draws from.
    static let recentPool = 25

    static func options(_ c: MusicArtistCatalog, personal: MusicArtistPersonal = .empty) -> [Option] {
        var out: [Option] = []
        if !c.primarySongs.isEmpty { out.append(Option(mode: .essentials, count: min(c.primarySongs.count, MusicArtistPlayCap.essentials))) }
        let rest = deepCutSongs(c).count
        if rest > 0, !c.primarySongs.isEmpty { out.append(Option(mode: .deepCuts, count: rest)) }
        if c.songs.count > 1 { out.append(Option(mode: .catalog, count: c.songs.count)) }
        let langs = MusicArtistFacets.languages(in: c.songs)
        if langs.count > 1 { out += langs.prefix(8).map { Option(mode: .language($0.code), count: $0.count) } }
        let decs = MusicArtistFacets.decades(in: c.songs)
        if decs.count > 1 { out += decs.prefix(8).map { Option(mode: .decade($0.decade), count: $0.count) } }
        let films = filmSongs(c).count
        if films > 1 { out.append(Option(mode: .filmMusic, count: films)) }
        let recent = recentSongs(c).count
        if recent > 1, c.songs.count > recentPool { out.append(Option(mode: .recent, count: recent)) }
        for f in MusicSongPerformance.facets(in: c.songs) where f.count > 1 { out.append(Option(mode: .performance(f.kind), count: f.count)) }
        let liked = c.songs.filter { personal.isLiked($0) }.count
        if liked > 1 { out.append(Option(mode: .liked, count: liked)) }
        let fresh = unplayedSongs(c, personal: personal).count
        if fresh > 1, personal.hasPlays { out.append(Option(mode: .unplayed, count: fresh)) }
        return out
    }

    static func deepCutSongs(_ c: MusicArtistCatalog) -> [MusicPersonEntry] {
        let top = Set(c.primarySongs.prefix(MusicArtistPlayCap.essentials).map(\.id))
        return c.songs.filter { !top.contains($0.id) }
    }

    /// The songs of the catalog with no counted play on this Mac.
    static func unplayedSongs(_ c: MusicArtistCatalog, personal: MusicArtistPersonal) -> [MusicPersonEntry] { c.songs.filter { personal.playCount($0) == 0 } }

    /// Songs that name their film.
    static func filmSongs(_ c: MusicArtistCatalog) -> [MusicPersonEntry] { c.songs.filter { $0.filmID != nil } }

    /// The newest songs by year (songs with no year are not placed).
    static func recentSongs(_ c: MusicArtistCatalog) -> [MusicPersonEntry] {
        Array(MusicArtistSongFilter.sorted(c.songs.filter { $0.year != nil }, by: .newest).prefix(recentPool))
    }

    /// The recordings for a mode, never more than `cap` (default `MusicArtistPlayCap.songs`).
    static func ids<G: RandomNumberGenerator>(_ mode: MusicArtistRadioMode, in c: MusicArtistCatalog, cap: Int = MusicArtistPlayCap.songs, personal: MusicArtistPersonal = .empty, using g: inout G) -> [MusicEntityID] {
        switch mode {
        case .essentials: return MusicArtistPlayCap.play(Array(c.primarySongs.prefix(MusicArtistPlayCap.essentials)), cap: cap)
        case .deepCuts: return MusicArtistPlayCap.sample(deepCutSongs(c), cap: cap, using: &g)
        case .catalog: return MusicArtistPlayCap.sample(c.songs, cap: cap, using: &g)
        case .language(let code): return MusicArtistPlayCap.sample(c.songs.filter { MusicPersonReader.languageCode($0.lang) == code }, cap: cap, using: &g)
        case .decade(let d): return MusicArtistPlayCap.sample(c.songs.filter { ($0.year.map { $0 / 10 * 10 }) == d }, cap: cap, using: &g)
        case .filmMusic: return MusicArtistPlayCap.sample(filmSongs(c), cap: cap, using: &g)
        case .recent: return MusicArtistPlayCap.sample(recentSongs(c), cap: cap, using: &g)
        case .performance(let k): return MusicArtistPlayCap.sample(c.songs.filter { MusicSongPerformance.of($0).contains(k) }, cap: cap, using: &g)
        case .liked: return MusicArtistPlayCap.sample(c.songs.filter { personal.isLiked($0) }, cap: cap, using: &g)
        case .unplayed: return personal.hasPlays ? MusicArtistPlayCap.sample(unplayedSongs(c, personal: personal), cap: cap, using: &g) : []
        }
    }
}

// MARK: timeline

struct MusicArtistTimelineEntry: Hashable, Sendable, Identifiable {
    var year: Int
    var songs: Int
    var albums: Int
    var films: Int
    /// The entry the row names: an album, else a film, else a song (the one with the highest count, then the first by name).
    var highlight: MusicPersonEntry?
    var id: Int { year }
    var decade: Int { year / 10 * 10 }
}

enum MusicArtistTimeline {
    /// One entry per year that any song, album or film names, oldest first.
    static func build(_ c: MusicArtistCatalog) -> [MusicArtistTimelineEntry] { build(songs: c.songs, albums: c.albums.map(\.entry), films: c.films) }

    static func build(songs: [MusicPersonEntry], albums: [MusicPersonEntry], films: [MusicPersonEntry]) -> [MusicArtistTimelineEntry] {
        func byYear(_ list: [MusicPersonEntry]) -> [Int: [MusicPersonEntry]] {
            Dictionary(grouping: list.filter { ($0.year).map { (1850...2100).contains($0) } ?? false }, by: { $0.year ?? 0 })
        }
        let s = byYear(songs), a = byYear(albums), f = byYear(films)
        func best(_ l: [MusicPersonEntry]?) -> MusicPersonEntry? {
            l?.sorted { ($0.count ?? 0) != ($1.count ?? 0) ? ($0.count ?? 0) > ($1.count ?? 0) : $0.name < $1.name }.first
        }
        return Set(s.keys).union(a.keys).union(f.keys).sorted().map { y in
            MusicArtistTimelineEntry(year: y, songs: s[y]?.count ?? 0, albums: a[y]?.count ?? 0, films: f[y]?.count ?? 0, highlight: best(a[y]) ?? best(f[y]) ?? best(s[y]))
        }
    }

    /// The pill a tapped year opens: the one with most to show for it, songs first.
    static func target(_ e: MusicArtistTimelineEntry) -> MusicArtistPill {
        if e.songs > 0 { return .songs }
        if e.albums > 0 { return .albums }
        return .films
    }
}

// MARK: overview explore chips

enum MusicArtistExplore {
    struct Options: Equatable, Sendable {
        var languages: [(code: String, count: Int)]
        var decades: [(decade: Int, count: Int)]
        static func == (a: Options, b: Options) -> Bool {
            a.languages.map(\.code) == b.languages.map(\.code) && a.languages.map(\.count) == b.languages.map(\.count)
                && a.decades.map(\.decade) == b.decades.map(\.decade) && a.decades.map(\.count) == b.decades.map(\.count)
        }
        var isEmpty: Bool { languages.isEmpty && decades.isEmpty }
    }

    /// Chips only where choosing one narrows something: a single language or a single decade is not offered.
    static func options(_ c: MusicArtistCatalog, includeLanguages: Bool = true) -> Options {
        let langs = MusicArtistFacets.languages(in: c.songs), decs = MusicArtistFacets.decades(in: c.songs)
        return Options(languages: includeLanguages && langs.count > 1 ? langs : [], decades: decs.count > 1 ? decs : [])
    }
}

// MARK: catalog statistics for About and the header line

struct MusicArtistStats: Equatable, Sendable {
    var songs: Int
    var albums: Int
    var films: Int
    var collaborators: Int
    var languages: [String]
    var span: ClosedRange<Int>?
    var isEmpty: Bool { songs + albums + films + collaborators == 0 }

    init(_ c: MusicArtistCatalog) {
        songs = c.songs.count; albums = c.albums.count; films = c.films.count; collaborators = c.collaborators.count
        languages = c.languages.map(\.code); span = c.yearSpan
    }
}

// MARK: A x B

/// The people to preset in the Combine sheet for "this artist with that collaborator": each in the slot their role names. A role with no slot (actor, director)
/// leaves it empty; nothing is guessed.
struct MusicCombinePreset: Equatable, Sendable, Identifiable {
    struct Slot: Equatable, Sendable { var id: MusicEntityID; var name: String }
    var singer: Slot?
    var composer: Slot?
    var lyricist: Slot?
    var isEmpty: Bool { singer == nil && composer == nil && lyricist == nil }
    /// A preset names its people, so the sheet is rebuilt for each different pair (`.sheet(item:)`).
    var id: String { [singer, composer, lyricist].map { $0.map { String(describing: $0.id) } ?? "-" }.joined(separator: "|") }
    /// Combine needs two people: one slot filled by the page's person and another by the collaborator. Two singers fill the one singer slot, so they are not a pair.
    var isPair: Bool { [singer, composer, lyricist].compactMap { $0 }.count == 2 }

    enum Kind { case singer, composer, lyricist }

    static func kind(of view: MusicPersonView) -> Kind? {
        switch view { case .singer: .singer; case .composer: .composer; case .lyricist: .lyricist; default: nil }
    }

    static func kind(of role: MusicRole?) -> Kind? {
        switch role {
        case .singer, .performer, .featured: .singer
        case .composer, .musicDirector, .arranger: .composer
        case .lyricist, .writer: .lyricist
        default: nil
        }
    }

    static func make(person: MusicEntityID, personName: String, view: MusicPersonView, other: MusicPersonEntry) -> MusicCombinePreset {
        var p = MusicCombinePreset()
        func put(_ k: Kind?, _ s: Slot) {
            guard let k else { return }
            switch k {
            case .singer: if p.singer == nil { p.singer = s }
            case .composer: if p.composer == nil { p.composer = s }
            case .lyricist: if p.lyricist == nil { p.lyricist = s }
            }
        }
        put(kind(of: view), Slot(id: person, name: personName))
        // The collaborator's first role whose slot is still free (a singer-and-composer on a singer page takes the composer slot).
        let free: [Kind] = other.roles.compactMap { kind(of: $0) }.filter { k in
            switch k {
            case .singer: return p.singer == nil
            case .composer: return p.composer == nil
            case .lyricist: return p.lyricist == nil
            }
        }
        put(free.first, Slot(id: other.id, name: other.name))
        return p
    }
}
