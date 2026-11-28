import Foundation

/// The person completeness pass: fetches a person's full filmography and discography from public sources and writes it into the graph, once per person
/// per freshness window. Sources in order: Wikidata (identity, then every film, album and song the person is linked to), MusicBrainz (release groups, works,
/// recordings, paged), IMDb's public pages (filmography, best effort), and the catalogue providers the app already has (playable albums). Each stage
///   - is gated like every other metadata call (consent, per-source switch, Kids/lock, offline) and runs through the same governed transport,
///   - is cached per person and source (TTL on success, a shorter one on "nothing found", back-off on error),
///   - writes what it found before the next stage starts and reports the changed entities, so an open page shows partial results as they arrive,
///   - stops at once when the task is cancelled, leaving finished stages written and the unfinished one unmarked (the next run redoes only that one).
/// It works with no TMDB key and no sign-in. It never throws for a network or source failure.
actor MusicPersonCompleteness {
    enum Phase: Sendable, Equatable {
        case started
        case stage(String)
        case finished(complete: Bool)
    }

    struct Limits: Sendable {
        // A prolific artist has thousands of credited recordings; MusicBrainz pages at 100 and the gate allows one request a second, so these walk up to 2,000 release groups,
        // 1,500 works and 2,000 recordings in the background (cancel-safe, and each finished page is already written).
        var releaseGroupPages = 20
        var workPages = 15
        var recordingPages = 20
        var catalogueAlbumPages = 8
        var searchFallbackPages = 6
        var okTTL: TimeInterval = 14 * 86_400
        var catalogueTTL: TimeInterval = 7 * 86_400
        var emptyTTL: TimeInterval = 3 * 86_400
        var identityTTL: TimeInterval = 90 * 86_400
    }

    struct Outcome: Sendable {
        var person: MusicEntityID
        var stagesRun: [String] = []
        var stagesCached: [String] = []
        var stagesSkipped: [String: MusicEnrichmentSkip] = [:]
        var stagesFailed: [String] = []
        var filmsFound = 0, albumsFound = 0, worksFound = 0
        var edgesWritten = 0
        var cancelled = false
        /// Every stage ended well or was already fresh (nothing failed, nothing was refused).
        var complete: Bool { !cancelled && stagesFailed.isEmpty && stagesSkipped.isEmpty }
    }

    typealias Progress = @Sendable (Set<MusicEntityID>, Phase) async -> Void

    static let facetPrefix = "full."
    /// The cache source id under which stage states are kept for stages that span sources.
    static let wikidataBase = URL(string: "https://www.wikidata.org/w/api.php")!
    static let wikidataEntity = URL(string: "https://www.wikidata.org/wiki/Special:EntityData/")!
    static let wikidataSPARQL = URL(string: "https://query.wikidata.org/sparql")!
    static let mbBase = URL(string: "https://musicbrainz.org/ws/2/")!
    static let imdbSuggest = URL(string: "https://v2.sg.media-imdb.com/suggestion/")!
    static let imdbName = URL(string: "https://www.imdb.com/name/")!

    let resolver: MusicEntityResolver
    let transport: any MusicMetadataTransport
    let gate: any MusicEnrichmentGating
    let catalogue: (any MusicPersonCatalogueFetching)?
    let limits: Limits
    let now: @Sendable () -> Date
    let imdbLatch = MusicBlockLatch()
    let writer: MusicPersonWorkWriter
    var store: any MusicGraphStoring { resolver.store }

    init(resolver: MusicEntityResolver, transport: any MusicMetadataTransport, gate: any MusicEnrichmentGating = MusicEnrichmentPolicy.open,
         catalogue: (any MusicPersonCatalogueFetching)? = nil, limits: Limits = Limits(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.resolver = resolver; self.transport = transport; self.gate = gate; self.catalogue = catalogue; self.limits = limits; self.now = now
        self.writer = MusicPersonWorkWriter(resolver: resolver, now: now)
    }

    // MARK: plumbing

    enum Stop: Error { case skipped(MusicEnrichmentSkip), failed }

    func allow(_ s: MusicSourceID) throws {
        if case .skipped(let why) = gate.decision(for: s) { throw Stop.skipped(why) }
        if s == .imdb, imdbLatch.isBlocked(now: now()) { throw Stop.skipped(.unconfigured) }
        try Task.checkCancellation()
    }

    func get(_ s: MusicSourceID, _ url: URL, _ query: [String: String] = [:], headers: [String: String] = MusicSourceKit.headers) async throws -> Data {
        try allow(s)
        do { return try await transport.get(url, query: query, headers: headers) }
        catch is CancellationError { throw CancellationError() }
        catch let e as MusicError {
            if case .cancelled = e { throw CancellationError() }
            if s == .imdb, case .refused = e { imdbLatch.trip(now: now()); throw Stop.skipped(.unconfigured) }
            throw Stop.failed
        } catch { throw Stop.failed }
    }

    func mb(_ path: String, _ q: [String: String]) async throws -> Data {
        var q = q; q["fmt"] = "json"
        return try await get(.musicbrainz, Self.mbBase.appendingPathComponent(path), q)
    }

    /// Runs one stage under its cache state. `body` returns how many works it wrote (0 is remembered as "nothing found" for a short time).
    func stage(_ name: String, source: MusicSourceID, ttl: TimeInterval, person: MusicEntityID, out: inout Outcome, progress: Progress,
                       _ body: () async throws -> Int) async {
        let facet = Self.facetPrefix + name
        let t = now()
        if let st = try? await store.cacheState(entity: person, facet: facet, source: source) {
            if st.isFresh(at: t) { out.stagesCached.append(name); return }
            if !st.needsFetch(at: t) { out.stagesFailed.append(name); return }   // backing off after an error
        }
        await progress([], .stage(name))
        do {
            let n = try await body()
            try? await store.setCacheState(entity: person, facet: facet, source: source, outcome: n == 0 ? .empty : .ok, ttl: n == 0 ? limits.emptyTTL : ttl, etag: nil,
                                           matcherVersion: MusicResolutionScoring.matcherVersion)
            out.stagesRun.append(name)
        } catch is CancellationError {
            out.cancelled = true
        } catch Stop.skipped(let why) {
            out.stagesSkipped[name] = why
        } catch {
            try? await store.setCacheState(entity: person, facet: facet, source: source, outcome: .error, ttl: 0, etag: nil, matcherVersion: nil)
            out.stagesFailed.append(name)
        }
    }

    // MARK: run

    private struct Run {
        var person: MusicEntityID
        var name: String
        var year: Int?
        var ids: [ExternalID]
        var ledger = MusicPersonWorkLedger()
        var written: [(work: MusicPersonWork, id: MusicEntityID)] = []
        var composerCount = 0
        var personIsComposer: Bool { composerCount >= 2 }
        func id(_ s: ExternalID.Scheme) -> String? { ids.first { $0.scheme == s }?.value }
    }

    /// The whole pass for a person or group. Safe to call from a task that is cancelled at any point.
    func run(_ requested: MusicEntityID, progress: @escaping Progress = { _, _ in }) async -> Outcome {
        var out = Outcome(person: requested)
        guard requested.kind.isAgent, let live = try? await store.resolve(requested), let snap = try? await store.entity(live) else { return out }
        var r = Run(person: live, name: snap.name, year: snap.year, ids: (try? await store.externalIDs(of: live)) ?? [])
        await progress([], .started)
        // Sources only ever see the person's name and public ids, never anything about the listener.
        await stage("identity", source: .wikidata, ttl: limits.identityTTL, person: live, out: &out, progress: progress) { try await identity(&r) }
        if out.cancelled { await progress([], .finished(complete: false)); return out }
        r.person = (try? await store.resolve(r.person)) ?? r.person
        r.ids = (try? await store.externalIDs(of: r.person)) ?? r.ids

        if let q = r.id(.wikidata) {
            await stage("wikidata", source: .wikidata, ttl: limits.okTTL, person: r.person, out: &out, progress: progress) { try await wikidataWorks(q, &r, progress) }
        }
        if out.cancelled { await progress([], .finished(complete: false)); return out }
        if let m = r.id(.mbid) {
            await stage("mb.releaseGroups", source: .musicbrainz, ttl: limits.okTTL, person: r.person, out: &out, progress: progress) { try await mbPaged(m, &r, progress, kind: .releaseGroups) }
            if out.cancelled { await progress([], .finished(complete: false)); return out }
            await stage("mb.works", source: .musicbrainz, ttl: limits.okTTL, person: r.person, out: &out, progress: progress) { try await mbPaged(m, &r, progress, kind: .works) }
            if out.cancelled { await progress([], .finished(complete: false)); return out }
            await stage("mb.recordings", source: .musicbrainz, ttl: limits.okTTL, person: r.person, out: &out, progress: progress) { try await mbPaged(m, &r, progress, kind: .recordings) }
            if out.cancelled { await progress([], .finished(complete: false)); return out }
        }
        await stage("imdb", source: .imdb, ttl: limits.okTTL, person: r.person, out: &out, progress: progress) { try await imdb(&r, progress) }
        if out.cancelled { await progress([], .finished(complete: false)); return out }
        if let catalogue {
            await stage("catalogue", source: .jiosaavn, ttl: limits.catalogueTTL, person: r.person, out: &out, progress: progress) { try await catalogueAlbums(catalogue, &r, progress) }
            if out.cancelled { await progress([], .finished(complete: false)); return out }
        }
        let linked = await linkSoundtracks(r)
        out.edgesWritten += linked.count
        out.filmsFound = r.ledger.count(.film); out.albumsFound = r.ledger.count(.album); out.worksFound = r.ledger.count(.work) + r.ledger.count(.recording)
        await progress(linked.changed, .finished(complete: out.complete))
        return out
    }

    // MARK: stages

    private func personFacts(_ qid: String) async throws -> MusicPersonWikidataParser.Facts? {
        let d = try await get(.wikidata, Self.wikidataEntity.appendingPathComponent(qid + ".json"))
        return MusicPersonWikidataParser.facts(d, qid: qid)
    }

    /// Records ids on the person through the resolver (it unifies with an entity that already carries one of them, under the merge rule's blockers).
    private func attach(_ ids: [ExternalID], to r: inout Run) async {
        let kind = r.person.kind
        var batch = MusicClaimBatch(source: .wikidata, license: .cc0, retrievedAt: now())
        let ref = MusicDraftRef.known(r.person)
        let own = ((try? await store.externalIDs(of: r.person)) ?? []).first(where: \.isStrong)
        batch.drafts.append(MusicSourceDraft(ref, MusicEntityDraft(kind: kind, name: r.name, year: r.year, externalIDs: (own.map { [$0] } ?? []) + ids)))
        if let rep = try? await resolver.ingest(batch, bind: [ref: r.person]), let id = rep.ids[ref] { r.person = id }
        r.ids = (try? await store.externalIDs(of: r.person)) ?? r.ids
    }

    /// Who the person is in Wikidata, MusicBrainz and IMDb. An id is only attached when it is stated by a source that already holds one of the person's
    /// ids, or the name matches nearly exactly and the description says music or film work and nobody else fits.
    private func identity(_ r: inout Run) async throws -> Int {
        var qid = r.id(.wikidata)
        if qid == nil, let m = r.id(.mbid) {
            let d = try await mb("artist/" + m, ["inc": "url-rels"])
            qid = MusicPersonMusicBrainzParser.artistLinks(d).first { $0.scheme == .wikidata }?.value
            var extra = MusicPersonMusicBrainzParser.artistLinks(d).filter { [.wikidata, .imdbName, .tmdbPerson].contains($0.scheme) }
            if qid != nil { await attach(extra, to: &r); extra = [] }
        }
        if qid == nil, let nm = r.id(.imdbName), nm.dropFirst(2).allSatisfy(\.isNumber) {
            let q = "SELECT ?f WHERE { ?f wdt:P345 \"\(nm)\" } LIMIT 2"
            let d = try await get(.wikidata, Self.wikidataSPARQL, ["query": q, "format": "json"], headers: MusicSourceKit.headers.merging(["Accept": "application/sparql-results+json"]) { $1 })
            let found = MusicWikidataParser.sparqlItems(d)
            if found.count == 1 { qid = found[0] }
        }
        if qid == nil {
            let d = try await get(.wikidata, Self.wikidataBase, ["action": "wbsearchentities", "search": r.name, "language": "en", "type": "item", "limit": "8", "format": "json"])
            if let c = MusicPersonWikidataParser.pick(MusicPersonWikidataParser.searchCandidates(d), name: r.name), let f = try await personFacts(c.qid), f.isHuman {
                let birthOK = MusicPersonWorkKey.yearsCompatible(f.birthYear, r.year, tolerance: 2)
                let mineMB = r.id(.mbid), mineIM = r.id(.imdbName)
                let clash = (mineMB != nil && f.ids.contains { $0.scheme == .mbid } && !f.ids.contains(ExternalID(.mbid, mineMB!)))
                    || (mineIM != nil && f.ids.contains { $0.scheme == .imdbName } && !f.ids.contains(ExternalID(.imdbName, mineIM!)))
                if birthOK && !clash { qid = c.qid }
            }
        }
        guard let q = qid, MusicPersonWikidataParser.isQID(q), let facts = try await personFacts(q) else { return 0 }
        await attach(facts.ids, to: &r)
        if r.id(.mbid) == nil {
            // No MusicBrainz id on Wikidata: a name search is accepted only when the artist's own links point back at this person.
            let d = try await mb("artist", ["query": "artist:\"" + r.name.replacingOccurrences(of: "\"", with: " ") + "\"", "limit": "5"])
            for hit in MusicPersonMusicBrainzParser.artistSearch(d).filter({ $0.score >= 90 && MusicTransliterationKey.similarity($0.name, r.name) >= 0.9 }).prefix(3) {
                let l = try await mb("artist/" + hit.mbid, ["inc": "url-rels"])
                if MusicPersonMusicBrainzParser.linked(MusicPersonMusicBrainzParser.artistLinks(l), to: r.ids) { await attach([ExternalID(.mbid, hit.mbid)], to: &r); break }
            }
        }
        return 1
    }

    private func wikidataWorks(_ qid: String, _ r: inout Run, _ progress: Progress) async throws -> Int {
        var works: [MusicPersonWork] = []
        do {
            guard let q = MusicPersonWikidataParser.worksQuery(qid: qid) else { return 0 }
            let d = try await get(.wikidata, Self.wikidataSPARQL, ["query": q, "format": "json"], headers: MusicSourceKit.headers.merging(["Accept": "application/sparql-results+json"]) { $1 })
            works = MusicPersonWikidataParser.works(sparql: d, retrievedAt: now())
        } catch Stop.failed {
            works = try await wikidataWorksBySearch(qid)   // the Query Service refused or timed out: the search API does the same work in pages
        }
        return try await write(works, &r, progress)
    }

    /// `list=search&srsearch=haswbstatement:P86=Q...` (paged) and `wbgetentities` in groups of 50.
    private func wikidataWorksBySearch(_ qid: String) async throws -> [MusicPersonWork] {
        var out: [MusicPersonWork] = []
        for (prop, rel) in MusicPersonWikidataParser.relationProperty {
            var offset = 0, qids: [String] = []
            for _ in 0..<limits.searchFallbackPages {
                let d = try await get(.wikidata, Self.wikidataBase, ["action": "query", "list": "search", "srsearch": "haswbstatement:\(prop)=\(qid)", "srlimit": "50", "sroffset": String(offset), "format": "json"])
                let (ids, next) = MusicPersonWikidataParser.searchHits(d)
                qids += ids
                guard let n = next, !ids.isEmpty else { break }
                offset = n
            }
            for chunk in stride(from: 0, to: qids.count, by: 50).map({ Array(qids[$0..<min($0 + 50, qids.count)]) }) {
                let d = try await get(.wikidata, Self.wikidataBase, ["action": "wbgetentities", "ids": chunk.joined(separator: "|"), "props": "labels|claims", "languages": "en", "format": "json"])
                out += MusicPersonWikidataParser.works(entities: d, relation: rel, retrievedAt: now())
            }
        }
        return out
    }

    private enum MBList { case releaseGroups, works, recordings }

    private func mbPaged(_ mbid: String, _ r: inout Run, _ progress: Progress, kind: MBList) async throws -> Int {
        var total = 0, offset = 0
        let pages: Int
        switch kind { case .releaseGroups: pages = limits.releaseGroupPages; case .works: pages = limits.workPages; case .recordings: pages = limits.recordingPages }
        for _ in 0..<pages {
            let page: MusicPersonMusicBrainzParser.Page<MusicPersonWork>
            switch kind {
            case .releaseGroups:
                page = MusicPersonMusicBrainzParser.releaseGroups(try await mb("release-group", ["artist": mbid, "type": "album|ep|single", "limit": "100", "offset": String(offset)]))
            case .works:
                page = MusicPersonMusicBrainzParser.works(try await mb("work", ["artist": mbid, "inc": "artist-rels", "limit": "100", "offset": String(offset)]), artist: mbid)
            case .recordings:
                page = MusicPersonMusicBrainzParser.recordings(try await mb("recording", ["artist": mbid, "inc": "artist-credits+isrcs", "limit": "100", "offset": String(offset)]))
            }
            total += try await write(page.items, &r, progress)
            guard let n = page.next(offset: offset) else { break }
            offset = n
        }
        return total
    }

    private func imdb(_ r: inout Run, _ progress: Progress) async throws -> Int {
        var nm = r.id(.imdbName)
        var corroborate = false
        if nm == nil {
            guard let first = r.name.lowercased().unicodeScalars.first(where: { CharacterSet.alphanumerics.contains($0) && $0.isASCII }) else { return 0 }
            let slug = String(String.UnicodeScalarView(r.name.lowercased().unicodeScalars.map { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) ? $0 : "_" })).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            let d = try await get(.imdb, URL(string: Self.imdbSuggest.absoluteString + String(Character(first)) + "/" + String(slug.prefix(40)) + ".json")!)
            let hits = MusicPersonIMDbParser.nameHits(d).filter { MusicTransliterationKey.similarity($0.name, r.name) >= 0.92 }
            guard hits.count == 1 else { return 0 }   // none, or two people with this name: never guess
            nm = hits[0].id; corroborate = true
        }
        guard let id = nm, id.hasPrefix("nm"), id.dropFirst(2).allSatisfy(\.isNumber) else { return 0 }
        var h = MusicSourceKit.headers; h["Accept"] = "text/html"; h["Accept-Language"] = "en"
        let d = try await get(.imdb, Self.imdbName.appendingPathComponent(id + "/"), headers: h)
        let html = String(decoding: d.prefix(MusicPersonIMDbParser.maxPage), as: UTF8.self)
        let works = MusicPersonIMDbParser.credits(html: html, retrievedAt: now())
        if works.isEmpty, MusicIMDbParser.looksBlocked(html) { imdbLatch.trip(now: now()); throw Stop.skipped(.unconfigured) }
        if corroborate {
            // A name found only by search is the person when at least two of its films are ones the pass already found (or the graph already knows).
            let known = Set(r.ledger.films.map(\.key))
            let shared = works.filter { known.contains(MusicPersonWorkKey.filmKey($0.title)) }.count
            guard shared >= 2 else { return 0 }
            await attach([ExternalID(.imdbName, id)], to: &r)
        }
        return try await write(works, &r, progress)
    }

    private func catalogueAlbums(_ c: any MusicPersonCatalogueFetching, _ r: inout Run, _ progress: Progress) async throws -> Int {
        try Task.checkCancellation()
        var provider: [String: String] = [:]
        for x in r.ids where x.scheme == .provider { if let i = x.value.firstIndex(of: ":") { provider[String(x.value[..<i])] = String(x.value[x.value.index(after: i)...]) } }
        let works = await c.albums(forArtist: r.name, providerIDs: provider, maxPages: limits.catalogueAlbumPages)
        try Task.checkCancellation()
        return try await write(works, &r, progress)
    }

    // MARK: writing

    private func write(_ works: [MusicPersonWork], _ r: inout Run, _ progress: Progress) async throws -> Int {
        guard !works.isEmpty else { return 0 }
        // A source's own duplicates collapse here too: the ledger groups them, the writer's canonical id makes them one entity.
        for w in works { r.ledger.add(w) }
        r.composerCount += works.filter { $0.relations.contains(.composer) && $0.kind != .work }.count
        let res = try await writer.write(works, person: r.person, personIsComposer: r.personIsComposer)
        for (i, id) in res.ids { r.written.append((works[i], id)) }
        await progress(res.changed, .stage("write"))
        return works.count
    }

    /// Soundtrack albums to their films, over everything this run wrote.
    private func linkSoundtracks(_ r: Run) async -> (count: Int, changed: Set<MusicEntityID>) {
        let albums = r.written.filter { $0.work.kind == .album }, films = r.written.filter { $0.work.kind == .film }
        guard !albums.isEmpty, !films.isEmpty else { return (0, []) }
        let pairs = MusicPersonWorkWriter.soundtrackPairs(albums: albums.map(\.work), films: films.map(\.work))
        guard let n = try? await writer.link(pairs, albumIDs: albums.map(\.id), filmIDs: films.map(\.id), albums: albums.map(\.work)), n > 0 else { return (0, []) }
        return (n, Set(pairs.compactMap { albums.indices.contains($0.album) ? albums[$0.album].id : nil } + pairs.compactMap { films.indices.contains($0.film) ? films[$0.film].id : nil }))
    }
}
