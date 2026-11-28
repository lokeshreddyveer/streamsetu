import Foundation
import Testing
@testable import REDDY

@Suite("Playback recovery")
struct PlaybackRecoveryTests {
    @MainActor @Test func webmOpusIsPickedOnlyWhenNothingNativeIsLeftAndTheBackendExists() {
        let webm = MusicStream(url: "https://a/x", codec: "opus", container: "webm", bitrate: 160)
        let m4a = MusicStream(url: "https://a/y", codec: "aac", container: "m4a", bitrate: 128)
        #expect(MusicStreamResolver.pick(from: [webm], quality: .high, opusAvailable: false) == nil)
        #expect(MusicStreamResolver.pick(from: [webm, m4a], quality: .high, opusAvailable: true) == m4a)
        #expect(MusicStreamResolver.isPlayable(container: "mp3", codec: "mp3"))
        #expect(!MusicStreamResolver.isPlayable(container: "ogg", codec: "vorbis"))
    }

    @MainActor @Test func theLogKeepsTheLastTwentyNewestFirst() {
        let log = MusicPlaybackLog()
        for i in 0..<25 { log.record(track: "T\(i)", provider: "P", reason: "r") }
        #expect(log.entries.count == 20)
        #expect(log.entries.first?.track == "T24")
        log.clear()
        #expect(log.entries.isEmpty)
    }

    @Test func aProviderWithThreeRecentFailuresIsAskedLast() {
        let t = ManualClock()
        let h = MusicProviderHealth(now: { t.now })
        for _ in 0..<2 { h.recordFailure("a") }
        #expect(h.ordered(["a", "b"], id: { $0 }) == ["a", "b"])
        h.recordFailure("a")
        #expect(h.ordered(["a", "b", "c"], id: { $0 }) == ["b", "c", "a"])
        t.now = t.now.addingTimeInterval(MusicProviderHealth.window + 1)
        #expect(!h.isDegraded("a"))
        h.recordFailure("a"); h.recordFailure("a"); h.recordFailure("a")
        h.recordSuccess("a")
        #expect(!h.isDegraded("a"))
    }

    @Test func skipMessageStatesTheReason() {
        let text = MusicPlaybackMessages.reason(error: MusicError.noPlayableSource("Song"), message: "", title: "Song")
        #expect(text == "This song could not be played from any source right now.")  // was "No playable source found for Song"
        #expect(MusicPlaybackMessages.reason(error: nil, message: "The operation could not be completed (Cannot Open)", title: "S") == "This audio format cannot be played")
    }

    private func track(_ id: String, _ provider: String, title: String = "One Name", artist: String = "Anirudh", ms: Int64 = 200_000, isrc: String? = nil, stream: Bool = false, pop: Int? = nil) -> MusicTrack {
        MusicTrack(id: id, providerID: provider, title: title, durationMs: ms, artists: [MusicArtistRef(id: "a", name: artist)], popularity: pop, isrc: isrc,
                   directStreams: stream ? [MusicStream(url: "https://s/\(id)", codec: "mp3", container: "mp3")] : nil)
    }

    @Test func duplicatesAcrossSourcesCollapseAndKeepTheOneWithAStream() {
        let a = track("1", "itunes", isrc: "X1")
        let b = track("2", "audius", isrc: "x1", stream: true)
        let c = track("3", "yt", ms: 202_500)
        let d = track("4", "yt", ms: 230_000)
        let merged = MusicSearchRanker.mergeTracks([[a, c], [b, d]], query: "one name")
        #expect(merged.count == 2)
        #expect(merged.contains { $0.uid == b.uid })
        #expect(merged.contains { $0.uid == d.uid })
    }

    @Test func exactMatchesRankFirstThenStreamsThenPopularity() {
        let other = track("1", "x", title: "One Name Remix Extended", pop: 5_000_000)
        let exact = track("2", "y", title: "One Name", ms: 100_000, pop: 10)
        let withStream = track("3", "z", title: "One Name", artist: "Cover Band", ms: 300_000, stream: true, pop: 10)
        let merged = MusicSearchRanker.mergeTracks([[other], [exact], [withStream]], query: "one name")
        #expect(merged.map(\.id) == ["3", "2", "1"])
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
