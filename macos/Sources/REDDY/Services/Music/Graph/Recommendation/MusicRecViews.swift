import Foundation

// The named entry points the pages call (section 6): each is one recommendation with the right seed, kinds and filters. Pages never build a traversal
// of their own.

/// One next step on an album or song page ("continue exploring"): a real place to go next, built from the seed's own edges.
struct MusicContinueStep: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case person(role: MusicRole?)
        case film
        case language
        case era(decade: Int)
        case radio
    }
    var kind: Kind
    /// The entity to open (nil for an era, which is opened by decade, and for radio, whose seed is the page's own entity).
    var target: MusicEntityID?
    var title: String
    /// How many works the graph holds for this person (capped at 100), when it was cheap to know.
    var count: Int?
}

/// A home shelf made from the person's own listening. It exists only with history and only when it has at least `minimumItems` items.
struct MusicHomeSection: Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case soundtracksFromMoviesYouLike, composersYouListenTo, discoverThroughCast, similarAlbums, rediscoverClassics, moreFromRecentArtists
        var title: String {
            switch self {
            case .soundtracksFromMoviesYouLike: "Soundtracks from movies you like"
            case .composersYouListenTo: "Composers you listen to"
            case .discoverThroughCast: "Discover through cast"
            case .similarAlbums: "Similar albums"
            case .rediscoverClassics: "Rediscover classics"
            case .moreFromRecentArtists: "More from recently played artists"
            }
        }
    }
    static let minimumItems = 6
    var kind: Kind
    var items: [MusicRecCandidate]
    /// The entities the shelf was built around (the loved film, composer or artist), for a "because" line.
    var seeds: [MusicEntityID]
}

extension MusicRecommender {
    // MARK: page entry points

    /// G5 section I: related soundtracks of an album (same film in another language, same music director and era, same director, same cast).
    func relatedSoundtracks(forAlbum album: MusicEntityID, limit: Int = 12, context: MusicRecContext = MusicRecContext()) async -> MusicRecResult {
        await recommend(for: album, kinds: [.album, .release], limit: limit, context: context)
    }

    /// G5 section J: more classic cinema, in the album's (or a given) language, within ten years of it, strongest relationships first.
    func moreClassicCinema(forAlbum album: MusicEntityID, language: String? = nil, window: Int = 10, limit: Int = 12,
                           context: MusicRecContext = MusicRecContext()) async -> MusicRecResult {
        var r = await recommend(for: album, kinds: [.album, .release, .film, .series], limit: 60, context: context)
        let seedSnap = try? await store.entity(album)
        let lang = (language ?? seedSnap?.lang).map(MusicRecLanguage.key)
        let year = seedSnap?.year
        r.items = r.items.filter { c in
            if let lang, let cl = c.snapshot.lang, MusicRecLanguage.key(cl) != lang { return false }
            if let year, let cy = c.snapshot.year, abs(cy - year) > window { return false }
            return true
        }
        r.items = Array(r.items.prefix(max(1, limit)))
        return r
    }

    /// G5 section K: next steps for an album, song or film from its own edges (the top people, the film, the language and era, and a radio).
    func continueExploring(for seed: MusicEntityID, maxPeople: Int = 3) async -> [MusicContinueStep] {
        let id = (try? await store.resolve(seed)) ?? seed
        guard let snap = try? await store.entity(id) else { return [] }
        var steps: [MusicContinueStep] = []
        let edges = (try? await store.edges(of: id, predicate: nil, direction: .both, limit: 100)) ?? []
        var seenPeople: Set<MusicEntityID> = []
        let people = edges.filter { $0.subject == id && ($0.object.kind.isAgent) && recEdgeIsUsable($0, floor: 0.3) && MusicRecRoles.credit.contains($0.predicate) }
            .sorted { MusicRecRoles.weight(MusicRecRoles.role(of: $0)) != MusicRecRoles.weight(MusicRecRoles.role(of: $1)) ? MusicRecRoles.weight(MusicRecRoles.role(of: $0)) > MusicRecRoles.weight(MusicRecRoles.role(of: $1)) : ($0.order ?? 999) < ($1.order ?? 999) }
        for e in people where steps.count < maxPeople && seenPeople.insert(e.object).inserted {
            guard let p = try? await store.entity(e.object) else { continue }
            let incoming = (try? await store.edges(of: e.object, predicate: nil, direction: .incoming, limit: 100)) ?? []
            let works: Int? = incoming.isEmpty ? nil : incoming.filter { MusicRecRoles.credit.contains($0.predicate) }.count
            steps.append(MusicContinueStep(kind: .person(role: MusicRecRoles.role(of: e)), target: e.object, title: p.name, count: works))
        }
        if let f = edges.first(where: { $0.subject == id && ($0.predicate == .soundtrackOf || $0.predicate == .featuredIn) && recEdgeIsUsable($0, floor: 0.3) }),
           let film = try? await store.entity(f.object) {
            steps.append(MusicContinueStep(kind: .film, target: f.object, title: film.name, count: nil))
        }
        if let l = edges.first(where: { $0.subject == id && $0.predicate == .inLanguage }), let ls = try? await store.entity(l.object) {
            steps.append(MusicContinueStep(kind: .language, target: l.object, title: ls.name, count: nil))
        }
        if let y = snap.year { steps.append(MusicContinueStep(kind: .era(decade: (y / 10) * 10), target: nil, title: "\((y / 10) * 10)s", count: nil)) }
        steps.append(MusicContinueStep(kind: .radio, target: nil, title: snap.name, count: nil))
        return steps
    }

    /// G8: related films (shared cast, director or composer; same era and language).
    func relatedFilms(forFilm film: MusicEntityID, limit: Int = 12, context: MusicRecContext = MusicRecContext()) async -> MusicRecResult {
        await recommend(for: film, kinds: [.film, .series], limit: limit, context: context)
    }

    /// G6: related songs and similar recordings of a song.
    func relatedSongs(forSong song: MusicEntityID, limit: Int = 20, context: MusicRecContext = MusicRecContext()) async -> MusicRecResult {
        await recommend(for: song, kinds: [.recording, .track], limit: limit, context: context)
    }
    func similarRecordings(of song: MusicEntityID, limit: Int = 20, context: MusicRecContext = MusicRecContext()) async -> MusicRecResult {
        await relatedSongs(forSong: song, limit: limit, context: context)
    }
    /// G6 versions section: the song's own other versions (remix, karaoke, dub), which the related lists leave out.
    func versions(of song: MusicEntityID, limit: Int = 20, context: MusicRecContext = MusicRecContext()) async -> MusicRecResult {
        var ctx = context
        ctx.includeSeedVersions = true
        var r = await recommend(for: song, kinds: [.recording, .track], limit: 60, context: ctx)
        r.items = Array(r.items.filter { $0.band == .verifiedDirect && $0.explanation.reason == .versionOf }.prefix(limit))
        return r
    }

    /// G7: related artists of a person or group.
    func relatedArtists(forPerson person: MusicEntityID, limit: Int = 12, context: MusicRecContext = MusicRecContext()) async -> MusicRecResult {
        await recommend(for: person, kinds: [.person, .group], limit: limit, context: context)
    }

    /// G11: station seeds. Playable songs only, ordered by band then affinity, no more than `maxRun` in a row from one artist.
    func radioCandidates(seed: MusicEntityID, limit: Int = 50, maxRun: Int = 2, context: MusicRecContext = MusicRecContext(),
                         isPlayable: @Sendable (MusicEntityID) -> Bool = { _ in true }) async -> MusicRecResult {
        var r = await recommend(for: seed, kinds: [.recording, .track], limit: max(limit * 2, 40), context: context)
        r.items = Self.diversify(r.items.filter { isPlayable($0.id) }, maxRun: maxRun, limit: limit)
        return r
    }

    /// Reorders so no artist appears more than `maxRun` times in a row, keeping the original order as far as that allows.
    static func diversify(_ items: [MusicRecCandidate], maxRun: Int, limit: Int) -> [MusicRecCandidate] {
        var pool = items, out: [MusicRecCandidate] = []
        var run = 0
        var last: MusicEntityID?
        while out.count < limit, !pool.isEmpty {
            let i = pool.firstIndex { c in !(c.artist != nil && c.artist == last && run >= maxRun) } ?? 0
            let c = pool.remove(at: i)
            run = (c.artist != nil && c.artist == last) ? run + 1 : 1
            last = c.artist
            out.append(c)
        }
        return out
    }

    // MARK: home sections (G9): need history, absent in a cold start

    func homeSection(_ kind: MusicHomeSection.Kind, perSeed: Int = 8, limit: Int = 20, context: MusicRecContext = MusicRecContext()) async -> MusicHomeSection? {
        let affinity: MusicAffinityVector
        if let a = context.affinity { affinity = a } else { affinity = await affinityStore?.vector() ?? .empty }
        guard !affinity.isEmpty else { return nil }
        var ctx = context
        ctx.affinity = affinity
        let played = Set(affinity.recording.filter { $0.value >= 1 }.keys)
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: ctx.now)

        switch kind {
        case .soundtracksFromMoviesYouLike:
            let seeds = affinity.top(.film, count: 4).map(\.id)
            return await merged(kind, seeds: seeds, kinds: [.album, .release], perSeed: perSeed, limit: limit, context: ctx, keep: { _ in true })
        case .discoverThroughCast:
            let seeds = affinity.top(.film, count: 4).map(\.id)
            let known = Set(seeds)
            return await merged(kind, seeds: seeds, kinds: [.film, .series], perSeed: perSeed, limit: limit, context: ctx, keep: { !known.contains($0.id) })
        case .similarAlbums:
            let seeds = affinity.top(.recording, count: 4).map(\.id)
            return await merged(kind, seeds: seeds, kinds: [.album, .release], perSeed: perSeed, limit: limit, context: ctx, keep: { _ in true })
        case .rediscoverClassics:
            let seeds = affinity.top(.composer, count: 4).map(\.id)
            return await merged(kind, seeds: seeds, kinds: [.recording, .track, .album, .release], perSeed: perSeed, limit: limit, context: ctx,
                                keep: { c in !played.contains(c.id) && (c.snapshot.year.map { thisYear - $0 >= 25 } ?? false) })
        case .moreFromRecentArtists:
            let seeds = affinity.top(.singer, count: 4).map(\.id)
            return await merged(kind, seeds: seeds, kinds: [.recording, .track, .album, .release], perSeed: perSeed, limit: limit, context: ctx, keep: { !played.contains($0.id) })
        case .composersYouListenTo:
            let top = affinity.top(.composer, count: limit)
            var items: [MusicRecCandidate] = []
            let maxW = top.first?.weight ?? 1
            for t in top {
                guard let s = try? await store.entity(t.id), s.state == .live else { continue }
                let inBand = min(MusicRecBand.inBandCeiling, 99 * t.weight / max(maxW, 0.0001))
                items.append(MusicRecCandidate(id: s.id, snapshot: s, band: .affinity, score: MusicRecBand.affinity.base + inBand,
                                               explanation: .init(.affinityComposer, [MusicRecSubject(id: s.id, name: s.name)]), otherReasons: [], confidence: 0.9,
                                               affinityBoost: min(1, t.weight / MusicAffinityVector.saturation), versionCount: 1, flags: []))
            }
            guard items.count >= MusicHomeSection.minimumItems else { return nil }
            return MusicHomeSection(kind: kind, items: items, seeds: top.map(\.id))
        }
    }

    /// Runs one recommendation per seed and merges them round-robin by (band, score), best first, one entry per entity.
    private func merged(_ kind: MusicHomeSection.Kind, seeds: [MusicEntityID], kinds: Set<MusicEntityKind>, perSeed: Int, limit: Int, context: MusicRecContext,
                        keep: (MusicRecCandidate) -> Bool) async -> MusicHomeSection? {
        var best: [MusicEntityID: MusicRecCandidate] = [:]
        for seed in seeds {
            var ctx = context
            ctx.exclude.formUnion(seeds)
            let r = await recommend(for: seed, kinds: kinds, limit: perSeed * 3, context: ctx)
            for c in r.items.filter(keep).prefix(perSeed) {
                if let cur = best[c.id], (cur.band, -cur.score) <= (c.band, -c.score) { continue }
                best[c.id] = c
            }
        }
        let items = best.values.sorted { a, b in a.band != b.band ? a.band < b.band : (a.score != b.score ? a.score > b.score : a.id < b.id) }
        guard items.count >= MusicHomeSection.minimumItems else { return nil }
        return MusicHomeSection(kind: kind, items: Array(items.prefix(limit)), seeds: seeds)
    }
}
