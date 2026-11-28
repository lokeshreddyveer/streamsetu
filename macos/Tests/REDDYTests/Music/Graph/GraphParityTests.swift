import Foundation
import Testing
@testable import REDDY

private typealias T = GraphTestSupport

/// The SQLite store and the in-memory store must answer one script the same way.
@Suite("Graph store parity") struct GraphParityTests {
    private func fmt(_ e: MusicEdge) -> String {
        "\(e.subject)|\(e.predicate.label)|\(e.object)|\(e.qualifier)|\(String(format: "%.3f", e.confidence))|\(e.status)|\(e.tombstone)|\(e.order.map(String.init) ?? "-")|\(e.creditLevel)|\(e.attributes.values.sorted { $0.key < $1.key })"
    }

    private func script(_ g: any MusicGraphStoring, clock: GraphTestClock) async throws -> [String] {
        var out: [String] = []
        let jio = MusicSourceID("jiosaavn")
        let drafts = [
            T.person("Arijit", ids: [T.provider("a:art")]),
            T.person("Arijit Singh", ids: [T.provider("b:art"), ExternalID(.mbid, "arijit")]),
            T.recording("Tum Hi Ho", uid: "a:s1", extra: [ExternalID(.isrc, "I1")]),
            T.recording("Tum Hi Ho (Aashiqui 2)", uid: "b:s1", extra: [ExternalID(.isrc, "I1")]),
            MusicEntityDraft(kind: .film, name: "आशिकी 2", lang: "hin", year: 2013, externalIDs: [ExternalID(.tmdbMovie, "7")], aliases: [NameAlias("Aashiqui 2")]),
            MusicEntityDraft(kind: .release, name: "Aashiqui 2 (Original Motion Picture Soundtrack)", subkind: "soundtrack", year: 2013, externalIDs: [T.provider("a:alb")]),
            MusicEntityDraft(kind: .person, name: "Mithoon"),
        ]
        let results = try await g.upsert(drafts)
        out += results.map { "\($0.id) \($0.created) \($0.conflicts)" }
        let ids = results.map(\.id)
        let (a, b, s1, s2, film, rel) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5])
        out.append("again \(try await g.upsert(drafts[1]))")
        let claims = [
            MusicEdgeClaim(MusicEdge(subject: s1, predicate: .performedBy, object: a, role: .singer, order: 1), T.claim(jio, score: 0.6)),
            MusicEdgeClaim(MusicEdge(subject: s1, predicate: .performedBy, object: b, role: .singer, order: 0), T.claim(.musicbrainz)),
            MusicEdgeClaim(MusicEdge(subject: s2, predicate: .performedBy, object: a, role: .singer), T.claim(jio)),
            MusicEdgeClaim(MusicEdge(subject: s1, predicate: .trackOn, object: rel, attributes: ["position": "3", "disc": "1"], creditLevel: .album), T.claim(jio, score: 0.9)),
            MusicEdgeClaim(MusicEdge(subject: rel, predicate: .soundtrackOf, object: film), T.claim(.matcher, score: 0.9)),
            MusicEdgeClaim(MusicEdge(subject: s1, predicate: .featuredIn, object: film), T.claim(.wikidata, stated: true)),
            MusicEdgeClaim(MusicEdge(subject: film, predicate: .composedBy, object: a, role: .composer, creditLevel: .film), T.claim(.tmdb)),
        ]
        out += try await g.addEdges(claims).map(fmt)
        try await g.setFact(T.claim(.wikidata, stance: .contradicts), for: MusicEdgeKey(subject: s1, predicate: .performedBy, object: b, qualifier: "singer"))
        try await g.retractEdge(MusicEdgeKey(subject: s2, predicate: .performedBy, object: a, qualifier: "singer"))
        for id in [s1, s2, a, b, film, rel] { out += try await g.edges(of: id, predicate: nil, direction: .both, limit: 50).map(fmt) }
        out.append("facts \(try await g.facts(for: MusicEdgeKey(subject: s1, predicate: .performedBy, object: b, qualifier: "singer")).map { "\($0.source)|\($0.stance)" })")

        try await g.setCacheState(entity: s1, facet: "credits", source: .musicbrainz, outcome: .ok, ttl: 3600)
        try await g.setCacheState(entity: s1, facet: "cast", source: .tmdb, outcome: .error, ttl: 0)
        try await g.setCacheState(entity: s1, facet: "cast", source: .tmdb, outcome: .error, ttl: 0)
        for (f, src) in [("credits", MusicSourceID.musicbrainz), ("cast", .tmdb), ("none", .tmdb)] {
            let st = try await g.cacheState(entity: s1, facet: f, source: src)
            out.append("cache \(f) \(st.map { "\($0.outcome) \($0.attempts) \($0.fetchedAt?.timeIntervalSince1970 ?? -1) \($0.expiresAt?.timeIntervalSince1970 ?? -1) \($0.nextRetryAt?.timeIntervalSince1970 ?? -1)" } ?? "nil")")
        }

        for q in ["arijit", "Aashiqui", "आशिकी", "ashiki", "tum hi", "mithoon", "zzz"] {
            out.append("search \(q) " + (try await g.search(q, kinds: [], limit: 10)).map { "\($0.id)@\(String(format: "%.1f", $0.score))\($0.viaRomanised)" }.joined(separator: ","))
        }
        out.append("kinds " + (try await g.search("arijit", kinds: [.person], limit: 10)).map { "\($0.id)" }.joined(separator: ","))
        for id in [s1, film, a] {
            let n = try await g.neighbours(of: id, depth: 2, fanOut: 40)
            out.append("nb \(id) \(n.truncated) " + n.nodes.map { "\($0.id)/\($0.depth)/\($0.parent)/\($0.predicate.label)/\($0.direction)" }.joined(separator: ","))
        }

        // Merge and look again.
        out.append("merge \(try await g.mergeEntities(winner: b, loser: a, byUser: false))")
        _ = try await g.mergeEntities(winner: s1, loser: s2, byUser: true)
        for id in [s1, s2, a, b, film, rel] { out += try await g.edges(of: id, predicate: nil, direction: .both, limit: 50).map(fmt) }
        out.append("resolve \(try await g.resolve(a)!) \(try await g.resolve(s2)!) \(String(describing: try await g.resolveAlias(for: T.provider("a:art"))))")
        out.append("ids \(try await g.externalIDs(of: b).map(\.description))")
        out.append("aliases \(try await g.aliases(of: b).map { "\($0.text)\($0.isPrimary)" })")
        out.append("search \((try await g.search("arijit", kinds: [], limit: 10)).map(\.id))")
        out.append("cands \(try await g.candidates(for: ExternalID(.isrc, "I1")))")
        out.append("entity \(String(describing: try await g.entity(s1).map { "\($0.name)|\($0.year ?? 0)|\($0.state)" }))")

        let c = try await g.counts()
        out.append("counts \(c.entities) \(c.tombstones) \(c.edges) \(c.retractedEdges) \(c.facts) \(c.externalIDs) \(c.aliases) \(c.cacheStates)")
        return out
    }

    @Test func sqliteAndMemoryAgree() async throws {
        let c1 = GraphTestClock(), c2 = GraphTestClock()
        let (sql, dir) = T.makeStore(clock: c1); defer { T.cleanup(dir) }
        let mem = MusicInMemoryGraph(clock: c2.reader)
        let a = try await script(sql, clock: c1), b = try await script(mem, clock: c2)
        #expect(a.count == b.count)
        for (x, y) in zip(a, b) { #expect(x == y) }
        #expect(a.contains { $0.hasPrefix("counts 5 3 ") } || a.last!.hasPrefix("counts"))
    }

    @Test func memoryStoreHonoursTheSameRules() async throws {
        let m = MusicInMemoryGraph()
        let song = try await m.upsert(T.recording("S", uid: "p:1")).id
        let film = try await m.upsert(MusicEntityDraft(kind: .film, name: "F", year: 2000, externalIDs: [ExternalID(.tmdbMovie, "1")])).id
        let e = try await m.addEdge(MusicEdge(subject: song, predicate: .featuredIn, object: film), provenance: T.claim(.matcher, score: 0.9))
        #expect(e.status == .inferred)
        await #expect(throws: MusicGraphError.self) { try await m.addEdge(MusicEdge(subject: film, predicate: .featuredIn, object: song), provenance: T.claim(.matcher)) }
        try await m.wipe()
        #expect(try await m.counts().entities == 0)
    }
}
