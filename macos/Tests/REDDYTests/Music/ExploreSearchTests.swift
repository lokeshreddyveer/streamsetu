import Testing
import Foundation
@testable import REDDY

@Suite("Music Explore, Radio, Search and category layout") @MainActor struct ExploreSearchTests {
    private func song(_ id: String, _ title: String, artist: String, thumbs: [MusicThumbnail] = [], genres: [String] = []) -> MusicTrack {
        MusicTrack(id: id, providerID: "p", title: title, durationMs: 200_000, artists: [MusicArtistRef(id: artist, name: artist)], thumbnails: thumbs)
    }
    private func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("genre-art-" + UUID().uuidString) }

    // MARK: categories

    @Test("Language ordering (changed: there is no stock list; it is the device's languages with the history's first)")
    func languageOrdering() {
        let keys = ["english", "telugu", "hindi"]
        #expect(MusicLanguageDetect.ordered(keys: keys, preferring: []) == keys)
        let led = MusicLanguageDetect.ordered(keys: keys, preferring: ["hindi", "telugu", "klingon", "hindi"])
        #expect(Array(led.prefix(2)) == ["hindi", "telugu"])
        #expect(led.count == keys.count && Set(led) == Set(keys))
    }

    @Test("Scripts in titles rank the person's languages, most played first")
    func scriptRanking() {
        let texts = ["నువ్వే నువ్వే", "ఊహలు", "வணக்கம்", "Shape of You", "안녕"]
        #expect(MusicLanguageDetect.ranked(texts: texts) == ["telugu", "tamil", "korean"])
        #expect(MusicLanguageDetect.language(of: "Hello") == nil)
        #expect(MusicLanguageDetect.language(of: "हिंदी") == "hindi")
    }

    @Test("Categories are unique by kind and name and keep their order")
    func uniqueCategories() {
        let a = MusicCategory(name: "Chill", kind: .mood, target: .search("chill"))
        let b = MusicCategory(name: " chill ", kind: .mood, target: .search("chill"))
        let c = MusicCategory(name: "Chill", kind: .genre, target: .search("chill"))
        #expect(MusicCategory.unique([a, b, c]).map(\.id) == [a.id, c.id])
        #expect(MusicCategoryCatalogue.kind(forSection: "Moods & moments") == .mood)
        #expect(MusicCategoryCatalogue.kind(forSection: "Genres") == .genre)
    }

    // MARK: fallback

    @Test("The fallback tint is stable and spans the allowed turn")
    func fallbackStable() {
        for name in ["Rock", "Telugu", "Bollywood & Indian Pop", "ధ్యానం"] {
            let t = MusicCategoryFallback.hueTurn(for: name)
            #expect(t == MusicCategoryFallback.hueTurn(for: name))
            #expect(t >= -70 && t < 70)
        }
        #expect(MusicCategoryFallback.hueTurn(for: "Rock") != MusicCategoryFallback.hueTurn(for: "Jazz"))
        #expect(MusicCategoryFallback.glyph(for: .language) != MusicCategoryFallback.glyph(for: .genre))
    }

    // MARK: cache

    @Test("Cover cache: keyed by category and words, expires after the TTL, survives a reload, wipes")
    func cacheKeyingTTLWipe() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
        var cache = MusicGenreArtworkCache(directory: dir, now: { clock.now })
        let rock = MusicCategory(name: "Rock", kind: .genre, target: .search("rock"))
        let rockMood = MusicCategory(name: "Rock", kind: .mood, target: .search("rock"))
        #expect(MusicGenreArtworkCache.key(rock) != MusicGenreArtworkCache.key(rockMood))
        cache.set("https://example.org/a.jpg", for: MusicGenreArtworkCache.key(rock))
        cache.save()
        #expect(cache.url(for: MusicGenreArtworkCache.key(rock)) == "https://example.org/a.jpg")
        #expect(cache.url(for: MusicGenreArtworkCache.key(rockMood)) == nil)
        let reloaded = MusicGenreArtworkCache(directory: dir, now: { clock.now })
        #expect(reloaded.url(for: MusicGenreArtworkCache.key(rock)) != nil)
        clock.now = clock.now.addingTimeInterval(MusicGenreArtworkCache.ttl - 60)
        #expect(reloaded.url(for: MusicGenreArtworkCache.key(rock)) != nil)
        clock.now = clock.now.addingTimeInterval(120)
        #expect(reloaded.url(for: MusicGenreArtworkCache.key(rock)) == nil)
        var wiped = MusicGenreArtworkCache(directory: dir, now: { clock.now })
        wiped.set("https://example.org/b.jpg", for: "k"); wiped.save()
        wiped.clear()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(MusicGenreArtworkCache(directory: dir).entries.isEmpty)
        #expect(MusicGenreArtworkCache.ttl >= 3 * 24 * 3600)
    }

    @Test("The service answers from a fake source once, then from the cache, and a wipe forgets")
    func serviceWithFake() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeCoverSource(answer: "https://example.org/cover.jpg")
        let service = MusicGenreArtwork(directory: dir, sources: [fake])
        let c = MusicCategory(name: "Jazz", kind: .genre, target: .search("jazz"))
        #expect(service.cachedURL(for: c) == nil)
        #expect(await service.cover(for: c) == "https://example.org/cover.jpg")
        #expect(service.cachedURL(for: c) == "https://example.org/cover.jpg")
        #expect(await service.cover(for: c) == "https://example.org/cover.jpg")
        #expect(fake.calls == 1)
        service.wipe()
        #expect(service.cachedURL(for: c) == nil)
    }

    @Test("A cover search result is chosen by the category's own words and a real size")
    func coverPick() {
        let cat = MusicCategory(name: "Country & Americana", kind: .genre, target: .search("x"))
        let list: [MusicGenreCoverPick.Candidate] = [
            .init(title: "Sleep Token", tracks: 100, cover: "https://e.org/1.jpg"),
            .init(title: "Country Americana", tracks: 3, cover: "https://e.org/2.jpg"),
            .init(title: "Country/Americana", tracks: 366, cover: "https://e.org/3.jpg"),
            .init(title: "Country Americana", tracks: 1330, cover: "https://e.org/4.jpg"),
        ]
        #expect(MusicGenreCoverPick.pick(list, category: cat) == "https://e.org/4.jpg")
        #expect(MusicGenreCoverPick.pick([.init(title: "Unrelated", tracks: 99, cover: "https://e.org/5.jpg")], category: cat) == nil)
        #expect(MusicGenreCoverPick.pick([.init(title: "Country", tracks: 99, cover: "http://e.org/6.jpg")], category: cat) == nil)
    }

    // MARK: columns and labels

    @Test("Column count follows the width and the layout class, between 2 and 6")
    func columnCounts() {
        let cls = MusicLayoutClass.self
        #expect(MusicCategoryTileLayout.columns(width: 300, cls: cls.compact) == 2)
        #expect(MusicCategoryTileLayout.columns(width: 640, cls: cls.compact) == 3)
        #expect(MusicCategoryTileLayout.columns(width: 900, cls: cls.medium) == 4)
        #expect(MusicCategoryTileLayout.columns(width: 1100, cls: cls.expanded) == 5)
        #expect(MusicCategoryTileLayout.columns(width: 1300, cls: cls.wide) == 6)
        #expect(MusicCategoryTileLayout.columns(width: 3000, cls: cls.wide) == 6)
        for w in stride(from: CGFloat(200), through: 2000, by: 40) {
            let n = MusicCategoryTileLayout.columns(width: w, cls: MusicLayoutClass.resolve(width: w))
            #expect((2...6).contains(n))
            if n > 2 { #expect(MusicCategoryTileLayout.tileWidth(width: w, columns: n) >= MusicCategoryTileLayout.minTileWidth - 0.5) }
        }
        #expect(MusicCategoryTileLayout.columns(width: 0, cls: .wide) == 6)
    }

    @Test("Every category name fits two lines at the narrowest tile")
    func namesFitTwoLines() {
        let narrow = MusicCategoryTileLayout.minTileWidth
        let names = ["Bollywood & Indian Pop", "Country & Americana", "Mandopop & Cantopop", "Hip-Hop", "Classical", "Soundtracks",
                     "Electronic & Dance", "Romance", "Focus", "Workout", "Sleep", "Telugu", "మలయాళం", "हिन्दी", "한국어"]
        for n in names { #expect(MusicCategoryTileLayout.fitsTwoLines(n, tileWidth: narrow), "\(n)") }
        #expect(MusicCategoryTileLayout.lines(for: "A very long mood title that needs more room than a small tile", tileWidth: narrow) > 2)
        #expect(MusicCategoryTileLayout.aspect == 1.6)
    }

    // MARK: recents

    @Test("Recent searches: at most eight chips, newest first, each removable, cleared on request")
    func recentChips() {
        var r = MusicRecentSearches()
        for i in 1...12 { r.add("query \(i)") }
        #expect(r.items.count == MusicRecentSearches.limit)
        #expect(r.chips.count == 8 && MusicRecentSearches.chipLimit == 8)
        #expect(r.chips.first == "query 12")
        r.remove("query 12")
        #expect(!r.chips.contains("query 12") && r.chips.count == 8)
        r.clear()
        #expect(r.chips.isEmpty)
    }

    // MARK: search layout

    @Test("Search groups: songs are a list, other types one row under All and a grid under their chip")
    func searchStyles() {
        #expect(MusicSearchLayout.style(.songs, chosen: .all) == .list)
        #expect(MusicSearchLayout.style(.albums, chosen: .all) == .row)
        #expect(MusicSearchLayout.style(.albums, chosen: .albums) == .grid)
        #expect(MusicSearchLayout.visibleCount(total: 30, capacity: 5, kind: .all) == 5)
        #expect(MusicSearchLayout.visibleCount(total: 3, capacity: 5, kind: .all) == 3)
        #expect(MusicSearchLayout.visibleCount(total: 30, capacity: 5, kind: .albums) == 30)
        #expect(MusicSearchLayout.showsSeeAll(total: 6, shown: 5))
        #expect(!MusicSearchLayout.showsSeeAll(total: 5, shown: 5))
    }

    @Test("Search row capacity at 640, 900, 1100, 1400 and 2000 points, and with the context panel open")
    func searchCapacity() {
        func cap(_ window: CGFloat, panel: Bool = false) -> Int {
            let region = panel ? window - MusicLayoutGrid.contextPanelDefaultWidth : window
            let cls = MusicLayoutClass.resolve(width: region)
            let content = MusicLayoutGrid.contentWidth(available: region)
            return MusicSearchLayout.rowCapacity(width: content, cls: cls)
        }
        let widths: [CGFloat] = [640, 900, 1100, 1400, 2000]
        let caps = widths.map { cap($0) }
        #expect(caps.allSatisfy { (2...6).contains($0) })
        #expect(caps == caps.sorted())
        #expect(cap(1400, panel: true) <= cap(1400))
        #expect(MusicSearchLayout.sideBySide(.expanded) && MusicSearchLayout.sideBySide(.wide))
        #expect(!MusicSearchLayout.sideBySide(.medium) && !MusicSearchLayout.sideBySide(.compact))
        #expect(MusicSearchLayout.songLimit(.compact) <= MusicSearchLayout.songLimit(.wide))
    }

    // MARK: shelf fit

    @Test("A shelf shows arrows and Show all only when its cards overflow the row")
    func shelfFit() {
        #expect(MusicShelfFit.fits(content: 600, viewport: 800))
        #expect(MusicShelfFit.fits(content: 800, viewport: 800))
        #expect(!MusicShelfFit.fits(content: 1200, viewport: 800))
        #expect(MusicShelfFit.fits(content: 5000, viewport: 0), "unmeasured counts as fitting")
        #expect(!MusicShelfFit.showsArrows(fits: true, canPage: true))
        #expect(MusicShelfFit.showsArrows(fits: false, canPage: true))
        #expect(!MusicShelfFit.showsArrows(fits: false, canPage: false))
        #expect(!MusicShelfFit.showsShowAll(hasAll: true, fits: true))
        #expect(MusicShelfFit.showsShowAll(hasAll: true, fits: false))
        #expect(!MusicShelfFit.showsShowAll(hasAll: false, fits: false))
    }

    // MARK: category page

    @Test("A category section is split into songs, playlists, albums and artists in order")
    func categorySplit() {
        let t = song("1", "A", artist: "X")
        let p = MusicPlaylist(id: "p1", providerID: "p", name: "P")
        let al = MusicAlbum(id: "a1", providerID: "p", title: "Al")
        let split = MusicCategoryLayout.split([.playlist(p), .track(t), .album(al)])
        #expect(split.blocks == [.songs, .playlists, .albums])
        let s1 = MusicBrowseSection(id: "s1", title: "One", items: [.track(t)])
        let s2 = MusicBrowseSection(id: "s2", title: "Two", items: [.track(t), .playlist(p)])
        #expect(MusicCategoryLayout.allSongs([s1, s2]).count == 1)
        #expect(MusicCategoryLayout.firstPlaylist([s1, s2])?.id == "p1")
        let many = (0..<20).map { song("\($0)", "T\($0)", artist: "A") }
        #expect(MusicCategoryLayout.shownSongs(many, expanded: false).count == MusicCategoryLayout.songPreview)
        #expect(MusicCategoryLayout.shownSongs(many, expanded: true).count == 20)
        #expect(MusicCategoryLayout.showsMoreSongs(total: 20, expanded: false) && !MusicCategoryLayout.showsMoreSongs(total: 6, expanded: false))
        #expect(MusicCategoryLayout.clean([s1, MusicBrowseSection(id: "s1", title: "One", items: [.track(t)]), MusicBrowseSection(id: "e", title: "Empty", items: [])]).count == 1)
    }

    // MARK: explore composition

    @Test("Explore composition: charts from the country source, releases and hero from artwork, no repeated titles")
    func exploreComposition() {
        let art = [MusicThumbnail(url: "https://e.org/c.jpg", width: 300, height: 300)]
        let t = song("1", "Hit", artist: "A", thumbs: art)
        let al = MusicAlbum(id: "a", providerID: "p", title: "Fresh", thumbnails: art)
        let charts = MusicBrowseSection(id: "c", title: "Top Songs", items: [.track(t)])
        let news = MusicBrowseSection(id: "n", title: "New releases", items: [.album(al)])
        let dup = MusicBrowseSection(id: "d", title: "Top Songs", items: [.track(t)])
        let r = MusicExploreComposition.compose([
            .init(providerID: "x", regional: false, sections: [dup]),
            .init(providerID: "y", regional: true, sections: [charts, news]),
        ])
        #expect(r.charts?.id == "c")
        #expect(r.releases?.id == "n")
        #expect(r.heroIsNewRelease)
        #expect(r.more.isEmpty, "the duplicate title is not shown again")
        #expect(MusicExploreComposition.compose([]).hero == nil)
    }
}

private final class ClockBox: @unchecked Sendable {
    var now: Date
    init(_ d: Date) { now = d }
}

private final class FakeCoverSource: MusicGenreCoverSource, @unchecked Sendable {
    let answer: String
    private(set) var calls = 0
    init(answer: String) { self.answer = answer }
    func cover(for category: MusicCategory) async -> String? { calls += 1; return answer }
}
