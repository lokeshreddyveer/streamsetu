import Foundation
import Testing
@testable import REDDY

private typealias T = GraphTestSupport

/// The G1 performance fixture (50,000 entities, 202,000 edges, one busy person with 2,000 credits), rebuilt here so the recommender is measured on the
/// same shape of data the store was.
private enum RecScaleFixture {
    static let persons = 5_000, recordings = 30_000, releases = 10_000, films = 5_000

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
            try c.exec("""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
                INSERT INTO edge(subject, predicate, object, qual, confidence, status, credit_level, tomb, created_at, updated_at)
                SELECT \(p) + 1 + (i % \(r)), \(MusicPredicate.performedBy.rawValue), 1, 'hub' || i, 0.5 + (i % 50) / 100.0, 1, 3, 0, 1000, 1000 FROM n;
                INSERT INTO fact(edge, source, source_ref, retrieved_at, license, score, stance, override)
                SELECT rid, 'jiosaavn', '', 1000, 4, 0.6, 1, 0 FROM edge WHERE qual LIKE 'hub%';
                """)
        }
    }
    static func id(_ kind: MusicEntityKind, _ rid: Int) -> MusicEntityID { .derive(kind: kind, aliasKey: "fx:\(rid)") }
}

@Suite("Recommender scale", .serialized) struct RecommenderScaleTests {
    private func ms(_ block: () async throws -> Void) async rethrows -> Double {
        let t = ContinuousClock.now
        try await block()
        let d = ContinuousClock.now - t
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    @Test func fiftyThousandEntitiesTwoHundredThousandEdgesStayInsideTheBudgets() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        try await RecScaleFixture.build(s)
        let counting = CountingStore(s)
        let engine = MusicRecommender(store: counting, cache: MusicRecommendationCache())
        var ctx = MusicRecContext(affinity: .empty); ctx.useCache = false
        let seeds: [(String, MusicEntityID, Set<MusicEntityKind>)] = [
            ("busy person", RecScaleFixture.id(.person, 1), [.recording]),
            ("person", RecScaleFixture.id(.person, 77), [.recording, .person]),
            ("recording", RecScaleFixture.id(.recording, 5_000 + 123), [.recording, .album, .release, .film]),
            ("release", RecScaleFixture.id(.release, 35_000 + 9), [.release, .album, .recording]),
            ("film", RecScaleFixture.id(.film, 45_000 + 5), [.film, .release]),
        ]
        var worst = 0.0
        for (label, seed, kinds) in seeds {
            counting.resetCounts()
            var r = MusicRecResult.empty(seed)
            let took = try await ms { r = await engine.recommend(for: seed, kinds: kinds, limit: 20, context: ctx) }
            worst = max(worst, took)
            print(String(format: "REC-SCALE %@: %.1f ms, visited %d, items %d, truncated %@, edge reads %d, entity reads %d", label, took, r.visitedNodes, r.items.count, "\(r.truncated)", counting.edgeCalls, counting.entityCalls))
            #expect(counting.neighbourCalls == 1 && counting.lastDepth <= MusicTraversal.maxDepth && counting.lastFan <= MusicTraversal.maxFanOut, "\(label)")
            #expect(r.visitedNodes <= MusicTraversal.maxNodes, "\(label)")
            // One edge read per profiled node, one ring of at most 120 more, plus the seed: never a table scan.
            #expect(counting.edgeCalls <= MusicTraversal.maxNodes + ctx.maxRing + 1, "\(label)")
            #expect(r.items.count <= 20)
            #expect(zip(r.items, r.items.dropFirst()).allSatisfy { $0.band < $1.band || ($0.band == $1.band && $0.score >= $1.score) }, "\(label)")
            #expect(r.items.allSatisfy { $0.id != seed })
        }
        // The walk (40 ms) and the profile pass (40 ms) are each bounded; an unoptimised test build is allowed generous slack.
        #expect(worst < 600, "worst \(worst) ms")
        // A repeat is a cache hit with no graph reads.
        let engine2 = MusicRecommender(store: counting)
        var c2 = MusicRecContext(affinity: .empty); c2.useCache = true
        _ = await engine2.recommend(for: seeds[2].1, kinds: seeds[2].2, limit: 20, context: c2)
        counting.resetCounts()
        let again = await engine2.recommend(for: seeds[2].1, kinds: seeds[2].2, limit: 20, context: c2)
        #expect(again.fromCache && counting.edgeCalls == 0 && counting.entityCalls == 0)
    }

    @Test func busyPersonWithTwoThousandCreditsReturnsPromptlyAndTruncated() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        try await RecScaleFixture.build(s, edges: 60_000)
        let engine = MusicRecommender(store: s)
        var ctx = MusicRecContext(affinity: .empty); ctx.useCache = false
        var r = MusicRecResult.empty(RecScaleFixture.id(.person, 1))
        let took = try await ms { r = await engine.recommend(for: RecScaleFixture.id(.person, 1), kinds: [.recording], limit: 20, context: ctx) }
        print(String(format: "REC-SCALE hub 60k edges: %.1f ms, visited %d, items %d", took, r.visitedNodes, r.items.count))
        #expect(r.truncated && r.visitedNodes <= MusicTraversal.maxNodes && took < 600)
    }
}
