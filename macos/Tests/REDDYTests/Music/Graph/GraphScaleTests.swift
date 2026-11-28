import Foundation
import Testing
@testable import REDDY

private typealias T = GraphTestSupport

/// Bulk fixtures are written straight through the writer connection in one transaction (the public API is for page-sized batches).
private enum GraphScaleFixture {
    static let persons = 5_000, recordings = 30_000, releases = 10_000, films = 5_000   // 50,000 entities

    /// 50,000 entities with names, full-text rows, and 200,000 edges (plus 2,000 on one busy person) with one fact each.
    static func build(_ s: MusicGraphStore, edges: Int = 200_000) async throws {
        try await s.withWriter { c in
            let ins = try c.prepare("INSERT INTO entity(id, kind, name, name_latin, state, pinned, created_at, updated_at, accessed_at) VALUES(?, ?, ?, ?, 0, 0, 1000, 1000, 1000)")
            var rid = 0
            func add(_ kind: MusicEntityKind, _ n: Int, _ name: (Int) -> String) throws {
                for i in 0..<n {
                    rid += 1
                    let nm = name(i)
                    try ins.run([MusicEntityID.derive(kind: kind, aliasKey: "fx:\(rid)").rawValue, Int(kind.rawValue), nm, MusicGraphText.latin(nm)])
                }
            }
            try add(.person, persons) { "Artist \($0) Kumar" }
            try add(.recording, recordings) { "Song \($0) Awaara" }
            try add(.release, releases) { "Album \($0) Hits" }
            try add(.film, films) { "Film \($0) Awaara" }
            try c.exec("INSERT INTO entity_fts(rowid, name, latin, aliases) SELECT rid, name, name_latin, '' FROM entity")
            // Edges: 2/3 recording -> person (some people are hubs), then recording -> release placements, release -> film.
            let p = persons, r = recordings, rel = releases, f = films
            try c.exec("""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(edges))
                INSERT INTO edge(subject, predicate, object, qual, confidence, status, credit_level, tomb, created_at, updated_at)
                SELECT
                  CASE WHEN i % 3 = 2 THEN \(p + r) + 1 + (i % \(rel)) ELSE \(p) + 1 + (i % \(r)) END,
                  CASE WHEN i % 3 = 2 THEN \(MusicPredicate.soundtrackOf.rawValue) WHEN i % 3 = 1 THEN \(MusicPredicate.trackOn.rawValue) ELSE \(MusicPredicate.performedBy.rawValue) END,
                  CASE WHEN i % 3 = 2 THEN \(p + r + rel) + 1 + (i % \(f))
                       WHEN i % 3 = 1 THEN \(p + r) + 1 + ((i * 7) % \(rel))
                       ELSE 1 + ((i * 7919) % \(p)) END,
                  'q' || i, 0.5 + (i % 50) / 100.0, 1, 3, 0, 1000, 1000
                FROM n;
                INSERT INTO fact(edge, source, source_ref, retrieved_at, license, score, stance, override)
                SELECT rid, 'jiosaavn', '', 1000, 4, 0.6, 1, 0 FROM edge;
                """)
            // One busy person (rid 1): credited on 2,000 distinct recordings, like a prolific singer.
            try c.exec("""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
                INSERT INTO edge(subject, predicate, object, qual, confidence, status, credit_level, tomb, created_at, updated_at)
                SELECT \(p) + 1 + (i % \(r)), \(MusicPredicate.performedBy.rawValue), 1, 'hub' || i, 0.5 + (i % 50) / 100.0, 1, 3, 0, 1000, 1000 FROM n;
                INSERT INTO fact(edge, source, source_ref, retrieved_at, license, score, stance, override)
                SELECT rid, 'jiosaavn', '', 1000, 4, 0.6, 1, 0 FROM edge WHERE qual LIKE 'hub%';
                """)
        }
    }
}

@Suite("Graph scale", .serialized) struct GraphScaleTests {
    private func ms(_ block: () async throws -> Void) async rethrows -> Double {
        let t = ContinuousClock.now
        try await block()
        let d = ContinuousClock.now - t
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    @Test func fiftyThousandEntitiesTwoHundredThousandEdgesStayWithinBudget() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let build = try await ms { try await GraphScaleFixture.build(s) }
        let counts = try await s.counts()
        #expect(counts.entities == 50_000 && counts.edges == 202_000 && counts.facts == 202_000)

        // Prefix search over 50,000 names (original and romanised).
        var searchTimes: [Double] = []
        for q in ["awaara", "avara", "artist 4", "film 12", "song 29999", "Kum"] {
            var hits: [MusicSearchHit] = []
            searchTimes.append(try await ms { hits = try await s.search(q, kinds: [], limit: 20) })
            #expect(!hits.isEmpty, "\(q)")
        }
        // Traversal from the busy person: 2,000 credits, each recording linked on to its own people and releases.
        let hub = MusicEntityID.derive(kind: .person, aliasKey: "fx:1")
        var nb: MusicNeighbourhood?
        let walk = try await ms { nb = try await s.neighbours(of: hub, depth: 2, fanOut: 40) }
        #expect((nb?.nodes.count ?? 0) > 40 && (nb?.nodes.count ?? 0) <= MusicTraversal.maxNodes)
        var edgeList: [MusicEdge] = []
        let edgeRead = try await ms { edgeList = try await s.edges(of: hub, predicate: .performedBy, direction: .incoming, limit: 100) }
        #expect(edgeList.count == 100 && edgeList.allSatisfy { $0.object == hub })
        // Page-sized ingest into the big graph.
        var written = 0
        let ingest = try await ms {
            let drafts = (0..<500).map { T.recording("New \($0)", uid: "n:\($0)") }
            let ids = try await s.upsert(drafts).map(\.id)
            written = try await s.addEdges(ids.map { MusicEdgeClaim(MusicEdge(subject: $0, predicate: .performedBy, object: hub, role: .singer), T.claim(MusicSourceID("jiosaavn"))) }).count
        }
        #expect(written == 500)
        let merge = try await ms { _ = try await s.mergeEntities(winner: MusicEntityID.derive(kind: .person, aliasKey: "fx:2"), loser: hub, byUser: false) }

        print(String(format: "GRAPH-SCALE fixture %.0f ms | search avg %.1f max %.1f ms | neighbours(depth2,fan40) %.1f ms (%d nodes) | edges(of:,100) %.1f ms | ingest 500 entities + 500 edges %.0f ms | merge hub (2500 edges) %.0f ms",
                     build, searchTimes.reduce(0, +) / Double(searchTimes.count), searchTimes.max() ?? 0, walk, nb?.nodes.count ?? 0, edgeRead, ingest, merge))
        // Budgets: generous for an unoptimised test build; the traversal budget itself is 40 ms of work.
        #expect(searchTimes.max()! < 250)
        #expect(walk < 250)
        #expect(edgeRead < 100)
        #expect(ingest < 5_000)
        #expect(merge < 5_000)
    }

    @Test func evictionHonoursTheEdgeCapOnHalfAMillionEdgesAndNeverTouchesPinned() async throws {
        let clock = GraphTestClock()
        var limits = MusicGraphLimits.standard
        limits.maxEdges = 400_000
        let (s, dir) = T.makeStore(clock: clock, limits: limits); defer { T.cleanup(dir) }
        try await GraphScaleFixture.build(s, edges: 500_000)
        // Pin 200 recordings; their credit and placement neighbours are protected with them.
        try await s.withWriter { try $0.exec("UPDATE entity SET pinned = 1 WHERE kind = \(MusicEntityKind.recording.rawValue) AND rid <= 5200") }
        let pinnedBefore = try await s.withReader { try $0.scalarInt("SELECT count(*) FROM entity WHERE pinned = 1") }
        let protectedEdges = try await s.withReader { try $0.scalarInt("SELECT count(*) FROM edge WHERE subject IN (SELECT rid FROM entity WHERE pinned = 1) OR object IN (SELECT rid FROM entity WHERE pinned = 1)") }
        #expect((try await s.counts()).edges == 502_000)

        clock.advance(1_000)
        let t0 = ContinuousClock.now
        let report = try await s.evict()
        let took = ContinuousClock.now - t0
        let after = try await s.counts()
        print("GRAPH-EVICT 502000 edges -> \(after.edges) (cap 400000), entities removed \(report.entities), protected edges \(protectedEdges), took \(took)")
        #expect(after.edges <= 400_000 && report.entities > 0)
        #expect(try await s.withReader { try $0.scalarInt("SELECT count(*) FROM entity WHERE pinned = 1") } == pinnedBefore)
        let kept = try await s.withReader { try $0.scalarInt("SELECT count(*) FROM edge WHERE subject IN (SELECT rid FROM entity WHERE pinned = 1) OR object IN (SELECT rid FROM entity WHERE pinned = 1)") }
        #expect(kept == protectedEdges, "every edge of a pinned entity survived")
        #expect(try await s.withReader { try $0.scalarInt("PRAGMA foreign_key_check") } == 0)
        #expect(try await s.withReader { try $0.scalarInt("SELECT count(*) FROM fact WHERE edge NOT IN (SELECT rid FROM edge)") } == 0)
    }

    @Test func byteCapIsRespectedAndTheHardStopRefusesUnpinnedWrites() async throws {
        var limits = MusicGraphLimits.standard
        let (probe, pdir) = T.makeStore(); defer { T.cleanup(pdir) }
        try await GraphScaleFixture.build(probe, edges: 60_000)
        let full = try await probe.counts().bytes
        limits.targetBytes = full / 2
        let (s, dir) = T.makeStore(limits: limits); defer { T.cleanup(dir) }
        try await GraphScaleFixture.build(s, edges: 60_000)
        #expect(try await s.counts().bytes > limits.targetBytes)
        _ = try await s.evict()
        let after = try await s.counts().bytes
        print("GRAPH-EVICT bytes \(full) -> \(after) (target \(limits.targetBytes))")
        #expect(after <= limits.targetBytes)

        limits.hardStopBytes = 1
        let (h, hdir) = T.makeStore(limits: limits); defer { T.cleanup(hdir) }
        _ = try await h.counts()
        await #expect(throws: MusicGraphError.full) { try await h.upsert(T.recording("Song", uid: "p:1")) }
        // Pinning and cache bookkeeping are still allowed.
        try await h.withWriter { _ in }
    }

    @Test func staleEntitiesGoFirstAndOnlyWhenOverTheLimit() async throws {
        let clock = GraphTestClock()
        var limits = MusicGraphLimits.standard; limits.maxEdges = 150
        let (s, dir) = T.makeStore(clock: clock, limits: limits); defer { T.cleanup(dir) }
        func ring(_ tag: String) async throws -> [MusicEntityID] {
            let ids = try await s.upsert((0..<100).map { T.person("\(tag) \($0)", ids: [T.provider("\(tag):\($0)")]) }).map(\.id)
            _ = try await s.addEdges(ids.indices.map { MusicEdgeClaim(MusicEdge(subject: ids[$0], predicate: .collaboratedWith, object: ids[($0 + 1) % ids.count]), T.claim(MusicSourceID("jio"))) })
            return ids
        }
        let old = try await ring("old")
        clock.advance(100 * 86_400)
        let fresh = try await ring("fresh")
        #expect(try await s.counts().edges == 200)
        _ = try await s.evict()
        #expect(try await s.counts().edges == 100)
        for id in old { #expect(try await s.entity(id) == nil) }
        for id in fresh { #expect(try await s.entity(id) != nil) }
        // Under the limit: nothing more goes, however old.
        clock.advance(400 * 86_400)
        #expect(try await s.evict().entities == 0)
    }
}
