import Foundation
import Testing
@testable import REDDY

private typealias T = GraphTestSupport

@Suite("Graph side index and adapters") struct GraphIndexAndAdapterTests {
    private func track(_ id: String = "s1", title: String = "Awaara Hoon", provider: String = "jiosaavn", artists: [MusicArtistRef] = [MusicArtistRef(id: "a1", name: "Kishore Kumar")]) -> MusicTrack {
        MusicTrack(id: id, providerID: provider, title: title, durationMs: 215_000, trackNumber: 3, discNumber: 1, artists: artists,
                   album: MusicAlbumRef(id: "al1", title: "Awaara (Original Motion Picture Soundtrack)", releaseDate: "1951-01-01", albumType: "Album"), explicit: false, isrc: "inx510000001")
    }

    @Test func providerUIDMapsToAStableIDWithoutRewritingTheLibrary() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let index = MusicEntityIndex(store: s)
        let t = track()
        #expect(try await index.lookup(providerUID: t.uid, kind: .recording) == nil, "lookup never mints")
        let id = try await index.mint(MusicGraphAdapters.plan(for: t))
        #expect(id == MusicEntityIndex.provisionalID(kind: .recording, providerUID: t.uid))
        #expect(id == MusicGraphAdapters.provisionalID(for: .track(t)))
        #expect(try await index.lookup(providerUID: t.uid, kind: .recording) == id)
        // Minting again changes nothing.
        let before = try await s.counts()
        #expect(try await index.mint(MusicGraphAdapters.plan(for: t)) == id)
        let after = try await s.counts()
        #expect(after.entities == before.entities && after.edges == before.edges)

        // The recording is linked to its credit and its release at provider confidence, as inferred claims.
        let credits = try await s.edges(of: id, predicate: .performedBy)
        #expect(credits.count == 1 && credits[0].role == .performer && credits[0].status == .inferred && abs(credits[0].confidence - 0.6) < 0.01)
        let placement = try #require(try await s.edges(of: id, predicate: .trackOn).first)
        #expect(placement.attributes.position == 3 && placement.attributes.disc == 1)
        let release = try #require(try await s.entity(placement.object))
        #expect(release.kind == .release && release.year == 1951 && MusicReleaseNode(snapshot: release)?.isSoundtrack == true)
        // The adapter never invents a film link.
        #expect(try await s.edges(of: release.id, predicate: .soundtrackOf).isEmpty)
        #expect(try await s.candidates(for: ExternalID(.isrc, "INX510000001")) == [id])
    }

    @Test func plainTextArtistsBecomeProvisionalPeopleByName() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let index = MusicEntityIndex(store: s)
        let id = try await index.mint(MusicGraphAdapters.plan(for: track(artists: [MusicArtistRef(id: "", name: "Lata Mangeshkar")])))
        let person = try #require(try await s.edges(of: id, predicate: .performedBy).first?.object)
        let e = try #require(try await s.entity(person))
        #expect(e.provisional && e.name == "Lata Mangeshkar" && e.kind == .person)
        // The same text artist on another track is the same person.
        let id2 = try await index.mint(MusicGraphAdapters.plan(for: track("s2", title: "Other", artists: [MusicArtistRef(id: "", name: "Lata Mangeshkar")])))
        #expect(try await s.edges(of: id2, predicate: .performedBy).first?.object == person)
    }

    @Test func browseItemsAlbumsArtistsPlaylists() {
        let t = track()
        let album = MusicAlbum(id: "al", providerID: "jiosaavn", title: "Aashiqui 2 (OST)", artists: t.artists, releaseDate: "2013-04-01", albumType: "Soundtrack")
        let artist = MusicArtist(id: "a1", providerID: "jiosaavn", name: "Kishore Kumar", genres: ["Classic"])
        let pl = MusicPlaylist(id: "p", providerID: "jiosaavn", name: "Best of")
        for (item, kind) in [(MusicBrowseItem.track(t), MusicEntityKind.recording), (.album(album), .release), (.artist(artist), .person), (.playlist(pl), .playlist)] {
            let plan = MusicGraphAdapters.plan(for: item)
            #expect(plan.primary.kind == kind && plan.primary.derivedID == MusicGraphAdapters.provisionalID(for: item))
        }
        #expect(MusicGraphAdapters.plan(for: album).primary.subkind == "soundtrack")
        #expect(MusicGraphAdapters.albumSubkind(type: "EP", title: "x") == "ep")
        #expect(MusicGraphAdapters.albumSubkind(type: nil, title: "Greatest Hits") == nil)
        #expect(MusicGraphAdapters.filmHint(inTitle: "Kesariya (From \"Brahmastra\")") == "Brahmastra")
        #expect(MusicGraphAdapters.filmHint(inTitle: "Naatu Naatu [From RRR]") == "RRR")
        #expect(MusicGraphAdapters.filmHint(inTitle: "Plain Title") == nil)
    }

    @Test func canonicalTracksKeepTheirKeyAndHints() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let c = MusicCanonicalTrack(key: "kesariya|arijit singh|", title: "Kesariya", artists: ["Arijit Singh"], film: "Brahmastra", year: 2022, durationMs: 268_000, isrc: "INS220000001",
                                    language: "hin", versionTags: ["remix"], seenOn: ["jiosaavn:k1", "ytmusic:k2"])
        let d = MusicGraphAdapters.draft(for: c)
        #expect(d.attrs["filmHint"] == "Brahmastra" && d.attrs["versionKind"] == "remix")
        let id = try await s.upsert(d).id
        #expect(try await s.resolveAlias(for: ExternalID(.provider, "ytmusic:k2")) == id)
        #expect(try await s.candidates(for: ExternalID(.canon, c.key)) == [id])
        #expect(MusicRecordingNode(snapshot: try #require(try await s.entity(id)))?.versionKind == .remix)
    }

    @Test func filmInfoBecomesClaimsFromItsSource() async throws {
        let clock = GraphTestClock()
        let (s, dir) = T.makeStore(clock: clock); defer { T.cleanup(dir) }
        let index = MusicEntityIndex(store: s)
        let at = clock.now
        let info = MusicFilmInfo(title: "Awaara", year: 2010, language: "tel", tmdbID: 42, wikidataID: "Q9", imdbID: "tt1",
                                 cast: [MusicFilmPerson(tmdbID: 1, name: "Karthi", character: "Shiva"), MusicFilmPerson(tmdbID: 2, name: "Tamannaah", character: "Anjali")],
                                 directors: [MusicFilmPerson(tmdbID: 3, name: "Lingusamy")], composers: [MusicFilmPerson(tmdbID: 4, name: "Yuvan Shankar Raja")],
                                 source: .tmdb, provenance: MusicFilmProvenance(source: .tmdb, retrievedAt: at, confidence: 0.92))
        let film = try await index.mint(MusicGraphAdapters.plan(for: info))
        #expect(try await s.resolveAlias(for: ExternalID(.wikidata, "Q9")) == film)
        let cast = try await s.edges(of: film, predicate: .hasCast)
        #expect(cast.map(\.attributes.characterName) == ["Shiva", "Anjali"] && cast.allSatisfy { $0.status == .verified && $0.role == .actor && $0.creditLevel == .film })
        #expect(try await s.edges(of: film, predicate: .directedBy).count == 1)
        #expect(try await s.edges(of: film, predicate: .composedBy).count == 1)
        let fact = try #require(try await s.facts(for: cast[0].key).first)
        #expect(fact.license == .termsRestricted && fact.expiresAt == at.addingTimeInterval(30 * 86_400) && fact.source == .tmdb)
        // Acts-in from the person's side.
        let karthi = try #require(try await s.resolveAlias(for: ExternalID(.tmdbPerson, "1")))
        #expect(try await s.edges(of: karthi, predicate: .hasCast, direction: .incoming).first?.subject == film)
    }

    @Test @MainActor func tenThousandRowBackfillNeverBlocksTheMainThread() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let index = MusicEntityIndex(store: s)
        let drafts = (0..<10_000).map { MusicGraphAdapters.plan(for: track("t\($0)", title: "Song \($0)", artists: [])).primary }
        Perf.resetCounters(); Perf.collecting = true
        defer { Perf.collecting = false }
        let t0 = ContinuousClock.now
        let n = try await index.backfill(drafts, chunkSize: 300)
        let took = ContinuousClock.now - t0
        #expect(n == 10_000)
        let mainBlocked = Perf.mainTimes()
        #expect(mainBlocked["dbWrite"] == nil && mainBlocked["dbRead"] == nil, "no database call ran on the main thread: \(mainBlocked)")
        let counts = try await s.counts()
        #expect(counts.entities == 10_000)
        #expect(try await s.withReader { try $0.scalarInt("SELECT count(*) FROM entity WHERE pinned = 1") } == 10_000)
        print("GRAPH-BACKFILL 10000 rows in \(took)")
        // The index answers from memory afterwards.
        #expect(try await index.lookup(providerUID: "jiosaavn:t5", kind: .recording) != nil)
    }

    @Test func memoryIndexCapacityIsBounded() async throws {
        let m = MusicInMemoryGraph()
        let index = MusicEntityIndex(store: m, capacity: 16)
        for i in 0..<100 { _ = try await index.entityID(for: T.recording("S\(i)", uid: "p:\(i)")) }
        #expect(try await m.counts().entities == 100)
        #expect(try await index.entityID(for: T.recording("S3", uid: "p:3")) == MusicEntityIndex.provisionalID(kind: .recording, providerUID: "p:3"))
    }
}
