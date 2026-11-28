import Foundation

// The builders of the shelves E to K. Same rules as the core builders: local reads only, bounded, each failure reads as "nothing there", real data
// only (a film is never an album, a name is never a link, a guess is never a fact).

extension MusicSoundtrackBuild {
    private static func accepts(_ e: MusicEdge) -> Bool {
        guard !e.tombstone, e.status != .conflicted else { return false }
        return e.status == .verified || e.confidence >= MusicSoundtrackLimits.plainWordingConfidence
    }

    // MARK: E: more films featuring this cast

    /// The films of this page's cast. `enrichActors` first asks the entity layer for each of the top actors' filmographies (two at a time), so a
    /// loader runs this once on what the graph has and once more after the enrichment landed.
    static func moreFilms(_ r: MusicSoundtrackReader, id: MusicEntityID, hooks: MusicSoundtrackHooks = .none, enrichActors: Bool = false) async -> (film: MusicSoundtrackFilm?, items: [MusicSoundtrackFilmItem]) {
        let family = await r.family(of: id)
        guard let film = await r.filmLink(family) else { return (nil, []) }
        let castEdges = await castEdges(r, film: film.id)
        let actors: [MusicSoundtrackPerson?] = await r.boundedMap(Array(castEdges.prefix(MusicSoundtrackLimits.castForFilmography))) { await r.person($0.object) }
        let top = actors.compactMap { $0 }
        guard !top.isEmpty else { return (film, []) }
        if enrichActors { _ = await r.boundedMap(top, width: MusicSoundtrackLimits.enrichmentInFlight) { await hooks.enrich($0.id) } }

        struct Appearance: Sendable { var actor: Int; var billing: Int }
        let perActor: [[(MusicEntityID, Int)]] = await r.boundedMap(Array(top.enumerated())) { pair in
            await r.edges(pair.element.id, .hasCast, .incoming, limit: MusicSoundtrackLimits.filmsPerActor * 3)
                .filter { accepts($0) && ($0.subject.kind == .film || $0.subject.kind == .series) && $0.subject != film.id }
                .prefix(MusicSoundtrackLimits.filmsPerActor)
                .map { ($0.subject, $0.order ?? $0.attributes.creditOrder ?? 20) }
        }
        var appearances: [MusicEntityID: [Appearance]] = [:]
        for (i, list) in perActor.enumerated() { for (fid, billing) in list { appearances[fid, default: []].append(Appearance(actor: i, billing: billing)) } }

        let ids = Array(appearances.keys).sorted()
        let films: [MusicSoundtrackFilm?] = await r.boundedMap(ids) { await r.filmRef($0) }
        var items: [MusicSoundtrackFilmItem] = []
        for f in films.compactMap({ $0 }) {
            let ap = (appearances[f.id] ?? []).sorted { $0.actor < $1.actor }
            let people = ap.map { top[$0.actor] }
            let score = MusicSoundtrackFilmFilter.score(shared: ap.count, leadBillings: ap.map(\.billing), year: f.year, seedYear: film.year)
            items.append(MusicSoundtrackFilmItem(film: f, actors: people, reason: .withActors(people.prefix(3).map(\.name)), score: score))
        }
        items.sort { $0.score != $1.score ? $0.score > $1.score : ($0.film.year ?? 0, $0.film.title) < ($1.film.year ?? 0, $1.film.title) }
        return (film, Array(items.prefix(MusicSoundtrackLimits.filmsShown)))
    }

    // MARK: F: soundtracks from those films

    /// The soundtrack albums of the films in E: a graph `soundtrackOf` link, or (when the page allows provider searches) a provider album that
    /// matches the film strictly and is written back as an inferred link. A film with neither shows nothing.
    static func soundtracksOfCast(_ r: MusicSoundtrackReader, films: [MusicSoundtrackFilmItem], hooks: MusicSoundtrackHooks = .none,
                                  useProvider: Bool = false) async -> [MusicSoundtrackAlbum] {
        let chosen = Array(films.prefix(MusicSoundtrackLimits.filmsForSoundtracks))
        let found: [[MusicSoundtrackAlbum]] = await r.boundedMap(chosen) { item in
            var albums: [MusicSoundtrackAlbum] = []
            for e in await r.edges(item.film.id, .soundtrackOf, .incoming, limit: 6) where MusicSoundtrackReader.acceptsFilmLink(e) {
                guard let s = await r.entity(e.subject), s.kind == .album || s.kind == .release else { continue }
                let film = MusicSoundtrackFilm(id: item.film.id, title: item.film.title, year: item.film.year, language: item.film.language, imageRef: item.film.imageRef,
                                               linkStatus: e.status, linkConfidence: e.confidence)
                let reason = MusicSoundtrackReason.qualified(.soundtrackOfFilmWith(film: film.title, actors: item.actors.prefix(2).map(\.name)), status: e.status, confidence: e.confidence)
                albums.append(MusicSoundtrackAlbum(id: s.id, title: s.name, year: s.year, imageRef: s.imageRef, subkind: s.subkind, film: film, reason: reason, band: 3,
                                                   score: item.score + Double(e.confidence), cluster: MusicSoundtrackCluster.key(id: s.id, title: s.name, year: s.year, film: film.id)))
            }
            return albums
        }
        var out = found.flatMap { $0 }
        if useProvider, let search = hooks.providerAlbums {
            let have = Set(out.compactMap { $0.film?.id })
            let missing = chosen.filter { !have.contains($0.film.id) }
            let matched: [MusicSoundtrackAlbum?] = await r.boundedMap(missing, width: MusicSoundtrackLimits.providerSearchesInFlight) { item in
                guard !Task.isCancelled else { return nil }
                for cand in await search(item.film) where MusicSoundtrackMatch.accepts(film: item.film, album: cand) {
                    let id = await hooks.persistInferred(cand, item.film) ?? cand.id
                    let film = MusicSoundtrackFilm(id: item.film.id, title: item.film.title, year: item.film.year, language: item.film.language, imageRef: item.film.imageRef,
                                                   linkStatus: .inferred, linkConfidence: 0.7)
                    return MusicSoundtrackAlbum(id: id, title: cand.title, year: cand.year, imageRef: cand.imageRef, subkind: MusicAlbumSubkind.soundtrack.rawValue, film: film,
                                                reason: .possibly(.soundtrackOfFilmWith(film: film.title, actors: item.actors.prefix(2).map(\.name))), band: 3, score: item.score,
                                                cluster: MusicSoundtrackCluster.key(id: id, title: cand.title, year: cand.year, film: film.id))
                }
                return nil
            }
            out += matched.compactMap { $0 }
        }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.title < $1.title }
        var seen = Set<String>()
        return out.filter { seen.insert($0.cluster).inserted }
    }

    // MARK: G: more music by the composers

    /// Soundtracks and compositions by the same music directors and composers: albums first, then songs. Excludes this album, its edition family and
    /// its film's other soundtrack editions.
    static func moreByComposers(_ r: MusicSoundtrackReader, id: MusicEntityID) async -> [MusicSoundtrackEntry] {
        let family = await r.family(of: id)
        let film = await r.filmLink(family)
        let makers = await makers(r, family: family, film: film)
        guard !makers.isEmpty else { return [] }
        let seedSnap = await r.entity(id)
        let seedYear = film?.year ?? seedSnap?.year
        let seedCluster = MusicSoundtrackCluster.key(id: id, title: seedSnap?.name ?? "", year: seedSnap?.year, film: film?.id)
        var albums: [MusicSoundtrackAlbum] = []
        var songs: [MusicSoundtrackSong] = []
        var seenAlbums: Set<MusicEntityID> = Set(family.members)
        var seenSongs = Set<MusicEntityID>()

        for maker in makers {
            var incoming = await r.edges(maker.person.id, .musicDirectedBy, .incoming, limit: 100)
            incoming += await r.edges(maker.person.id, .composedBy, .incoming, limit: 100)
            for e in incoming where e.status != .conflicted && !e.tombstone {
                let role = e.role ?? defaultRole(e.predicate)
                let reason: MusicSoundtrackReason = (role == .musicDirector) ? .sameMusicDirector(maker.person.name) : .sameComposer(maker.person.name)
                let roleBase: Double = role == .musicDirector ? 100 : 90
                switch e.subject.kind {
                case .album, .release:
                    guard seenAlbums.insert(e.subject).inserted, albums.count < MusicSoundtrackLimits.albumsPerShelf * 2, let s = await r.entity(e.subject) else { continue }
                    let link = await r.edges(s.id, .soundtrackOf, .outgoing, limit: 4).filter { MusicSoundtrackReader.acceptsFilmLink($0) }.max { MusicSoundtrackReader.better($1, than: $0) }
                    let f: MusicSoundtrackFilm? = await { if let link { return await r.filmRef(link.object, status: link.status, confidence: link.confidence) } else { return nil } }()
                    let key = MusicSoundtrackCluster.key(id: s.id, title: s.name, year: s.year, film: f?.id)
                    guard key != seedCluster else { continue }
                    albums.append(MusicSoundtrackAlbum(id: s.id, title: s.name, year: s.year, imageRef: s.imageRef, subkind: s.subkind, film: f,
                                                       reason: .qualified(reason, status: e.status, confidence: e.confidence), band: 5,
                                                       score: roleBase + Double(e.confidence) * 10 + closeness(s.year ?? f?.year, seedYear), cluster: key))
                case .film, .series:
                    guard film?.id != e.subject, let fr = await r.filmRef(e.subject) else { continue }
                    for l in await r.edges(fr.id, .soundtrackOf, .incoming, limit: 3) where MusicSoundtrackReader.acceptsFilmLink(l) {
                        guard seenAlbums.insert(l.subject).inserted, let s = await r.entity(l.subject) else { continue }
                        let f = MusicSoundtrackFilm(id: fr.id, title: fr.title, year: fr.year, language: fr.language, imageRef: fr.imageRef, linkStatus: l.status, linkConfidence: l.confidence)
                        let key = MusicSoundtrackCluster.key(id: s.id, title: s.name, year: s.year, film: f.id)
                        guard key != seedCluster else { continue }
                        albums.append(MusicSoundtrackAlbum(id: s.id, title: s.name, year: s.year, imageRef: s.imageRef, subkind: s.subkind, film: f,
                                                           reason: .qualified(reason, status: weaker(e.status, l.status), confidence: min(e.confidence, l.confidence)), band: 5,
                                                           score: roleBase + Double(min(e.confidence, l.confidence)) * 10 + closeness(fr.year, film?.year), cluster: key))
                    }
                case .recording:
                    guard songs.count < MusicSoundtrackLimits.songsPerShelf, seenSongs.insert(e.subject).inserted, let s = await r.entity(e.subject) else { continue }
                    let on = await r.edges(s.id, .trackOn, .outgoing, limit: 4).map(\.object)
                    if on.contains(where: { family.members.contains($0) }) { continue }
                    var title: String?
                    if let first = on.first { title = await r.name(first) }
                    let singers = await r.edges(s.id, .performedBy, .outgoing, limit: 6).filter { MusicSoundtrackSinging.isSinger($0) }
                    var names: [String] = []
                    for p in singers.prefix(3) { if let n = await r.name(p.object) { names.append(n) } }
                    songs.append(MusicSoundtrackSong(id: s.id, title: s.name, year: s.year, imageRef: s.imageRef, singers: names, albumID: on.first, albumTitle: title,
                                                     reason: .qualified(reason, status: e.status, confidence: e.confidence), score: roleBase + Double(e.confidence) * 10))
                default: break
                }
            }
        }
        albums.sort { $0.score != $1.score ? $0.score > $1.score : $0.title < $1.title }
        songs.sort { $0.score != $1.score ? $0.score > $1.score : $0.title < $1.title }
        var shown = Set<String>()
        let a = albums.filter { shown.insert($0.cluster).inserted }.prefix(MusicSoundtrackLimits.albumsPerShelf).map(MusicSoundtrackEntry.album)
        return a + songs.prefix(MusicSoundtrackLimits.songsPerShelf).map(MusicSoundtrackEntry.song)
    }

    private static func weaker(_ a: EdgeStatus, _ b: EdgeStatus) -> EdgeStatus { a == .verified ? b : a }

    private static func closeness(_ a: Int?, _ b: Int?) -> Double {
        guard let a, let b else { return 0 }
        return max(0, 10 - Double(abs(a - b)) / 6)
    }

    // MARK: H: more songs by the singers

    static func moreBySingers(_ r: MusicSoundtrackReader, id: MusicEntityID, credits: MusicSoundtrackCredits? = nil) async -> [MusicSoundtrackSong] {
        let family = await r.family(of: id)
        let recordings = await r.recordings(family)
        let own = Set(recordings.map(\.id))
        let c: MusicSoundtrackCredits
        if let credits { c = credits } else { c = await MusicSoundtrackBuild.credits(r, id: id, recordings: recordings) }
        let pool = c.people(.singer).isEmpty ? c.people(.artist) : c.people(.singer)
        let singers = Array(pool.prefix(MusicSoundtrackLimits.singersUsed))
        guard !singers.isEmpty else { return [] }
        let seedYear = (await r.entity(id))?.year ?? c.film?.year
        let perSinger: [[(MusicEdge, MusicSoundtrackCredit)]] = await r.boundedMap(singers) { s in
            await r.edges(s.person.id, .performedBy, .incoming, limit: 120)
                .filter { $0.subject.kind == .recording && $0.status != .conflicted && !own.contains($0.subject) && MusicSoundtrackSinging.isSinger($0) }
                .map { ($0, s) }
        }
        var bySong: [MusicEntityID: [MusicSoundtrackCredit]] = [:]
        var edgeFor: [MusicEntityID: MusicEdge] = [:]
        for list in perSinger { for (e, s) in list { bySong[e.subject, default: []].append(s); edgeFor[e.subject] = edgeFor[e.subject] ?? e } }
        let candidates = Array(bySong.keys.sorted().prefix(120))
        let bySongFinal = bySong, edgeForFinal = edgeFor
        let built: [MusicSoundtrackSong?] = await r.boundedMap(candidates) { sid in
            guard let s = await r.entity(sid) else { return nil }
            let version = s.attrs["versionKind"].flatMap(MusicVersionKind.init(rawValue:))
            if let version, [.karaoke, .instrumental, .remix].contains(version) { return nil }
            let on = await r.edges(s.id, .trackOn, .outgoing, limit: 4).map(\.object)
            if on.contains(where: { family.members.contains($0) }) { return nil }
            var albumTitle: String?
            if let first = on.first { albumTitle = await r.name(first) }
            let who = bySongFinal[sid] ?? []
            let popularity = Double(s.attrs["popularity"].flatMap(Int.init) ?? 0)
            let e = edgeForFinal[sid]!
            let reason = MusicSoundtrackReason.qualified(.sungOnThisSoundtrack(who.first?.person.name ?? ""), status: e.status, confidence: e.confidence)
            return MusicSoundtrackSong(id: s.id, title: s.name, year: s.year, imageRef: s.imageRef, singers: who.map(\.person.name), albumID: on.first, albumTitle: albumTitle,
                                       reason: reason, score: Double(who.count) * 100 + popularity + closeness(s.year, seedYear))
        }
        var seenTitles = Set<String>()
        return built.compactMap { $0 }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.title < $1.title }
            .filter { seenTitles.insert(MusicGraphText.latin($0.title) + "|" + ($0.singers.first ?? "")).inserted }
            .prefix(MusicSoundtrackLimits.songsPerShelf).map { $0 }
    }

    // MARK: I: related soundtracks

    /// Candidate albums from every way the graph relates one to the opened album, ranked with the reason each one is here.
    static func related(_ r: MusicSoundtrackReader, id: MusicEntityID, hooks: MusicSoundtrackHooks = .none) async -> [MusicSoundtrackAlbum] {
        guard var seed = await albumFacts(r, id: id) else { return [] }
        let family = await r.family(of: id)
        // the opened album's singers come from its songs (the credits), not only from album-level claims
        let own = await MusicSoundtrackBuild.credits(r, id: id)
        for c in own.people(.singer) + own.people(.artist) { seed.singers[c.person.id] = c.person.name }
        var ids: [MusicEntityID] = []
        func add(_ x: MusicEntityID) { if x != id, !family.members.contains(x), !ids.contains(x), ids.count < 36 { ids.append(x) } }

        // direct relations
        var directs: [MusicEntityID: MusicEdge] = [:]
        for m in family.members {
            for e in await r.edges(m, .relatedAlbum, .both, limit: 20) where e.status != .conflicted {
                let other = e.subject == m ? e.object : e.subject
                directs[other] = e; add(other)
            }
        }
        // shared creators and singers (the composer shelf), and other soundtracks of the same film
        for entry in await moreByComposers(r, id: id) { if case .album(let a) = entry { add(a.id) } }
        if let film = seed.film { for e in await r.edges(film.id, .soundtrackOf, .incoming, limit: 8) where MusicSoundtrackReader.acceptsFilmLink(e) { add(e.subject) } }
        for song in await moreBySingers(r, id: id) { if let a = song.albumID { add(a) } }
        // shared cast: the soundtracks of the films of this cast
        let films = await moreFilms(r, id: id).items
        for a in await soundtracksOfCast(r, films: films) { add(a.id) }
        // language and era: bounded read of the language facet
        for a in await facetAlbums(r, languageFacet: await r.facet(of: family.members, .inLanguage)?.id, around: seed.eraYear, window: MusicSoundtrackLimits.eraYears) { add(a) }

        let directsFinal = directs
        let facts: [MusicSoundtrackAlbumFacts?] = await r.boundedMap(ids) { cid in
            guard var f = await albumFacts(r, id: cid, withCast: true) else { return nil }
            if let d = directsFinal[cid] { f.directStatus = d.status; f.directConfidence = d.confidence }
            return f
        }
        return MusicSoundtrackRelated.rank(seed: seed, candidates: facts.compactMap { $0 })
    }

    // MARK: J: more classic cinema

    /// Albums that are soundtracks of films in the language facet within the era window. Bounded: one facet read, at most 40 film reads.
    static func facetAlbums(_ r: MusicSoundtrackReader, languageFacet: MusicEntityID?, around year: Int?, window: Int) async -> [MusicEntityID] {
        guard let languageFacet, let year else { return [] }
        let incoming = await r.edges(languageFacet, .inLanguage, .incoming, limit: 300).filter { [.film, .series, .album, .release].contains($0.subject.kind) }
        let checked: [(MusicEntityID, Int)?] = await r.boundedMap(Array(incoming.prefix(160))) { e in
            guard let s = await r.entity(e.subject), let y = s.year, abs(y - year) <= window else { return nil }
            return (s.id, abs(y - year))
        }
        let near = checked.compactMap { $0 }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.prefix(40)
        var albums: [MusicEntityID] = []
        for (eid, _) in near {
            switch eid.kind {
            case .film, .series: for l in await r.edges(eid, .soundtrackOf, .incoming, limit: 3) where MusicSoundtrackReader.acceptsFilmLink(l) { albums.append(l.subject) }
            default: albums.append(eid)
            }
        }
        return albums
    }

    static func classic(_ r: MusicSoundtrackReader, id: MusicEntityID) async -> [MusicSoundtrackAlbum] {
        let family = await r.family(of: id)
        guard let film = await r.filmLink(family) else { return [] }
        let lang = await r.facet(of: family.members, .inLanguage)
        let seedSnapForYear = await r.entity(id)
        let seedYear = film.year ?? seedSnapForYear?.year
        let ids = await facetAlbums(r, languageFacet: lang?.id, around: seedYear, window: MusicSoundtrackLimits.eraYears)
        var uniqueSet = Set<MusicEntityID>()
        let unique = ids.filter { $0 != id && !family.members.contains($0) && uniqueSet.insert($0).inserted }
        let facts: [MusicSoundtrackAlbumFacts?] = await r.boundedMap(Array(unique.prefix(40))) { await albumFacts(r, id: $0, withCast: false) }
        let name = lang?.name ?? languageName(film.language)
        var pool = facts.compactMap { $0 }
        for i in pool.indices where pool[i].languageName == nil { pool[i].languageName = name }
        let seedSnap = await r.entity(id)
        let seedCluster = MusicSoundtrackCluster.key(id: id, title: seedSnap?.name ?? "", year: seedSnap?.year, film: film.id)
        return MusicSoundtrackClassic.select(seedYear: seedYear, languageName: name, candidates: pool, excluding: [seedCluster])
    }

    // MARK: K: continue exploring

    static func explore(header: MusicSoundtrackHeaderFacts, credits: MusicSoundtrackCredits, cast: MusicSoundtrackCastResult?) -> [MusicSoundtrackLink] {
        var out: [MusicSoundtrackLink] = []
        func person(_ c: MusicSoundtrackCredit, _ role: MusicRole) {
            out.append(MusicSoundtrackLink(target: .person(c.person.id, role), title: c.person.name, reason: c.songCount > 0 ? .creditsOfThisAlbum(role: role, songs: c.songCount) : .fromThisAlbum))
        }
        if let c = credits.people(.musicDirector).first { person(c, .musicDirector) }
        if let c = credits.people(.composer).first, c.person.id != credits.people(.musicDirector).first?.person.id { person(c, .composer) }
        if let c = credits.people(.singer).first ?? credits.people(.artist).first { person(c, credits.people(.singer).isEmpty ? .performer : .singer) }
        if let c = credits.people(.lyricist).first { person(c, .lyricist) }
        if let film = header.film {
            out.append(MusicSoundtrackLink(target: .film(film.id), title: film.title, reason: .filmOfThisAlbum))
            if let lead = cast?.cast.first { out.append(MusicSoundtrackLink(target: .person(lead.person.id, .actor), title: lead.person.name, reason: .actorInFilm(film.title))) }
        }
        if let id = header.languageID, let name = header.languageName { out.append(MusicSoundtrackLink(target: .language(id), title: name, reason: .languageOfThisAlbum)) }
        if let id = header.eraID, let name = header.eraName { out.append(MusicSoundtrackLink(target: .era(id), title: name, reason: .eraOfThisAlbum)) }
        out.append(MusicSoundtrackLink(target: .radio, title: header.title, reason: .radioFromAlbum))
        return out
    }

    // MARK: B: singers of the songs

    /// The singer names of recordings, for the song rows (read in place after the rows are drawn).
    static func singerLines(_ r: MusicSoundtrackReader, recordings: [MusicEntityID]) async -> [MusicEntityID: [String]] {
        let rows: [(MusicEntityID, [String])] = await r.boundedMap(Array(recordings.prefix(MusicSoundtrackLimits.tracksForCredits * 2))) { rid in
            var names: [String] = []
            for e in await r.edges(rid, .performedBy, .outgoing, limit: 8) where e.status != .conflicted && MusicSoundtrackSinging.isSinger(e) {
                if let n = await r.name(e.object), !MusicCompilationArtist.isCompilation(n), !names.contains(n) { names.append(n) }
            }
            return (rid, names)
        }
        return Dictionary(rows.filter { !$0.1.isEmpty }, uniquingKeysWith: { a, _ in a })
    }
}
