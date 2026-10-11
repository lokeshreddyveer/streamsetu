import Testing
import Foundation
@testable import REDDY

@Suite("Featured slideshow") @MainActor struct SlideshowTests {
    let src = PlaylistSource(name: "T", type: .m3uRemote, baseURL: "http://example.com/p.m3u")

    private func movie(_ n: Int, title: String? = nil, year: Int? = 2022, backdrop: String? = "https://img.example/b.jpg",
                       overview: String? = String(repeating: "A real synopsis. ", count: 4), rating: String? = "7.4") -> Movie {
        var m = TestSupport.movie(src, "m\(n)", title ?? "Film \(n)", year: year)
        m.backdropURL = backdrop; m.overview = overview; m.rating = rating; m.posterURL = "https://img.example/p\(n).jpg"; m.genre = "Drama"
        return m
    }

    @Test("Only titles with a real backdrop and synopsis become slides")
    func eligibility() {
        #expect(FeaturedPolicy.slide(.movie(movie(1))) != nil)
        #expect(FeaturedPolicy.slide(.movie(movie(2, backdrop: nil))) == nil)
        #expect(FeaturedPolicy.slide(.movie(movie(3, backdrop: "not a url"))) == nil)
        #expect(FeaturedPolicy.slide(.movie(movie(4, overview: "short"))) == nil)
        #expect(FeaturedPolicy.slide(.movie(movie(5, overview: nil))) == nil)
        #expect(FeaturedPolicy.slide(.movie(movie(6, rating: "0")))?.rating == nil, "a zero rating is never shown")
    }

    @Test("The same film listed in several languages appears once, and provider tags are stripped")
    func uniqueness() {
        let items = [movie(1, title: "Alien: Romulus (2024) (Tamil)"), movie(2, title: "Alien: Romulus (Hindi)"), movie(3)].map(LibraryItem.movie)
        let slides = FeaturedPolicy.slides(from: items)
        #expect(slides.count == 2)
        #expect(slides.first?.title == "Alien: Romulus")
    }

    @Test("A day gives a stable order; another day gives another")
    func dailyRotation() {
        let pool = (1...60).map { movie($0) }
        let a = FeaturedPolicy.moviePool(pool, day: "2026-10-10", scope: "x").map(\.id)
        let b = FeaturedPolicy.moviePool(pool, day: "2026-10-10", scope: "x").map(\.id)
        let c = FeaturedPolicy.moviePool(pool, day: "2026-10-11", scope: "x").map(\.id)
        #expect(a == b)
        #expect(a != c)
        #expect(Set(a) == Set(c))
    }

    @Test("Enough eligible titles give at least ten slides, never duplicated")
    func slideCount() {
        let items = (1...40).map { LibraryItem.movie(movie($0)) }
        let slides = FeaturedPolicy.slides(from: items)
        #expect(slides.count >= FeaturedPolicy.minimumSlides)
        #expect(Set(slides.map(\.id)).count == slides.count)
    }

    @Test("Autoplay runs only when it should")
    func controller() {
        let c = SlideshowController()
        c.configure(count: 3)
        #expect(c.shouldAutoplay)
        c.interacting = true; #expect(!c.shouldAutoplay); c.interacting = false
        c.windowActive = false; #expect(!c.shouldAutoplay); c.windowActive = true
        c.reduceMotion = true; #expect(!c.shouldAutoplay); c.reduceMotion = false
        c.togglePause(); #expect(!c.shouldAutoplay); c.togglePause()
        c.configure(count: 1); #expect(!c.shouldAutoplay, "one slide never advances")
    }

    @Test("Next and previous wrap, and a refresh keeps the position")
    func navigation() {
        let c = SlideshowController()
        c.configure(count: 3)
        c.previous(); #expect(c.index == 2)
        c.next(); #expect(c.index == 0)
        c.go(to: 1); c.configure(count: 3); #expect(c.index == 1)
        c.configure(count: 1); #expect(c.index == 0)
        c.configure(count: 0); c.next(); #expect(c.index == 0)
    }

    @Test("Banner height shrinks with the window and keeps room for the catalog")
    func bannerHeight() {
        for h in [680.0, 800, 900, 1117] {
            let b = FeaturedLayout.bannerHeight(contentHeight: h)
            #expect(b <= FeaturedLayout.maxHeight)
            #expect(h - FeaturedLayout.chrome - b >= FeaturedLayout.minCatalogHeight - 0.5 || b <= FeaturedLayout.minHeight * 0.75 + 0.5, "height \(h)")
        }
        #expect(FeaturedLayout.bannerHeight(contentHeight: 1117) == FeaturedLayout.maxHeight)
    }

    @Test("Sort options are offered only when the data supports them")
    func sortSupport() {
        let none = VODMetadataCoverage(total: 100, rated: 0, withYear: 0, withDuration: 0)
        let all = VODMetadataCoverage(total: 100, rated: 100, withYear: 100, withDuration: 100)
        #expect(!LibrarySort.topRated.isSupported(by: none, kind: .movie))
        #expect(LibrarySort.topRated.isSupported(by: all, kind: .movie))
        #expect(!LibrarySort.shortest.isSupported(by: all, kind: .series))
        #expect(LibrarySort.titleAZ.isSupported(by: none, kind: .movie))
    }

    @Test("Discover filters narrow and reorder rails and never touch the slideshow input")
    func discoverFilter() {
        let items = [movie(1, title: "Old Hit (Telugu)", year: 2010, rating: "9.0"), movie(2, title: "New Thing (Hindi)", year: 2025, rating: "6.0"), movie(3, title: "Mid (Telugu)", year: 2018, rating: "7.5")].map(LibraryItem.movie)
        let shelf = DiscoverShelf(id: "trending", title: "Trending", caption: "c", items: items)
        var f = DiscoverFilter()
        f.language = "Telugu"
        #expect(f.apply(to: [shelf]).first?.items.count == 2)
        f = DiscoverFilter(); f.mode = .recent
        #expect(f.apply(to: [shelf]).first?.items.first?.year == 2025)
        f.mode = .topRated
        #expect(f.apply(to: [shelf]).first?.items.first?.year == 2010)
        f.query = "zzz"; #expect(f.apply(to: [shelf]).isEmpty)
        #expect(DiscoverFilter.slideshowOrder([shelf]).count == 3, "filters are not an input to the slideshow")
        #expect(f.apply(to: [shelf]).first?.ranked != true)
    }
}
