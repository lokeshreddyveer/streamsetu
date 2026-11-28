import Foundation

// Search, entity-typed (G10): the people, films, soundtracks, albums, songs and playlists the graph knows for a query, grouped by type, with a best
// match, a "did you mean" and type filters. Searching a person or a film also returns their full works (from the link matrix), so the page for
// "Shankar Jaikishan" is a screen of albums, songs and films and not a single row. Provider results (the existing page) are merged by the page; this is
// the graph and roster side.

enum MusicSearchEntityFilter: String, CaseIterable, Sendable, Hashable {
    case all, songs, albums, soundtracks, films, people, musicDirectors, singers, lyricists, actors, playlists
    var kinds: Set<MusicEntityKind> {
        switch self {
        case .all: []
        case .songs: [.recording, .track, .work]
        case .albums, .soundtracks: [.album, .release]
        case .films: [.film, .series]
        case .people, .musicDirectors, .singers, .lyricists, .actors: [.person, .group]
        case .playlists: [.playlist]
        }
    }
    var role: MusicRole? {
        switch self { case .musicDirectors: .musicDirector; case .singers: .singer; case .lyricists: .lyricist; case .actors: .actor; default: nil }
    }
}

struct MusicSearchEntityRow: Hashable, Sendable, Identifiable {
    var entity: MusicEntityID
    var tileKind: MusicFillTileKind
    var title: String
    /// "Music director · Hindi film music" or "Soundtrack · Awaara (1951)".
    var subtitle: String
    var imageRef: String?
    var role: MusicRole?
    var score: Float
    var id: String { entity.rawValue }
}

struct MusicSearchEntityResult: Sendable {
    var query: String
    var best: MusicSearchEntityRow?
    var groups: [(filter: MusicSearchEntityFilter, rows: [MusicSearchEntityRow])]
    var didYouMean: String?
    /// For a best match that is a person or film: its works, from the link matrix.
    var works: MusicLinkSet?
    var isEmpty: Bool { best == nil && groups.allSatisfy { $0.rows.isEmpty } }

    func rows(_ f: MusicSearchEntityFilter) -> [MusicSearchEntityRow] {
        if f == .all { return groups.flatMap(\.rows) }
        return groups.first { $0.filter == f }?.rows ?? []
    }
    /// Filters that have rows (the chips show only these).
    var availableFilters: [MusicSearchEntityFilter] { groups.filter { !$0.rows.isEmpty }.map(\.filter) }
}

enum MusicSearchEntities {
    static let perGroup = 12

    // MARK: typing

    /// Damerau-Levenshtein (adjacent swaps count once) on folded Latin skeletons.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }

    /// The closest known name within two edits (one for short words), or nil when the query already matches a name or nothing is close. `names` are
    /// the roster, the graph's recent hits and the library's titles; the nearest wins, ties go to the earlier name (more popular first).
    static func didYouMean(_ query: String, names: [String]) -> String? {
        let q = Array(MusicGraphText.latin(query))
        guard q.count >= 3 else { return nil }
        let limit = q.count <= 5 ? 1 : 2
        var best: (name: String, d: Int)?
        for n in names {
            let l = Array(MusicGraphText.latin(n))
            if l == q { return nil }
            // a prefix of a longer name is a match, not a typo
            if l.count > q.count, Array(l.prefix(q.count)) == q { return nil }
            let d = distance(q, l.count > q.count + limit ? Array(l.prefix(q.count)) : l)
            if d <= limit, best == nil || d < best!.d { best = (n, d) }
        }
        return best?.name
    }

    // MARK: building

    static func bestMatch(query: String, rows: [MusicSearchEntityRow]) -> MusicSearchEntityRow? {
        let q = MusicGraphText.latin(query)
        func rank(_ r: MusicSearchEntityRow) -> (Int, Float, Int) {
            let n = MusicGraphText.latin(r.title)
            let tier = n == q ? 0 : (n.hasPrefix(q) ? 1 : 2)
            let kindPriority: Int
            switch r.tileKind { case .musicDirector, .singer, .lyricist, .actor, .person: kindPriority = 0; case .film: kindPriority = 1; case .soundtrack, .album: kindPriority = 2; default: kindPriority = 3 }
            return (tier, -r.score, kindPriority)
        }
        return rows.min { a, b in rank(a) < rank(b) }
    }

    /// The group a row sits in. A soundtrack album sits in `.soundtracks` and not in `.albums`; a person sits in `.people` and in their role's group.
    static func groupKeys(_ r: MusicSearchEntityRow) -> [MusicSearchEntityFilter] {
        switch r.tileKind {
        case .song: [.songs]
        case .album: [.albums]
        case .soundtrack: [.soundtracks]
        case .film: [.films]
        case .playlist: [.playlists]
        case .musicDirector: [.people, .musicDirectors]
        case .singer: [.people, .singers]
        case .lyricist: [.people, .lyricists]
        case .actor: [.people, .actors]
        case .person: [.people]
        default: []
        }
    }

    static func search(_ query: String, store: any MusicGraphStoring, extraNames: [String] = [], wording: MusicFillWording = .english, withWorks: Bool = true) async -> MusicSearchEntityResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return MusicSearchEntityResult(query: q, best: nil, groups: [], didYouMean: nil, works: nil) }
        let r = MusicFillResolver(store: store, wording: wording)
        var hits = (try? await store.search(q, kinds: [], limit: 40)) ?? []
        let qLat = MusicGraphText.latin(q)
        hits = Array(hits.prefix(40))
        var rows: [MusicSearchEntityRow] = []
        for h in hits {
            guard !MusicLinkMatrix.isVariousArtists(h.name), let s = try? await store.entity(h.id), s.state == .live else { continue }
            var kind: MusicFillTileKind
            var role: MusicRole?
            switch s.kind {
            case .recording, .track, .work: kind = .song
            case .album, .release: kind = (s.subkind == "soundtrack" || s.subkind == "score") ? .soundtrack : .album
            case .film, .series:
                if MusicFranchise.isFranchise(s.subkind) { continue }   // a franchise has no page of its own: its films are reached from a film's Details
                kind = .film
            case .playlist: kind = .playlist
            case .person, .group:
                (kind, role) = await personKind(s.id, store: store)
            default: continue
            }
            let sub = await subtitle(for: s, kind: kind, role: role, store: store, resolver: r)
            rows.append(MusicSearchEntityRow(entity: s.id, tileKind: kind, title: kind == .film ? MusicFillLine.filmCaption(s.name, year: s.year) : s.name,
                                             subtitle: sub, imageRef: s.imageRef, role: role, score: h.score))
        }
        var seen = Set<String>()
        rows = rows.filter { seen.insert($0.id).inserted }
        let order: [MusicSearchEntityFilter] = [.people, .films, .soundtracks, .albums, .songs, .playlists, .musicDirectors, .singers, .lyricists, .actors]
        var groups: [(filter: MusicSearchEntityFilter, rows: [MusicSearchEntityRow])] = []
        for f in order {
            let g = rows.filter { groupKeys($0).contains(f) }.sorted { $0.score > $1.score }
            if !g.isEmpty { groups.append((f, Array(g.prefix(perGroup)))) }
        }
        let best = bestMatch(query: q, rows: rows)
        var works: MusicLinkSet?
        if withWorks, let b = best, [.musicDirector, .singer, .lyricist, .actor, .person, .film, .soundtrack].contains(b.tileKind) {
            works = await MusicLinkMatrix.read(b.entity, store: store)
        }
        let names = extraNames + rows.map(\.title)
        let dym = rows.isEmpty || (best.map { MusicGraphText.latin($0.title).hasPrefix(qLat) } == false) ? didYouMean(q, names: names) : nil
        return MusicSearchEntityResult(query: q, best: best, groups: groups, didYouMean: dym, works: works)
    }

    /// A person's main role from the credits that point at them (the most frequent role wins; ties go to music director, singer, lyricist, actor).
    static func personKind(_ id: MusicEntityID, store: any MusicGraphStoring) async -> (MusicFillTileKind, MusicRole?) {
        let edges = (try? await store.edges(of: id, predicate: nil, direction: .incoming, limit: 100)) ?? []
        var counts: [MusicConnectionKind: Int] = [:]
        for e in edges {
            let role: MusicRole? = e.role ?? { switch e.predicate { case .composedBy, .musicDirectedBy: .musicDirector; case .writtenBy: .lyricist; case .performedBy: .singer; case .hasCast: .actor; default: nil } }()
            let k = MusicConnectionKind.person(role: role)
            if k != .artist { counts[k, default: 0] += 1 }
        }
        let prio: [MusicConnectionKind] = [.musicDirector, .singer, .lyricist, .actor]
        guard let top = prio.max(by: { (counts[$0] ?? 0) != (counts[$1] ?? 0) ? (counts[$0] ?? 0) < (counts[$1] ?? 0) : prio.firstIndex(of: $0)! > prio.firstIndex(of: $1)! }), (counts[top] ?? 0) > 0 else { return (.person, nil) }
        switch top {
        case .musicDirector: return (.musicDirector, .musicDirector)
        case .singer: return (.singer, .singer)
        case .lyricist: return (.lyricist, .lyricist)
        default: return (.actor, .actor)
        }
    }

    private static func subtitle(for s: MusicEntitySnapshot, kind: MusicFillTileKind, role: MusicRole?, store: any MusicGraphStoring, resolver r: MusicFillResolver) async -> String {
        var parts: [String?] = [s.kind == .series && kind == .film ? r.wording.s("Series") : r.kindLabel(kind)]
        switch kind {
        case .song, .album, .soundtrack:
            let edges = (try? await store.edges(of: s.id, predicate: nil, direction: .outgoing, limit: 40)) ?? []
            if let f = edges.first(where: { $0.predicate == .soundtrackOf || $0.predicate == .featuredIn }), let film = try? await store.entity(f.object) {
                parts.append(MusicFillLine.filmCaption(film.name, year: film.year))
            }
            if let p = edges.first(where: { $0.predicate == .musicDirectedBy || $0.predicate == .composedBy }), let who = try? await store.entity(p.object), !MusicLinkMatrix.isVariousArtists(who.name) { parts.append(who.name) }
            else if let p = edges.first(where: { $0.predicate == .performedBy }), let who = try? await store.entity(p.object), !MusicLinkMatrix.isVariousArtists(who.name) { parts.append(who.name) }
        case .film: parts.append(MusicFillLanguage.name(s.lang))
        default: parts.append(MusicFillLanguage.name(s.lang)); parts.append(MusicFillLine.decade(s.year))
        }
        return MusicFillLine.join(parts)
    }
}
