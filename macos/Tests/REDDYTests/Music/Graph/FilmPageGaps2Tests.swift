import Foundation
import Testing
@testable import REDDY

@Suite("Film page gaps 2") struct FilmPageGaps2Tests {
    @Test func licensedSongCreditsAreNotSoundCrew() {
        #expect(MusicFilmDepartment.of(job: "Soundtrack") == nil)
        #expect(MusicFilmDepartment.of(job: "Songs") == nil)
        #expect(MusicFilmDepartment.of(job: "Sound Designer") == .sound)
        #expect(MusicFilmDepartment.of(job: "Supervising Sound Editor") == .sound)
        #expect(MusicFilmDepartment.of(job: "Foley Artist") == .sound)
    }

    @Test func aSeriesReplyGivesSeasonsAndFacts() throws {
        let json = """
        {"id":7,"name":"Show","original_name":"Orig","first_air_date":"2019-05-03","number_of_seasons":4,"overview":" A story. ","status":"Ended","tagline":"Tag",
         "genres":[{"name":"Drama"}],"original_language":"en"}
        """
        let b = try #require(TMDBGraphSource.seriesBatch(Data(json.utf8), tmdbID: "7", now: Date(timeIntervalSince1970: 0)))
        let e = try #require(b.drafts.first?.entity)
        #expect(e.kind == .series)
        #expect(e.attrs["seasons"] == "4")
        #expect(e.attrs["synopsis"] == "A story.")
        #expect(e.attrs["releaseDate"] == "2019-05-03")
        #expect(e.year == 2019)
        #expect(e.externalIDs == [ExternalID(.tmdbTV, "7")])
    }

    @Test func aSeriesReplyWithoutNameGivesNothing() {
        #expect(TMDBGraphSource.seriesBatch(Data("{\"id\":1}".utf8), tmdbID: "1", now: Date()) == nil)
    }

    @Test func theCanonFallbackKeyMatchesTheBridge() {
        let info = MusicFilmInfo(title: "Some Film", year: 2001, source: .provider)
        let batch = MusicFilmGraphBridge.batch(from: info)
        let bridgeIDs = batch.drafts.first { $0.ref.kind == .film }?.entity.externalIDs ?? []
        #expect(bridgeIDs == MusicFilmPageRouting.writeIDs(for: info))
    }

    @Test func personIDsComeFromStrongIDsOnly() {
        let p = MusicFilmPerson(tmdbID: 5, wikidataID: "Q9", imdbID: "nm1", name: "X")
        #expect(MusicFilmPageRouting.personExternalIDs(p).map(\.scheme) == [.tmdbPerson, .wikidata, .imdbName])
        #expect(MusicFilmPageRouting.personExternalIDs(MusicFilmPerson(name: "Y")).isEmpty)
    }
}
