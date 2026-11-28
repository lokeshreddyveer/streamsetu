import Testing
import Foundation
@testable import REDDY

/// One authoritative playback shuffle: every page's Shuffle goes through `playShuffled` (the engine orders once); no page shuffles a list itself.
@Suite("Shuffle Play goes through the engine once") struct ShufflePlayAdapterTests {
    private static func source(_ rel: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        return try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/" + rel), encoding: .utf8)
    }

    @Test func noPageShufflesAListItselfAnymore() throws {
        for file in ["Features/Music/MusicCategoryPage.swift", "Features/Music/MusicLibraryControls.swift", "Features/Music/MusicDetailPages.swift", "Features/Music/Home/MusicHomeHeader.swift",
                     "Features/Music/MusicListKit.swift", "Features/Music/Graph/Person/MusicPersonPlayback.swift", "Features/Music/MusicChartViews.swift", "Services/Music/Catalogue/MusicChartResolver.swift"] {
            let src = try Self.source(file)
            #expect(!src.contains(".shuffled()") && !src.contains(".shuffle()") && !src.contains("player.shuffle = true"), "\(file) must call hub.playShuffled, not shuffle by itself")
        }
    }

    @Test func everyShuffleButtonCallsTheOneEntryPoint() throws {
        for file in ["Features/Music/MusicCategoryPage.swift", "Features/Music/MusicLibraryControls.swift", "Features/Music/MusicDetailPages.swift", "Features/Music/Home/MusicHomeHeader.swift",
                     "Features/Music/MusicListKit.swift", "Features/Music/Graph/Person/MusicPersonPlayback.swift", "Features/Music/MusicChartViews.swift"] {
            #expect(try Self.source(file).contains("playShuffled"), "\(file)")
        }
        #expect(try Self.source("Features/Music/MusicHub.swift").contains("player.playShuffled("))
        #expect(try Self.source("Services/Music/Playback/MusicPlayer.swift").contains("shuffleOn: true"))
    }

    @Test func shufflePlayTurnsTheModeOnWithoutNeedingStickyShuffle() throws {
        let p = try Self.source("Services/Music/Playback/MusicPlayer.swift")
        #expect(p.contains("shuffleOn || (wasShuffle && prefs.stickyShuffle)"), "Shuffle Play is shuffled whatever the sticky preference says")
    }

    private func tracks(_ n: Int) -> [MusicTrack] { (0..<n).map { MusicTrack(id: "t\($0)", providerID: "p", title: "Song \($0)", durationMs: 0, artists: [MusicArtistRef(id: "", name: "Artist \($0 % 5)")]) } }

    @Test func theOpenerIsADeterministicDrawFromTheList() {
        let list = tracks(40)
        let a = MusicShuffleEngine.openingIndex(of: list, mode: .smart, seed: 42)
        #expect(a == MusicShuffleEngine.openingIndex(of: list, mode: .smart, seed: 42), "the same seed gives the same opener")
        #expect((0..<40).contains(a))
        #expect(MusicShuffleEngine.openingIndex(of: [list[0]], mode: .smart, seed: 1) == 0)
        let openers = Set((0..<200).map { MusicShuffleEngine.openingIndex(of: list, mode: .random, seed: UInt64($0)) })
        #expect(openers.count > 25, "random mode reaches most of the list, not a fixed favourite: \(openers.count)")
    }

    @Test func likedAndMorePlayedSongsOpenMoreOftenAndRecentOnesLess() {
        let list = tracks(10)
        var sig = MusicShuffleSignals()
        sig.favourites = [list[3].uid]
        sig.affinity[list[3].uid] = 1
        sig.lastPlayed[list[7].uid] = Date()
        var counts = [Int](repeating: 0, count: 10)
        for s in 0..<4000 { counts[MusicShuffleEngine.openingIndex(of: list, mode: .smart, signals: sig, seed: UInt64(s))] += 1 }
        #expect(counts[3] > counts[0] * 2 - 100, "a liked, often played song opens about three times as often: \(counts)")
        #expect(counts[7] * 2 < counts[0], "a song played in the last day opens about a quarter as often: \(counts)")
        #expect(counts.allSatisfy { $0 > 0 }, "nothing is unreachable")
    }
}
