import Foundation

/// The same completeness idea for film pages (the film's soundtrack albums, in every language and edition the sources list) and album pages (the
/// album's other editions on the catalogue providers). Cast and crew of a film come from the existing film enrichment, whose Wikidata reader is widened
/// by this change; a film page reads soundtracks through the graph's `soundtrackOf` edges, which until now only songs the listener opened could create.
extension MusicPersonCompleteness {
    private func pickSoundtracks(_ cands: [MusicPersonWork], film title: String, year: Int?, lang: String?) -> [MusicPersonWork] {
        let fk = MusicPersonWorkKey.filmKey(title)
        guard !fk.isEmpty else { return [] }
        return cands.filter { w in
            let p = MusicPersonWorkKey.parse(w.title)
            let named = p.key == fk || (w.filmTitle.map { MusicPersonWorkKey.filmKey($0) == fk } ?? false)
            return named && (w.statesFilm || w.isSoundtrack || p.soundtrackWording) && MusicPersonWorkKey.yearsCompatible(w.year, year, tolerance: 1)
                && MusicPersonWorkKey.langsCompatible(w.lang ?? p.lang, nil)
        }
    }

    /// Soundtrack albums of one film: Wikidata's own statement (P406), MusicBrainz soundtrack release groups of the same title, and catalogue albums.
    func runFilm(_ requested: MusicEntityID, progress: @escaping Progress = { _, _ in }) async -> Outcome {
        var out = Outcome(person: requested)
        guard requested.kind == .film || requested.kind == .series, let film = try? await store.resolve(requested), let snap = try? await store.entity(film) else { return out }
        let ids = (try? await store.externalIDs(of: film)) ?? []
        let filmWork: MusicPersonWork = {
            var w = MusicPersonWork(kind: .film, title: snap.name, year: snap.year, lang: snap.lang, ids: ids.filter(\.isStrong), source: .matcher)
            w.relations = []; return w
        }()
        await progress([], .started)
        var albums: [MusicPersonWork] = []
        if let q = ids.first(where: { $0.scheme == .wikidata })?.value {
            await stage("film.wikidata", source: .wikidata, ttl: limits.okTTL, person: film, out: &out, progress: progress) {
                let e = try await get(.wikidata, Self.wikidataEntity.appendingPathComponent(q + ".json"))
                let st = MusicPersonWikidataParser.soundtrackIDs(entity: e, qid: q)
                guard !st.isEmpty else { return 0 }
                let d = try await get(.wikidata, Self.wikidataBase, ["action": "wbgetentities", "ids": st.prefix(50).joined(separator: "|"), "props": "labels|claims", "languages": "en", "format": "json"])
                let found = MusicPersonWikidataParser.soundtrackAlbums(entities: d, film: snap.name)
                albums += found
                return found.count
            }
        }
        await stage("film.musicbrainz", source: .musicbrainz, ttl: limits.okTTL, person: film, out: &out, progress: progress) {
            let key = snap.name.replacingOccurrences(of: "\"", with: " ")
            let d = try await mb("release-group", ["query": "releasegroup:\"\(key)\" AND secondarytype:soundtrack", "limit": "10"])
            let found = pickSoundtracks(MusicPersonMusicBrainzParser.releaseGroups(d).items.map { var w = $0; w.relations = []; return w }, film: snap.name, year: snap.year, lang: snap.lang)
            albums += found
            return found.count
        }
        if let catalogue {
            await stage("film.catalogue", source: .jiosaavn, ttl: limits.catalogueTTL, person: film, out: &out, progress: progress) {
                let found = pickSoundtracks(await catalogue.albums(titled: snap.name, maxPerProvider: 12).map { var w = $0; w.relations = []; return w }, film: snap.name, year: snap.year, lang: snap.lang)
                albums += found
                return found.count
            }
        }
        if out.cancelled { await progress([], .finished(complete: false)); return out }
        guard !albums.isEmpty, let res = try? await writer.write(albums, person: nil, personIsComposer: false) else { await progress([], .finished(complete: out.complete)); return out }
        out.edgesWritten += res.edgesWritten
        let order = albums.indices.filter { res.ids[$0] != nil }
        let pairs = MusicPersonWorkWriter.soundtrackPairs(albums: order.map { albums[$0] }, films: [filmWork])
        let n = (try? await writer.link(pairs, albumIDs: order.compactMap { res.ids[$0] }, filmIDs: [film], albums: order.map { albums[$0] })) ?? 0
        out.edgesWritten += n; out.albumsFound = order.count
        await progress(res.changed.union([film]), .finished(complete: out.complete))
        return out
    }

    /// Other editions of one album on the catalogue providers, joined to it by `editionOf` (never merged). A provider album that has no album concept
    /// yet gets one, and the opened release is joined to it.
    func runAlbum(_ requested: MusicEntityID, progress: @escaping Progress = { _, _ in }) async -> Outcome {
        var out = Outcome(person: requested)
        guard requested.kind == .album || requested.kind == .release, let album = try? await store.resolve(requested), let snap = try? await store.entity(album), let catalogue else { return out }
        let credits = (try? await store.edges(of: album, predicate: nil, direction: .outgoing, limit: 40)) ?? []
        var names: [String] = []
        for e in credits where !e.tombstone && e.object.kind.isAgent && [.performedBy, .composedBy, .musicDirectedBy].contains(e.predicate) {
            if let s = try? await store.entity(e.object), !MusicCompilationArtist.isCompilation(s.name) { names.append(s.name) }
        }
        guard !names.isEmpty else { return out }   // nobody to check an edition against: never guess by title alone
        await progress([], .started)
        let p = MusicPersonWorkKey.parse(snap.name)
        var changed: Set<MusicEntityID> = []
        var edges = 0
        await stage("album.editions", source: .jiosaavn, ttl: limits.catalogueTTL, person: album, out: &out, progress: progress) {
            let found = await catalogue.albums(titled: snap.name, maxPerProvider: 12).filter { w in
                let wp = MusicPersonWorkKey.parse(w.title)
                return wp.key == p.key && MusicPersonWorkKey.langsCompatible(w.lang ?? wp.lang, snap.lang ?? p.lang) && MusicPersonWorkKey.yearsCompatible(w.year, snap.year, tolerance: 2)
                    && w.artists.contains { a in names.contains { MusicTransliterationKey.similarity(a, $0) >= 0.85 } }
            }
            guard !found.isEmpty else { return 0 }
            var bindings: [Int: MusicEntityID] = [:]
            if requested.kind == .album { for i in found.indices { bindings[i] = album } }
            let res = try await writer.write(found, person: nil, personIsComposer: false, bindings: bindings)
            edges += res.edgesWritten; changed.formUnion(res.changed)
            if requested.kind == .release, let concept = res.ids.values.first(where: { $0.kind == .album }) {
                let e = MusicEdge(subject: album, predicate: .editionOf, object: concept, confidence: 0.8, creditLevel: .album)
                let prov = MusicProvenance(source: .matcher, retrievedAt: now(), license: .derived, score: 0.8, matcherVersion: MusicResolutionScoring.matcherVersion, evidence: ["title+artist"])
                if (try? await store.addEdge(e, provenance: prov)) != nil { edges += 1 }
            }
            return found.count
        }
        out.edgesWritten += edges
        await progress(changed.union(changed.isEmpty ? [] : [album]), .finished(complete: out.complete))
        return out
    }
}
