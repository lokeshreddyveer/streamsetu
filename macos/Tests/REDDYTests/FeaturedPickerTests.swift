import Testing
import Foundation
@testable import REDDY

@Suite struct FeaturedPickerTests {
    private let source = PlaylistSource(name: "Test", type: .m3uRemote, baseURL: "http://example.com/p.m3u")

    private func movie(_ n: Int, backdrop: Bool = true, title: String? = nil) -> LibraryItem {
        var m = TestSupport.movie(source, "m\(n)", title ?? "Movie \(n)")
        m.posterURL = "http://img/p\(n).jpg"
        if backdrop { m.backdropURL = "http://img/b\(n).jpg" }
        return .movie(m)
    }

    private func series(_ n: Int) -> LibraryItem {
        var s = TestSupport.series(source, "s\(n)", "Series \(n)")
        s.posterURL = "http://img/sp\(n).jpg"; s.backdropURL = "http://img/sb\(n).jpg"
        return .series(s)
    }

    @Test func theSameSeedGivesTheSameBannerAndAnotherSeedAnotherMix() {
        let movies = (0..<40).map { movie($0) }, shows = (0..<40).map { series($0) }
        let a = FeaturedPicker.pick(movies: movies, series: shows, count: 6, seed: 1).map(\.id)
        let again = FeaturedPicker.pick(movies: movies, series: shows, count: 6, seed: 1).map(\.id)
        let other = FeaturedPicker.pick(movies: movies, series: shows, count: 6, seed: 2).map(\.id)
        #expect(a == again)
        #expect(a != other)
        #expect(a.count == 6)
    }

    @Test func moviesAndSeriesTakeTurns() {
        let picked = FeaturedPicker.pick(movies: (0..<20).map { movie($0) }, series: (0..<20).map { series($0) }, count: 6, seed: 9)
        #expect(picked.map(\.isSeries) == [false, true, false, true, false, true])
    }

    @Test func aScreenOfOnlyMoviesGetsOnlyMovies() {
        let picked = FeaturedPicker.pick(movies: (0..<20).map { movie($0) }, series: [], count: 6, seed: 3)
        #expect(picked.count == 6 && picked.allSatisfy { !$0.isSeries })
    }

    @Test func wideBannerPicturesComeBeforeTallPostersAndCameraCopiesAreSkipped() {
        let wide = (0..<3).map { movie($0) }
        let tall = (10..<14).map { movie($0, backdrop: false) }
        let cam = movie(99, title: "Some Film (2026) (CAM)")
        let picked = FeaturedPicker.pick(movies: tall + [cam] + wide, series: [], count: 5, seed: 4)
        #expect(Set(picked.prefix(3).map(\.id)) == Set(wide.map(\.id)))
        #expect(!picked.contains { $0.title.contains("CAM") })
    }

    @Test func fewerTitlesThanAskedForJustGivesWhatThereIs() {
        #expect(FeaturedPicker.pick(movies: [movie(1)], series: [], count: 6, seed: 5).count == 1)
        #expect(FeaturedPicker.pick(movies: [], series: [], count: 6, seed: 5).isEmpty)
    }
}
