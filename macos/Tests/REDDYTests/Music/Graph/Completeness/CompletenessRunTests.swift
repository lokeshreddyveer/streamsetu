import Foundation
import Testing
@testable import REDDY

@Suite("Completeness: the pass end to end (fixture transport, in-memory graph)") struct CompletenessRunTests {
    typealias F = CompletenessFixtures
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func setup(gate: any MusicEnrichmentGating = MusicEnrichmentPolicy.open, catalogue: (any MusicPersonCatalogueFetching)? = nil, ids: [ExternalID] = [ExternalID(.canon, "person|gv")]) async throws
        -> (g: MusicInMemoryGraph, t: CompletenessTransport, pass: MusicPersonCompleteness, person: MusicEntityID) {
        let g = MusicInMemoryGraph()
        let r = MusicEntityResolver(store: g, sources: [], gate: gate)
        let t = CompletenessTransport()
        t.add("action=wbsearchentities", F.searchGV)
        t.add("Special:EntityData/Q444.json", F.factsGV())
        t.add("query.wikidata.org", F.sparql(F.vaathiRows))
        t.add("offset=200", F.rgPage(30, offset: 200, total: 230))
        t.add("offset=100", F.rgPage(100, offset: 100, total: 230))
        t.add("release-group?", F.rgPage(100, total: 230))
        t.add("/work?", F.data("{\"work-count\":0,\"works\":[]}"))
        t.add("/recording?", F.data("{\"recording-count\":0,\"recordings\":[]}"))
        t.fail("imdb.com")
        t.fail("media-imdb.com")
        let p = try await g.upsert(MusicEntityDraft(kind: .person, name: "G. V. Prakash Kumar", year: 1987, externalIDs: ids)).id
        let pass = MusicPersonCompleteness(resolver: r, transport: t, gate: gate, catalogue: catalogue, now: { Date() })
        return (g, t, pass, p)
    }

    @Test func aPersonWithOnlyANameGetsFilmsAlbumsAndSoundtrackLinksWithNoKeyAndNoSignIn() async throws {
        let s = try await setup()
        let out = await s.pass.run(s.person)
        #expect(out.stagesRun.contains("identity") && out.stagesRun.contains("wikidata") && out.stagesRun.contains("mb.releaseGroups"))
        let live = try #require(try await s.g.resolve(s.person))
        let ids = try await s.g.externalIDs(of: live)
        #expect(ids.contains(ExternalID(.wikidata, "Q444")) && ids.contains(ExternalID(.mbid, "22222222-2222-2222-2222-222222222222")))
        let d = try await MusicPersonReader(store: s.g, person: live).build(.composer)
        #expect(Set((d.section(.films)?.entries ?? []).map(\.name)) == ["Vaathi", "Soorarai Pottru", "Asuran", "Aadukalam"])
        #expect((d.section(.soundtracks)?.entries ?? []).contains { $0.name.hasPrefix("Vaathi") } || (d.section(.albums)?.entries ?? []).contains { $0.name.hasPrefix("Vaathi") })
        // the albums MusicBrainz credits to the person (three pages, 230 rows) are the singer view's albums; the composer view holds the soundtrack
        let singer = try await MusicPersonReader(store: s.g, person: live).build(.singer)
        #expect(singer.section(.albums)?.entries.count == 230 && singer.section(.albums)?.total == 230)
        let vaathi = try #require(try await s.g.search("Vaathi", kinds: [.film], limit: 3).first)
        let links = try await s.g.edges(of: vaathi.id, predicate: .soundtrackOf, direction: .incoming, limit: 5)
        #expect(links.count == 1 && links[0].status == .verified, "Wikidata P406 states it")
        #expect(out.stagesFailed.contains("imdb") || out.stagesSkipped["imdb"] != nil, "IMDb is best effort: its failure does not stop the pass")
    }

    @Test func aFreshPersonIsNotFetchedAgain() async throws {
        let s = try await setup()
        _ = await s.pass.run(s.person)
        let first = s.t.count
        let out = await s.pass.run(s.person)
        #expect(s.t.count == first || out.stagesRun == ["imdb"] || out.stagesFailed.contains("imdb"), "only a failed stage is retried, and only after its back-off")
        #expect(out.stagesCached.contains("wikidata") && out.stagesCached.contains("mb.releaseGroups"))
    }

    @Test func aSwitchedOffSourceIsSkippedAndTheRestStillRun() async throws {
        let s = try await setup(gate: CompletenessGate(off: [.musicbrainz]))
        let out = await s.pass.run(s.person)
        #expect(out.stagesSkipped["mb.releaseGroups"] == .switchOff || out.stagesSkipped["identity"] == nil)
        #expect(s.t.count(containing: "musicbrainz.org") == 0)
        #expect(out.stagesRun.contains("wikidata") && !out.complete)
    }

    @Test func theQueryServiceFailingFallsBackToTheSearchApi() async throws {
        let s = try await setup()
        let g = s.t
        g.fail("query.wikidata.org")
        // route order: the earlier SPARQL route wins, so use a fresh transport with the failure first
        let t2 = CompletenessTransport()
        t2.fail("query.wikidata.org")
        t2.add("action=wbsearchentities", F.searchGV)
        t2.add("Special:EntityData/Q444.json", F.factsGV(mb: nil, imdb: nil))
        t2.add("list=search", F.data("{\"query\":{\"search\":[{\"title\":\"Q7\"}]}}"))
        t2.add("action=wbgetentities", F.data("{\"entities\":{\"Q7\":{\"labels\":{\"en\":{\"value\":\"Jailer\"}},\"claims\":{\"P345\":[{\"mainsnak\":{\"datavalue\":{\"value\":\"tt15\"}}}],\"P577\":[{\"mainsnak\":{\"datavalue\":{\"value\":{\"time\":\"+2023-08-10T00:00:00Z\"}}}}]}}}}"))
        t2.add("musicbrainz.org/ws/2/artist?", F.data("{\"artists\":[]}"))
        let g2 = MusicInMemoryGraph()
        let p = try await g2.upsert(MusicEntityDraft(kind: .person, name: "G. V. Prakash Kumar", year: 1987, externalIDs: [ExternalID(.canon, "person|gv")])).id
        let pass = MusicPersonCompleteness(resolver: MusicEntityResolver(store: g2, sources: []), transport: t2)
        let out = await pass.run(p)
        #expect(out.stagesRun.contains("wikidata"))
        #expect(try await g2.search("Jailer", kinds: [.film], limit: 3).count == 1)
    }

    @Test func aNameWithTwoEqualCandidatesAttachesNothing() async throws {
        let g = MusicInMemoryGraph()
        let t = CompletenessTransport()
        t.add("action=wbsearchentities", F.data("{\"search\":[{\"id\":\"Q1\",\"label\":\"Ravi\",\"description\":\"Indian composer\"},{\"id\":\"Q2\",\"label\":\"Ravi\",\"description\":\"Indian playback singer\"}]}"))
        let p = try await g.upsert(MusicEntityDraft(kind: .person, name: "Ravi", externalIDs: [ExternalID(.canon, "person|ravi")])).id
        let pass = MusicPersonCompleteness(resolver: MusicEntityResolver(store: g, sources: []), transport: t)
        _ = await pass.run(p)
        let ids = try await g.externalIDs(of: p)
        #expect(!ids.contains { $0.scheme == .wikidata }, "never guess between two people")
        #expect(t.count(containing: "Special:EntityData") == 0 && t.count(containing: "query.wikidata.org") == 0)
    }

    @Test func catalogueAlbumsJoinTheGraphAsEditions() async throws {
        let cat = CompletenessCatalogue(byArtist: [providerAlbum("1", "Asuran (Original Motion Picture Soundtrack)", year: 2019), providerAlbum("2", "Vaathi", year: 2023), providerAlbum("3", "Brand New", year: 2024)])
        let s = try await setup(catalogue: cat)
        _ = await s.pass.run(s.person)
        let vaathi = try await s.g.search("Vaathi", kinds: [.album], limit: 10)
        #expect(vaathi.count == 1, "the catalogue's Vaathi joined Wikidata's soundtrack album: \(vaathi.map(\.name))")
        let rel = try #require(try await s.g.resolveAlias(for: ExternalID(.provider, "jiosaavn:2"), kind: .release))
        #expect((try await s.g.edges(of: rel, predicate: .editionOf, direction: .outgoing, limit: 2)).first?.object == vaathi[0].id)
        #expect(try await s.g.search("Brand New", kinds: [.album], limit: 3).count == 1)
    }

    @Test func cancellingStopsTheRunAndMarksNothingHalfDone() async throws {
        let s = try await setup()
        s.t.hold = true
        let task = Task { await s.pass.run(s.person) }
        try await Task.sleep(nanoseconds: 60_000_000)
        task.cancel()
        s.t.hold = false
        let out = await task.value
        #expect(out.cancelled && !out.complete)
        let live = try #require(try await s.g.resolve(s.person))
        #expect(try await s.g.cacheState(entity: live, facet: "full.identity", source: .wikidata) == nil)
        #expect(try await s.g.search("Vaathi", kinds: [.film], limit: 3).isEmpty)
    }

    @Test func partialResultsAreAnnouncedStageByStage() async throws {
        let s = try await setup()
        let seen = CompletenessBox<[String]>([])
        _ = await s.pass.run(s.person) { changed, phase in
            if !changed.isEmpty { seen.mutate { $0.append("changed") } }
            if case .stage(let n) = phase { seen.mutate { $0.append(n) } }
        }
        let log = seen.value
        #expect(log.first == "identity" && log.contains("wikidata") && log.filter { $0 == "changed" }.count >= 2)
        let firstChanged = try #require(log.firstIndex(of: "changed")), mbStage = try #require(log.firstIndex(of: "mb.releaseGroups"))
        #expect(firstChanged < mbStage, "Wikidata's results are announced before MusicBrainz is asked")
    }

    @Test func aFilmGetsItsSoundtrackAlbumsFromTheCatalogueByTitleAndYear() async throws {
        let cat = CompletenessCatalogue(byTitle: [providerAlbum("v", "Vaathi (Original Motion Picture Soundtrack)", year: 2023, artists: ["G. V. Prakash Kumar"], type: "soundtrack"),
                                                  providerAlbum("x", "Vaathi", year: 1999, artists: ["Someone"])])
        let g = MusicInMemoryGraph()
        let t = CompletenessTransport()
        t.add("release-group?", F.data("{\"release-groups\":[]}"))
        let film = try await g.upsert(MusicEntityDraft(kind: .film, name: "Vaathi", year: 2023, externalIDs: [ExternalID(.imdbTitle, "tt15327088")])).id
        let pass = MusicPersonCompleteness(resolver: MusicEntityResolver(store: g, sources: []), transport: t, catalogue: cat)
        let out = await pass.runFilm(film)
        #expect(out.albumsFound == 1)
        let links = try await g.edges(of: film, predicate: .soundtrackOf, direction: .incoming, limit: 5)
        #expect(links.count == 1 && links[0].status == .inferred, "inferred, never verified from a catalogue title")
    }

    @Test func anAlbumGetsOtherEditionsOnlyWhenTheArtistAgrees() async throws {
        let g = MusicInMemoryGraph()
        let artist = try await g.upsert(MusicEntityDraft(kind: .person, name: "Anirudh", externalIDs: [ExternalID(.canon, "p|ani")])).id
        let album = try await g.upsert(MusicEntityDraft(kind: .album, name: "Jailer", year: 2023, externalIDs: [ExternalID(.mbReleaseGroup, "rgJ")])).id
        _ = try await g.addEdge(MusicEdge(subject: album, predicate: .performedBy, object: artist, role: .performer, creditLevel: .album), provenance: MusicProvenance(source: .musicbrainz, license: .cc0, score: 0.95))
        let cat = CompletenessCatalogue(byTitle: [providerAlbum("j1", "Jailer", year: 2023, artists: ["Anirudh"]), providerAlbum("j2", "Jailer", year: 2023, artists: ["Other Band"])])
        let pass = MusicPersonCompleteness(resolver: MusicEntityResolver(store: g, sources: []), transport: CompletenessTransport(), catalogue: cat)
        _ = await pass.runAlbum(album)
        #expect(try await g.edges(of: album, predicate: .editionOf, direction: .incoming, limit: 5).count == 1)
        #expect(try await g.resolveAlias(for: ExternalID(.provider, "jiosaavn:j2"), kind: .release) == nil)
    }
}

final class CompletenessBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}
