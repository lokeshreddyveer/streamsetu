import Foundation
import Testing
@testable import REDDY

@Suite("Graph entity ids") struct EntityIDTests {
    @Test func sameProviderUIDAlwaysGivesTheSameID() {
        let a = MusicEntityID.provisional(kind: .release, providerUID: "jiosaavn:abc123")
        let b = MusicEntityID.provisional(kind: .release, providerUID: "jiosaavn:abc123")
        #expect(a == b)
        #expect(a.token.count == 13)
        #expect(a.rawValue.hasPrefix("release:"))
        #expect(a != MusicEntityID.provisional(kind: .recording, providerUID: "jiosaavn:abc123"))
        #expect(a != MusicEntityID.provisional(kind: .release, providerUID: "jiosaavn:abc124"))
    }

    @Test func stringAndCodableFormsRoundTrip() throws {
        let id = MusicEntityID.derive(kind: .person, aliasKey: "x")
        #expect(MusicEntityID(rawValue: id.rawValue) == id)
        #expect(MusicEntityID(routePath: id.routePath) == id)
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == "[\"\(id.rawValue)\"]")
        #expect(try JSONDecoder().decode([MusicEntityID].self, from: data) == [id])
        #expect(MusicEntityID(rawValue: "album:short") == nil)
        #expect(MusicEntityID(rawValue: "nonsense:7K2QXM4V9ZT3B") == nil)
        #expect(MusicEntityID(rawValue: "album7K2QXM4V9ZT3B") == nil)
        #expect(throws: (any Error).self) { try JSONDecoder().decode([MusicEntityID].self, from: Data("[\"bad\"]".utf8)) }
    }

    @Test func tokensUseOnlyTheBase32Alphabet() {
        for i in 0..<500 {
            let id = MusicEntityID.derive(kind: .recording, aliasKey: "k\(i)")
            #expect(id.token.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
        }
        // No collisions in a modest sample.
        #expect(Set((0..<5000).map { MusicEntityID.derive(kind: .recording, aliasKey: "k\($0)") }).count == 5000)
    }

    @Test func nameMintedIdsSeparateFilmsOfOneTitleByYear() {
        let a = MusicEntityID.provisional(kind: .film, name: "Awaara", year: 1951)
        let b = MusicEntityID.provisional(kind: .film, name: "Awaara", year: 2010)
        #expect(a != b)
        #expect(a == MusicEntityID.provisional(kind: .film, name: "AWAARA", year: 1951))
    }

    @Test func idDerivesFromTheFirstExternalIDOnly() {
        let d1 = MusicEntityDraft(kind: .recording, name: "Song", externalIDs: [ExternalID(.provider, "x:1"), ExternalID(.isrc, "INA000000001")])
        let d2 = MusicEntityDraft(kind: .recording, name: "Other title", externalIDs: [ExternalID(.provider, "x:1")])
        #expect(d1.derivedID == d2.derivedID)
        #expect(d1.derivedID == MusicEntityIndex.provisionalID(kind: .recording, providerUID: "x:1"))
    }

    @Test func storeFilesAProvisionalIDUnderTheSameID() async throws {
        let (store, dir) = GraphTestSupport.makeStore(); defer { GraphTestSupport.cleanup(dir) }
        let want = MusicEntityID.provisional(kind: .recording, providerUID: "jiosaavn:s1")
        let r = try await store.upsert(GraphTestSupport.recording("Awaara Hoon", uid: "jiosaavn:s1"))
        #expect(r.id == want && r.created)
        // A strong id that arrives later never changes the id.
        let r2 = try await store.upsert(GraphTestSupport.recording("Awaara Hoon", uid: "jiosaavn:s1", extra: [ExternalID(.mbid, "11111111-1111-1111-1111-111111111111")]))
        #expect(r2.id == want && !r2.created)
        #expect(try await store.resolveAlias(for: ExternalID(.mbid, "11111111-1111-1111-1111-111111111111")) == want)
    }
}
