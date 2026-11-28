import Foundation

// The Credits tab's data (section 6.10): the playing song's people grouped by role, with the film and album it belongs to and where each fact came
// from. The loader reads only the graph (edges, facts, names), reports what it has as soon as it has the song's own credits, and again when the album
// and film credits are in; the layout is a pure function of what the section holds, so the tab never reshuffles while a later part lands.

/// The headings of the tab, in display order.
enum MusicCreditGroup: String, CaseIterable, Sendable, Hashable {
    case singers, composers, lyricists, musicDirectors, producers, other

    /// English heading; the tab passes it through `Localized.string`.
    var title: String {
        switch self {
        case .singers: "Singers"
        case .composers: "Composers"
        case .lyricists: "Lyricists"
        case .musicDirectors: "Music directors"
        case .producers: "Producers"
        case .other: "Other contributors"
        }
    }

    static func group(for role: MusicRole) -> MusicCreditGroup {
        switch role {
        case .singer, .performer, .featured: .singers
        case .composer, .arranger, .conductor: .composers
        case .lyricist, .writer: .lyricists
        case .musicDirector: .musicDirectors
        case .producer: .producers
        default: .other
        }
    }
}

/// Where a link on the tab goes: an entity page.
struct MusicCreditTarget: Hashable, Sendable {
    var id: MusicEntityID
    var name: String
    /// The link was inferred (a film credited to a song because its soundtrack album is of that film), not stated by a source.
    var inferred: Bool
    var year: Int?
    var sources: [String]
}

/// One credited person in one role.
struct MusicCreditEntry: Hashable, Sendable {
    var person: MusicEntityID
    var name: String
    var role: MusicRole
    var level: CreditLevel
    /// The credit comes from the album or the film rather than this song (the "film credit" tag of design decision D7).
    var inherited: Bool
    var sources: [String]
    var order: Int
    /// A birth year or country, kept so two people with one name can be told apart.
    var hint: String?
}

enum MusicSongCreditItem: Hashable, Sendable {
    case song(id: MusicEntityID, title: String, version: MusicVersionKind?)
    case credit(MusicCreditEntry)
    case film(MusicCreditTarget)
    case album(MusicCreditTarget)
}

enum MusicSourceNames {
    /// "MusicBrainz", "Wikidata", "TMDB"; a provider shows under its own id with the first letter capitalised.
    static func display(_ s: MusicSourceID) -> String {
        switch s.rawValue {
        case "musicbrainz": "MusicBrainz"
        case "wikidata": "Wikidata"
        case "tmdb": "TMDB"
        case "imdb": "IMDb"
        case "listenbrainz": "ListenBrainz"
        case "discogs": "Discogs"
        case "jiosaavn": "JioSaavn"
        case "appleMusic": "Apple Music"
        case "ytMusic": "YouTube Music"
        case "wikipedia": "Wikipedia"
        case "omdb": "OMDb"
        case "lastfm": "Last.fm"
        case "user": "You"
        case "matcher": "Matched by the app"
        default: s.rawValue.prefix(1).uppercased() + s.rawValue.dropFirst()
        }
    }
}

/// The tab's layout: only groups with people, people merged per group, the film and album links, and the lines of small print.
struct MusicCreditsLayout: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        var person: MusicEntityID
        var name: String
        /// The roles this person has in this group, in order (a person can be both composer and arranger).
        var roles: [MusicRole]
        /// What a tap opens: the person page on the group's main role.
        var linkRole: MusicRole
        var inherited: Bool
        /// Where the credit was read: the song itself, its album, or only the film (shown as a small tag).
        var level: CreditLevel
        var hint: String?
        var sources: [String]
    }
    struct Group: Equatable, Sendable {
        var group: MusicCreditGroup
        var rows: [Row]
    }
    var songTitle: String
    var version: MusicVersionKind?
    /// The song's own credits, and nothing else: a credit read from the album or the film never sits here.
    var groups: [Group]
    /// Credits read from the song's album, shown apart ("From the album") so they are never taken for the song's own.
    var fromAlbum: [Group] = []
    /// Credits read from the film, shown apart ("From the film"). A film-level credit is never copied into the song's groups.
    var fromFilm: [Group] = []
    var film: MusicCreditTarget?
    var album: MusicCreditTarget?
    /// Every source that contributed, most trusted first, for the "Source: ..." line.
    var sources: [String]
    /// "Not credited in the sources we checked": only when the loading is finished and not one person is credited.
    var showsEmptyLine: Bool
    var hasPeople: Bool { !groups.isEmpty || !fromAlbum.isEmpty || !fromFilm.isEmpty }

    static let empty = MusicCreditsLayout(songTitle: "", version: nil, groups: [], fromAlbum: [], fromFilm: [], film: nil, album: nil, sources: [], showsEmptyLine: false)

    static func make(items: [MusicSongCreditItem], phase: MusicSectionPhase) -> MusicCreditsLayout {
        var title = "", version: MusicVersionKind?
        var film: MusicCreditTarget?, album: MusicCreditTarget?
        var credits: [MusicCreditEntry] = []
        for i in items {
            switch i {
            case .song(_, let t, let v): title = t; version = v
            case .credit(let c): credits.append(c)
            case .film(let f): film = film ?? f
            case .album(let a): album = album ?? a
            }
        }
        // The same person in the same role from the song and from its album or film: keep the song's own (the more specific) credit.
        var best: [String: MusicCreditEntry] = [:]
        for c in credits {
            let k = c.person.rawValue + "|" + c.role.rawValue
            if let cur = best[k], !(cur.inherited && !c.inherited) { continue }
            best[k] = c
        }
        var peopleByName: [String: Set<MusicEntityID>] = [:]
        for c in best.values { peopleByName[c.name.lowercased(), default: []].insert(c.person) }
        // Three lists that never mix: the song's own credits, those read from its album, those read from its film.
        let own = best.values.filter { !$0.inherited }
        let albumLevel = best.values.filter { $0.inherited && $0.level == .album }
        let filmLevel = best.values.filter { $0.inherited && $0.level != .album }
        let groups = buildGroups(own, peopleByName: peopleByName)
        let albumGroups = buildGroups(albumLevel, peopleByName: peopleByName)
        let filmGroups = buildGroups(filmLevel, peopleByName: peopleByName)
        var all: [String] = []
        for c in credits { all = merge(all, c.sources) }
        if let f = film { all = merge(all, f.sources) }
        if let a = album { all = merge(all, a.sources) }
        let finished = phase == .loaded || phase == .empty
        let nobody = groups.isEmpty && albumGroups.isEmpty && filmGroups.isEmpty
        return MusicCreditsLayout(songTitle: title, version: version, groups: groups, fromAlbum: albumGroups, fromFilm: filmGroups, film: film, album: album, sources: all, showsEmptyLine: finished && nobody)
    }

    /// People merged per group, in the fixed heading order; a name shared by two different people carries a hint to tell them apart.
    private static func buildGroups(_ credits: [MusicCreditEntry], peopleByName: [String: Set<MusicEntityID>]) -> [Group] {
        var byGroup: [MusicCreditGroup: [MusicCreditEntry]] = [:]
        for c in credits { byGroup[MusicCreditGroup.group(for: c.role), default: []].append(c) }
        var groups: [Group] = []
        for g in MusicCreditGroup.allCases {
            guard let list = byGroup[g], !list.isEmpty else { continue }
            let sorted = list.sorted { a, b in
                if a.order != b.order { return a.order < b.order }
                return a.name != b.name ? a.name < b.name : a.person < b.person
            }
            var rows: [Row] = []
            var index: [MusicEntityID: Int] = [:]
            for c in sorted {
                if let i = index[c.person] {
                    if !rows[i].roles.contains(c.role) { rows[i].roles.append(c.role) }
                    rows[i].sources = merge(rows[i].sources, c.sources)
                    continue
                }
                index[c.person] = rows.count
                let clash = (peopleByName[c.name.lowercased()]?.count ?? 1) > 1
                rows.append(Row(person: c.person, name: c.name, roles: [c.role], linkRole: c.role, inherited: c.inherited, level: c.level,
                                hint: clash ? c.hint : nil, sources: c.sources))
            }
            groups.append(Group(group: g, rows: rows))
        }
        return groups
    }

    private static func merge(_ a: [String], _ b: [String]) -> [String] { a + b.filter { !a.contains($0) } }
}

/// Reads one song's credits from the graph. Key `songCredits`.
struct MusicSongCreditsLoader: MusicEntitySectionLoader {
    static let sectionKey = "songCredits"
    var key: String { Self.sectionKey }
    /// Edges read per node.
    var maxEdges = 120
    var minInferred: Float = 0.3

    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let song = try await store.entity(entity)
        var items: [MusicSongCreditItem] = []
        if let s = song {
            let v = s.attrs["versionKind"].flatMap(MusicVersionKind.init(rawValue:))
            items.append(.song(id: s.id, title: s.name, version: (v == nil || v == .original || v == .unknown) ? nil : v))
        }
        var seenSources: [MusicSourceID] = []
        func note(_ ids: [MusicSourceID]) { for x in ids where !seenSources.contains(x) { seenSources.append(x) } }
        func provenance() -> [MusicSectionProvenance] { seenSources.map { MusicSectionProvenance(source: $0) } }

        // 1. The song's own edges: its people, its album and its film.
        let edges = try await store.edges(of: entity, predicate: nil, direction: .outgoing, limit: maxEdges)
        var albumEdge: MusicEdge?, filmEdge: MusicEdge?
        for e in edges where usable(e) {
            switch e.predicate {
            case .performedBy, .composedBy, .musicDirectedBy, .writtenBy, .producedBy:
                if let c = try await entry(for: e, level: e.creditLevel == .unknown ? .song : e.creditLevel, inherited: false, store: store) {
                    items.append(.credit(c.entry)); note(c.ids)
                }
            case .trackOn: if albumEdge == nil || (e.order ?? 0) < (albumEdge?.order ?? 0) { albumEdge = e }
            case .featuredIn: filmEdge = filmEdge ?? e
            default: break
            }
        }
        if let e = albumEdge, let t = try await target(for: e.object, via: e, store: store) { items.append(.album(t.target)); note(t.ids) }
        if let e = filmEdge, let t = try await target(for: e.object, via: e, store: store) { items.append(.film(t.target)); note(t.ids) }
        await report.partial(MusicSectionResult(items: items.map { AnyHashable($0) }, provenance: provenance()))

        // 2. The album's and the film's own credits fill the roles the song does not carry, tagged as inherited; a soundtrack album also names the film.
        var inheritedFrom: [(MusicEntityID, CreditLevel)] = []
        if let e = albumEdge {
            inheritedFrom.append((e.object, .album))
            if filmEdge == nil {
                let ae = try await store.edges(of: e.object, predicate: .soundtrackOf, direction: .outgoing, limit: 5)
                if let f = ae.first(where: usable), var t = try await target(for: f.object, via: f, store: store) {
                    t.target.inferred = t.target.inferred || e.status != .verified   // the song-to-album link is part of the chain
                    items.append(.film(t.target)); note(t.ids); filmEdge = f
                }
            }
        }
        if let f = filmEdge { inheritedFrom.append((f.object, .film)) }
        for (node, level) in inheritedFrom {
            let ne = try await store.edges(of: node, predicate: nil, direction: .outgoing, limit: maxEdges)
            for e in ne where usable(e) && [.composedBy, .musicDirectedBy, .writtenBy, .producedBy].contains(e.predicate) {
                if let c = try await entry(for: e, level: level, inherited: true, store: store) { items.append(.credit(c.entry)); note(c.ids) }
            }
        }
        return MusicSectionResult(items: items.map { AnyHashable($0) }, provenance: provenance())
    }

    private func usable(_ e: MusicEdge) -> Bool { recEdgeIsUsable(e, floor: minInferred) }

    /// The sources that assert an edge, most trusted first.
    private func sourceIDs(for e: MusicEdge, store: any MusicGraphStoring) async throws -> [MusicSourceID] {
        let facts = try await store.facts(for: e.key).filter { $0.stance == .asserts && !$0.isExpired(at: Date()) }
        var out: [MusicSourceID] = []
        for f in facts.sorted(by: { $0.source.rank != $1.source.rank ? $0.source.rank > $1.source.rank : $0.source.rawValue < $1.source.rawValue }) where !out.contains(f.source) { out.append(f.source) }
        return out
    }
    private func names(_ ids: [MusicSourceID]) -> [String] {
        var out: [String] = []
        for i in ids { let n = MusicSourceNames.display(i); if !out.contains(n) { out.append(n) } }
        return out
    }

    private func entry(for e: MusicEdge, level: CreditLevel, inherited: Bool, store: any MusicGraphStoring) async throws -> (entry: MusicCreditEntry, ids: [MusicSourceID])? {
        guard e.object.kind.isAgent, let p = try await store.entity(e.object), p.state == .live else { return nil }
        let ids = try await sourceIDs(for: e, store: store)
        let hint = p.year.map { "b. \($0)" } ?? p.country
        return (MusicCreditEntry(person: p.id, name: p.name, role: MusicRecRoles.role(of: e), level: level, inherited: inherited,
                                 sources: names(ids), order: e.order ?? 999, hint: hint), ids)
    }

    private func target(for id: MusicEntityID, via e: MusicEdge, store: any MusicGraphStoring) async throws -> (target: MusicCreditTarget, ids: [MusicSourceID])? {
        guard let s = try await store.entity(id), s.state == .live else { return nil }
        let ids = try await sourceIDs(for: e, store: store)
        return (MusicCreditTarget(id: s.id, name: s.name, inferred: e.status != .verified, year: s.year, sources: names(ids)), ids)
    }
}
