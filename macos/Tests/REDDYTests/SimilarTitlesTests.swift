import Testing
import Foundation
@testable import REDDY

@Suite struct SimilarTitlesTests {
    private let source = PlaylistSource(name: "Test", type: .m3uRemote, baseURL: "http://example.com/p.m3u")

    private func cand(_ pid: String, _ title: String, year: Int? = 2020, rating: String? = "7.0", plot: String? = nil, genre: String? = nil, folder: String? = "F1") -> SimilarTitles.Candidate {
        var m = TestSupport.movie(source, pid, title, year: year)
        m.rating = rating; m.overview = plot; m.genre = genre; m.categoryID = folder
        return .init(item: .movie(m), rating: Double(rating ?? ""), plot: plot, genres: SimilarTitles.genreSet(genre), folder: folder)
    }

    @Test func stemDropsYearQualityLanguageAndSequelMarkers() {
        #expect(SimilarTitles.stem("Rolling Loud: The Movie (2026) (HDCAM)") == "rolling loud")
        #expect(SimilarTitles.stem("John Wick 3") == "john wick")
        #expect(SimilarTitles.stem("Sully (2016) (Tamil)") == "sully")
    }

    @Test func aSequelRanksFirst() {
        let target = cand("t", "John Wick (2014)", year: 2014, plot: "A retired hitman seeks vengeance for the killing of his dog.")
        let r = SimilarTitles.rank(target: target, extras: nil, pool: [cand("a", "Toy Story"), cand("b", "John Wick 2 (2017)", year: 2017), cand("c", "Notebook", plot: "Two lovers")])
        #expect(r.first?.item.title == "John Wick 2 (2017)")
        #expect(r.first?.reason == "Same franchise")
    }

    @Test func theSameTitleIsNeverASuggestion() {
        let target = cand("t", "Sully (2016)")
        let r = SimilarTitles.rank(target: target, extras: nil, pool: [cand("x", "Sully (2016)"), cand("y", "Sully 2")])
        #expect(!r.contains { $0.item.title == "Sully (2016)" })
    }

    @Test func aDubOfTheSameShowIsTheSameTitle() {
        let target = cand("t", "VisionQuest (Telugu)", folder: "TELUGU")
        let r = SimilarTitles.rank(target: target, extras: nil, pool: [cand("a", "VisionQuest (Tamil)", folder: "TAMIL"), cand("b", "VisionQuest 2 (Telugu)", folder: "TELUGU")])
        #expect(!r.contains { $0.item.title == "VisionQuest (Tamil)" })
        #expect(r.contains { $0.item.title == "VisionQuest 2 (Telugu)" })
    }

    @Test func sameGenreAndSharedCastCount() {
        let target = cand("t", "Inception", genre: "Action, Sci-Fi")
        var extras = ProviderExtras(); extras.directors = ["Christopher Nolan"]; extras.cast = ["Leonardo DiCaprio"]
        let pool = [cand("a", "Interstellar", genre: "Adventure, Sci-Fi"), cand("b", "Random Comedy", genre: "Comedy"), cand("c", "Heat", genre: "Action, Crime")]
        let r = SimilarTitles.rank(target: target, extras: extras, pool: pool)
        #expect(r.contains { $0.item.title == "Interstellar" && $0.reason == "Same genre" })
        #expect(r.first { $0.item.title == "Random Comedy" }?.reason == "From the same folder")     // a thin pool is topped up from the folder, after every real match
        #expect(r.last?.item.title == "Random Comedy")
    }

    @Test func similarStoryUsesRareWords() {
        let target = cand("t", "A", plot: "A detective hunts a serial killer through the foggy docks of London.")
        let r = SimilarTitles.rank(target: target, extras: nil, pool: [
            cand("a", "B", plot: "Detective chases a serial killer along the docks of Paris."),
            cand("b", "C", plot: "A baker opens a shop and falls in love with a customer."),
        ])
        #expect(r.first?.item.title == "B")
        #expect(r.first?.reason == "Similar story")
    }

    @Test func unrelatedFilmsThatShareAThemeOrAnArticleAreNotAFranchise() {
        let target = cand("t", "The Amazing Spider-Man (2012)", year: 2012)
        let pool = [cand("a", "The Amazing Bulk (2012)", year: 2012), cand("b", "The Amazing Colossal Man (1957)", year: 1957), cand("c", "The Amazing Spider-Man 2 (2014)", year: 2014)]
        #expect(SimilarTitles.franchise(target: target, pool: pool).map(\.title) == ["The Amazing Spider-Man (2012)", "The Amazing Spider-Man 2 (2014)"])
    }

    @Test func twoUnrelatedFilmsWithTheSameOneWordNameAreNotAFranchise() {
        #expect(SimilarTitles.franchise(target: cand("t", "Crash (2004)", year: 2004), pool: [cand("a", "Crash (1996)", year: 1996)]).isEmpty)
        #expect(SimilarTitles.franchise(target: cand("t", "Rocky II (1979)", year: 1979), pool: [cand("a", "Rocky (1976)", year: 1976)]).map(\.title) == ["Rocky (1976)", "Rocky II (1979)"])
    }

    @Test func everyTagShapeOfTheSameFilmIsOneFilm() {
        let target = cand("t", "John Wick (2014) (Telugu)", year: 2014)
        let pool = [cand("a", "John Wick (2014)[Tam, Tel, Hin, Kan, Eng]", year: 2014, rating: "7.4"), cand("b", "John Wick Chapter 1 - Keanu Reeves (2014)", year: 2014),
                    cand("c", "John Wick: Chapter 2 (2017)[Tam, Tel]", year: 2017), cand("d", "John Wick: Chapter 2 (2017) (Telugu)", year: 2017)]
        let result = SimilarTitles.franchise(target: target, pool: pool)
        #expect(result.map(\.year) == [2014, 2017])
        #expect(result.first?.id == target.item.id)           // the open film is the one shown for its year
    }

    @Test func aFranchiseIsListedInTheOrderTheFilmsCameOut() {
        let target = cand("t", "Spider-Man: Far From Home (2019)", year: 2019)
        let pool = [cand("a", "Spider-Man: No Way Home (2021)", year: 2021), cand("b", "Spider-Man: Homecoming (2017)", year: 2017), cand("c", "Toy Story (1995)", year: 1995)]
        #expect(SimilarTitles.franchise(target: target, pool: pool).map(\.year) == [2017, 2019, 2021])
    }
}
