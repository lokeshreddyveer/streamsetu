import Foundation
import Testing
@testable import REDDY

@Suite("Completeness: writing into the graph and reading it back") struct CompletenessGraphTests {
    typealias F = CompletenessFixtures

    private func world() async throws -> (graph: MusicInMemoryGraph, resolver: MusicEntityResolver, writer: MusicPersonWorkWriter, person: MusicEntityID) {
        let g = MusicInMemoryGraph()
        let r = MusicEntityResolver(store: g, sources: [])
        let p = try await g.upsert(MusicEntityDraft(kind: .person, name: "G. V. Prakash Kumar", externalIDs: [ExternalID(.canon, "person|gv")])).id
        return (g, r, MusicPersonWorkWriter(resolver: r), p)
    }

    private func film(_ i: Int, source: MusicSourceID = .wikidata) -> MusicPersonWork {
        MusicPersonWork(kind: .film, title: "Film number \(i)", year: 1990 + i, relations: [.composer], ids: [ExternalID(.wikidata, "Q\(1000 + i)")], source: source, sourceRef: "Q\(1000 + i)")
    }

    @Test func aPersonWithFortyFilmsShowsFortyFilms() async throws {
        let w = try await world()
        let res = try await w.writer.write((0..<40).map { film($0) }, person: w.person, personIsComposer: true)
        #expect(res.ids.count == 40 && Set(res.ids.values).count == 40)
        let d = try await MusicPersonReader(store: w.graph, person: w.person).build(.composer)
        let films = try #require(d.section(.films))
        #expect(films.entries.count == 40 && films.total == 40)
        #expect(films.entries.first?.year == 2029 && films.entries.last?.year == 1990, "newest first")
        #expect(!d.truncated)
    }

    @Test func aHundredAndFiftyFilmsAndTwoHundredAlbumsAreAllListedAndNothingIsTruncated() async throws {
        let w = try await world()
        _ = try await w.writer.write((0..<150).map { film($0) }, person: w.person, personIsComposer: true)
        let albums = (0..<200).map { MusicPersonWork(kind: .album, title: "Album number \($0)", year: 1900 + $0 / 2, relations: [.composer], ids: [ExternalID(.mbReleaseGroup, "rg\($0)")], source: .musicbrainz) }
        _ = try await w.writer.write(albums, person: w.person, personIsComposer: true)
        let d = try await MusicPersonReader(store: w.graph, person: w.person).build(.composer)
        #expect(d.section(.films)?.entries.count == 150 && d.section(.films)?.total == 150)
        #expect(d.section(.albums)?.entries.count == 200 && !d.truncated)
    }

    @Test func filmCreditsSurviveHundredsOfSongCredits() async throws {
        let w = try await world()
        // 650 provider songs credited to the person: more than the store's 500-edge cap on one read.
        var claims: [MusicEdgeClaim] = []
        for i in 0..<650 {
            let s = try await w.graph.upsert(MusicEntityDraft(kind: .recording, name: "Song \(i)", externalIDs: [ExternalID(.provider, "jiosaavn:s\(i)")])).id
            claims.append(MusicEdgeClaim(MusicEdge(subject: s, predicate: .composedBy, object: w.person, role: .composer, creditLevel: .song, order: 0),
                                         MusicProvenance(source: "jiosaavn", license: .providerCache, score: 0.99)))
        }
        _ = try await w.graph.addEdges(claims)
        _ = try await w.writer.write((0..<40).map { film($0) }, person: w.person, personIsComposer: true)
        let d = try await MusicPersonReader(store: w.graph, person: w.person).build(.composer)
        #expect(d.section(.films)?.entries.count == 40)
    }

    @Test func oneAlbumFromThreeSourcesIsOneEntityWithItsEditionsListed() async throws {
        let w = try await world()
        let wd = MusicPersonWork(kind: .album, title: "Vaathi (Original Motion Picture Soundtrack)", year: 2023, subkind: "soundtrack", relations: [.composer], ids: [ExternalID(.wikidata, "Q211")], source: .wikidata)
        let mb = MusicPersonWork(kind: .album, title: "Vaathi", year: 2023, subkind: "soundtrack", relations: [.performer], ids: [ExternalID(.mbReleaseGroup, "rg1")], source: .musicbrainz)
        let jio = providerAlbum("alb1", "Vaathi (Tamil)", year: 2023, type: "soundtrack")
        let itu = providerAlbum("999", "Vaathi (Original Motion Picture Soundtrack)", year: 2023, provider: "itunes")
        for batch in [[wd], [mb], [jio, itu]] { _ = try await w.writer.write(batch, person: w.person, personIsComposer: true) }
        let hits = try await w.graph.search("Vaathi", kinds: [.album], limit: 20)
        #expect(hits.count == 1, "one album concept, not one per source")
        let album = hits[0].id
        let editions = try await w.graph.edges(of: album, predicate: .editionOf, direction: .incoming, limit: 10)
        #expect(editions.count == 2 && editions.allSatisfy { $0.subject.kind == .release && $0.status != .verified }, "editions are joined, never merged; a provider's word is inferred")
        let ids = try await w.graph.externalIDs(of: album)
        #expect(ids.contains(ExternalID(.wikidata, "Q211")) && ids.contains(ExternalID(.mbReleaseGroup, "rg1")))
        let d = try await MusicPersonReader(store: w.graph, person: w.person).build(.composer)
        #expect((d.section(.soundtracks)?.entries.count ?? 0) + (d.section(.albums)?.entries.count ?? 0) == 1)
    }

    @Test func aProviderReleaseAlreadyInTheGraphBecomesAnEditionNotADuplicate() async throws {
        let w = try await world()
        let release = try await w.graph.upsert(MusicEntityDraft(kind: .release, name: "Asuran", year: 2019, externalIDs: [ExternalID(.provider, "jiosaavn:asu")], provisional: true)).id
        _ = try await w.graph.addEdge(MusicEdge(subject: release, predicate: .performedBy, object: w.person, role: .performer, creditLevel: .album),
                                      provenance: MusicProvenance(source: "jiosaavn", license: .providerCache, score: 0.6))
        let mb = MusicPersonWork(kind: .album, title: "Asuran (Original Motion Picture Soundtrack)", year: 2019, subkind: "soundtrack", relations: [.performer], ids: [ExternalID(.mbReleaseGroup, "rgA")], source: .musicbrainz)
        let jio = providerAlbum("asu", "Asuran", year: 2019)
        _ = try await w.writer.write([mb], person: w.person, personIsComposer: false)
        _ = try await w.writer.write([jio], person: w.person, personIsComposer: false)
        let up = try await w.graph.edges(of: release, predicate: .editionOf, direction: .outgoing, limit: 3)
        #expect(up.count == 1)
        let d = try await MusicPersonReader(store: w.graph, person: w.person).build(.singer)
        #expect(d.section(.albums)?.entries.count == 1, "the release stands for its album on the page")
        #expect(try await w.graph.entity(release)?.state == .live, "the edition entity is untouched")
    }

    @Test func variousArtistsIsNeverWrittenAsAnIdentity() async throws {
        let w = try await world()
        let alb = MusicPersonWork(kind: .album, title: "Hits", year: 2020, relations: [.performer], ids: [ExternalID(.mbReleaseGroup, "rgV")], source: .musicbrainz)
        var withVA = alb; withVA.artists = ["Various Artists"]
        _ = try await w.writer.write([withVA], person: w.person, personIsComposer: false)
        #expect((try await w.graph.search("Various Artists", kinds: [.person, .group], limit: 5)).isEmpty)
        // and the catalogue mapper drops it from the credited names
        var a = MusicAlbum(id: "1", providerID: "jiosaavn", title: "Hits"); a.artists = [MusicArtistRef(id: "x", name: "Various Artists"), MusicArtistRef(id: "y", name: "Anirudh")]
        #expect(MusicPersonCatalogue.work(from: a)?.artists == ["Anirudh"])
    }

    @Test func soundtrackLinkIsStatedByWikidataAndInferredOtherwise() async throws {
        let w = try await world()
        var f = MusicPersonWork(kind: .film, title: "Vaathi", year: 2023, relations: [.composer], ids: [ExternalID(.wikidata, "Q111")], source: .wikidata)
        f.soundtrackQID = "Q211"
        let a = MusicPersonWork(kind: .album, title: "Vaathi (Original Motion Picture Soundtrack)", year: 2023, subkind: "soundtrack", relations: [.composer], ids: [ExternalID(.wikidata, "Q211")], source: .wikidata)
        let jio = providerAlbum("v", "Vaathi (Tamil) (Original Motion Picture Soundtrack)", year: 2023, type: "soundtrack")
        let res = try await w.writer.write([f, a, jio], person: w.person, personIsComposer: true)
        let pairs = MusicPersonWorkWriter.soundtrackPairs(albums: [a, jio], films: [f])
        let n = try await w.writer.link(pairs, albumIDs: [res.ids[1]!, res.ids[2]!], filmIDs: [res.ids[0]!], albums: [a, jio])
        #expect(n >= 1)
        let links = try await w.graph.edges(of: res.ids[0]!, predicate: .soundtrackOf, direction: .incoming, limit: 5)
        #expect(links.count == 1, "the stated album and the matching provider album are one album concept")
        #expect(links[0].status == .verified)
    }

    @Test func aSecondRunWritesNothingNew() async throws {
        let w = try await world()
        let works = (0..<10).map { film($0) }
        _ = try await w.writer.write(works, person: w.person, personIsComposer: true)
        let before = try await w.graph.counts()
        _ = try await w.writer.write(works, person: w.person, personIsComposer: true)
        let after = try await w.graph.counts()
        #expect(before.entities == after.entities && before.edges == after.edges)
    }

    @Test func aFilmThatOtherSourcesKnowUnderAnotherYearIsNotDuplicated() async throws {
        let w = try await world()
        let wd = MusicPersonWork(kind: .film, title: "Vaathi", year: 2023, relations: [.composer], ids: [ExternalID(.wikidata, "Q111")], source: .wikidata)
        let imdb = MusicPersonWork(kind: .film, title: "Vaathi", year: 2022, relations: [.cast], ids: [ExternalID(.imdbTitle, "tt15327088")], source: .imdb)
        _ = try await w.writer.write([wd], person: w.person, personIsComposer: true)
        _ = try await w.writer.write([imdb], person: w.person, personIsComposer: true)
        #expect(try await w.graph.search("Vaathi", kinds: [.film], limit: 5).count == 1)
        let d = try await MusicPersonReader(store: w.graph, person: w.person).build(.composer)
        #expect(d.section(.films)?.entries.count == 1)
    }
}
