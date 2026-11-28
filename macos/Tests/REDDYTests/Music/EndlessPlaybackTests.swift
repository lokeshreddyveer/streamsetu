import Testing
import Foundation
@testable import REDDY

private func song(_ n: Int, title: String? = nil, artistID: String = "a", artist: String = "Artist", provider: String = "p") -> MusicTrack {
    MusicTrack(id: "t\(n)", providerID: provider, title: title ?? "Song \(n)", durationMs: 200_000,
               artists: [MusicArtistRef(id: artistID, name: artist)])
}

private struct FixedRNG: RandomNumberGenerator {
    var state: UInt64 = 42
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

private func pick(_ cands: [MusicTrack], _ filter: MusicEndlessFilter) -> [MusicTrack] {
    var rng = FixedRNG()
    return filter.apply(cands, using: &rng)
}

@Suite("Endless playback")
struct EndlessPlaybackTests {
    @Test func dedupesByTitleAndArtist() {
        let c = [song(1, title: "Hello!", artistID: "a1", artist: "Adele"), song(2, title: "hello", artistID: "a2", artist: "ADELE"),
                 song(3, title: "Hello", artistID: "a3", artist: "Other")]
        #expect(Set(pick(c, MusicEndlessFilter()).map(\.id)) == ["t1", "t3"])
    }

    @Test func dropsSongsAlreadyQueued() {
        let queued = song(1, title: "Same", artist: "X")
        var f = MusicEndlessFilter()
        f.queuedUIDs = [queued.uid]; f.queuedKeys = [MusicEndlessSource.songKey(queued)]
        let out = pick([song(9, title: "Same", artist: "X"), song(2, artistID: "b", artist: "Y")], f)
        #expect(out.map(\.id) == ["t2"])
    }

    @Test func capsTwoPerArtist() {
        let c = (0..<6).map { song($0, artistID: "same", artist: "Same") } + [song(10, artistID: "other", artist: "Other")]
        let out = pick(c, MusicEndlessFilter())
        #expect(out.filter { $0.artists.first?.id == "same" }.count == 2)
        #expect(out.count == 3)
    }

    @Test func removesBlacklistedTracksAndArtists() {
        var f = MusicEndlessFilter()
        f.blocked = ["p:t1", "bad"]
        let out = pick([song(1, artistID: "x"), song(2, artistID: "bad"), song(3, artistID: "ok")], f)
        #expect(out.map(\.id) == ["t3"])
    }

    @Test func removesRecentlyPlayed() {
        var f = MusicEndlessFilter()
        f.recentUIDs = ["p:t1"]
        let out = pick([song(1, artistID: "x"), song(2, artistID: "y")], f)
        #expect(out.map(\.id) == ["t2"])
    }

    @Test func limitsBatchSize() {
        let c = (0..<40).map { song($0, artistID: "a\($0)", artist: "A\($0)") }
        #expect(pick(c, MusicEndlessFilter()).count == MusicEndlessSource.batchSize)
    }

    @Test func lightShuffleKeepsWindows() {
        let items = (0..<12).map { song($0, artistID: "a\($0)") }
        var rng = FixedRNG()
        let out = MusicEndlessSource.lightShuffle(items, window: 4, using: &rng)
        for w in 0..<3 {
            #expect(Set(out[(w * 4)..<(w * 4 + 4)].map(\.id)) == Set(items[(w * 4)..<(w * 4 + 4)].map(\.id)))
        }
    }

    @Test func fetchesOnlyOncePerTail() {
        var gate = MusicEndlessGate()
        let tail = UUID()
        #expect(gate.shouldFetch(enabled: true, repeatOff: true, isTail: true, tailKey: tail))
        gate.begin(tail)
        #expect(!gate.shouldFetch(enabled: true, repeatOff: true, isTail: true, tailKey: tail))
        gate.finish()
        #expect(!gate.shouldFetch(enabled: true, repeatOff: true, isTail: true, tailKey: tail))
        #expect(gate.shouldFetch(enabled: true, repeatOff: true, isTail: true, tailKey: UUID()))
        gate.reset()
        #expect(gate.shouldFetch(enabled: true, repeatOff: true, isTail: true, tailKey: tail))
    }

    @Test func gateRespectsSettingRepeatAndTail() {
        let gate = MusicEndlessGate()
        let k = UUID()
        #expect(!gate.shouldFetch(enabled: false, repeatOff: true, isTail: true, tailKey: k))
        #expect(!gate.shouldFetch(enabled: true, repeatOff: false, isTail: true, tailKey: k))
        #expect(!gate.shouldFetch(enabled: true, repeatOff: true, isTail: false, tailKey: k))
        #expect(!gate.shouldFetch(enabled: true, repeatOff: true, isTail: true, tailKey: nil))
    }

    @Test func suppressedTailIsNotFetched() {
        var gate = MusicEndlessGate()
        let k = UUID()
        gate.suppress(k)
        #expect(!gate.shouldFetch(enabled: true, repeatOff: true, isTail: true, tailKey: k))
    }

    @Test func autoEntriesSurviveSnapshotAndOldSnapshotsLoad() throws {
        var q = MusicQueue()
        q.replace(with: [song(0)], startAt: 0)
        q.append([song(1, artistID: "b"), song(2, artistID: "c")], auto: true)
        let data = try JSONEncoder().encode(q.snapshot(position: 3))
        let back = MusicQueue(snapshot: try JSONDecoder().decode(MusicQueue.Snapshot.self, from: data))
        #expect(back.entries.map(\.auto) == [false, true, true])

        let old = #"{"tracks":[],"shuffle":false,"repeatMode":"off","position":0}"#
        let snap = try JSONDecoder().decode(MusicQueue.Snapshot.self, from: Data(old.utf8))
        #expect(snap.autoIndices == nil)
    }

    @Test func clearAutoKeepsPlayingTrackAndOwnTracks() {
        var q = MusicQueue()
        q.replace(with: [song(0), song(1, artistID: "b")], startAt: 0)
        q.append([song(2, artistID: "c"), song(3, artistID: "d")], auto: true)
        q.clearAuto()
        #expect(q.tracks.map(\.id) == ["t0", "t1"])
        #expect(q.autoCount == 0)
    }

    @Test func settingsDefaultsAndOldFilesDecode() throws {
        let s = try JSONDecoder().decode(MusicSettings.self, from: Data("{}".utf8))
        #expect(s.endlessPlayback)
        #expect(s.tagDownloads)
    }
}
