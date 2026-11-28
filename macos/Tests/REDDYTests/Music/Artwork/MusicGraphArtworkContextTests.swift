import Testing
import Foundation
#if canImport(REDDY)
@testable import REDDY
#else
@testable import ArtworkCore
#endif

@Suite("Artwork graph context")
struct MusicGraphArtworkContextTests {
    private struct World {
        var store: any MusicGraphStoring
        var film: MusicEntityID, album: MusicEntityID, person: MusicEntityID
    }

    private func world() async throws -> World {
        let store = ArtworkTestGraph.make()
        let film = try await store.upsert(MusicEntityDraft(kind: .film, name: "Master", year: 2021, externalIDs: [ExternalID(.tmdbMovie, "1")])).id
        let album = try await store.upsert(MusicEntityDraft(kind: .album, name: "Master (OST)", imageRef: "https://img.example/ost.jpg", externalIDs: [ExternalID(.mbReleaseGroup, "0de25d19-e99f-4059-887e-ac3572f2101a")])).id
        let person = try await store.upsert(MusicEntityDraft(kind: .person, name: "Anirudh Ravichander", externalIDs: [ExternalID(.imdbName, "nm1")])).id
        let p = MusicProvenance(source: .musicbrainz, evidence: [MusicProvenance.statedToken])
        _ = try await store.addEdge(MusicEdge(subject: album, predicate: .soundtrackOf, object: film), provenance: p)
        _ = try await store.addEdge(MusicEdge(subject: film, predicate: .composedBy, object: person, qualifier: MusicRole.musicDirector.rawValue), provenance: p)
        return World(store: store, film: film, album: album, person: person)
    }

    @Test func aFilmFindsItsSoundtrackAlbumAndAnAlbumItsStoredCover() async throws {
        let w = try await world()
        let ctx = MusicGraphArtworkContext(store: w.store)
        let rel = await ctx.related(to: MusicArtworkSubject(kind: .film, name: "Master", id: w.film))
        #expect(rel.map(\.label) == ["Master (OST)"])
        #expect(await ctx.storedAddress(for: MusicArtworkSubject(kind: .album, name: "x", id: w.album)) == "https://img.example/ost.jpg")
        #expect(await ctx.storedAddress(for: MusicArtworkSubject(kind: .film, name: "Master", id: w.film)) == nil)
    }

    @Test func aPersonLearnsJobsWorksAndIdsAndAFilmItsMusicDirector() async throws {
        let w = try await world()
        let ctx = MusicGraphArtworkContext(store: w.store)
        let person = await ctx.enrich(MusicArtworkSubject(kind: .person, name: "Anirudh Ravichander", id: w.person))
        #expect(person.roles.contains(.composer))
        #expect(person.works == ["Master"])
        #expect(person.externalID(.imdbName) == "nm1")
        let film = await ctx.enrich(MusicArtworkSubject(kind: .film, name: "Master", id: w.film))
        #expect(film.creator == "Anirudh Ravichander")
        #expect(film.externalID(.tmdbMovie) == "1")
    }

    @Test func aFilmWithNoPosterEndsWithItsSoundtrackCoverThroughTheWholeChain() async throws {
        let w = try await world()
        let log = CallLogShim()
        let none = FakeNoSource(id: .tmdb, log: log)
        let cache = MusicArtworkResolutionCache(file: nil)
        let r = MusicEntityArtworkResolver(sources: [none], graph: MusicGraphArtworkContext(store: w.store), cache: cache, gate: .open,
                                           context: MusicArtworkContext(transport: NullTransport(), tmdb: nil), probe: { _ in true })
        let got = await r.resolve(MusicArtworkSubject(kind: .film, name: "Master", id: w.film, year: 2021))
        #expect(got?.address == "https://img.example/ost.jpg")
        #expect(got?.source == .relation && got?.borrowedFrom == "Master (OST)")
        #expect(log.calls == 1)
    }
}

private final class CallLogShim: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func hit() { lock.lock(); n += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return n }
}
private struct FakeNoSource: MusicArtworkSource {
    var id: MusicArtworkSourceID; var log: CallLogShim
    var switchID: MusicSourceID? { nil }
    func applies(to kind: MusicEntityKind) -> Bool { true }
    func candidates(for subject: MusicArtworkSubject, context: MusicArtworkContext) async throws -> [MusicArtworkCandidate] { log.hit(); return [] }
}
private struct NullTransport: MusicMetadataTransport {
    func get(_ url: URL, query: [String: String], headers: [String: String]) async throws -> Data { throw MusicError.notFound }
}
