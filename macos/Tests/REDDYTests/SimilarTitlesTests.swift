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
}
