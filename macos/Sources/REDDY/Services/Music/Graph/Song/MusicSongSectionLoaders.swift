import Foundation

// The nine section loaders of the song page. Every one: reads the graph only, runs under the page's gate (at most three at once), checks for
// cancellation between reads, and hands back Sendable values the page draws. An empty result means "the graph has nothing", never "go and ask".

// MARK: context: album, film, version, facts (items 2, 3, 4)

struct MusicSongContextLoader: MusicEntitySectionLoader {
    let env: MusicSongLoaderEnv
    var key: String { MusicSongSectionKey.context.loaderKey }

    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        try await env.gate.run { try await self.read(entity, store, report) }
    }

    private func read(_ id: MusicEntityID, _ s: any MusicGraphStoring, _ report: MusicSectionReporter) async throws -> MusicSectionResult {
        guard let snap = await MusicSongReads.entity(s, id) else { return MusicSectionResult() }
        let alt = await MusicSongReads.edges(s, id, .alternateOf, .outgoing, 12)
        var ctx = MusicSongContext(album: nil, film: nil, version: MusicSongVersioning.classify(snapshot: snap, outgoing: alt), year: snap.year, language: snap.attrs["languageHint"] ?? snap.lang,
                                   durationMs: snap.durationMs, explicit: snap.attrs["explicit"] == "1", isProvisional: snap.provisional)
        if let o = ctx.version.originalID, ctx.version.linksToOriginal, let e = await MusicSongReads.entity(s, o) { ctx.original = MusicSongReads.link(e) }
        await report.partial(result(ctx, []))
        try Task.checkCancellation()

        let placements = await MusicSongReads.edges(s, id, .trackOn, .outgoing, 12)
        if let pick = MusicSongContextRules.pickAlbum(placements: placements) {
            var target = pick.object
            // A release that belongs to an album: show the album.
            if target.kind == .release, let up = await MusicSongReads.edges(s, target, .editionOf, .outgoing, 3).sorted(by: MusicSongVersioning.better).first { target = up.object }
            if let a = await MusicSongReads.entity(s, target) { ctx.album = MusicSongReads.link(a) }
        }
        try Task.checkCancellation()

        let direct = await MusicSongReads.edges(s, id, .featuredIn, .outgoing, 8)
        let viaAlbum = await MusicSongReads.soundtrackEdges(s, placements: placements)
        if let (edge, origin) = MusicSongContextRules.pickFilm(direct: direct, viaAlbum: viaAlbum), let f = await MusicSongReads.entity(s, edge.object) {
            var evidence: [String] = []
            if origin == .viaSoundtrack { evidence.append("via-soundtrack") }
            ctx.film = MusicSongFilmLink(film: MusicSongReads.link(f), status: edge.status, confidence: edge.confidence, evidence: evidence, origin: origin)
        }
        return result(ctx, [ctx.film?.status ?? .verified])
    }

    private func result(_ c: MusicSongContext, _ statuses: [EdgeStatus]) -> MusicSectionResult {
        MusicSectionResult(items: [c], provenance: MusicSongReads.provenance(statuses))
    }
}

// MARK: credits (items 5 to 8)

struct MusicSongPageCreditsLoader: MusicEntitySectionLoader {
    let env: MusicSongLoaderEnv
    var key: String { MusicSongSectionKey.credits.loaderKey }

    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        try await env.gate.run { try await self.read(entity, store, report) }
    }

    private func read(_ id: MusicEntityID, _ s: any MusicGraphStoring, _ report: MusicSectionReporter) async throws -> MusicSectionResult {
        // Singers first (they show at once), then the rest of the credits.
        let first = await MusicSongReads.creditRows(s, id, predicates: [.performedBy])
        try Task.checkCancellation()
        let early = MusicSongCredits.build(rows: first)
        if !early.isEmpty { await report.partial(MusicSectionResult(items: early.map { $0 as AnyHashable })) }
        let rest = await MusicSongReads.creditRows(s, id, predicates: [.composedBy, .musicDirectedBy, .writtenBy, .producedBy])
        try Task.checkCancellation()
        let groups = MusicSongCredits.build(rows: first + rest)
        let statuses = groups.flatMap { $0.people.map(\.status) }
        return MusicSectionResult(items: groups.map { $0 as AnyHashable }, provenance: MusicSongReads.provenance(statuses))
    }
}

// MARK: samples

/// One row of "Samples from" or "Sampled by".
struct MusicSongSampleItem: Hashable, Sendable, Identifiable {
    enum Direction: Int, Sendable { case samplesFrom = 0, sampledBy }
    var id: MusicEntityID
    var name: String
    var year: Int?
    var direction: Direction
    var status: EdgeStatus
    var confidence: Float
    var artistLine: String?
    var imageRef: String?
}

/// The samples a song contains (its outgoing `samples` links) and the songs that sample it (incoming ones). The link is stored once, sampling recording to
/// sampled source, so nothing here depends on which side was read first. Remixes, covers and influences are other links and never appear.
struct MusicSongSamplesLoader: MusicEntitySectionLoader {
    let env: MusicSongLoaderEnv
    var key: String { MusicSongSectionKey.samples.loaderKey }
    static let maxItems = 40

    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        try await env.gate.run { try await self.read(entity, store) }
    }

    private func read(_ id: MusicEntityID, _ s: any MusicGraphStoring) async throws -> MusicSectionResult {
        var items: [MusicSongSampleItem] = []
        var seen = Set<String>()
        func add(_ other: MusicEntityID, _ edge: MusicEdge, _ direction: MusicSongSampleItem.Direction) async {
            guard other != id, items.count < Self.maxItems, seen.insert("\(direction.rawValue)|\(other)").inserted, let e = await MusicSongReads.entity(s, other) else { return }
            items.append(MusicSongSampleItem(id: other, name: e.name, year: e.year, direction: direction, status: edge.status, confidence: edge.confidence, artistLine: nil, imageRef: e.imageRef))
        }
        for e in await MusicSongReads.edges(s, id, .samples, .outgoing, 40) where !e.tombstone { await add(e.object, e, .samplesFrom) }
        try Task.checkCancellation()
        for e in await MusicSongReads.edges(s, id, .samples, .incoming, 40) where !e.tombstone { await add(e.subject, e, .sampledBy) }
        for i in items.indices.prefix(12) {
            try Task.checkCancellation()
            items[i].artistLine = await MusicSongReads.artistLine(s, items[i].id)
        }
        items.sort { $0.direction != $1.direction ? $0.direction.rawValue < $1.direction.rawValue : ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) < ($1.year ?? 0) : $0.name < $1.name }
        return MusicSectionResult(items: items.map { $0 as AnyHashable }, provenance: MusicSongReads.provenance(items.map(\.status)))
    }
}

// MARK: versions (items 10 and 11)

struct MusicSongVersionsLoader: MusicEntitySectionLoader {
    let env: MusicSongLoaderEnv
    var key: String { MusicSongSectionKey.versions.loaderKey }
    static let maxItems = 48

    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        try await env.gate.run { try await self.read(entity, store, report) }
    }

    private func read(_ id: MusicEntityID, _ s: any MusicGraphStoring, _ report: MusicSectionReporter) async throws -> MusicSectionResult {
        var items: [MusicSongVersionItem] = []
        var seenKinds: [MusicEntityID: MusicVersionKind] = [:]

        func add(_ other: MusicEntityID, kind: MusicVersionKind, edge: MusicEdge?, relation: MusicSongVersionItem.Relation) async {
            guard other != id, items.count < Self.maxItems, let e = await MusicSongReads.entity(s, other) else { return }
            var k = kind
            if k == .unknown, let raw = e.attrs["versionKind"], let v = MusicVersionKind(rawValue: raw) { k = v }
            seenKinds[other] = k
            items.append(MusicSongVersionItem(id: other, name: e.name, year: e.year, kind: k, status: edge?.status ?? .inferred, confidence: edge?.confidence ?? 0.5,
                                              relation: relation, artistLine: nil, imageRef: e.imageRef, durationMs: e.durationMs))
        }

        // The recording this one is a version of.
        let out = await MusicSongReads.edges(s, id, .alternateOf, .outgoing, 12).filter { !$0.tombstone }.sorted(by: MusicSongVersioning.better)
        var originals: [MusicEntityID] = []
        for e in out where (e.attributes.versionKind ?? .unknown) != .original {
            await add(e.object, kind: .original, edge: e, relation: .original)
            originals.append(e.object)
        }
        try Task.checkCancellation()
        // Versions of this recording.
        for e in await MusicSongReads.edges(s, id, .alternateOf, .incoming, 40) where !e.tombstone {
            await add(e.subject, kind: e.attributes.versionKind ?? .unknown, edge: e, relation: .version)
        }
        await report.partial(MusicSectionResult(items: items.map { $0 as AnyHashable }))
        try Task.checkCancellation()
        // Other versions of the same original.
        for o in originals.prefix(2) {
            for e in await MusicSongReads.edges(s, o, .alternateOf, .incoming, 40) where !e.tombstone && e.subject != id {
                await add(e.subject, kind: e.attributes.versionKind ?? .unknown, edge: e, relation: .sibling)
            }
        }
        // Other recordings of the same work.
        for w in await MusicSongReads.edges(s, id, .recordingOf, .outgoing, 2) where !w.tombstone {
            try Task.checkCancellation()
            for e in await MusicSongReads.edges(s, w.object, .recordingOf, .incoming, 40) where !e.tombstone && e.subject != id {
                if seenKinds[e.subject] != nil { continue }
                var kind = MusicVersionKind.unknown
                if let own = await MusicSongReads.edges(s, e.subject, .alternateOf, .outgoing, 3).filter({ !$0.tombstone }).sorted(by: MusicSongVersioning.better).first {
                    kind = own.attributes.versionKind ?? .unknown
                }
                await add(e.subject, kind: kind, edge: e, relation: .sibling)
            }
        }
        // Fill in the singers' names for the first rows only (bounded reads).
        var final = MusicSongVersioning.dedupe(items, excluding: id).sorted(by: MusicSongVersioning.order)
        for i in final.indices.prefix(12) {
            try Task.checkCancellation()
            final[i].artistLine = await MusicSongReads.artistLine(s, final[i].id)
        }
        return MusicSectionResult(items: final.map { $0 as AnyHashable }, provenance: MusicSongReads.provenance(final.map(\.status)))
    }
}

// MARK: related songs (item 12)

struct MusicSongRelatedLoader: MusicEntitySectionLoader {
    let env: MusicSongLoaderEnv
    var key: String { MusicSongSectionKey.related.loaderKey }
    static let maxItems = 24
    static let maxLookups = 40

    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        try await env.gate.run { try await self.read(entity, store) }
    }

    private func read(_ id: MusicEntityID, _ s: any MusicGraphStoring) async throws -> MusicSectionResult {
        guard let hood = await env.hood.get(s, id) else { return MusicSectionResult() }
        try Task.checkCancellation()
        let direct = Set(hood.nodes.filter { $0.depth == 1 && MusicSongReads.isSong($0.id) }.map(\.id))
        var parentNames: [MusicEntityID: String] = [:]
        var raw: [(id: MusicEntityID, kind: MusicSongReasonKind, parent: MusicEntityID, conf: Float, status: EdgeStatus)] = []
        for n in hood.nodes where n.depth == 2 && n.id != id && MusicSongReads.isSong(n.id) && !direct.contains(n.id) {
            guard let k = MusicSongRelated.reasonKind(parent: n.parent.kind, predicate: n.predicate, direction: n.direction), k != .sameWork else { continue }
            raw.append((n.id, k, n.parent, n.confidence, n.status))
        }
        for p in Set(raw.map(\.parent)).sorted() where parentNames[p] == nil { parentNames[p] = await MusicSongReads.entity(s, p)?.name }
        try Task.checkCancellation()
        var snaps: [MusicEntityID: MusicEntitySnapshot] = [:]
        var cands: [(item: MusicSongRelatedItem, confidence: Float)] = []
        for r in raw {
            if snaps[r.id] == nil {
                if snaps.count >= Self.maxLookups { continue }
                if let e = await MusicSongReads.entity(s, r.id) { snaps[r.id] = e } else { continue }
            }
            guard let e = snaps[r.id] else { continue }
            let reason = MusicSongRelated.makeReason(r.kind, subject: parentNames[r.parent], confidence: r.conf, status: r.status)
            cands.append((MusicSongRelatedItem(id: e.id, name: e.name, year: e.year, imageRef: e.imageRef, artistLine: nil, reason: reason, score: 0), r.conf))
        }
        var ranked = Array(MusicSongRelated.rank(cands).prefix(Self.maxItems))
        for i in ranked.indices.prefix(12) { try Task.checkCancellation(); ranked[i].artistLine = await MusicSongReads.artistLine(s, ranked[i].id) }
        return MusicSectionResult(items: ranked.map { $0 as AnyHashable }, provenance: MusicSongReads.provenance(raw.map(\.status)))
    }
}

// MARK: more by the singer / the composer (items 13 and 14)

struct MusicSongMoreLoader: MusicEntitySectionLoader {
    let env: MusicSongLoaderEnv
    let section: MusicSongSectionKey
    var key: String { section.loaderKey }
    static let maxPeople = 3
    static let perPerson = 40
    static let maxItems = 24

    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        try await env.gate.run { try await self.read(entity, store) }
    }

    private var groupKinds: [MusicSongCreditGroupKind] { section == .moreBySinger ? [.singers] : [.composers, .musicDirectors] }

    private func reasonKind(_ g: MusicSongCreditGroupKind) -> MusicSongReasonKind {
        switch g { case .singers: .samePerformer; case .musicDirectors: .sameMusicDirector; default: .sameComposer }
    }

    private func read(_ id: MusicEntityID, _ s: any MusicGraphStoring) async throws -> MusicSectionResult {
        let groups = await env.credits.groups(s, id)
        try Task.checkCancellation()
        let selfName = await MusicSongReads.entity(s, id)?.name ?? ""
        let selfKey = MusicGraphText.latin(selfName)
        var perPersonLists: [[(MusicEdge, MusicSongCreditPerson, MusicSongCreditGroupKind)]] = []
        for kind in groupKinds {
            guard let g = groups.first(where: { $0.kind == kind }) else { continue }
            for person in g.people.prefix(Self.maxPeople) {
                try Task.checkCancellation()
                let pred: MusicPredicate = kind == .singers ? .performedBy : (kind == .musicDirectors ? .musicDirectedBy : .composedBy)
                let edges = await MusicSongReads.edges(s, person.id, pred, .incoming, Self.perPerson)
                    .filter { !$0.tombstone && MusicSongReads.isSong($0.subject) && $0.subject != id && (person.role == nil || $0.role == person.role) }
                perPersonLists.append(edges.map { ($0, person, kind) })
            }
        }
        // Round-robin so every person contributes.
        var picked: [(MusicEdge, MusicSongCreditPerson, MusicSongCreditGroupKind)] = []
        var seen = Set<MusicEntityID>()
        var i = 0
        while picked.count < Self.maxItems * 2, perPersonLists.contains(where: { i < $0.count }) {
            for l in perPersonLists where i < l.count && seen.insert(l[i].0.subject).inserted { picked.append(l[i]) }
            i += 1
        }
        var cands: [(item: MusicSongRelatedItem, confidence: Float)] = []
        for (e, person, kind) in picked {
            try Task.checkCancellation()
            guard let song = await MusicSongReads.entity(s, e.subject), MusicGraphText.latin(song.name) != selfKey else { continue }
            let reason = MusicSongReason(kind: reasonKind(kind), subject: person.displayName, possibly: false)
            cands.append((MusicSongRelatedItem(id: song.id, name: song.name, year: song.year, imageRef: song.imageRef, artistLine: nil, reason: reason, score: 0), e.confidence))
            if cands.count >= Self.maxItems { break }
        }
        var ranked = MusicSongRelated.rank(cands)
        for k in ranked.indices.prefix(12) { try Task.checkCancellation(); ranked[k].artistLine = await MusicSongReads.artistLine(s, ranked[k].id) }
        return MusicSectionResult(items: ranked.map { $0 as AnyHashable }, provenance: MusicSongReads.provenance(picked.map { $0.0.status }))
    }
}

// MARK: other films of the credited people (item 15)

struct MusicSongFilmsLoader: MusicEntitySectionLoader {
    let env: MusicSongLoaderEnv
    var key: String { MusicSongSectionKey.films.loaderKey }
    static let maxPeople = 4
    static let maxItems = 16
    static let predicates: [MusicPredicate] = [.composedBy, .musicDirectedBy, .writtenBy, .hasCast, .directedBy]

    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        try await env.gate.run { try await self.read(entity, store) }
    }

    private func read(_ id: MusicEntityID, _ s: any MusicGraphStoring) async throws -> MusicSectionResult {
        let groups = await env.credits.groups(s, id)
        let people = MusicSongCredits.people(in: groups, kinds: [.composers, .musicDirectors, .singers, .lyricists, .writers]).prefix(Self.maxPeople)
        guard !people.isEmpty else { return MusicSectionResult() }
        // The song's own film is not "another film".
        var own = Set<MusicEntityID>()
        for e in await MusicSongReads.edges(s, id, .featuredIn, .outgoing, 8) { own.insert(e.object) }
        for e in await MusicSongReads.soundtrackEdges(s, placements: await MusicSongReads.edges(s, id, .trackOn, .outgoing, 6), limit: 6) { own.insert(e.object) }
        try Task.checkCancellation()
        var cands: [(item: MusicSongRelatedItem, confidence: Float)] = []
        var statuses: [EdgeStatus] = []
        for person in people {
            try Task.checkCancellation()
            // One read per credit kind: a prolific person's incoming edges are mostly songs, so a single wide read would leave the film credits out of its window.
            var credits: [MusicEdge] = []
            for predicate in MusicSongFilmsLoader.predicates { credits += await MusicSongReads.edges(s, person.id, predicate, .incoming, 150) }
            for e in credits where !e.tombstone {
                guard e.subject.kind == .film || e.subject.kind == .series, !own.contains(e.subject), let k = MusicSongRelated.filmReasonKind(e.predicate),
                      let f = await MusicSongReads.entity(s, e.subject), f.attrs["hintOnly"] != "1" else { continue }
                let reason = MusicSongReason(kind: k, subject: person.displayName, possibly: false)
                cands.append((MusicSongRelatedItem(id: f.id, name: f.name, year: f.year, imageRef: f.imageRef, artistLine: nil, reason: reason, score: 0), e.confidence))
                statuses.append(e.status)
                if cands.count >= Self.maxItems * 3 { break }
            }
        }
        let ranked = Array(MusicSongRelated.rank(cands).prefix(Self.maxItems))
        return MusicSectionResult(items: ranked.map { $0 as AnyHashable }, provenance: MusicSongReads.provenance(statuses))
    }
}

// MARK: playlists (item 16, the graph's side; the person's own playlists come from the library)

struct MusicSongPlaylistsLoader: MusicEntitySectionLoader {
    let env: MusicSongLoaderEnv
    var key: String { MusicSongSectionKey.playlists.loaderKey }

    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        try await env.gate.run { try await self.read(entity, store) }
    }

    private func read(_ id: MusicEntityID, _ s: any MusicGraphStoring) async throws -> MusicSectionResult {
        var items: [MusicSongPlaylistItem] = []
        for e in await MusicSongReads.edges(s, id, .playlistContains, .incoming, 40) where !e.tombstone && e.subject.kind == .playlist {
            try Task.checkCancellation()
            guard let p = await MusicSongReads.entity(s, e.subject) else { continue }
            items.append(MusicSongPlaylistItem(id: p.id.rawValue, name: p.name, source: .provider, entityID: p.id, localID: nil, imageRef: p.imageRef))
        }
        let list = MusicSongPlaylists.combine(local: [], provider: items)
        return MusicSectionResult(items: list.map { $0 as AnyHashable })
    }
}

// MARK: similar recordings (item 17)

struct MusicSongSimilarLoader: MusicEntitySectionLoader {
    let env: MusicSongLoaderEnv
    var key: String { MusicSongSectionKey.similar.loaderKey }
    static let maxCandidates = 24
    static let maxItems = 16

    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        try await env.gate.run { try await self.read(entity, store) }
    }

    static func facets(_ s: any MusicGraphStoring, _ id: MusicEntityID) async -> MusicSongRelated.Facets {
        var f = MusicSongRelated.Facets()
        for e in await MusicSongReads.edges(s, id, nil, .outgoing, 60) where !e.tombstone {
            switch e.predicate {
            case .inLanguage: f.language.insert(e.object)
            case .ofEra: f.era.insert(e.object)
            case .hasGenre: f.genre.insert(e.object)
            default: break
            }
        }
        return f
    }

    private func read(_ id: MusicEntityID, _ s: any MusicGraphStoring) async throws -> MusicSectionResult {
        let mine = await Self.facets(s, id)
        guard !mine.isEmpty, let hood = await env.hood.get(s, id) else { return MusicSectionResult() }
        let direct = Set(hood.nodes.filter { $0.depth == 1 }.map(\.id))
        var seen = Set<MusicEntityID>(), cands: [MusicNeighbour] = []
        for n in hood.nodes where n.depth == 2 && n.id != id && MusicSongReads.isSong(n.id) && !direct.contains(n.id) && seen.insert(n.id).inserted {
            cands.append(n)
            if cands.count >= Self.maxCandidates { break }
        }
        var out: [(item: MusicSongRelatedItem, confidence: Float)] = []
        var names: [MusicEntityID: String] = [:]
        for n in cands {
            try Task.checkCancellation()
            let theirs = await Self.facets(s, n.id)
            let (kinds, shared) = MusicSongRelated.sharedFacets(mine, theirs)
            guard kinds >= MusicSongRelated.minimumSharedFacetKinds, let song = await MusicSongReads.entity(s, n.id) else { continue }
            var labels: [String] = []
            for f in shared.prefix(4) {
                if names[f] == nil { names[f] = await MusicSongReads.entity(s, f)?.name ?? "" }
                if let l = names[f], !l.isEmpty { labels.append(l) }
            }
            let reason = MusicSongReason(kind: .sharedFacets, subject: labels.joined(separator: ", "), possibly: false)
            out.append((MusicSongRelatedItem(id: song.id, name: song.name, year: song.year, imageRef: song.imageRef, artistLine: nil, reason: reason, score: 0), Float(kinds) / 3))
        }
        var ranked = Array(MusicSongRelated.rank(out).prefix(Self.maxItems))
        for i in ranked.indices.prefix(12) { try Task.checkCancellation(); ranked[i].artistLine = await MusicSongReads.artistLine(s, ranked[i].id) }
        return MusicSectionResult(items: ranked.map { $0 as AnyHashable })
    }
}
