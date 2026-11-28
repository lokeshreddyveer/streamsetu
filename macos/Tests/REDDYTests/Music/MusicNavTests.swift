import Testing
import Foundation
@testable import REDDY

@Suite("Music navigation and search state") struct MusicNavTests {
    private let album = MusicAlbum(id: "a1", providerID: "p", title: "Album")
    private let artist = MusicArtist(id: "r1", providerID: "p", name: "Artist")

    @Test func startsOnHomeWithNothingToGoBackTo() {
        let nav = MusicNav()
        #expect(nav.section == .home)
        #expect(nav.top == nil)
        #expect(!nav.canGoBack)
    }

    @Test func pushAndBackUnwindInOrder() {
        var nav = MusicNav()
        nav.push(.album(album)); nav.push(.artist(artist))
        #expect(nav.top == .artist(artist))
        #expect(nav.canGoBack)
        #expect(nav.back() == .artist(artist))
        #expect(nav.top == .album(album))
        #expect(nav.back() == .album(album))
        #expect(!nav.canGoBack)
        #expect(nav.back() == nil)
    }

    @Test func pushingTheSamePageTwiceDoesNotStackIt() {
        var nav = MusicNav()
        nav.push(.album(album)); nav.push(.album(album))
        #expect(nav.stack.count == 1)
    }

    @Test func choosingASectionClearsTheStack() {
        var nav = MusicNav()
        nav.push(.album(album))
        nav.select(.search)
        #expect(nav.section == .search)
        #expect(!nav.canGoBack)
    }

    @Test func everySectionHasATitleAndSymbol() {
        for s in MusicSection.allCases { #expect(!s.title.isEmpty && !s.symbol.isEmpty) }
        #expect(MusicSection.allCases.count == 10)
    }

    @Test func recentSearchesAreNewestFirstUniqueAndCapped() {
        var r = MusicRecentSearches()
        r.add("alpha"); r.add("beta"); r.add("ALPHA")
        #expect(r.items == ["ALPHA", "beta"])
        for i in 0..<20 { r.add("query \(i)") }
        #expect(r.items.count == MusicRecentSearches.limit)
        #expect(r.items.first == "query 19")
    }

    @Test func tooShortOrBlankSearchesAreNotRemembered() {
        var r = MusicRecentSearches()
        r.add("  "); r.add("a")
        #expect(r.items.isEmpty)
    }

    @Test func recentSearchesSaveLoadAndClear() throws {
        let suite = "music.test.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        var r = MusicRecentSearches(defaults: d)
        r.add("jazz"); r.save(to: d)
        #expect(MusicRecentSearches(defaults: d).items == ["jazz"])
        r.clear(); r.save(to: d)
        #expect(MusicRecentSearches(defaults: d).items.isEmpty)
    }

    @Test func searchChipsAskForTheRightTypes() {
        #expect(MusicSearchKind.all.types == [.track, .artist, .album, .playlist])
        #expect(MusicSearchKind.songs.types == [.track])
        #expect(!MusicSearchKind.all.pages)
        #expect(MusicSearchKind.albums.pages)
    }

    @Test func mergeAlternatesSourcesAndDropsRepeats() {
        let merged = MusicSearchMerge.interleave([["a1", "a2", "x"], ["b1", "x", "b2"]], key: { $0 })
        #expect(merged == ["a1", "b1", "a2", "x", "b2"])
        #expect(MusicSearchMerge.append(["a", "b"], ["b", "c"], key: { $0 }) == ["a", "b", "c"])
    }
}
