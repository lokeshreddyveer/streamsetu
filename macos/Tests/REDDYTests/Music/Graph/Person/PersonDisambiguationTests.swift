import Foundation
import Testing
@testable import REDDY

@Suite struct PersonDisambiguationTests {
    @Test func twoDifferentPeopleOfOneNameStayTwoEntities() async throws {
        let w = try await PersonWorld.make()
        #expect(w.bakshiA != w.bakshiB)
        let a = try #require(try await w.store.entity(w.bakshiA)), b = try #require(try await w.store.entity(w.bakshiB))
        #expect(a.name == b.name && !a.provisional && !b.provisional)
        #expect(MusicPersonDisambiguation.line(for: a) == "Indian lyricist · 1930")
        #expect(MusicPersonDisambiguation.line(for: b) == "Indian cricketer")
    }

    @Test func rowAppearsOnlyForANameSearchRoute() async throws {
        let w = try await PersonWorld.make()
        let a = try #require(try await w.store.entity(w.bakshiA))
        let fromSearch = await MusicPersonDisambiguation.candidates(for: a, query: "anand bakshi", store: w.store)
        #expect(fromSearch.map(\.id) == [w.bakshiB] && fromSearch[0].line == "Indian cricketer")
        #expect(MusicPersonDisambiguation.shouldShowRow(fromSearch))
        let direct = await MusicPersonDisambiguation.candidates(for: a, query: nil, store: w.store)
        #expect(direct.isEmpty && !MusicPersonDisambiguation.shouldShowRow(direct))
        let blank = await MusicPersonDisambiguation.candidates(for: a, query: "  ", store: w.store)
        #expect(blank.isEmpty)
    }

    @Test func noRowWhenTheNameIsUniqueOrOnlySimilar() async throws {
        let w = try await PersonWorld.make()
        let raj = try #require(try await w.store.entity(w.raj))
        #expect(await MusicPersonDisambiguation.candidates(for: raj, query: "raj kapoor", store: w.store).isEmpty)
        // a different person whose name merely starts the same is not a "same name"
        _ = try await PersonWorld.person(w.store, "Raj Kapoor Junior", wikidata: "Q999")
        #expect(await MusicPersonDisambiguation.candidates(for: raj, query: "raj kapoor", store: w.store).isEmpty)
    }

    @Test func mergedEntityIsNotACandidate() async throws {
        let w = try await PersonWorld.make()
        let c = try await PersonWorld.person(w.store, "Anand Bakshi", wikidata: "Q209")
        _ = try await w.store.mergeEntities(winner: w.bakshiB, loser: c, byUser: true)
        let a = try #require(try await w.store.entity(w.bakshiA))
        let list = await MusicPersonDisambiguation.candidates(for: a, query: "anand bakshi", store: w.store)
        #expect(list.map(\.id) == [w.bakshiB])
    }

    @Test func lineFallsBackToYearsAndCountry() {
        func snap(year: Int?, end: Int?, country: String?) -> MusicEntitySnapshot {
            MusicEntitySnapshot(id: .derive(kind: .person, aliasKey: "d"), subkind: nil, name: "D", nameLatin: "d", lang: nil, year: year, yearEnd: end, country: country, durationMs: nil, imageRef: nil,
                                attrs: [:], provisional: false, state: .live, pinned: false, mergedInto: nil, createdAt: .distantPast, updatedAt: .distantPast)
        }
        #expect(MusicPersonDisambiguation.line(for: snap(year: 1930, end: 2002, country: "IN")) == "1930–2002 · IN")
        #expect(MusicPersonDisambiguation.line(for: snap(year: nil, end: nil, country: nil)) == nil)
    }
}
