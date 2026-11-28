import Foundation

/// What the music side already knows about an album, for the soundtrack-to-film join.
struct MusicAlbumHints: Sendable {
    var language: String?
    var musicBy: [String] = []
    var starring: [String] = []
    var singers: [String] = []
    init(language: String? = nil, musicBy: [String] = [], starring: [String] = [], singers: [String] = []) {
        self.language = language; self.musicBy = musicBy; self.starring = starring; self.singers = singers
    }
    init(_ f: MusicFilmProviderFacts?, language: String? = nil) { self.init(language: language ?? f?.language, musicBy: f?.musicBy ?? [], starring: f?.starring ?? [], singers: f?.singers ?? []) }
}

/// What the matcher needs of an album: from a provider album and its tracks, or from a stored release.
struct MusicAlbumFacts: Sendable {
    struct Track: Sendable { var title: String; var number: Int?; var durationMs: Int?; var recording: MusicEntityID? }
    var title: String
    var artists: [String]
    var releaseDate: String?
    var albumType: String?
    var tracks: [Track]
    init(title: String, artists: [String], releaseDate: String? = nil, albumType: String? = nil, tracks: [Track] = []) {
        self.title = title; self.artists = artists; self.releaseDate = releaseDate; self.albumType = albumType; self.tracks = tracks
    }
    init(_ a: MusicAlbum, tracks: [MusicTrack]) {
        self.init(title: a.title, artists: a.artists.map(\.name), releaseDate: a.releaseDate, albumType: a.albumType,
                  tracks: tracks.map { Track(title: $0.title, number: $0.trackNumber, durationMs: $0.durationMs > 0 ? Int($0.durationMs) : nil, recording: .provisional(kind: .recording, providerUID: $0.uid)) })
    }
}

extension MusicEntityResolver {
    // MARK: albums

    /// Album to MusicBrainz release group (editions, tracklist, credits) and, for a film soundtrack, to the film. Lazy and cache aware; the soundtrack edge
    /// is always `inferred` unless a source states it, with the evidence list on the claim.
    func enrichAlbum(_ album: MusicAlbum, tracks: [MusicTrack] = [], hints: MusicAlbumHints = MusicAlbumHints()) async -> MusicMetadataOutcome {
        guard let rel = try? await index.mint(MusicGraphAdapters.plan(for: album)) else { return MusicMetadataOutcome() }
        // Local, instant: the saved tracks exist as recordings so the MusicBrainz tracklist can bind to them.
        for t in tracks.prefix(200) { _ = try? await index.mint(MusicGraphAdapters.plan(for: t)) }
        return await enrichRelease(rel, MusicAlbumFacts(album, tracks: tracks), hints: hints)
    }

    /// The same for an album or release already in the graph.
    func enrichAlbum(_ id: MusicEntityID, hints: MusicAlbumHints = MusicAlbumHints()) async -> MusicMetadataOutcome {
        guard let rel = try? await store.resolve(id), let s = try? await store.entity(rel) else { return MusicMetadataOutcome() }
        var tracks: [MusicAlbumFacts.Track] = []
        for e in (try? await store.edges(of: rel, predicate: .trackOn, direction: .incoming, limit: 200)) ?? [] where !e.tombstone {
            if let r = try? await store.entity(e.subject) { tracks.append(.init(title: r.name, number: e.attributes.position, durationMs: r.durationMs, recording: e.subject)) }
        }
        let artists = await namesOf(rel, [.performedBy])
        return await enrichRelease(rel, MusicAlbumFacts(title: s.name, artists: artists, releaseDate: s.year.map(String.init), albumType: s.subkind, tracks: tracks), hints: hints)
    }

    func enrichRelease(_ rel: MusicEntityID, _ album: MusicAlbumFacts, hints: MusicAlbumHints = MusicAlbumHints()) async -> MusicMetadataOutcome {
        var result = MusicMetadataOutcome()
        let tracks = album.tracks
        result.entity = rel
        let t = now()
        let mbFresh = (try? await store.cacheState(entity: rel, facet: "albumLinks", source: .musicbrainz))?.isFresh(at: t) ?? false
        var group = await groupOf(rel)
        if !mbFresh { group = await linkReleaseGroup(album: album, release: rel, hints: hints, result: &result) ?? group }
        else { result.fromCache = true }
        guard !Task.isCancelled else { result.cancelled = true; return result }
        let filmFresh = (try? await store.cacheState(entity: rel, facet: "filmLink", source: .matcher))?.isFresh(at: t) ?? false
        if filmFresh {
            var found = await linkedFilm(of: group ?? rel)
            if found == nil, group != nil { found = await linkedFilm(of: rel) }
            result.linkedFilm = found
            return result
        }
        result.fromCache = false
        let hintTitle = MusicFilmResolver.soundtrackFilm(inAlbumTitle: album.title) ?? MusicGraphAdapters.filmHint(inTitle: album.title)
            ?? tracks.compactMap { MusicGraphAdapters.filmHint(inTitle: $0.title) }.first
        let isSoundtrack = MusicGraphAdapters.albumSubkind(type: album.albumType, title: album.title) == MusicAlbumSubkind.soundtrack.rawValue
        let groupSnap: MusicEntitySnapshot? = group == nil ? nil : (try? await store.entity(group!)) ?? nil
        guard hintTitle != nil || isSoundtrack || groupSnap?.subkind == MusicAlbumSubkind.soundtrack.rawValue else { return result }
        let title = MusicResolutionScoring.cleanTitle(hintTitle ?? album.title)
        let gYear = groupSnap?.year
        var composers = hints.musicBy
        if let g = group { composers += await names(of: g, predicates: [.performedBy, .composedBy]) }
        composers += album.artists
        let hint = MusicResolutionScoring.FilmHint(title: title, year: gYear ?? MusicGraphAdapters.year(album.releaseDate), yearTrusted: gYear != nil, language: hints.language,
                                                   composers: Array(NSOrderedSet(array: composers)) as? [String] ?? composers, starring: hints.starring)
        if let (film, scored) = await resolveFilm(hint: hint, result: &result) {
            let subject = group ?? rel
            result.linkedFilm = film
            await writeSoundtrackEdge(subject: subject, film: film, scored: scored, dub: hints.language, result: &result)
            try? await store.setCacheState(entity: rel, facet: "filmLink", source: .matcher, outcome: .ok, ttl: 30 * 86_400, etag: nil, matcherVersion: MusicResolutionScoring.matcherVersion)
        } else if !Task.isCancelled && result.failed.isEmpty {
            try? await store.setCacheState(entity: rel, facet: "filmLink", source: .matcher, outcome: .empty, ttl: 7 * 86_400, etag: nil, matcherVersion: MusicResolutionScoring.matcherVersion)
        }
        return result
    }

    private func groupOf(_ release: MusicEntityID) async -> MusicEntityID? {
        guard let e = try? await store.edges(of: release, predicate: .editionOf, direction: .outgoing, limit: 5) else { return nil }
        return e.first { !$0.tombstone }?.object
    }

    private func linkedFilm(of id: MusicEntityID) async -> MusicEntityID? {
        (try? await store.edges(of: id, predicate: .soundtrackOf, direction: .outgoing, limit: 5))?.first { !$0.tombstone && $0.confidence >= 0.6 }?.object
    }

    private func names(of id: MusicEntityID, predicates: Set<MusicPredicate>) async -> [String] {
        var out: [String] = []
        for e in (try? await store.edges(of: id, predicate: nil, direction: .outgoing, limit: 100)) ?? [] where predicates.contains(e.predicate) && !e.tombstone {
            if let s = try? await store.entity(e.object) { out.append(s.name) }
        }
        return out
    }

    private func linkReleaseGroup(album: MusicAlbumFacts, release: MusicEntityID, hints: MusicAlbumHints, result: inout MusicMetadataOutcome) async -> MusicEntityID? {
        let title = MusicResolutionScoring.cleanTitle(MusicFilmResolver.soundtrackFilm(inAlbumTitle: album.title) ?? album.title)
        let artist = hints.musicBy.first ?? album.artists.first ?? ""
        var cands: [(MusicSourceDraft, MusicResolutionScoring.Scored)] = []
        // MusicBrainz folds nothing: "Awaara" does not find "Awāra". Try the spelling, the macron spelling, then the transliteration alternates, with the
        // artist first and the title alone last.
        var variants = [title]
        let macron = title.replacingOccurrences(of: "aa", with: "ā").replacingOccurrences(of: "Aa", with: "Ā")
        if macron != title { variants.append(macron) }
        variants += MusicTransliterationKey.alternates(of: title, limit: 2).filter { !variants.contains($0) }
        var attempts: [(String, Bool)] = variants.prefix(3).map { ($0, true) }
        if !artist.isEmpty { attempts.append((title, false)) } else { attempts = attempts.map { ($0.0, false) } }
        for (variant, useArtist) in attempts {
            if !cands.isEmpty { break }
            if useArtist, artist.isEmpty { continue }
            let f = await fetch(.musicbrainz, MusicSourceRequest(.musicbrainz, MusicFacet.releaseGroupSearch, ["title": variant, "artist": useArtist ? artist : ""]), cacheEntity: nil, result: &result)
            guard case .batch(let b) = f else { if case .skipped = f { return nil }; if case .failed = f { return nil }; continue }
            let artists = [artist] + album.artists
            cands = b.drafts.map { ($0, MusicResolutionScoring.album(title: title, artists: artists.filter { !$0.isEmpty }, year: nil, trackTitles: [], candidate: $0.entity, candidateTracks: nil)) }
                .filter { MusicResolutionScoring.sim(title, $0.0.entity.name) >= 0.85 && $0.1.score >= 0.6 }.sorted { $0.1.score > $1.1.score }
        }
        guard let top = cands.first, case .external(_, let gx) = top.0.ref, !Task.isCancelled else {
            try? await store.setCacheState(entity: release, facet: "albumLinks", source: .musicbrainz, outcome: .empty, ttl: 7 * 86_400, etag: nil, matcherVersion: MusicResolutionScoring.matcherVersion)
            return nil
        }
        // Release group lookup (editions, Wikidata link), then the first edition's tracklist for the overlap signal.
        let gf = await fetch(.musicbrainz, MusicSourceRequest(.musicbrainz, MusicFacet.releaseGroup, ["mbid": gx.value]), cacheEntity: nil, result: &result)
        guard let (gb, grep) = await take(gf, result: &result), let groupID = grep?.ids[top.0.ref] else { return nil }
        let firstRelease = gb.drafts.first { $0.ref.kind == .release }
        var trackTitles: [String]?
        if case .external(_, let rx)? = firstRelease?.ref {
            let tf = await fetch(.musicbrainz, MusicSourceRequest(.musicbrainz, MusicFacet.releaseTracklist, ["mbid": rx.value]), cacheEntity: nil, result: &result)
            if case .batch(let tb) = tf {
                trackTitles = tb.drafts.filter { $0.ref.kind == .recording }.map(\.entity.name)
                if let rep = try? await ingest(tb) { result.edgesWritten += rep.edgesWritten; await bindTracks(provider: album.tracks, mbBatch: tb, report: rep) }
            }
        }
        let final = MusicResolutionScoring.album(title: title, artists: [artist] + album.artists, year: nil, trackTitles: album.tracks.map(\.title), candidate: top.0.entity, candidateTracks: trackTitles)
        let decision = final.decision
        if decision == .merge || decision == .probable {
            let conf = decision == .merge ? min(0.99, final.score) : 0.6
            let edge = MusicEdge(subject: release, predicate: .editionOf, object: groupID, confidence: conf, creditLevel: .album)
            _ = try? await store.addEdge(edge, provenance: MusicProvenance(source: .matcher, retrievedAt: now(), license: .derived, score: conf, matcherVersion: MusicResolutionScoring.matcherVersion,
                                                                          evidence: final.evidence + (decision == .probable ? ["probable"] : [])))
            try? await store.setCacheState(entity: release, facet: "albumLinks", source: .musicbrainz, outcome: .ok, ttl: 60 * 86_400, etag: nil, matcherVersion: MusicResolutionScoring.matcherVersion)
            return groupID
        }
        try? await store.setCacheState(entity: release, facet: "albumLinks", source: .musicbrainz, outcome: .empty, ttl: 7 * 86_400, etag: nil, matcherVersion: MusicResolutionScoring.matcherVersion)
        return nil
    }

    /// Provider track to the MusicBrainz recording at the same position with the same title and a duration within five seconds: two independent
    /// signals (duration, same place on the same release) beside the name, so the recordings merge and the credits land on the saved one.
    private func bindTracks(provider tracks: [MusicAlbumFacts.Track], mbBatch: MusicClaimBatch, report: MusicIngestReport) async {
        var position: [MusicDraftRef: Int] = [:]
        for c in mbBatch.claims where c.predicate == .trackOn { if let p = c.attributes.position { position[c.subject] = p } }
        for t in tracks {
            guard let n = t.number, let rid = t.recording, let local = try? await store.resolve(rid) else { continue }
            for d in mbBatch.drafts where d.ref.kind == .recording && position[d.ref] == n {
                guard MusicResolutionScoring.sim(t.title, d.entity.name) >= 0.9, let mbID = report.ids[d.ref], mbID != local,
                      let ls = try? await store.entity(local), let ms = try? await store.entity(mbID) else { continue }
                var e = MusicMergeRule.Evidence(kind: .recording, signals: [.init(.name, 1), .init(.workOverlap, 0.9)])
                if let a = t.durationMs, let b = d.entity.durationMs {
                    e.signals.append(.init(.duration, abs(a - b) <= 5_000 ? 1 : 0))
                    e.blockers = MusicMergeRule.blockers(kind: .recording, strongIDsA: [], strongIDsB: [], yearA: nil, yearB: nil, durationMsA: a, durationMsB: b)
                }
                if MusicMergeRule.decide(e) == .merge {
                    let (w, l) = ls.createdAt <= ms.createdAt ? (local, mbID) : (mbID, local)
                    _ = try? await store.mergeEntities(winner: w, loser: l, byUser: false)
                }
            }
        }
    }

    // MARK: film finding

    private struct FilmCandidate { var qid: String?; var tmdb: String?; var imdb: String?; var name: String; var year: Int?; var source: MusicSourceID }

    private func prescore(_ hint: MusicResolutionScoring.FilmHint, _ c: FilmCandidate) -> Float {
        var s = MusicResolutionScoring.sim(hint.title, c.name)
        if let hy = hint.year, let cy = c.year, hint.yearTrusted, abs(hy - cy) > 1 { s = 0 }
        return s
    }

    private func facts(of film: MusicEntityID) async -> MusicResolutionScoring.FilmFacts? {
        guard let s = try? await store.entity(film) else { return nil }
        let al = (try? await store.aliases(of: film)) ?? []
        var dub: [String] = []
        for a in al { if let l = a.lang { dub.append(l.lowercased()) } }
        for part in (s.attrs["sitelinks"] ?? "").split(separator: "|") { if let i = part.firstIndex(of: ":"), part[..<i].hasSuffix("wiki") { dub.append(String(part[..<i].dropLast(4))) } }
        let composers = await names(of: film, predicates: [.composedBy, .musicDirectedBy])
        let cast = await names(of: film, predicates: [.hasCast])
        return .init(names: [s.name] + al.map(\.text), year: s.year, language: s.lang, composers: composers, cast: cast, dubLanguages: dub)
    }

    /// The film a soundtrack belongs to, through the chain Wikidata, Wikipedia (including the soundtrack article), IMDb and TMDB (optional, last).
    /// Returns nil when no candidate reaches the probable band. Two candidates in the merge band are an ambiguity and are both returned as conflicted.
    private func resolveFilm(hint: MusicResolutionScoring.FilmHint, result: inout MusicMetadataOutcome) async -> (MusicEntityID, MusicResolutionScoring.Scored)? {
        var cands: [FilmCandidate] = []
        func add(_ b: MusicClaimBatch, _ src: MusicSourceID) {
            for d in b.drafts where d.entity.kind == .film {
                var c = FilmCandidate(qid: nil, tmdb: nil, imdb: nil, name: d.entity.name, year: d.entity.year, source: src)
                for x in d.entity.externalIDs { switch x.scheme { case .wikidata: c.qid = x.value; case .tmdbMovie: c.tmdb = x.value; case .imdbTitle: c.imdb = x.value; default: break } }
                cands.append(c)
            }
        }
        if case .batch(let b) = await fetch(.wikidata, MusicSourceRequest(.wikidata, MusicFacet.filmSearch, ["title": hint.title]), cacheEntity: nil, result: &result) { add(b, .wikidata) }
        var viable = cands.filter { prescore(hint, $0) >= 0.7 }
        if viable.isEmpty {
            // The soundtrack's own article names its film, which also catches a dub whose title differs from the film's.
            let q = ([hint.title, hint.year.map(String.init) ?? "", "film"] + hint.composers.prefix(1)).filter { !$0.isEmpty }.joined(separator: " ")
            if case .batch(let b) = await fetch(.wikipedia, MusicSourceRequest(.wikipedia, "articleSearch", ["query": q, "lang": "en"]), cacheEntity: nil, result: &result) {
                add(b, .wikipedia)
                for d in b.drafts where d.entity.kind == .album && viable.count < 3 {
                    // A soundtrack article is relevant by its composer and year, not by its title (a dub is released under another name).
                    let desc = (d.entity.attrs["description"] ?? "").lowercased()
                    let byComposer = hint.composers.contains { !$0.isEmpty && desc.contains($0.lowercased()) }
                    let yearOK = hint.year.map { y in d.entity.year.map { abs($0 - y) <= 1 } ?? true } ?? true
                    guard byComposer || MusicResolutionScoring.sim(hint.title, d.entity.name) >= 0.85, yearOK, let article = d.entity.attrs["article"] else { continue }
                    if case .batch(let fb) = await fetch(.wikipedia, MusicSourceRequest(.wikipedia, "soundtrackFilm", ["lang": "en", "article": article]), cacheEntity: nil, result: &result) {
                        for fd in fb.drafts where fd.entity.kind == .film {
                            let c = FilmCandidate(qid: fd.entity.externalIDs.first { $0.scheme == .wikidata }?.value, tmdb: nil, imdb: nil, name: hint.title, year: hint.year, source: .wikipedia)
                            cands.append(c); viable.append(c)
                        }
                    }
                }
            }
            viable = viable.isEmpty ? cands.filter { prescore(hint, $0) >= 0.7 } : viable
        }
        if viable.isEmpty {
            if case .batch(let b) = await fetch(.imdb, MusicSourceRequest(.imdb, MusicFacet.filmSearch, ["title": hint.title]), cacheEntity: nil, result: &result) { add(b, .imdb) }
            if case .batch(let b) = await fetch(.tmdb, MusicSourceRequest(.tmdb, MusicFacet.filmSearch, ["title": hint.title, "year": hint.year.map(String.init) ?? ""]), cacheEntity: nil, result: &result) { add(b, .tmdb) }
            viable = cands.filter { prescore(hint, $0) >= 0.7 }
        }
        var scored: [(MusicEntityID, MusicResolutionScoring.Scored)] = []
        for c in viable.sorted(by: { prescore(hint, $0) > prescore(hint, $1) }).prefix(3) {
            guard !Task.isCancelled else { break }
            var filmID: MusicEntityID?
            if let q = c.qid, case .batch(let b) = await fetch(.wikidata, MusicSourceRequest(.wikidata, MusicFacet.filmCredits, ["qid": q, "kind": "film"]), cacheEntity: nil, result: &result) {
                filmID = (try? await ingest(b))?.ids[.external(.film, ExternalID(.wikidata, q))]
            } else if let tm = c.tmdb, case .batch(let b) = await fetch(.tmdb, MusicSourceRequest(.tmdb, MusicFacet.filmCredits, ["tmdb": tm]), cacheEntity: nil, result: &result) {
                filmID = (try? await ingest(b))?.ids[.external(.film, ExternalID(.tmdbMovie, tm))]
            } else if let im = c.imdb {
                if case .batch(let b) = await fetch(.imdb, MusicSourceRequest(.imdb, MusicFacet.filmCredits, ["imdb": im]), cacheEntity: nil, result: &result) { filmID = (try? await ingest(b))?.ids[.external(.film, ExternalID(.imdbTitle, im))] }
                if filmID == nil, let x = try? await store.resolveAlias(for: ExternalID(.imdbTitle, im), kind: .film) { filmID = x }
            }
            guard let fid = filmID, let f = await facts(of: fid) else { continue }
            scored.append((fid, MusicResolutionScoring.film(hint: hint, facts: f)))
        }
        guard let best = scored.max(by: { $0.1.score < $1.1.score }), best.1.decision != .reject else { return nil }
        result.linkedFilm = best.0
        // Two different films both in the merge band: an ambiguity (remake, dub, same title), kept as conflicted, never merged.
        let strong = scored.filter { $0.1.decision == .merge && $0.0 != best.0 }
        if best.1.decision == .merge, !strong.isEmpty { result.stale = result.stale || false; ambiguous = [best] + strong }
        return best
    }

    /// Writes the soundtrack edge: always `inferred` here (a matcher claim, never `stated`), with the signals as the evidence list.
    private func writeSoundtrackEdge(subject: MusicEntityID, film: MusicEntityID, scored: MusicResolutionScoring.Scored, dub: String?, result: inout MusicMetadataOutcome) async {
        let decision = scored.decision
        let conf: Float = decision == .merge ? min(0.99, scored.score) : 0.6
        var attrs = EdgeAttributes()
        if scored.evidence.contains("dub-language") { attrs.dubLanguage = dub }
        let edge = MusicEdge(subject: subject, predicate: .soundtrackOf, object: film, attributes: attrs, confidence: conf, creditLevel: .film)
        let ev = scored.evidence + (decision == .probable ? ["probable"] : [])
        let key = edge.key
        if let amb = ambiguous, amb.count > 1 {
            // Each candidate gets an assertion and a disagreement of equal rank: the aggregate is `conflicted`.
            for (fid, s) in amb {
                let e = MusicEdge(subject: subject, predicate: .soundtrackOf, object: fid, confidence: min(0.99, s.score), creditLevel: .film)
                _ = try? await store.addEdge(e, provenance: MusicProvenance(source: .matcher, sourceRef: "match", retrievedAt: now(), license: .derived, score: s.score, matcherVersion: MusicResolutionScoring.matcherVersion, evidence: s.evidence))
                try? await store.setFact(MusicProvenance(source: .matcher, sourceRef: "ambiguous", retrievedAt: now(), license: .derived, score: 0.9, matcherVersion: MusicResolutionScoring.matcherVersion,
                                                         evidence: ["ambiguous-with-other-film"], stance: .contradicts), for: e.key)
            }
            ambiguous = nil
            result.edgesWritten += amb.count
            return
        }
        _ = try? await store.addEdge(edge, provenance: MusicProvenance(source: .matcher, sourceRef: "match", retrievedAt: now(), license: .derived, score: conf, matcherVersion: MusicResolutionScoring.matcherVersion, evidence: ev))
        _ = key
        result.edgesWritten += 1
    }

    // MARK: films and people

    /// Cast, crew and composer of a film entity, from the TMDB-free chain (Wikidata, then Wikipedia in every edition the film has, then IMDb) and TMDB or OMDb
    /// when they are on. Each source is asked only when its facet is not fresh. Returns quickly from the store when everything is fresh.
    func enrichFilm(_ film: MusicEntityID) async -> MusicMetadataOutcome {
        var result = MusicMetadataOutcome(); result.entity = film
        guard let snap = try? await store.entity(film) else { return result }
        var ids = (try? await store.externalIDs(of: film)) ?? []
        func id(_ s: ExternalID.Scheme) -> String? { ids.first { $0.scheme == s }?.value }
        var asked = false
        // Wikidata item: known, or found by IMDb or TMDB id (bounded SPARQL), or by title.
        if id(.wikidata) == nil, let im = id(.imdbTitle) {
            if case .batch(let b) = await fetch(.wikidata, MusicSourceRequest(.wikidata, MusicFacet.reverseLookup, ["property": "P345", "value": im, "kind": "film"]), cacheEntity: film, cacheFacet: "reverse:imdb", background: true, result: &result),
               let q = b.drafts.first?.entity.externalIDs.first(where: { $0.scheme == .wikidata }) { _ = try? await store.upsert(MusicEntityDraft(kind: .film, name: snap.name, externalIDs: [ids.first(where: \.isStrong) ?? q, q])); ids.append(q) }
        }
        if let q = id(.wikidata) {
            let f = await fetch(.wikidata, MusicSourceRequest(.wikidata, MusicFacet.filmCredits, ["qid": q, "kind": "film"]), cacheEntity: film, cacheFacet: MusicFacet.filmCredits, result: &result)
            switch f { case .batch, .cached: asked = true; default: break }
            _ = await take(f, result: &result)
            ids = (try? await store.externalIDs(of: film)) ?? ids
        }
        let castCount = await names(of: film, predicates: [.hasCast]).count
        // Wikipedia: the editions Wikidata lists (English, the film's language, Telugu, Tamil...), when the cast is thin or no structured source answered.
        if castCount < 8 || !asked {
            let s = (try? await store.entity(film)) ?? snap
            var links: [String: String] = [:]
            for part in (s.attrs["sitelinks"] ?? "").split(separator: "|") { if let i = part.firstIndex(of: ":") { links[String(part[..<i])] = String(part[part.index(after: i)...]) } }
            for a in WikipediaSource.articles(sitelinks: links, language: s.lang).prefix(2) {
                let f = await fetch(.wikipedia, MusicSourceRequest(.wikipedia, MusicFacet.filmCredits, ["lang": a.lang, "article": a.title] .merging(id(.wikidata).map { ["qid": $0] } ?? [:]) { $1 }),
                                    cacheEntity: film, cacheFacet: "filmCredits:" + a.lang + "wiki", result: &result)
                _ = await take(f, result: &result)
            }
        }
        if let im = id(.imdbTitle), (await names(of: film, predicates: [.hasCast]).count) < 8 {
            let f = await fetch(.imdb, MusicSourceRequest(.imdb, MusicFacet.filmCredits, ["imdb": im]), cacheEntity: film, cacheFacet: MusicFacet.filmCredits, result: &result)
            _ = await take(f, result: &result)
        }
        if let tm = id(.tmdbMovie) {
            let f = await fetch(.tmdb, MusicSourceRequest(.tmdb, MusicFacet.filmCredits, ["tmdb": tm]), cacheEntity: film, cacheFacet: MusicFacet.filmCredits, result: &result)
            _ = await take(f, result: &result)
        }
        if id(.tmdbMovie) == nil, let tv = id(.tmdbTV) {
            let f = await fetch(.tmdb, MusicSourceRequest(.tmdb, MusicFacet.filmCredits, ["tmdbTV": tv]), cacheEntity: film, cacheFacet: "filmCreditsTV", result: &result)
            _ = await take(f, result: &result)
        }
        if let im = id(.imdbTitle) {
            let f = await fetch(.omdb, MusicSourceRequest(.omdb, MusicFacet.filmCredits, ["imdb": im]), cacheEntity: film, cacheFacet: "omdb", result: &result)
            _ = await take(f, result: &result)
        }
        result.fromCache = result.fetched.isEmpty && result.failed.isEmpty
        return result
    }

    /// Roles, ids and works of one person: Wikidata ids and portrait file, TMDB filmography for actors and directors (when TMDB is on), and the
    /// MusicBrainz discography for musical roles. Facets are cache aware; nothing is asked for a person with no id.
    func enrichPerson(_ person: MusicEntityID, roles: Set<MusicRole> = []) async -> MusicMetadataOutcome {
        var result = MusicMetadataOutcome(); result.entity = person
        let ids = (try? await store.externalIDs(of: person)) ?? []
        func id(_ s: ExternalID.Scheme) -> String? { ids.first { $0.scheme == s }?.value }
        let kind = person.kind
        if let q = id(.wikidata) {
            let f = await fetch(.wikidata, MusicSourceRequest(.wikidata, MusicFacet.entityLinks, ["qid": q, "kind": kind.slug]), cacheEntity: person, cacheFacet: MusicFacet.entityLinks, result: &result)
            _ = await take(f, bind: [.external(kind, ExternalID(.wikidata, q)): person], result: &result)
        }
        if roles.isEmpty || !roles.isDisjoint(with: [.actor, .director, .producer]), let tp = id(.tmdbPerson) {
            let f = await fetch(.tmdb, MusicSourceRequest(.tmdb, MusicFacet.personFilmography, ["tmdbPerson": tp]), cacheEntity: person, cacheFacet: MusicFacet.personFilmography, result: &result)
            _ = await take(f, result: &result)
        }
        if roles.isEmpty || roles.contains(where: \.isMusical), let mb = id(.mbid) {
            let f = await fetch(.musicbrainz, MusicSourceRequest(.musicbrainz, "artistDiscography", ["mbid": mb]), cacheEntity: person, cacheFacet: "artistDiscography", result: &result)
            _ = await take(f, result: &result)
        }
        result.fromCache = result.fetched.isEmpty && result.failed.isEmpty
        return result
    }
}
