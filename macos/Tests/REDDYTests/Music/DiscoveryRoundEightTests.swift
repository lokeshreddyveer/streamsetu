import Foundation
import Testing
@testable import REDDY

// Regression tests for Listen Now, Explore and Recently Added (round eight).

@MainActor
@Suite("Discovery round eight") struct DiscoveryRoundEightTests {
    // MARK: Listen Now

    @Test func latinScriptNeverMakesAMoreShelf() {
        // English titles dominate the listening, so "latin" is one of the two strongest buckets: the shelf must still not be made.
        let english = HomePersona.catalogue("Song", HomePersona.english, perArtist: 8, prefix: "en")
        var heavy = HomePersona.heavy()
        heavy.history = ((0..<400).map { HomePersona.play(english[$0 % english.count], daysAgo: Double($0 % 60)) } + heavy.history).sorted { $0.at > $1.at }
        for seed in UInt64(1)...12 {
            for signals in [heavy, HomePersona.light(), HomePersona.oneArtist()] {
                let feed = HomeEngine.compose(signals, ctx: HomePersona.ctx(seed: seed))
                #expect(!feed.sections.contains { $0.id == "languageMix-latin" }, "seed \(seed)")
                #expect(!feed.sections.contains { $0.title.localizedCaseInsensitiveContains("Latin") }, "seed \(seed)")
            }
        }
    }

    @Test func aRelatedShelfWithOtherSeedsIsReplacedWhole() {
        func tile(_ n: String) -> MusicFillTile {
            MusicFillTile(entity: .provisional(kind: .person, name: n), kind: .singer, title: n, subtitle: "", imageRef: nil, role: .singer, year: nil)
        }
        let s0 = MusicEntityID.provisional(kind: .person, name: "s0"), s1 = MusicEntityID.provisional(kind: .person, name: "s1")
        var old = MusicFillShelf(id: "fill.related.byComposer", title: "Because you played A", reason: "r", scope: .related, tiles: [tile("one"), tile("two")])
        old.seeds = [s1]
        var new = MusicFillShelf(id: "fill.related.byComposer", title: "Because you played A", reason: "r", scope: .related, tiles: [tile("other")])
        new.seeds = [s0]
        let merged = MusicFillModel.merge(old: [old], new: [new])
        #expect(merged.first?.tiles.map(\.title) == ["other"], "another composer's tiles must not sit under the old song's words")
        #expect(merged.first?.seeds == [s0])
    }

    @Test func aPlaylistCardGoesWithItsHiddenOrBlockedArtistByIdOrName() {
        let artist = MusicArtistRef(id: "a1", name: "Some Singer")
        var item = HomeItem.make(MusicPlaylist(id: "pl", providerID: "p", name: "This Is Some Singer", thumbnails: []))
        item.artistKey = MusicText.normalize("Some Singer")
        item.seedArtists = [artist]
        // hidden by the artist's id (the song menu and the artist page store the id)
        #expect(MusicHiddenSet(tracks: [], artists: ["a1"]).hides(item))
        // hidden by the name (an artist a source gave no id)
        #expect(MusicHiddenSet(tracks: [], artists: [MusicText.normalize("Some Singer")]).hides(item))
        #expect(!MusicHiddenSet(tracks: [], artists: ["other"]).hides(item))
        // Never Play on the artist
        #expect(item.isBlocked(track: { _ in false }, artist: { $0.id == "a1" }))
        #expect(!item.isBlocked(track: { _ in false }, artist: { _ in false }))
    }

    // MARK: Explore

    @Test func anEmptyLazyShelfIsRememberedBrieflyAndAskedAgainOnTryAgain() {
        MusicExploreMemory.forget()
        let id = "chart-zz"
        let t0 = Date()
        #expect(!MusicExploreMemory.isKnownEmpty(id, retries: 0, now: t0))
        MusicExploreMemory.setShelfEmpty(id: id, retries: 0, now: t0)
        #expect(MusicExploreMemory.isKnownEmpty(id, retries: 0, now: t0.addingTimeInterval(30)))
        #expect(!MusicExploreMemory.isKnownEmpty(id, retries: 1, now: t0.addingTimeInterval(30)), "Try again asks every row once more")
        #expect(!MusicExploreMemory.isKnownEmpty(id, retries: 0, now: t0.addingTimeInterval(MusicExploreMemory.emptyLifetime + 1)), "a bad moment is not held for long")
        MusicExploreMemory.forget()
        #expect(!MusicExploreMemory.isKnownEmpty(id, retries: 0, now: t0))
    }

    @Test func countryNamesAreNamedInTheAppLanguageAndCached() {
        let first = MusicDiscoveryRegion.supported
        let second = MusicDiscoveryRegion.supported
        #expect(first.count > 200 && first.map(\.code) == second.map(\.code))
        #expect(MusicDiscoveryRegion.name("in") == first.first { $0.code == "in" }?.name)
    }

    // MARK: Recently Added

    @Test func whatAVisitShowsIsWrittenForTheNextVisitAndNeverRegroupsThisOne() throws {
        let suite = "recently-added-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let track = MusicTrack(id: "1", providerID: "p", title: "Song", durationMs: 1000, artists: [])
        let item = MusicBrowseItem.track(track)
        let now = Date()
        let snapshot = MusicRecentlyAddedVisit.snapshot(returning: false, defaults: defaults)   // the log this visit groups by
        MusicFirstSeenLog.recordShown([item], now: now, defaults: defaults)
        #expect(snapshot.bucket(item, now: now) == nil, "an item shown this visit is not 'found today' in this visit")
        #expect(MusicFirstSeenLog.load(defaults).bucket(item, now: now) == .today, "the next visit sees it")
        // Back from a page opened on top: the same snapshot, not a fresh read that now holds this visit's items
        let back = MusicRecentlyAddedVisit.snapshot(returning: true, defaults: defaults)
        #expect(back.bucket(item, now: now) == nil)
        // a new visit reads the disk again
        #expect(MusicRecentlyAddedVisit.snapshot(returning: false, defaults: defaults).bucket(item, now: now) == .today)
    }

    @Test func importedItemsGetAnAdditionDate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-dates-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = MusicLibrary(directory: dir.appendingPathComponent("a"), debounce: .milliseconds(10))
        let t = MusicTrack(id: "1", providerID: "audius", title: "T", durationMs: 1000, artists: [])
        source.toggleLike(t)
        let data = source.exportJSON()
        let target = MusicLibrary(directory: dir.appendingPathComponent("b"), debounce: .milliseconds(10))
        try target.importJSON(data)
        #expect(target.addedAt(.song, t.uid) != nil, "an imported song is dated, so it does not sort under Earlier")
    }

    @Test func aSavedPickKeepsItsSourceWhenOfferedFromTopPlayed() {
        let top = [MusicTopArtist(id: "x", name: "Singer", thumbnails: [], plays: 3, secs: 100, linkedID: "yt-1", providerID: "youtube")]
        let out = MusicTasteOptions.artists(chosen: [], followed: [], top: top, usable: { $0 == "youtube" })
        #expect(out.map(\.uid) == ["youtube:yt-1"])
        #expect(MusicTasteOptions.artists(chosen: [], followed: [], top: top, usable: { _ in false }).isEmpty, "a source switched off offers nothing")
    }

    @Test func recentLocalRowsKeepTheirEntryId() {
        #expect(MusicRecentlyAddedView.localEntryID("local:abc:def") == "abc:def")
    }
}
