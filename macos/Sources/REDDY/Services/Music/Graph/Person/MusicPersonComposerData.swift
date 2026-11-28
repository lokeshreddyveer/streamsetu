import Foundation

extension MusicPersonReader {
    /// Films reached through the songs: one entry per film with how many of the person's songs are in it.
    func filmsOfSongs(_ songs: [(snap: MusicEntitySnapshot, edge: MusicEdge)], limit: Int = 40) async -> [MusicPersonEntry] {
        var byFilm: [MusicEntityID: (link: FilmLink, n: Int)] = [:]
        for s in songs.prefix(limit) {
            if Task.isCancelled { break }
            guard let l = await filmLink(of: s.snap.id) else { continue }
            if let cur = byFilm[l.film] { byFilm[l.film] = (cur.link.status == .verified ? cur.link : l, cur.n + 1) } else { byFilm[l.film] = (l, 1) }
        }
        var out: [MusicPersonEntry] = []
        for (id, v) in byFilm {
            guard let f = await snapshot(id) else { continue }
            var e = MusicPersonEntry(snapshot: f)
            e.count = v.n; e.status = v.link.status; e.confidence = v.link.confidence
            if v.link.status != .verified && v.link.confidence < 0.75 { e.reason = .possibleFilmLink(f.name) }
            out.append(e)
        }
        return out.sorted(by: Self.newestFirst)
    }

    /// Soundtrack albums of films (incoming `soundtrackOf`), keyed by film.
    func soundtracks(of films: [MusicEntityID]) async -> [MusicEntityID: [MusicPersonEntry]] {
        var out: [MusicEntityID: [MusicPersonEntry]] = [:]
        for f in films {
            if Task.isCancelled { break }
            let fs = await snapshot(f)
            for e in await incoming(f, .soundtrackOf, limit: 8) where Self.albumKinds.contains(e.subject.kind) {
                guard let a = await snapshot(e.subject) else { continue }
                var x = MusicPersonEntry(snapshot: a)
                x.status = e.status; x.confidence = e.confidence
                if let fs { x.filmID = fs.id; x.filmTitle = fs.name; x.filmYear = fs.year; x.reason = e.status != .verified && e.confidence < 0.75 ? .possibleFilmLink(fs.name) : .fromFilm(fs.name) }
                out[f, default: []].append(x)
            }
        }
        return out
    }

    /// Songs of a film, from its soundtrack albums' tracklists and from stated `featuredIn` links, in track order, at most `limit`.
    func songs(ofFilm film: MusicEntityID, albums: [MusicPersonEntry], limit: Int) async -> [MusicPersonEntry] {
        var songIDs: [(MusicEntityID, Int)] = []
        for a in albums.prefix(2) { for e in await incoming(a.id, .trackOn, limit: 24) where Self.songKinds.contains(e.subject.kind) { songIDs.append((e.subject, e.attributes.position ?? e.order ?? 999)) } }
        for e in await incoming(film, .featuredIn, limit: 24) where Self.songKinds.contains(e.subject.kind) { songIDs.append((e.subject, 998)) }
        var seen = Set<MusicEntityID>(), out: [MusicPersonEntry] = []
        let filmSnap = await snapshot(film)
        for (id, _) in songIDs.sorted(by: { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }) where seen.insert(id).inserted {
            if out.count >= limit || Task.isCancelled { break }
            guard let s = await snapshot(id) else { continue }
            var e = MusicPersonEntry(snapshot: s)
            e.filmID = film; e.filmTitle = filmSnap?.name; e.filmYear = filmSnap?.year
            out.append(e)
        }
        return out
    }

    /// COMPOSER / MUSIC DIRECTOR: popular compositions, soundtracks, albums, films, singers, lyricists, related composers.
    func buildComposer(_ report: @escaping Report) async throws -> MusicPersonViewData {
        let view = MusicPersonView.composer
        var sections: [MusicPersonSection] = []
        var songs = await works(view: view, kinds: Self.songKinds, cap: Self.compositions)
        let albumCredits = await works(view: view, kinds: Self.albumKinds, cap: Self.albumCap)
        // A composer credited on an album only (no song-level credits): the album's tracks stand in, marked by their level in the credits later.
        if songs.isEmpty {
            for (a, e) in albumCredits.prefix(3) {
                for t in await incoming(a.id, .trackOn, limit: 20) where Self.songKinds.contains(t.subject.kind) { if let s = await snapshot(t.subject) { songs.append((s, e)) } }
            }
        }
        let top = songs.map { entry($0.snap, edge: $0.edge) }
        sections.append(Self.cut(.popularCompositions, top, to: Self.compositions))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        // albums vs soundtracks
        var soundtrackEntries: [MusicPersonEntry] = [], albumEntries: [MusicPersonEntry] = []
        for (a, e) in albumCredits {
            var x = entry(a, edge: e)
            var isSoundtrack = a.subkind == MusicAlbumSubkind.soundtrack.rawValue
            if let l = await filmLink(of: a.id), let f = await snapshot(l.film) {
                isSoundtrack = true
                x.filmID = f.id; x.filmTitle = f.name; x.filmYear = f.year; x.reason = Self.reason(for: l, filmTitle: f.name)
            }
            if isSoundtrack { soundtrackEntries.append(x) } else { albumEntries.append(x) }
        }
        // films the person is credited on, and their soundtrack albums
        let filmCredits = await works(view: view, kinds: Self.filmKinds, cap: Self.filmCap)
        var filmEntries = filmCredits.map { entry($0.snap, edge: $0.edge) }
        let viaSongs = await filmsOfSongs(songs)
        for f in viaSongs where !filmEntries.contains(where: { $0.id == f.id }) { filmEntries.append(f) }
        let st = await soundtracks(of: filmCredits.prefix(Self.filmCap).map(\.snap.id))
        for (_, list) in st { for a in list where !soundtrackEntries.contains(where: { $0.id == a.id }) { soundtrackEntries.append(a) } }
        sections.append(Self.cut(.soundtracks, await collapseEditions(Self.unique(soundtrackEntries)).sorted(by: Self.newestFirst), to: Self.grid))
        sections.append(Self.cut(.albums, await collapseEditions(albumEntries).sorted(by: Self.newestFirst), to: Self.grid))
        sections.append(Self.cut(.films, Self.unique(filmEntries).sorted(by: Self.newestFirst), to: Self.grid))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        // the people around the music
        let workIDs = Array(songs.prefix(40).map(\.snap.id))
        let singers = MusicCollaboration.rank(await observations(of: workIDs, roles: MusicPersonView.singer.roles, releaseLevel: true, filmLevel: false), excluding: [person], limit: 24)
        let lyricists = MusicCollaboration.rank(await observations(of: workIDs, roles: MusicPersonView.lyricist.roles, releaseLevel: true, filmLevel: false), excluding: [person], limit: 24)
        sections.append(Self.cut(.singersWorkedWith, await collaboratorEntries(singers) { .sharedWorks($0.workCount) }, to: Self.shelf * 2))
        sections.append(Self.cut(.lyricistsWorkedWith, await collaboratorEntries(lyricists) { .sharedWorks($0.workCount) }, to: Self.shelf * 2))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        sections.append(Self.cut(.relatedComposers, await relatedComposers(through: Array(singers.prefix(3))), to: Self.shelf))
        return data(view, sections, complete: true)
    }

    /// Composers who wrote for the same top singers (three singers, twenty songs each), at least two songs in common.
    func relatedComposers(through singers: [MusicCollaborator]) async -> [MusicPersonEntry] {
        var obs: [MusicCreditObservation] = []
        for s in singers {
            if Task.isCancelled { break }
            for w in Set(await incoming(s.id, .performedBy, limit: 20).filter { Self.songKinds.contains($0.subject.kind) }.map(\.subject)).sorted().prefix(20) {
                for e in await outgoing(w) where [.composedBy, .musicDirectedBy].contains(e.predicate) && MusicPersonRoles.counts(e) && e.object.kind.isAgent {
                    if let r = MusicPersonRoles.effectiveRole(e) { obs.append(MusicCreditObservation(work: w, agent: e.object, role: r, level: .song, confidence: e.confidence)) }
                }
            }
        }
        return await collaboratorEntries(MusicCollaboration.rank(obs, excluding: [person], minCount: 2, limit: 12)) { .sharedSingers($0.workCount) }
    }

    /// LYRICIST: songs written, albums, films, composers, singers, frequent collaborators.
    func buildLyricist(_ report: @escaping Report) async throws -> MusicPersonViewData {
        let view = MusicPersonView.lyricist
        var sections: [MusicPersonSection] = []
        let songs = await works(view: view, kinds: Self.songKinds, cap: Self.compositions)
        var written = songs.map { entry($0.snap, edge: $0.edge) }
        sections.append(Self.cut(.songsWritten, written, to: Self.compositions))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        let rel = await releases(view: view, songs: songs, cap: Self.albumCap)
        sections.append(Self.cut(.albums, (rel.albums + rel.singles).sorted(by: Self.newestFirst), to: Self.grid))
        sections.append(Self.cut(.films, await filmsOfSongs(songs), to: Self.grid))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        let workIDs = Array(songs.prefix(40).map(\.snap.id))
        let comp = await observations(of: workIDs, roles: MusicPersonView.composer.roles)
        let sing = await observations(of: workIDs, roles: MusicPersonView.singer.roles, releaseLevel: true, filmLevel: false)
        sections.append(Self.cut(.composers, await collaboratorEntries(MusicCollaboration.rank(comp, excluding: [person], limit: 24)) { .sharedWorks($0.workCount) }, to: Self.shelf * 2))
        sections.append(Self.cut(.singers, await collaboratorEntries(MusicCollaboration.rank(sing, excluding: [person], limit: 24)) { .sharedWorks($0.workCount) }, to: Self.shelf * 2))
        sections.append(Self.cut(.frequentCollaborators, await collaboratorEntries(MusicCollaboration.rank(comp + sing, excluding: [person], minCount: 2, limit: 16)) { .sharedWorks($0.workCount) }, to: Self.shelf))
        let near = MusicCollaboration.rank(comp + sing, excluding: [person], limit: 3)
        sections.append(Self.cut(.relatedArtists, await relatedPeers(through: near, roles: view.roles), to: Self.shelf))
        // who sings each of the first songs: a plain line under the title
        for i in written.indices.prefix(12) { written[i].detail = await performerLine(of: written[i].id, excluding: [person]) }
        sections[0] = Self.cut(.songsWritten, written, to: Self.compositions)
        return data(view, sections, complete: true)
    }
}
