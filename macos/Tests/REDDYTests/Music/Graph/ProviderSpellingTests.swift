import Foundation
import Testing
@testable import REDDY

@Suite("Graph: one spelling for a provider id")
struct ProviderSpellingTests {
    @Test func bothSpellingsAreTheSameId() {
        #expect(ExternalID(.provider, "youtube-music:UC1") == ExternalID(.provider, "ytmusic:UC1"))
        #expect(ExternalID(.provider, "audius:7").value == "audius:7")
    }

    @Test func aGraphWithTwoEntriesForOneArtistIsMendedOnOpen() async throws {
        let (store, dir) = GraphTestSupport.makeStore()
        defer { GraphTestSupport.cleanup(dir) }
        let rich = try await store.upsert(GraphTestSupport.person("Some Artist", ids: [GraphTestSupport.provider("ytmusic:UCX")])).id
        let thin = try await store.upsert(GraphTestSupport.person("Some Artist ", ids: [GraphTestSupport.provider("ytmusic:UCY")])).id
        let song = try await store.upsert(GraphTestSupport.recording("Song", uid: "ytmusic:v1")).id
        _ = try await store.addEdge(MusicEdge(subject: song, predicate: .performedBy, object: rich), provenance: GraphTestSupport.mb)
        // The old spelling, as an earlier build wrote it.
        let c = try Connection(path: dir.appendingPathComponent("graph.sqlite").path, readOnly: false)
        try c.execute("UPDATE external_id SET value = 'youtube-music:UCX' WHERE value = 'ytmusic:UCY'")
        try c.execute("DELETE FROM meta WHERE k = 'provider_canon_v1'")
        _ = thin
        let reopened = MusicGraphStore(directory: dir)
        let found = try await reopened.resolveAlias(for: GraphTestSupport.provider("ytmusic:UCX"), kind: .person)
        let top = try await reopened.resolve(rich)
        #expect(found != nil)
        #expect(found == top)
    }
}
