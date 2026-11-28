import Foundation
import Testing
@testable import REDDY

@MainActor @Suite("Round 14 fixes") struct Round14FixesTests {
    @Test func aFullLanguageNameIsLookedUpNotCutToTwoLetters() {
        #expect(MusicPersonReader.languageCode("malayalam") == "ml", "not \"ma\", which is Marathi's neighbour")
        #expect(MusicPersonReader.languageCode("kannada") == "kn")
        #expect(MusicPersonReader.languageCode("bengali") == "bn")
        #expect(MusicPersonReader.languageCode("te") == "te")
        #expect(MusicPersonReader.languageCode("hin") == "hi")
        #expect(MusicPersonReader.languageCode("zzzzzzzz") == nil, "a word that is no language is no language, not a wrong one")
    }

    @Test func aLanguageTileFindsItsCoverByTheEnglishNameWhateverTheAppLanguage() {
        let tile = MusicCategory(name: "తెలుగు", kind: .genre, target: .search("Telugu songs"), stableName: "Telugu")
        let list = [MusicGenreCoverPick.Candidate(title: "Telugu Hits", tracks: 50, cover: "https://img.example/t.jpg")]
        #expect(MusicGenreCoverPick.pick(list, category: tile) == "https://img.example/t.jpg")
    }

    @Test func aShelfThatLostSongsAndFellUnderTheMinimumIsDropped() {
        func item(_ n: Int) -> HomeItem { HomeItem.make(MusicTrack(id: "s\(n)", providerID: "p", title: "S\(n)", durationMs: 1000, artists: [])) }
        var feed = HomeFeed(seed: 1, composedAt: Date(), mode: .full)
        feed.sections = [HomeSection(id: "rediscover", kind: .rediscover, title: "Rediscover", reason: nil, items: [item(1), item(2), item(3)])]
        let out = HomeFeed.rendered(feed, trackBlocked: { $0.id == "s1" }, artistBlocked: { _ in false })
        #expect(out.sections.isEmpty, "two songs left of three is below the page minimum")
        let kept = HomeFeed.rendered(feed, trackBlocked: { _ in false }, artistBlocked: { _ in false })
        #expect(kept.sections.count == 1)
    }
}
