import Testing
import Foundation
@testable import REDDY

/// Trending chips and search persistence, checked on synthetic charts of several personas (never anyone's real library).
@Suite("Search: trending chips, recent searches and persistence") struct SearchTrendingPersistenceTests {
    // MARK: synthetic charts

    private static func track(_ title: String, by artist: String, art: Bool = true) -> MusicBrowseItem {
        .track(MusicTrack(id: "t-" + title, providerID: "src", title: title, durationMs: 200_000, artists: [MusicArtistRef(id: "a-" + artist, name: artist)],
                          thumbnails: art ? [MusicThumbnail(url: "https://img.test/" + title, width: 300, height: 300)] : []))
    }
    private static func album(_ title: String, by artist: String) -> MusicBrowseItem {
        .album(MusicAlbum(id: "al-" + title, providerID: "src", title: title, artists: [MusicArtistRef(id: "a-" + artist, name: artist)],
                          thumbnails: [MusicThumbnail(url: "https://img.test/" + title, width: 300, height: 300)]))
    }
    private static func artist(_ name: String) -> MusicBrowseItem {
        .artist(MusicArtist(id: "a-" + name, providerID: "src", name: name))
    }
    /// A chart of `n` songs by `artists` rotating, named after the persona so nothing is shared between personas.
    private static func chart(_ persona: String, songs n: Int, artists: Int) -> MusicBrowseSection {
        MusicBrowseSection(id: persona + "-chart", title: persona + " chart", items: (0..<n).map { track("\(persona) song \($0)", by: "\(persona) artist \($0 % artists)") })
    }
    private static func titles(_ chips: [MusicTrendingSearches.Chip]) -> [String] { chips.map(\.title) }

    // MARK: trending

    @Test func chipsComeOnlyFromTheChartsGiven() {
        for persona in ["telugu", "hindi", "us"] {
            let sections = [Self.chart(persona, songs: 30, artists: 6),
                            MusicBrowseSection(id: "r", title: "new", items: (0..<5).map { Self.album("\(persona) album \($0)", by: "\(persona) artist \($0)") })]
            let allowed = Set(sections.flatMap(\.items).flatMap { item -> [String] in
                switch item {
                case .track(let t): [t.title] + t.artists.map(\.name)
                case .album(let a): [a.title]
                case .artist(let a): [a.name]
                case .playlist(let p): [p.name]
                }
            })
            let chips = MusicTrendingSearches.build(from: sections)
            #expect(!chips.isEmpty)
            #expect(chips.allSatisfy { allowed.contains($0.title) }, "a chip name that is not in the chart leaked in for \(persona)")
            #expect(chips.allSatisfy { $0.title.hasPrefix(persona) })
        }
    }

    @Test func emptyRegionGivesNoChipsAndNeverFallbackNames() {
        #expect(MusicTrendingSearches.build(from: []).isEmpty)
        #expect(MusicTrendingSearches.build(from: [MusicBrowseSection(id: "e", title: "empty", items: [])]).isEmpty)
        #expect(MusicTrendingSearches.build(from: [Self.chart("x", songs: 5, artists: 2)], limit: 0).isEmpty)
    }

    @Test func capIsRespectedAndOrderFollowsTheChart() {
        let chips = MusicTrendingSearches.build(from: [Self.chart("us", songs: 50, artists: 25)])
        #expect(chips.count == MusicTrendingSearches.limit)
        let songs = chips.filter { $0.kind == .song }.map(\.title)
        #expect(songs == songs.sorted { (Int($0.split(separator: " ").last!) ?? 0) < (Int($1.split(separator: " ").last!) ?? 0) })
        #expect(MusicTrendingSearches.build(from: [Self.chart("us", songs: 50, artists: 25)], limit: 5).count == 5)
    }

    @Test func kindsAreMixedAndRepeatsDropped() {
        let sections = [Self.chart("hindi", songs: 10, artists: 3),
                        MusicBrowseSection(id: "dup", title: "again", items: [Self.track("hindi song 0", by: "hindi artist 0"), Self.artist("hindi artist 1"), Self.album("hindi album", by: "hindi artist 2")])]
        let chips = MusicTrendingSearches.build(from: sections)
        let kinds = Set(chips.map(\.kind))
        #expect(kinds == [.song, .artist, .album])
        let keys = chips.map { MusicSearchRanker.normalise($0.title) }
        #expect(Set(keys).count == keys.count, "the same words appear twice")
        #expect(Set(chips.map(\.id)).count == chips.count)
    }

    @Test func songsFillTheBlockWhenThereAreNoArtistsOrAlbums() {
        // A chart row with no artist name gives no artist chip; the block is still full of songs.
        let items = (0..<20).map { i in MusicBrowseItem.track(MusicTrack(id: "\(i)", providerID: "p", title: "solo \(i)", durationMs: 1, artists: [])) }
        let chips = MusicTrendingSearches.build(from: [MusicBrowseSection(id: "s", title: "s", items: items)])
        #expect(chips.count == MusicTrendingSearches.limit && chips.allSatisfy { $0.kind == .song })
    }

    @Test func tapTargetsAndArtwork() {
        let chips = MusicTrendingSearches.build(from: [MusicBrowseSection(id: "m", title: "m", items: [Self.track("Song", by: "Singer"), Self.album("Record", by: "Singer")])])
        let song = chips.first { $0.kind == .song }, album = chips.first { $0.kind == .album }, artist = chips.first { $0.kind == .artist }
        #expect(song?.query == "Song Singer" && song?.entityID == nil && !(song?.thumbnails.isEmpty ?? true))
        #expect(album?.entityID == "al-Record" && album?.providerID == "src")
        #expect(artist?.entityID == "a-Singer" && artist?.query == "Singer")
    }

    @Test func chipsSurviveTheDiskCacheRoundTrip() throws {
        let chips = MusicTrendingSearches.build(from: [Self.chart("telugu", songs: 12, artists: 4)])
        let back = try JSONDecoder().decode([MusicTrendingSearches.Chip].self, from: JSONEncoder().encode(chips))
        #expect(back == chips)
        #expect(MusicTrendingSearches.cacheKey(region: "in") != MusicTrendingSearches.cacheKey(region: "us"))
        #expect(MusicTrendingSearches.cacheKey(region: "") != MusicTrendingSearches.cacheKey(region: "in"))
    }

    // MARK: recent searches

    @Test func recentsAreNewestFirstDedupedRemovableAndClearable() {
        var r = MusicRecentSearches()
        r.add("alpha"); r.add("beta"); r.add("ALPHA"); r.add("a")
        #expect(r.items == ["ALPHA", "beta"])
        r.remove("beta"); #expect(r.items == ["ALPHA"])
        for i in 0..<30 { r.add("query \(i)") }
        #expect(r.items.count == MusicRecentSearches.limit && r.chips.count == MusicRecentSearches.chipLimit && r.items.first == "query 29")
        r.clear(); #expect(r.items.isEmpty)
    }

    // MARK: persistence

    @Test func restoreOnlyWithin24HoursOfLastUse() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(MusicSearchPersistence.shouldRestore(savedAt: t0, now: t0))
        #expect(MusicSearchPersistence.shouldRestore(savedAt: t0, now: t0.addingTimeInterval(23 * 3_600)))
        #expect(MusicSearchPersistence.shouldRestore(savedAt: t0, now: t0.addingTimeInterval(24 * 3_600)))
        #expect(!MusicSearchPersistence.shouldRestore(savedAt: t0, now: t0.addingTimeInterval(24 * 3_600 + 1)))
        #expect(!MusicSearchPersistence.shouldRestore(savedAt: t0, now: t0.addingTimeInterval(-3_600)))   // a save from the future is not trusted
    }

    @Test func decisionsRespectGatedExpiredAndAFieldThatAlreadyHasWords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = MusicSearchPersistence.state(query: "  some words ", kind: "songs", scope: "everything", now: now.addingTimeInterval(-3_600))
        #expect(saved?.query == "some words")
        #expect(MusicSearchPersistence.decide(saved: saved, gated: false, currentQuery: "", now: now) == .restore(saved!))
        #expect(MusicSearchPersistence.decide(saved: saved, gated: true, currentQuery: "", now: now) == .gated)
        #expect(MusicSearchPersistence.decide(saved: saved, gated: false, currentQuery: "typed", now: now) == .fieldNotEmpty)
        #expect(MusicSearchPersistence.decide(saved: nil, gated: false, currentQuery: "", now: now) == .nothingSaved)
        #expect(MusicSearchPersistence.decide(saved: saved, gated: false, currentQuery: "", now: now.addingTimeInterval(25 * 3_600)) == .expired)
        #expect(MusicSearchPersistence.state(query: "   ", kind: "all", scope: "everything", now: now) == nil)
    }

    @Test func storeSavesLoadsAndClears() throws {
        let suite = "SearchPersistenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MusicSearchPersistenceStore(defaults: defaults)
        let now = Date()
        #expect(store.load() == nil)
        store.save(MusicSearchPersistence.state(query: "words", kind: "albums", scope: "library", now: now))
        #expect(store.load()?.query == "words" && store.load()?.kind == "albums" && store.load()?.scope == "library")
        // blank words (an explicit Clear) forget the search
        store.save(MusicSearchPersistence.state(query: "", kind: "all", scope: "everything", now: now))
        #expect(store.load() == nil)
        store.save(MusicSearchPersistence.state(query: "again", kind: "all", scope: "everything", now: now))
        store.clear()
        #expect(store.load() == nil)
        #expect(MusicDefaultsKeys.activity.contains(MusicSearchPersistenceStore.key))
    }
}
