import Foundation
import Testing
@testable import REDDY

@MainActor @Suite("Round 9 fixes") struct Round9FixesTests {
    @Test func theGuideKeepsAGroupAndFavoritesButNotOtherLiveTVRows() {
        #expect(LiveTVScreen.guideSelection(from: .folder("news")) == .folder("news"))
        #expect(LiveTVScreen.guideSelection(from: .shortcut(.favorites)) == .shortcut(.favorites))
        #expect(LiveTVScreen.guideSelection(from: .shortcut(.recentlyWatched)) == .shortcut(.allChannels))
    }

    @Test func aReleaseDayIsReadFromItsDigitsAndAMissingDayIsNotADate() {
        #expect(MusicAlbumPageLogic.fullDate("2023-03-24") != nil)
        #expect(MusicAlbumPageLogic.fullDate("2023-02-30") == nil, "a day that does not exist")
        #expect(MusicAlbumPageLogic.fullDate("2023-03") == nil, "a year and month stay out")
        #expect(MusicAlbumPageLogic.fullDate("2023") == nil)
    }

    @Test func aMatchedCopyLivesFromWhenItWasLastCheckedNotFromWhenItWasLastRead() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = MusicCanonicalStore(file: FileManager.default.temporaryDirectory.appendingPathComponent("canon-\(UUID().uuidString).json"), now: { clock })
        var e = MusicCanonicalTrack(key: "k|a", title: "T", artists: ["A"], durationMs: 200_000, seenOn: ["g:1"],
                                    twins: [MusicCanonicalTwin(providerID: "ytmusic", sourceID: "v", title: "T", artist: nil, score: 0.9)], checkedAt: clock, updatedAt: clock)
        e.key = MusicCatalogCanon.key(title: "T", artists: ["A"], versionTags: [])
        _ = store.put(e)
        clock = clock.addingTimeInterval(20 * 86_400)
        var again = e; again.seenOn = ["g:1", "g:2"]; again.checkedAt = e.checkedAt   // a later row seen on it: written again, but not re-verified
        _ = store.put(again)
        clock = clock.addingTimeInterval(20 * 86_400)   // 40 days after the check
        let probe = MusicTrack(id: "g:1", providerID: "g", title: "T", durationMs: 200_000, artists: [MusicArtistRef(id: "", name: "A")])
        #expect(store.canonical(for: probe) == nil, "a copy not verified for 30 days is asked again, however often it was seen")
    }
}
