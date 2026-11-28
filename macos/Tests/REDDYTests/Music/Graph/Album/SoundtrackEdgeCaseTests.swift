import Foundation
import Testing
@testable import REDDY

private func english(_ r: MusicSoundtrackReason) -> String { r.text(MusicSoundtrackText.english) }

/// A graph that can be switched off (every call throws) and that counts calls, for the outage and request-count tests.
final class SoundtrackFlakyGraph: MusicGraphStoring, @unchecked Sendable {
    let inner: any MusicGraphStoring
    private let lock = NSLock()
    private var _down = false
    private var _calls = 0
    init(_ inner: any MusicGraphStoring) { self.inner = inner }
    var down: Bool { get { lock.withLock { _down } } set { lock.withLock { _down = newValue } } }
    var calls: Int { lock.withLock { _calls } }
    private func gate() throws { try lock.withLock { _calls += 1; if _down { throw MusicGraphError.readOnly } } }

    func upsert(_ d: MusicEntityDraft) async throws -> MusicUpsertResult { try gate(); return try await inner.upsert(d) }
    func upsert(_ d: [MusicEntityDraft]) async throws -> [MusicUpsertResult] { try gate(); return try await inner.upsert(d) }
    func resolveAlias(for x: ExternalID, kind: MusicEntityKind?) async throws -> MusicEntityID? { try gate(); return try await inner.resolveAlias(for: x, kind: kind) }
    func candidates(for x: ExternalID) async throws -> [MusicEntityID] { try gate(); return try await inner.candidates(for: x) }
    func resolve(_ id: MusicEntityID) async throws -> MusicEntityID? { try gate(); return try await inner.resolve(id) }
    func entity(_ id: MusicEntityID) async throws -> MusicEntitySnapshot? { try gate(); return try await inner.entity(id) }
    func externalIDs(of id: MusicEntityID) async throws -> [ExternalID] { try gate(); return try await inner.externalIDs(of: id) }
    func aliases(of id: MusicEntityID) async throws -> [NameAlias] { try gate(); return try await inner.aliases(of: id) }
    func setPinned(_ id: MusicEntityID, _ pinned: Bool) async throws { try gate(); try await inner.setPinned(id, pinned) }
    func mergeEntities(winner: MusicEntityID, loser: MusicEntityID, byUser: Bool) async throws -> MusicEntityID { try gate(); return try await inner.mergeEntities(winner: winner, loser: loser, byUser: byUser) }
    func addEdge(_ e: MusicEdge, provenance: MusicProvenance) async throws -> MusicEdge { try gate(); return try await inner.addEdge(e, provenance: provenance) }
    func addEdges(_ c: [MusicEdgeClaim]) async throws -> [MusicEdge] { try gate(); return try await inner.addEdges(c) }
    func edges(of id: MusicEntityID, predicate: MusicPredicate?, direction: MusicEdgeDirection, limit: Int) async throws -> [MusicEdge] {
        try gate(); return try await inner.edges(of: id, predicate: predicate, direction: direction, limit: limit)
    }
    func edge(_ k: MusicEdgeKey) async throws -> MusicEdge? { try gate(); return try await inner.edge(k) }
    func retractEdge(_ k: MusicEdgeKey) async throws { try gate(); try await inner.retractEdge(k) }
    func setFact(_ f: MusicProvenance, for k: MusicEdgeKey) async throws { try gate(); try await inner.setFact(f, for: k) }
    func facts(for k: MusicEdgeKey) async throws -> [MusicProvenance] { try gate(); return try await inner.facts(for: k) }
    func cacheState(entity: MusicEntityID, facet: String, source: MusicSourceID) async throws -> MusicCacheState? { try gate(); return try await inner.cacheState(entity: entity, facet: facet, source: source) }
    func setCacheState(entity: MusicEntityID, facet: String, source: MusicSourceID, outcome: MusicCacheState.Outcome, ttl: TimeInterval, etag: String?, matcherVersion: Int?) async throws {
        try gate(); try await inner.setCacheState(entity: entity, facet: facet, source: source, outcome: outcome, ttl: ttl, etag: etag, matcherVersion: matcherVersion)
    }
    func search(_ q: String, kinds: Set<MusicEntityKind>, limit: Int) async throws -> [MusicSearchHit] { try gate(); return try await inner.search(q, kinds: kinds, limit: limit) }
    func neighbours(of id: MusicEntityID, depth: Int, fanOut: Int) async throws -> MusicNeighbourhood { try gate(); return try await inner.neighbours(of: id, depth: depth, fanOut: fanOut) }
    func counts() async throws -> MusicGraphCounts { try gate(); return try await inner.counts() }
    func wipe() async throws { try gate(); try await inner.wipe() }
}

@Suite struct SoundtrackEdgeCaseTests {
    // MARK: non-film album, independent artist

    @Test func nonFilmAlbumDegradesToANormalAlbumPage() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let r = MusicSoundtrackReader(g.graph)
        let id = g.albums["Quiet Hours"]!
        let h = try #require(await MusicSoundtrackBuild.header(r, id: id))
        #expect(h.film == nil && h.filmHint == nil && !h.isFilm)
        let c = await MusicSoundtrackBuild.credits(r, id: id)
        #expect(c.groups.map(\.kind) == [.artist])                    // singers from the provider only; no composers, lyricists or film credit
        #expect(c.people(.artist).map(\.person.name) == ["Mira Sol"])
        let cast = await MusicSoundtrackBuild.cast(r, id: id)
        #expect(cast.film == nil && cast.cast.isEmpty)
        let films = await MusicSoundtrackBuild.moreFilms(r, id: id)
        #expect(films.film == nil && films.items.isEmpty)
        #expect((await MusicSoundtrackBuild.soundtracksOfCast(r, films: [])).isEmpty)
        #expect((await MusicSoundtrackBuild.classic(r, id: id)).isEmpty)
        #expect((await MusicSoundtrackBuild.moreByComposers(r, id: id)).isEmpty)
        #expect((await MusicSoundtrackBuild.moreBySingers(r, id: id)).isEmpty)
        let links = MusicSoundtrackBuild.explore(header: h, credits: c, cast: nil)
        #expect(links.map(\.target).contains(.person(g.people["Mira Sol"]!, .performer)) && links.map(\.target).contains(.radio))
        #expect(!links.contains { if case .film = $0.target { true } else { false } })
    }

    @Test func independentArtistWithNoExternalIdsIsAProvisionalPersonWithoutRoleChips() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let r = MusicSoundtrackReader(g.graph)
        let person = try #require(await r.person(g.people["Mira Sol"]!))
        #expect(person.detail == nil && person.name == "Mira Sol")
        let c = await MusicSoundtrackBuild.credits(r, id: g.albums["Quiet Hours"]!)
        #expect(c.groups.flatMap(\.credits).allSatisfy { $0.role == .performer && !$0.isFilmCredit })
        let hits = try await g.graph.search("Mira")
        #expect(hits.contains { $0.id == g.people["Mira Sol"] })
    }

    // MARK: international

    @Test func englishFilmSoundtrackAndAKDramaOstGroupedUnderASeries() async throws {
        let graph = MusicInMemoryGraph()
        let prov = SoundtrackFixtureGraph.musicbrainz
        let film = try await graph.upsert(MusicEntityDraft(kind: .film, name: "Interstellar", lang: "en", year: 2014, externalIDs: [ExternalID(.wikidata, "Q13417189")])).id
        let ost = try await graph.upsert(MusicEntityDraft(kind: .album, name: "Interstellar (Original Motion Picture Soundtrack)", subkind: "soundtrack", lang: "en", year: 2014,
                                                          externalIDs: [ExternalID(.mbReleaseGroup, "rg-interstellar")])).id
        let zimmer = try await graph.upsert(MusicEntityDraft(kind: .person, name: "Hans Zimmer", externalIDs: [ExternalID(.mbid, "mb-zimmer")])).id
        _ = try await graph.addEdge(MusicEdge(subject: ost, predicate: .soundtrackOf, object: film), provenance: prov)
        _ = try await graph.addEdge(MusicEdge(subject: ost, predicate: .composedBy, object: zimmer, role: .composer, creditLevel: .album), provenance: prov)
        let h = try #require(await MusicSoundtrackBuild.header(MusicSoundtrackReader(graph), id: ost))
        #expect(h.film?.title == "Interstellar" && h.languageName == "English" && h.makers.first?.person.name == "Hans Zimmer" && h.makers.first?.role == .composer)

        let series = try await graph.upsert(MusicEntityDraft(kind: .series, name: "Reply 1988", lang: "ko", year: 2015, externalIDs: [ExternalID(.tmdbTV, "61714")])).id
        let kost = try await graph.upsert(MusicEntityDraft(kind: .album, name: "Reply 1988 OST Part.1", subkind: "soundtrack", lang: "ko", year: 2015, externalIDs: [ExternalID(.mbReleaseGroup, "rg-reply1988-1")])).id
        let singer = try await graph.upsert(MusicEntityDraft(kind: .person, name: "박효신", externalIDs: [ExternalID(.mbid, "mb-parkhyoshin")],
                                                             aliases: [NameAlias("Park Hyo-shin", lang: "en", script: "Latn")])).id
        _ = try await graph.addEdge(MusicEdge(subject: kost, predicate: .soundtrackOf, object: series), provenance: prov)
        _ = try await graph.addEdge(MusicEdge(subject: kost, predicate: .performedBy, object: singer, role: .singer, creditLevel: .album), provenance: prov)
        let kh = try #require(await MusicSoundtrackBuild.header(MusicSoundtrackReader(graph), id: kost))
        #expect(kh.film?.isSeries == true && kh.film?.title == "Reply 1988")
        #expect((try await graph.search("박효신")).contains { $0.id == singer })           // Hangul
        #expect((try await graph.search("Park Hyo")).contains { $0.id == singer })        // romanised
    }

    // MARK: incomplete metadata

    @Test func incompleteMetadataStaysPlainAndInventsNoCast() async throws {
        let graph = MusicInMemoryGraph()
        let hinted = try await graph.upsert(MusicEntityDraft(kind: .release, name: "Kaavaalaa (From \"Jailer\")", year: 2023, attrs: ["filmHint": "Jailer"],
                                                             externalIDs: [ExternalID(.provider, "ytmusic:kaavaalaa")], provisional: true)).id
        let jailer = try await graph.upsert(MusicEntityDraft(kind: .film, name: "Jailer", year: 2023, externalIDs: [ExternalID(.wikidata, "Q-JAILER")])).id
        // a matcher guess below the minimum confidence: not a link the page may show
        _ = try await graph.addEdge(MusicEdge(subject: hinted, predicate: .soundtrackOf, object: jailer, confidence: 0.4), provenance: MusicProvenance(source: .matcher, score: 0.4))
        let r = MusicSoundtrackReader(graph)
        let h = try #require(await MusicSoundtrackBuild.header(r, id: hinted))
        #expect(h.film == nil)                                       // never linked
        #expect(h.filmHint == "Jailer")                              // shown as plain text only
        #expect((await MusicSoundtrackBuild.cast(r, id: hinted)).cast.isEmpty)
        #expect((await MusicSoundtrackBuild.credits(r, id: hinted)).isEmpty)
        // a title-only album that does not exist in the graph at all
        let ghost = MusicEntityID.provisional(kind: .release, providerUID: "jiosaavn:none")
        #expect(await MusicSoundtrackBuild.header(r, id: ghost) == nil)
    }

    @Test func anInferredLinkAboveTheMinimumShowsWithItsTagAndPossiblyWording() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let r = MusicSoundtrackReader(g.graph)
        let provider = try await g.graph.upsert(MusicEntityDraft(kind: .release, name: "Barsaat (Provider)", year: 1949, externalIDs: [ExternalID(.provider, "jiosaavn:barsaat-x")], provisional: true)).id
        _ = try await g.graph.addEdge(MusicEdge(subject: provider, predicate: .soundtrackOf, object: g.films["Barsaat"]!), provenance: SoundtrackFixtureGraph.matcher)
        let h = try #require(await MusicSoundtrackBuild.header(r, id: provider))
        #expect(h.film?.title == "Barsaat" && h.film?.isInferredLink == true && h.film?.linkStatus == .inferred)
        let q = MusicSoundtrackReason.qualified(.sameComposer("X"), status: .inferred, confidence: 0.6)
        #expect(english(q) == "Same composer: X")
        #expect(english(.qualified(.sameComposer("X"), status: .verified, confidence: 0.6)) == "Same composer: X")
    }

    // MARK: identical names

    @Test func identicalFilmNamesNeverLinkEachOthersAlbums() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let r = MusicSoundtrackReader(g.graph)
        let a2010 = g.albums["Awaara (2010)"]!
        let h = try #require(await MusicSoundtrackBuild.header(r, id: a2010))
        #expect(h.film?.id == g.films["Awaara (2010)"] && h.film?.id != g.film && h.year == 2010)
        #expect((await MusicSoundtrackBuild.cast(r, id: a2010)).cast.isEmpty)                    // no cast invented from the 1951 film
        let related = await MusicSoundtrackBuild.related(r, id: a2010)
        #expect(!related.contains { $0.id == g.album || $0.id == g.release })
        let back = await MusicSoundtrackBuild.related(r, id: g.album)
        #expect(!back.contains { $0.id == a2010 })
        // the two soundtrack albums cluster apart (different films)
        #expect(MusicSoundtrackCluster.key(id: a2010, title: "Awaara", year: 2010, film: g.films["Awaara (2010)"]) != MusicSoundtrackCluster.key(id: g.album, title: "Awaara", year: 1951, film: g.film))
    }

    @Test func disambiguatorNeverMergesAndKeepsEqualDetailsApart() {
        let a = MusicEntityID.derive(kind: .person, aliasKey: "a"), b = MusicEntityID.derive(kind: .person, aliasKey: "b"), c = MusicEntityID.derive(kind: .person, aliasKey: "c")
        let people = [MusicSoundtrackPerson(id: a, name: "Anand Bakshi", detail: "1930–2002"), MusicSoundtrackPerson(id: b, name: "Anand  Bakshi", detail: "1930–2002"),
                      MusicSoundtrackPerson(id: c, name: "Gulzar", detail: "1934")]
        let d = MusicSoundtrackDisambiguator.details(for: people)
        #expect(d[c] == nil)
        #expect(d[a] != nil && d[b] != nil && d[a] != d[b])
        #expect(d[a]!.hasPrefix("1930–2002") && d[a]!.contains("#"))
        let lone = MusicSoundtrackDisambiguator.details(for: [people[2]])
        #expect(lone.isEmpty)
    }

    // MARK: movies without soundtracks

    @Test func aFilmWithoutAReleaseIsNeverAnAlbumCard() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let r = MusicSoundtrackReader(g.graph)
        let jagte = MusicSoundtrackFilmItem(film: MusicSoundtrackFilm(id: g.films["Jagte Raho"]!, title: "Jagte Raho", year: 1956), actors: [], reason: .withActors(["Raj Kapoor"]), score: 1)
        #expect((await MusicSoundtrackBuild.soundtracksOfCast(r, films: [jagte])).isEmpty)
    }

    // MARK: provider matching rules

    @Test func providerMatchingIsStrict() {
        let film = MusicSoundtrackFilm(id: MusicEntityID.derive(kind: .film, aliasKey: "f"), title: "Awaara", year: 1951)
        func album(_ t: String, _ y: Int?) -> MusicSoundtrackProviderAlbum { MusicSoundtrackProviderAlbum(id: MusicEntityID.derive(kind: .release, aliasKey: t), title: t, year: y, imageRef: nil, artistLine: "") }
        #expect(MusicSoundtrackMatch.accepts(film: film, album: album("Awaara", 1951)))
        #expect(MusicSoundtrackMatch.accepts(film: film, album: album("Awaara (Original Motion Picture Soundtrack)", 1951)))
        #expect(MusicSoundtrackMatch.accepts(film: film, album: album("Awaara (Original Motion Picture Soundtrack)", nil)))
        #expect(!MusicSoundtrackMatch.accepts(film: film, album: album("Awaara (2010)", 2010)))
        #expect(!MusicSoundtrackMatch.accepts(film: film, album: album("Awaara (Original Motion Picture Soundtrack)", 2010)))
        #expect(!MusicSoundtrackMatch.accepts(film: film, album: album("Awaara Hoon", 1951)))              // a song title, not the film's record
        #expect(!MusicSoundtrackMatch.accepts(film: film, album: album("Best of Raj Kapoor", 1951)))
        #expect(!MusicSoundtrackMatch.accepts(film: film, album: album("Shree 420", 1955)))
    }

    // MARK: ranking rules and reasons

    @Test func relatedBandsOutrankByLadderAndReasonsAreWorded() {
        let seed = { () -> MusicSoundtrackAlbumFacts in
            var f = MusicSoundtrackAlbumFacts(id: MusicEntityID.derive(kind: .album, aliasKey: "seed"), title: "Seed", year: 1951)
            let sj = MusicEntityID.derive(kind: .group, aliasKey: "sj"), mukesh = MusicEntityID.derive(kind: .person, aliasKey: "mukesh"), nargis = MusicEntityID.derive(kind: .person, aliasKey: "nargis")
            f.musicDirectors[sj] = "Shankar-Jaikishan"; f.singers[mukesh] = "Mukesh"; f.cast[nargis] = "Nargis"; f.languageName = "Hindi"; f.genres = ["filmi"]
            return f
        }()
        let sj = seed.musicDirectors.keys.first!, mukesh = seed.singers.keys.first!, nargis = seed.cast.keys.first!
        func cand(_ name: String, year: Int, _ edit: (inout MusicSoundtrackAlbumFacts) -> Void) -> MusicSoundtrackAlbumFacts {
            var f = MusicSoundtrackAlbumFacts(id: MusicEntityID.derive(kind: .album, aliasKey: name), title: name, year: year)
            edit(&f); return f
        }
        let candidates = [
            cand("CreatorsAndSinger", year: 1955) { $0.musicDirectors[sj] = "Shankar-Jaikishan"; $0.singers[mukesh] = "Mukesh" },
            cand("Cast", year: 1957) { $0.film = MusicSoundtrackFilm(id: MusicEntityID.derive(kind: .film, aliasKey: "fc"), title: "FC", year: 1957); $0.cast[nargis] = "Nargis" },
            cand("Singer", year: 1970) { $0.singers[mukesh] = "Mukesh" },
            cand("Composer", year: 1980) { $0.musicDirectors[sj] = "Shankar-Jaikishan" },
            cand("Era", year: 1948) { $0.languageName = "Hindi" },
            cand("Genre", year: 1999) { $0.genres = ["Filmi"] },
            cand("Nothing", year: 1951) { _ in },
            cand("Telugu 1951", year: 1951) { $0.languageName = "Telugu" },
        ]
        let ranked = MusicSoundtrackRelated.rank(seed: seed, candidates: candidates)
        #expect(ranked.map(\.title) == ["CreatorsAndSinger", "Cast", "Singer", "Composer", "Era", "Genre"])
        #expect(ranked.map(\.band) == [2, 3, 4, 5, 6, 7])
        #expect(ranked.map { english($0.reason) } == ["Same music by Shankar-Jaikishan, sung by Mukesh", "Shares cast: Nargis", "Sung by Mukesh",
                                                      "Same music director: Shankar-Jaikishan", "Same era and language: 1940s Hindi", "Same genre: filmi"])
    }

    @Test func languageEditionsOfOneSoundtrackCollapseAndTheSeedClusterIsNeverShown() {
        let film = MusicSoundtrackFilm(id: MusicEntityID.derive(kind: .film, aliasKey: "film"), title: "Film", year: 2015)
        var seed = MusicSoundtrackAlbumFacts(id: MusicEntityID.derive(kind: .album, aliasKey: "seed"), title: "Film OST", year: 2015, film: film)
        let sj = MusicEntityID.derive(kind: .person, aliasKey: "sj")
        seed.musicDirectors[sj] = "M"
        var tamil = MusicSoundtrackAlbumFacts(id: MusicEntityID.derive(kind: .album, aliasKey: "tamil"), title: "Film OST (Tamil)", year: 2015, film: film)
        tamil.musicDirectors[sj] = "M"
        var other = MusicSoundtrackAlbumFacts(id: MusicEntityID.derive(kind: .album, aliasKey: "other"), title: "Other", year: 2016)
        other.musicDirectors[sj] = "M"
        let ranked = MusicSoundtrackRelated.rank(seed: seed, candidates: [tamil, other])
        #expect(ranked.map(\.title) == ["Other"])               // the Tamil edition is the seed's own cluster: never shown as "related"
        // an explicit related-album claim is band 1 and says so
        var direct = MusicSoundtrackAlbumFacts(id: MusicEntityID.derive(kind: .album, aliasKey: "direct"), title: "Direct", year: 1999)
        direct.directStatus = .verified; direct.directConfidence = 0.9
        let withDirect = MusicSoundtrackRelated.rank(seed: seed, candidates: [other, direct])
        #expect(withDirect.first?.title == "Direct" && withDirect.first?.band == 1)
        #expect(withDirect.first.map { english($0.reason) } == "Related album")
        // conflicted claims are ignored
        direct.directStatus = .conflicted
        #expect(!MusicSoundtrackRelated.rank(seed: seed, candidates: [direct]).contains { $0.title == "Direct" })
    }

    @Test func shelvesHideSilentlyWhenFinishedWithNothing() {
        #expect(MusicSoundtrackShelfRule.presentation(phase: .idle, itemCount: 0) == .skeleton)
        #expect(MusicSoundtrackShelfRule.presentation(phase: .loading, itemCount: 0) == .skeleton)
        #expect(MusicSoundtrackShelfRule.presentation(phase: .partial, itemCount: 0) == .skeleton)
        #expect(MusicSoundtrackShelfRule.presentation(phase: .loading, itemCount: 3) == .cards)      // cached items keep showing while it refreshes
        #expect(MusicSoundtrackShelfRule.presentation(phase: .partial, itemCount: 2) == .cards)
        #expect(MusicSoundtrackShelfRule.presentation(phase: .empty, itemCount: 0) == .hidden)
        #expect(MusicSoundtrackShelfRule.presentation(phase: .failed, itemCount: 0) == .hidden)
        #expect(MusicSoundtrackShelfRule.presentation(phase: .failed, itemCount: 4) == .cards)       // stale items stay
        #expect(MusicSoundtrackShelfRule.presentation(phase: .loaded, itemCount: 0) == .hidden)
    }

    @Test func songRowsGroupIntoDiscsOnlyWhenThereAreSeveral() {
        func row(_ n: Int, disc: Int?) -> MusicSoundtrackSongRow {
            MusicSoundtrackSongRow(id: MusicEntityID.derive(kind: .recording, aliasKey: "\(n)\(disc ?? 0)"), title: "t\(n)", durationMs: 1, number: n, disc: disc, singerLine: "", trackUID: "p:\(n)", explicit: false)
        }
        #expect(MusicSoundtrackSongs.discs([row(1, disc: 1), row(2, disc: 1)]).count == 1)
        let two = MusicSoundtrackSongs.discs([row(1, disc: 1), row(2, disc: 2), row(3, disc: 2)])
        #expect(two.map(\.disc) == [1, 2] && two[1].rows.count == 2)
    }

    // MARK: outage

    @Test func aFailingStoreMakesSectionsFailQuietlyAndKeepsWhatTheyHad() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let flaky = SoundtrackFlakyGraph(g.graph)
        let r = MusicSoundtrackReader(flaky)
        // partial: the first reads work, then the store goes away mid-build: no crash, whatever was read is returned
        flaky.down = true
        let credits = await MusicSoundtrackBuild.credits(r, id: g.album)
        #expect(credits.isEmpty && r.failures.count > 0)
        flaky.down = false

        let loader = MusicSoundtrackCreditsLoader()
        let result = try await loader.load(entity: g.album, store: flaky, report: MusicSectionReporter { _ in })
        #expect(!result.items.isEmpty)
        flaky.down = true
        do { _ = try await loader.load(entity: g.album, store: flaky, report: MusicSectionReporter { _ in }); Issue.record("an empty answer from a failed store must throw") }
        catch { #expect(error as? MusicSoundtrackError == .storeUnavailable) }
    }

    @MainActor @Test func theEntityModelKeepsStaleItemsThroughAnOutageAndRecovers() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let flaky = SoundtrackFlakyGraph(g.graph)
        let store = MusicEntityStore(graph: flaky)
        let model = MusicEntityModel(id: g.album, store: store)
        let loader = MusicSoundtrackCreditsLoader()
        model.load(loader)
        try await settle(model, MusicSoundtrackKey.credits)
        let first = model.section(MusicSoundtrackKey.credits)
        #expect(first.phase == .loaded && !first.items.isEmpty)
        flaky.down = true
        model.load(loader, force: true)
        try await settle(model, MusicSoundtrackKey.credits)
        let during = model.section(MusicSoundtrackKey.credits)
        #expect(during.phase == .failed)
        #expect(during.items == first.items)                                        // stale items stay; the shelf keeps showing them
        #expect(MusicSoundtrackShelfRule.presentation(phase: during.phase, itemCount: during.items.count) == .cards)
        flaky.down = false
        model.load(loader, force: true)
        try await settle(model, MusicSoundtrackKey.credits)
        #expect(model.section(MusicSoundtrackKey.credits).phase == .loaded)
    }

    // MARK: partial results, bounded work, cancellation

    @MainActor @Test func filmsShowFromTheGraphAtOnceThenRefineWhenEnrichmentLands() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let store = MusicEntityStore(graph: g.graph)
        let model = MusicEntityModel(id: g.album, store: store)
        let gate = SoundtrackGate()
        let inFlight = SoundtrackBox<[Int]>([0, 0])      // current, maximum
        let enriched = SoundtrackBox<[MusicEntityID]>([])
        let hooks = MusicSoundtrackHooks(enrich: { id in
            inFlight.mutate { $0[0] += 1; $0[1] = max($0[1], $0[0]) }
            enriched.mutate { $0.append(id) }
            await gate.wait()
            inFlight.mutate { $0[0] -= 1 }
        })
        let loader = MusicSoundtrackMoreFilmsLoader(hooks: hooks)
        model.load(loader)
        // the partial arrives before enrichment finishes
        var sawPartial = false
        for _ in 0..<200 {
            if model.section(loader.key).phase == .partial, !model.section(loader.key).items.isEmpty { sawPartial = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sawPartial)
        await gate.open()
        try await settle(model, loader.key)
        #expect(model.section(loader.key).phase == .loaded)
        #expect(enriched.value.count == MusicSoundtrackLimits.castForFilmography)                  // four actors asked, no more
        #expect(inFlight.value[1] <= MusicSoundtrackLimits.enrichmentInFlight)                      // two at a time
        // two views asking: one run
        model.load(loader); model.load(loader)
        #expect(model.sectionRuns[loader.key] == 1)
    }

    @MainActor @Test func sectionsDoNotLoadUntilAViewAsksAndLeavingCancelsTheLoad() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let store = MusicEntityStore(graph: g.graph)
        let model = MusicEntityModel(id: g.album, store: store)
        #expect(model.sectionRuns.isEmpty)                          // opening the page runs no section by itself
        let gate = SoundtrackGate()
        let hooks = MusicSoundtrackHooks(enrich: { _ in await gate.wait() })
        let loader = MusicSoundtrackMoreFilmsLoader(hooks: hooks)
        model.load(loader)
        try await Task.sleep(for: .milliseconds(50))
        model.cancelAll()
        let atLeave = model.section(loader.key)
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))
        let s = model.section(loader.key)
        #expect(s.phase != .loading && s.phase != .partial)          // not left working
        #expect(s.items == atLeave.items)                            // and nothing lands after the page left
    }

    @Test func requestCountForTheWholePageStaysBounded() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let flaky = SoundtrackFlakyGraph(g.graph)
        let enriched = SoundtrackBox<Int>(0)
        let hooks = MusicSoundtrackHooks(enrich: { _ in enriched.mutate { $0 += 1 } })
        for loader in MusicSoundtrackLoaders.all(hooks: hooks) {
            _ = try await loader.load(entity: g.album, store: flaky, report: MusicSectionReporter { _ in })
        }
        #expect(flaky.calls < 1500)          // local reads for all ten sections of the fixture page
        #expect(enriched.value <= 4 + 4 + 1) // actor filmographies (E and F) and at most one film enrichment, all single-flight on the entity layer
    }

    /// Waits until the section is no longer working (bounded).
    @MainActor private func settle(_ model: MusicEntityModel, _ key: String) async throws {
        for _ in 0..<400 {
            try await Task.sleep(for: .milliseconds(5))
            let p = model.section(key).phase
            if p != .loading && p != .partial && p != .idle { return }
        }
        Issue.record("section \(key) did not settle")
    }
}

/// Holds callers until opened.
actor SoundtrackGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if isOpen { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}

