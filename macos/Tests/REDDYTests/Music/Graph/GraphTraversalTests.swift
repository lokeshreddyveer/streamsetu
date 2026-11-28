import Foundation
import Testing
@testable import REDDY

private typealias T = GraphTestSupport

@Suite("Graph bounded traversal") struct GraphTraversalTests {
    private func star(_ s: MusicGraphStore, hub: MusicEntityID, count: Int, tag: String) async throws -> [MusicEntityID] {
        let results = try await s.upsert((0..<count).map { T.person("\(tag) \($0)", ids: [T.provider("\(tag):\($0)")]) })
        let ids = results.map(\.id)
        _ = try await s.addEdges(ids.enumerated().map { i, p in
            MusicEdgeClaim(MusicEdge(subject: hub, predicate: .performedBy, object: p, role: .singer, order: i), T.claim(MusicSourceID("jio"), score: Float(100 - i) / 200))
        })
        return ids
    }

    @Test func fanOutIsCappedAndReported() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let hub = try await s.upsert(T.recording("Hub", uid: "h:1")).id
        _ = try await star(s, hub: hub, count: 100, tag: "p")
        let n = try await s.neighbours(of: hub, depth: 1, fanOut: 500)
        #expect(n.nodes.count == 40 && n.truncated)
        #expect(n.nodes.allSatisfy { $0.depth == 1 && $0.parent == hub && $0.direction == .outgoing && $0.predicate == .performedBy })
        // Highest confidence first.
        #expect(n.nodes.map(\.confidence) == n.nodes.map(\.confidence).sorted(by: >))
        let small = try await s.neighbours(of: hub, depth: 1, fanOut: 5)
        #expect(small.nodes.count == 5 && small.truncated)
    }

    @Test func depthIsCappedAtTwoAndBothDirectionsWalk() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let a = try await s.upsert(T.recording("A", uid: "t:a")).id
        let p1 = try await s.upsert(T.person("P1", ids: [T.provider("t:p1")])).id
        let b = try await s.upsert(T.recording("B", uid: "t:b")).id
        let p2 = try await s.upsert(T.person("P2", ids: [T.provider("t:p2")])).id
        let c = try await s.upsert(T.recording("C", uid: "t:c")).id
        let src = MusicSourceID("jio")
        // a -> p1 <- b -> p2 <- c
        for (x, p) in [(a, p1), (b, p1), (b, p2), (c, p2)] { _ = try await s.addEdge(MusicEdge(subject: x, predicate: .performedBy, object: p, role: .singer), provenance: T.claim(src)) }
        let n = try await s.neighbours(of: a, depth: 5, fanOut: 40)
        #expect(Set(n.nodes.map(\.id)) == [p1, b])
        #expect(n.nodes.first(where: { $0.id == b })?.direction == .incoming && n.nodes.first(where: { $0.id == b })?.depth == 2)
        #expect(n.truncated, "depth was clamped")
        #expect(try await s.neighbours(of: a, depth: 1, fanOut: 40).nodes.map(\.id) == [p1])
        #expect(try await s.neighbours(of: a, depth: 0, fanOut: 40).nodes.isEmpty)
        // A retracted edge is not walked.
        try await s.retractEdge(MusicEdgeKey(subject: b, predicate: .performedBy, object: p1, qualifier: "singer"))
        #expect(try await s.neighbours(of: a, depth: 2, fanOut: 40).nodes.map(\.id) == [p1])
        // Unknown root.
        #expect(try await s.neighbours(of: .derive(kind: .person, aliasKey: "none")).nodes.isEmpty)
    }

    @Test func nodeCapOnAWideTwoLevelGraph() async throws {
        let (s, dir) = T.makeStore(); defer { T.cleanup(dir) }
        let root = try await s.upsert(T.person("Root", ids: [T.provider("r:p")])).id
        let songs = try await s.upsert((0..<40).map { T.recording("Song \($0)", uid: "w:\($0)") }).map(\.id)
        _ = try await s.addEdges(songs.map { MusicEdgeClaim(MusicEdge(subject: $0, predicate: .performedBy, object: root, role: .singer), T.claim(MusicSourceID("jio"))) })
        for (i, song) in songs.enumerated() {
            let people = try await s.upsert((0..<40).map { T.person("Co \(i)-\($0)", ids: [T.provider("c:\(i)-\($0)")]) }).map(\.id)
            _ = try await s.addEdges(people.map { MusicEdgeClaim(MusicEdge(subject: song, predicate: .performedBy, object: $0, role: .singer), T.claim(MusicSourceID("jio"))) })
        }
        let n = try await s.neighbours(of: root, depth: 2, fanOut: 40)
        #expect(n.nodes.count == MusicTraversal.maxNodes && n.truncated)
        #expect(Set(n.nodes.map(\.id)).count == n.nodes.count)
    }

    @Test func timeBudgetStopsTheWalk() async throws {
        let (s, dir) = T.makeStore(budget: .zero); defer { T.cleanup(dir) }
        let hub = try await s.upsert(T.recording("Hub", uid: "h:1")).id
        _ = try await star(s, hub: hub, count: 10, tag: "p")
        let n = try await s.neighbours(of: hub, depth: 2, fanOut: 40)
        #expect(n.truncated && n.nodes.isEmpty)
    }
}
