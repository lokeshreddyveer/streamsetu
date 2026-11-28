import Foundation
import Testing
@testable import REDDY

private typealias T = GraphTestSupport

@Suite("Graph store: entities, ids, merge") struct GraphStoreEntityTests {
    @Test func aliasResolutionAndStrongIDUniqueness() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let q = ExternalID(.wikidata, "Q1")
        let a = try await s.upsert(MusicEntityDraft(kind: .film, name: "Awaara", year: 1951, externalIDs: [ExternalID(.tmdbMovie, "100"), q]))
        // The same strong id from another draft is the same entity, whatever the name says.
        let b = try await s.upsert(MusicEntityDraft(kind: .film, name: "आवारा", lang: "hin", externalIDs: [q, ExternalID(.imdbTitle, "tt0043265")]))
        #expect(a.id == b.id && !b.created && b.conflicts.isEmpty)
        #expect(try await s.resolveAlias(for: ExternalID(.imdbTitle, "tt0043265")) == a.id)
        #expect(try await s.externalIDs(of: a.id).count == 3)
        #expect(try await s.counts().entities == 1)

        // A draft naming strong ids that belong to two different entities attaches to the first and reports the other as a conflict.
        let other = try await s.upsert(MusicEntityDraft(kind: .film, name: "Awaara", year: 2010, externalIDs: [ExternalID(.tmdbMovie, "300")]))
        #expect(other.id != a.id)
        let c = try await s.upsert(MusicEntityDraft(kind: .film, name: "Awaara", externalIDs: [ExternalID(.tmdbMovie, "100"), ExternalID(.tmdbMovie, "300")]))
        #expect(c.id == a.id && c.conflicts == [ExternalID(.tmdbMovie, "300")])
        #expect(try await s.resolveAlias(for: ExternalID(.tmdbMovie, "300")) == other.id)
        #expect(try await s.resolveAlias(for: q) == a.id)
        // The database refuses a second live owner of a strong id outright.
        await #expect(throws: (any Error).self) {
            try await s.withWriter { conn in
                try conn.execute("INSERT INTO external_id(entity, scheme, value, strong, retrieved_at, conflict) VALUES((SELECT rid FROM entity WHERE id = ?), 'wikidata', 'Q1', 1, 0, 0)", [other.id.rawValue])
            }
        }
    }

    @Test func weakIDsMayBeShared() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let isrc = ExternalID(.isrc, "INA000000001")
        let a = try await s.upsert(T.recording("Song (Film Version)", uid: "p:1", extra: [isrc]))
        let b = try await s.upsert(T.recording("Song (Remix)", uid: "p:2", extra: [isrc]))
        #expect(a.id != b.id && b.conflicts.isEmpty)
        #expect(Set(try await s.candidates(for: isrc)) == [a.id, b.id])
        #expect(try await s.resolveAlias(for: isrc) == nil, "ambiguous weak ids never resolve")
        #expect(try await s.resolveAlias(for: ExternalID(.provider, "p:2")) == b.id)
    }

    @Test func aProvisionalRowTakesARealDraftsValues() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let first = try await s.upsert(MusicEntityDraft(kind: .person, name: "a r rahman", externalIDs: [T.provider("jiosaavn:9")], provisional: true))
        let real = try await s.upsert(MusicEntityDraft(kind: .person, name: "A. R. Rahman", year: 1967, country: "IN", externalIDs: [T.provider("jiosaavn:9"), ExternalID(.mbid, "m1")]))
        #expect(real.id == first.id)
        let e = try #require(try await s.entity(first.id))
        #expect(e.name == "A. R. Rahman" && e.year == 1967 && !e.provisional && e.country == "IN")
        // Later drafts never overwrite known values.
        _ = try await s.upsert(MusicEntityDraft(kind: .person, name: "someone else", year: 1999, externalIDs: [ExternalID(.mbid, "m1")], provisional: true))
        let e2 = try #require(try await s.entity(first.id))
        #expect(e2.name == "A. R. Rahman" && e2.year == 1967)
        // Both names are searchable.
        #expect(try await s.search("a r rahman").first?.id == first.id)
    }

    @Test func mergeRedirectsTombstonesAndRepointsEdges() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let song1 = try await s.upsert(T.recording("Tum Hi Ho", uid: "a:1")).id
        let song2 = try await s.upsert(T.recording("Tum Hi Ho (Aashiqui 2)", uid: "b:1")).id
        let pA = try await s.upsert(T.person("Arijit", ids: [T.provider("a:art")])).id
        let pB = try await s.upsert(T.person("Arijit Singh", ids: [T.provider("b:art"), ExternalID(.mbid, "arijit")])).id
        let album = try await s.upsert(MusicEntityDraft(kind: .release, name: "Aashiqui 2", externalIDs: [T.provider("a:alb")])).id
        let src = MusicSourceID("jiosaavn")
        _ = try await s.addEdge(MusicEdge(subject: song1, predicate: .performedBy, object: pA, role: .singer), provenance: T.claim(src))
        _ = try await s.addEdge(MusicEdge(subject: song1, predicate: .performedBy, object: pB, role: .singer), provenance: T.claim(.musicbrainz))
        _ = try await s.addEdge(MusicEdge(subject: song2, predicate: .performedBy, object: pB, role: .singer), provenance: T.claim(src))
        _ = try await s.addEdge(MusicEdge(subject: song1, predicate: .trackOn, object: album, attributes: ["position": "3"]), provenance: T.claim(src))
        _ = try await s.addEdge(MusicEdge(subject: pA, predicate: .memberOf, object: try await s.upsert(MusicEntityDraft(kind: .group, name: "Duo")).id), provenance: T.claim(src))
        let before = try await s.counts()

        // pA (older) merges into pB; the duplicate edge song1-performedBy folds into one with both facts.
        let survivor = try await s.mergeEntities(winner: pB, loser: pA, byUser: false)
        #expect(survivor == pB)
        #expect(try await s.resolve(pA) == pB)
        let tomb = try await s.entity(pA)
        #expect(tomb?.state == .merged && tomb?.mergedInto == pB)
        let credits = try await s.edges(of: song1, predicate: .performedBy)
        #expect(credits.count == 1 && credits[0].object == pB && credits[0].status == .verified)
        #expect(try await s.facts(for: credits[0].key).count == 2)
        #expect(try await s.edges(of: pB, predicate: .performedBy, direction: .incoming).count == 2)
        // The loser's own edge (member of the duo) moved to the winner.
        #expect(try await s.edges(of: pB, predicate: .memberOf).count == 1)
        // Ids moved: the old provider uid now leads to the survivor.
        #expect(try await s.resolveAlias(for: T.provider("a:art")) == pB)
        let after = try await s.counts()
        #expect(after.entities == before.entities - 1 && after.tombstones == 1 && after.edges == before.edges - 1)
        // Edges added against the old id land on the survivor.
        let e = try await s.addEdge(MusicEdge(subject: song2, predicate: .composedBy, object: pA, role: .composer), provenance: T.claim(.musicbrainz))
        #expect(e.object == pB)
        // A name of the loser still finds the survivor, and the loser itself is never a result.
        #expect(try await s.search("Arijit").map(\.id) == [pB])
        // Chains: merge the survivor into a third; both old ids still lead home.
        let p3 = try await s.upsert(T.person("Arijit S", ids: [T.provider("c:art")])).id
        _ = try await s.mergeEntities(winner: p3, loser: pB, byUser: true)
        #expect(try await s.resolve(pA) == p3)
        #expect(try await s.resolve(pB) == p3)
        #expect(try await s.edges(of: song1, predicate: .performedBy).first?.object == p3)
    }

    @Test func mergeRefusesDifferentKindsAndSelf() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let p = try await s.upsert(T.person("X")).id, f = try await s.upsert(MusicEntityDraft(kind: .film, name: "X", year: 2000)).id
        await #expect(throws: MusicGraphError.self) { try await s.mergeEntities(winner: p, loser: f, byUser: false) }
        #expect(try await s.mergeEntities(winner: p, loser: p, byUser: false) == p)
    }

    @Test func pinnedFlagSurvivesMerge() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let a = try await s.upsert(T.person("Anil", ids: [T.provider("x:a")])).id, b = try await s.upsert(T.person("Bhaskar", ids: [T.provider("x:b")])).id
        try await s.setPinned(a, true)
        _ = try await s.mergeEntities(winner: b, loser: a, byUser: false)
        #expect(try await s.entity(b)?.pinned == true)
    }
}

@Suite("Graph store: edges and provenance") struct GraphStoreEdgeTests {
    private func world(_ s: MusicGraphStore) async throws -> (album: MusicEntityID, film: MusicEntityID, song: MusicEntityID, composer: MusicEntityID) {
        (try await s.upsert(MusicEntityDraft(kind: .album, name: "Awaara OST", externalIDs: [T.provider("jio:alb")])).id,
         try await s.upsert(MusicEntityDraft(kind: .film, name: "Awaara", year: 2010, externalIDs: [ExternalID(.tmdbMovie, "1")])).id,
         try await s.upsert(T.recording("Awaara", uid: "jio:s")).id,
         try await s.upsert(T.person("Yuvan", ids: [T.provider("jio:p")])).id)
    }

    @Test func soundtrackLinksStayInferredUntilASourceStatesThem() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let w = try await world(s)
        let key = MusicEdgeKey(subject: w.album, predicate: .soundtrackOf, object: w.film)
        var e = try await s.addEdge(MusicEdge(subject: w.album, predicate: .soundtrackOf, object: w.film, creditLevel: .film), provenance: T.claim(.matcher, score: 0.9, ref: "title+composer"))
        #expect(e.status == .inferred && e.confidence <= 0.99)
        e = try await s.addEdge(MusicEdge(subject: w.album, predicate: .soundtrackOf, object: w.film), provenance: T.claim(.musicbrainz))
        #expect(e.status == .inferred, "MusicBrainz without a statement")
        try await s.setFact(T.claim(.wikidata, stated: true), for: key)
        #expect(try await s.edge(key)?.status == .verified)
        #expect(try await s.facts(for: key).count == 3)
        // The same source replaces its own claim; it does not stack up.
        try await s.setFact(T.claim(.wikidata, stated: true, score: 0.8), for: key)
        #expect(try await s.facts(for: key).count == 3)
    }

    @Test func retractionKeepsATombstoneThatIsNotInferredAgain() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let w = try await world(s)
        let edge = MusicEdge(subject: w.song, predicate: .featuredIn, object: w.film)
        _ = try await s.addEdge(edge, provenance: T.claim(.matcher, score: 0.8))
        #expect(try await s.edges(of: w.song, predicate: .featuredIn).count == 1)
        try await s.retractEdge(edge.key)
        #expect(try await s.edges(of: w.song, predicate: .featuredIn).isEmpty)
        #expect(try await s.edge(edge.key)?.tombstone == true)
        // The matcher finds it again: it stays retracted.
        let again = try await s.addEdge(edge, provenance: T.claim(.matcher, score: 0.95))
        #expect(again.tombstone)
        #expect(try await s.edges(of: w.song, predicate: .featuredIn).isEmpty)
        #expect(try await s.counts().retractedEdges == 1)
    }

    @Test func roleQualifiedEdgesAndOrdering() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let w = try await world(s)
        let src = MusicSourceID("jiosaavn")
        _ = try await s.addEdge(MusicEdge(subject: w.song, predicate: .composedBy, object: w.composer, role: .composer), provenance: T.claim(src))
        _ = try await s.addEdge(MusicEdge(subject: w.song, predicate: .composedBy, object: w.composer, role: .musicDirector), provenance: T.claim(src))
        #expect(try await s.edges(of: w.song, predicate: .composedBy).count == 2)
        // Billing order.
        var ids: [MusicEntityID] = []
        for i in 0..<5 {
            let p = try await s.upsert(T.person("Singer \(i)", ids: [T.provider("jio:s\(i)")])).id
            ids.append(p)
            _ = try await s.addEdge(MusicEdge(subject: w.song, predicate: .performedBy, object: p, role: .singer, order: 4 - i), provenance: T.claim(src))
        }
        #expect(try await s.edges(of: w.song, predicate: .performedBy).map(\.object) == ids.reversed())
        #expect(try await s.edges(of: w.song, predicate: .performedBy, direction: .outgoing, limit: 2).count == 2)
        #expect(try await s.edges(of: ids[0], predicate: .performedBy, direction: .incoming).first?.subject == w.song)
        #expect(try await s.edges(of: ids[0], predicate: .performedBy, direction: .outgoing).isEmpty)
        // Attributes merge and a more specific credit level wins.
        _ = try await s.addEdge(MusicEdge(subject: w.song, predicate: .performedBy, object: ids[0], role: .singer, attributes: ["instrument": "voice"], creditLevel: .song), provenance: T.claim(src, ref: "r2"))
        let e = try #require(try await s.edge(MusicEdgeKey(subject: w.song, predicate: .performedBy, object: ids[0], qualifier: "singer")))
        #expect(e.attributes.instrument == "voice" && e.creditLevel == .song && e.order == 4)
    }

    @Test func invalidEdgesAreRefused() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let w = try await world(s)
        await #expect(throws: MusicGraphError.self) { try await s.addEdge(MusicEdge(subject: w.composer, predicate: .soundtrackOf, object: w.film), provenance: T.claim(.matcher)) }
        await #expect(throws: MusicGraphError.self) { try await s.addEdge(MusicEdge(subject: w.song, predicate: .performedBy, object: w.song), provenance: T.claim(.matcher)) }
        let ghost = MusicEntityID.derive(kind: .person, aliasKey: "nobody")
        await #expect(throws: MusicGraphError.self) { try await s.addEdge(MusicEdge(subject: w.song, predicate: .performedBy, object: ghost), provenance: T.claim(.matcher)) }
        #expect(try await s.counts().edges == 0)
    }

    @Test func factsSurviveAndExpire() async throws {
        let clock = GraphTestClock()
        let (s, dir) = T.makeStore(clock: clock); defer { T.cleanup(dir) }
        let w = try await world(s)
        let tmdb = MusicProvenance(source: .tmdb, retrievedAt: clock.now, expiresAt: clock.now.addingTimeInterval(30 * 86_400), license: .termsRestricted, score: 0.9)
        let e = try await s.addEdge(MusicEdge(subject: w.film, predicate: .directedBy, object: w.composer, role: .director), provenance: tmdb)
        #expect(e.status == .verified)
        let f = try #require(try await s.facts(for: e.key).first)
        #expect(f.license == .termsRestricted && f.expiresAt == tmdb.expiresAt && f.source == .tmdb)
        clock.advance(31 * 86_400)
        _ = try await s.evict()
        let left = try await s.counts()
        #expect(left.facts == 0 && left.edges == 0)
    }
}

@Suite("Graph store: cache state") struct GraphCacheStateTests {
    @Test func ttlAndBackoff() async throws {
        let clock = GraphTestClock()
        let (s, dir) = T.makeStore(clock: clock); defer { T.cleanup(dir) }
        let id = try await s.upsert(T.recording("S", uid: "p:1")).id
        #expect(try await s.cacheState(entity: id, facet: "credits", source: .musicbrainz) == nil)

        try await s.setCacheState(entity: id, facet: "credits", source: .musicbrainz, outcome: .ok, ttl: 3600, etag: "e1", matcherVersion: 2)
        var st = try #require(try await s.cacheState(entity: id, facet: "credits", source: .musicbrainz))
        #expect(st.isFresh(at: clock.now) && !st.needsFetch(at: clock.now) && st.etag == "e1" && st.matcherVersion == 2)
        clock.advance(3599); #expect(st.isFresh(at: clock.now))
        clock.advance(2); #expect(!st.isFresh(at: clock.now) && st.needsFetch(at: clock.now))

        // A remembered negative result is fresh until its own, shorter, expiry.
        try await s.setCacheState(entity: id, facet: "cast", source: .tmdb, outcome: .empty, ttl: 600)
        st = try #require(try await s.cacheState(entity: id, facet: "cast", source: .tmdb))
        #expect(st.outcome == .empty && st.isFresh(at: clock.now))

        // Failures back off 1 min, 2 min, 4 min...; a success clears them.
        for n in 1...3 {
            try await s.setCacheState(entity: id, facet: "bio", source: .wikidata, outcome: .error, ttl: 0)
            st = try #require(try await s.cacheState(entity: id, facet: "bio", source: .wikidata))
            #expect(st.attempts == n && !st.isFresh(at: clock.now) && !st.needsFetch(at: clock.now))
            let wait = MusicCacheState.backoff(attempts: n)
            #expect(wait == 60 * pow(2, Double(n - 1)))
            #expect(abs(st.nextRetryAt!.timeIntervalSince(clock.now) - wait) < 1)
        }
        clock.advance(MusicCacheState.backoff(attempts: 3) + 1)
        #expect(st.needsFetch(at: clock.now))
        try await s.setCacheState(entity: id, facet: "bio", source: .wikidata, outcome: .ok, ttl: 100)
        st = try #require(try await s.cacheState(entity: id, facet: "bio", source: .wikidata))
        #expect(st.attempts == 0 && st.nextRetryAt == nil && st.isFresh(at: clock.now))
        #expect(MusicCacheState.backoff(attempts: 30) == 21_600)
        // Facets and sources are independent keys.
        #expect(try await s.cacheState(entity: id, facet: "bio", source: .musicbrainz) == nil)
    }
}

@Suite("Graph store: search") struct GraphSearchTests {
    @Test func originalScriptAndRomanisedNamesMatch() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let hindi = try await s.upsert(MusicEntityDraft(kind: .film, name: "आवारा", lang: "hin", year: 1951, externalIDs: [ExternalID(.wikidata, "Q1")], aliases: [NameAlias("Awaara", lang: "en")])).id
        let telugu = try await s.upsert(MusicEntityDraft(kind: .film, name: "ఆవారా", lang: "tel", year: 2010, externalIDs: [ExternalID(.wikidata, "Q2")])).id
        let other = try await s.upsert(MusicEntityDraft(kind: .film, name: "Aawara Paagal Deewana", year: 2002, externalIDs: [ExternalID(.wikidata, "Q3")])).id
        _ = try await s.upsert(T.person("Kishore Kumar", ids: [T.provider("x:k")]))

        // Original script, exact and prefix.
        #expect(try await s.search("आवारा").map(\.id).contains(hindi))
        #expect(try await s.search("आव").map(\.id).contains(hindi))
        // Alias spelling.
        let awaara = try await s.search("awaara").map(\.id)
        #expect(awaara.contains(hindi))
        // Romanised queries reach every script through the folded skeleton (aa/a, w/v).
        for q in ["awara", "avaara", "Aavara"] {
            let ids = try await s.search(q, kinds: [.film]).map(\.id)
            #expect(ids.contains(hindi) && ids.contains(telugu), "\(q) -> \(ids)")
        }
        let r = try await s.search("awara", kinds: [.film])
        #expect(r.first(where: { $0.id == telugu })?.viaRomanised == true)
        #expect(Set(r.map(\.id)).isSuperset(of: [hindi, telugu, other]))
        // Kind filter, limit, prefix of a later word, no match, empty query.
        #expect(try await s.search("kishore", kinds: [.film]).isEmpty)
        #expect(try await s.search("kishore", kinds: [.person]).count == 1)
        #expect(try await s.search("kum").count == 1)
        #expect(try await s.search("awara", limit: 1).count == 1)
        #expect(try await s.search("zzzz").isEmpty)
        #expect(try await s.search("   ").isEmpty)
        #expect(try await s.search("\"*(").isEmpty)
    }

    @Test func foldingJoinsSpellings() {
        #expect(MusicGraphText.latin("Zinda") == MusicGraphText.latin("Jinda"))
        #expect(MusicGraphText.latin("Guzaarish") == MusicGraphText.latin("Gujarish"))
        #expect(MusicGraphText.latin("आवारा") == MusicGraphText.latin("Awaara"))
        #expect(MusicGraphText.latin("ఆవారా") == MusicGraphText.latin("Awaara"))
        #expect(MusicGraphText.latin("Beyoncé") == MusicGraphText.latin("Beyonce"))
        #expect(MusicGraphText.latin("  ") == "")
        #expect(MusicGraphText.ftsExpression("!!") == nil)
    }
}
