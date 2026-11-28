import Foundation
import Testing
@testable import REDDY

@MainActor @Suite("Film page: editions, TMDB facts, About rows, tabs") struct FilmPageEditionsAndFactsTests {
    private func song(_ title: String, album: String, sung: Bool) -> MusicFilmSongItem {
        let singer = MusicFilmSingerRef(person: MusicEntityID.provisional(kind: .person, name: "Singer"), name: "Singer", imageRef: nil)
        return MusicFilmSongItem(recording: MusicEntityID.provisional(kind: .recording, name: title), title: title, durationMs: nil, imageRef: nil,
                                 album: MusicEntityID.provisional(kind: .album, name: album), albumName: album, dubLanguage: nil, disc: 1, position: 1,
                                 singers: sung ? [singer] : [], providerUID: nil, releaseProviderUID: nil, status: .inferred)
    }

    @Test func aDubComesOnlyFromTheDubRelationship() {
        #expect(MusicFilmEditionRules.classify(name: "Film (Original Soundtrack)", dubLanguage: "hi", songs: []) == .dubbed)
        #expect(MusicFilmEditionRules.classify(name: "Film (Hindi)", dubLanguage: nil, songs: []) == .original)
    }

    @Test func aScoreNeedsTheWordsAndUnsungSongs() {
        let instrumental = [song("Theme", album: "A", sung: false), song("Chase", album: "A", sung: false)]
        let sung = [song("Song 1", album: "A", sung: true), song("Song 2", album: "A", sung: true), song("Cue", album: "A", sung: false)]
        #expect(MusicFilmEditionRules.classify(name: "Film (Background Score)", dubLanguage: nil, songs: instrumental) == .score)
        #expect(MusicFilmEditionRules.classify(name: "Film (Songs and Score)", dubLanguage: nil, songs: sung) == .original)
        #expect(MusicFilmEditionRules.classify(name: "Film Scoreboard", dubLanguage: nil, songs: []) == .original)
        #expect(MusicFilmEditionRules.classify(name: "Film BGM", dubLanguage: nil, songs: []) == .original, "one signal is not enough")
        #expect(MusicFilmEditionRules.classify(name: "Film BGM", dubLanguage: nil, songs: [song("Cue", album: "A", sung: false)]) == .score)
    }

    @Test func extendedAndRemasteredUseWholeWordsOnly() {
        #expect(MusicFilmEditionRules.classify(name: "Film (Extended Version)", dubLanguage: nil, songs: []) == .extended)
        #expect(MusicFilmEditionRules.classify(name: "Film (Remastered)", dubLanguage: nil, songs: []) == .remastered)
        #expect(MusicFilmEditionRules.classify(name: "Unextendedly", dubLanguage: nil, songs: []) == .original)
    }

    private let tmdb = """
    {"backdrop_path":"/b.jpg","original_title":"సీతా రామం","release_date":"2022-08-05","runtime":163,"tagline":"A war, a letter, a love","genres":[{"id":1,"name":"Romance"},{"id":2,"name":"Drama"}],
     "vote_average":7.8,"vote_count":900,
     "release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"NR"}]},{"iso_3166_1":"IN","release_dates":[{"certification":""},{"certification":"U/A"}]}]},
     "videos":{"results":[{"site":"Vimeo","type":"Trailer","key":"v1"},{"site":"YouTube","type":"Clip","key":"c1"},{"site":"YouTube","type":"Trailer","official":true,"key":"abc123"}]}}
    """

    @Test func tmdbFactsReadTheFieldsThePageShows() {
        let f = TMDBGraphSource.facts(Data(tmdb.utf8), regions: ["IN"])   // the viewer's region first (given here), then the title's own
        #expect(f["runtimeMinutes"] == "163" && f["tagline"] == "A war, a letter, a love" && f["genres"] == "Romance|Drama")
        #expect(f["rating"] == "7.8" && f["ratingVotes"] == "900")
        #expect(f["certification"] == "U/A" && f["certificationRegion"] == "IN")
        #expect(f["trailerKey"] == "abc123")
        #expect(f["releaseDate"] == "2022-08-05")
        #expect(f["backdropURL"] == "https://image.tmdb.org/t/p/w1280/b.jpg")
    }

    @Test func missingFieldsStayAbsentNotInvented() {
        let f = TMDBGraphSource.facts(Data(#"{"runtime":0,"tagline":"","vote_average":9.9,"vote_count":2,"genres":[]}"#.utf8))
        #expect(f.isEmpty)
        #expect(TMDBGraphSource.facts(Data("not json".utf8)).isEmpty)
    }

    @Test func aboutRowsExistOnlyForStatedFacts() {
        var o = MusicFilmOverview(title: "T", year: 2022, languages: ["Telugu"], description: nil, synopsis: nil, synopsisSource: nil, seasons: nil, imageRef: nil, isSeries: false, attributions: [])
        let bare = MusicFilmAboutSection.rows(overview: o, entity: nil, isSeries: false).map(\.0)
        #expect(!bare.contains("Runtime") && !bare.contains("Rating") && !bare.contains("Certificate"))
        o.runtimeMinutes = 125; o.rating = "7.0"; o.ratingVotes = 50; o.certification = "U"; o.certificationRegion = "IN"
        let full = MusicFilmAboutSection.rows(overview: o, entity: nil, isSeries: false)
        #expect(full.contains { $0.0 == "Runtime" && $0.1.contains("2") && $0.1.contains("5") })
        #expect(full.contains { $0.0 == "Certificate" && $0.1 == "U (IN)" })
    }

    @Test func runtimeWording() {
        #expect(MusicFilmAboutSection.runtime(45).contains("45"))
        #expect(MusicFilmAboutSection.runtime(125).contains("2") && MusicFilmAboutSection.runtime(125).contains("5"))
    }
}
