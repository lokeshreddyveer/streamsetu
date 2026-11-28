import Foundation

extension MusicPersonReader {
    static let filmExpandCap = 24

    /// Films of a person in a cinema view (actor or director), in the order they should be expanded: lead billing first, then the source's popularity,
    /// then newest. The first `filmExpandCap` are read for soundtracks and crew; the rest only appear in the filmography.
    func cinemaFilms(view: MusicPersonView) async -> [(entry: MusicPersonEntry, edge: MusicEdge)] {
        let films = await works(view: view, kinds: Self.filmKinds, cap: Self.grid)
        return films.map { (entry($0.snap, edge: $0.edge), $0.edge) }
    }

    static func expansionOrder(_ a: MusicPersonEntry, _ b: MusicPersonEntry) -> Bool {
        let (ba, bb) = (a.billing ?? 999, b.billing ?? 999)
        if ba != bb { return ba < bb }
        return newestFirst(a, b)
    }

    /// Popular films among the expanded ones: lead billing, soundtrack albums known, the source's own popularity.
    static func popularity(_ f: MusicPersonEntry, soundtracks: Int, source: Int) -> Double {
        var s = Double(source) * 10 + Double(min(soundtracks, 3)) * 20
        if let b = f.billing { s += b <= 2 ? 30 : (b <= 5 ? 10 : 0) }
        return s
    }

    /// Other films of the people a film list shares: for each agent, their incoming credit edges of one predicate on films not in `exclude`.
    func filmsOf(agents: [MusicEntityID], predicates: [MusicPredicate], exclude: Set<MusicEntityID>, reason: (String) -> MusicPersonReason, perAgent: Int = 8, cap: Int) async -> [MusicPersonEntry] {
        var out: [MusicPersonEntry] = []
        var seen = exclude
        for a in agents {
            guard let agent = await snapshot(a) else { continue }
            var taken = 0
            for p in predicates {
                for e in await incoming(a, p, limit: 20) where Self.filmKinds.contains(e.subject.kind) && MusicPersonRoles.counts(e) && seen.insert(e.subject).inserted {
                    if taken >= perAgent || out.count >= cap || Task.isCancelled { break }
                    guard let f = await snapshot(e.subject) else { continue }
                    var x = MusicPersonEntry(snapshot: f)
                    x.reason = reason(agent.name); x.status = e.status; x.confidence = e.confidence
                    out.append(x); taken += 1
                }
            }
        }
        return out
    }

    /// ACTOR: filmography, popular movies, movie soundtracks, popular songs from their movies, co-stars, directors worked with, related cinema.
    func buildActor(_ report: @escaping Report) async throws -> MusicPersonViewData {
        let view = MusicPersonView.actor
        var sections: [MusicPersonSection] = []
        let credited = await cinemaFilms(view: view)
        let filmography = credited.map(\.entry).sorted(by: Self.newestFirst)
        let total = await creditCount(view: view, kinds: Self.filmKinds)
        sections.append(MusicPersonSection(.filmography, filmography, total: max(total, filmography.count)))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        // films to expand: lead roles first
        let expand = Array(credited.map(\.entry).sorted(by: Self.expansionOrder).prefix(Self.filmExpandCap))
        let st = await soundtracks(of: expand.map(\.id))
        let popular = expand.map { f -> (MusicPersonEntry, Double) in
            let src = (snapCache[f.id].map(Self.popularity) ?? 0)
            return (f, Self.popularity(f, soundtracks: st[f.id]?.count ?? 0, source: src))
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : Self.newestFirst($0.0, $1.0) }.map(\.0)
        if filmography.count > 6 { sections.append(Self.cut(.popularMovies, popular, to: Self.shelf)) }
        let albums = popular.flatMap { st[$0.id] ?? [] }
        sections.append(Self.cut(.movieSoundtracks, Self.unique(albums), to: Self.grid))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        // songs of their movies (from the film, not "picturised on them")
        var songs: [MusicPersonEntry] = []
        for f in popular.prefix(12) {
            if Task.isCancelled { break }
            songs += await self.songs(ofFilm: f.id, albums: st[f.id] ?? [], limit: 6)
        }
        var songEntries = Self.unique(songs)
        for i in songEntries.indices.prefix(12) { songEntries[i].detail = await performerLine(of: songEntries[i].id) }
        sections.append(Self.cut(.songsFromMovies, songEntries, to: 24))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        // people around the films
        let filmIDs = expand.map(\.id)
        let stars = MusicCollaboration.rank(await observations(of: filmIDs, roles: [.actor], releaseLevel: false, filmLevel: false), excluding: [person], limit: 24)
        let directors = MusicCollaboration.rank(await observations(of: filmIDs, roles: [.director], releaseLevel: false, filmLevel: false), excluding: [person], limit: 12)
        let musicDirectors = MusicCollaboration.rank(await observations(of: filmIDs, roles: MusicPersonView.composer.roles, releaseLevel: false, filmLevel: false), excluding: [person], limit: 6)
        sections.append(Self.cut(.coStars, await collaboratorEntries(stars) { .sharedFilms($0.workCount) }, to: Self.shelf * 2))
        sections.append(Self.cut(.directorsWorkedWith, await collaboratorEntries(directors) { .sharedFilms($0.workCount) }, to: Self.shelf))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        // related cinema: more films by their directors and music directors
        let known = Set(credited.map(\.entry.id))
        var related = await filmsOf(agents: directors.prefix(3).map(\.id), predicates: [.directedBy], exclude: known, reason: { .sameDirector($0) }, cap: 16)
        related += await filmsOf(agents: musicDirectors.prefix(2).map(\.id), predicates: [.musicDirectedBy, .composedBy], exclude: known.union(related.map(\.id)), reason: { .sameMusicDirector($0) }, cap: 12)
        sections.append(Self.cut(.relatedCinema, related, to: Self.grid))
        return data(view, sections, complete: true)
    }

    /// DIRECTOR: filmography, film soundtracks, composers collaborated with, frequent cast, related films.
    func buildDirector(_ report: @escaping Report) async throws -> MusicPersonViewData {
        let view = MusicPersonView.director
        var sections: [MusicPersonSection] = []
        let credited = await cinemaFilms(view: view)
        let filmography = credited.map(\.entry).sorted(by: Self.newestFirst)
        sections.append(MusicPersonSection(.filmography, filmography, total: max(await creditCount(view: view, kinds: Self.filmKinds), filmography.count)))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        let expand = Array(credited.map(\.entry).sorted(by: Self.newestFirst).prefix(Self.filmExpandCap))
        let st = await soundtracks(of: expand.map(\.id))
        sections.append(Self.cut(.filmSoundtracks, Self.unique(expand.flatMap { st[$0.id] ?? [] }), to: Self.grid))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        let ids = expand.map(\.id)
        let composers = MusicCollaboration.rank(await observations(of: ids, roles: MusicPersonView.composer.roles, releaseLevel: false, filmLevel: false), excluding: [person], limit: 12)
        let cast = MusicCollaboration.rank(await observations(of: ids, roles: [.actor], releaseLevel: false, filmLevel: false), excluding: [person], minCount: 2, limit: 16)
        sections.append(Self.cut(.composersCollaborated, await collaboratorEntries(composers) { .sharedFilms($0.workCount) }, to: Self.shelf))
        sections.append(Self.cut(.frequentCast, await collaboratorEntries(cast) { .sharedFilms($0.workCount) }, to: Self.shelf * 2))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        let known = Set(credited.map(\.entry.id))
        var related = await filmsOf(agents: composers.prefix(3).map(\.id), predicates: [.musicDirectedBy, .composedBy], exclude: known, reason: { .sameMusicDirector($0) }, cap: 14)
        related += await filmsOf(agents: cast.prefix(2).map(\.id), predicates: [.hasCast], exclude: known.union(related.map(\.id)), reason: { .sharedCast($0) }, cap: 10)
        sections.append(Self.cut(.relatedFilms, related, to: Self.grid))
        return data(view, sections, complete: true)
    }
}
