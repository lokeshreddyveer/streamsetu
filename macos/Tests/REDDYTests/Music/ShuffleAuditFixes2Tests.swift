import Testing
@testable import REDDY

@Suite("Shuffle audit fixes, round 6") struct ShuffleAuditFixes2Tests {
    private func tracks(_ n: Int) -> [MusicTrack] {
        (0..<n).map { MusicTrack(id: "t\($0)", providerID: "p", title: "Song \($0)", durationMs: 200_000, artists: [MusicArtistRef(id: "a\($0 % 4)", name: "Artist \($0 % 4)")]) }
    }

    @Test func nextOnTheLastRowUnderRepeatOneStartsAShuffledLap() {
        var q = MusicQueue()
        q.replace(with: tracks(10), startAt: 0)
        q.repeatMode = .one
        q.setShuffle(true)
        q.lapShuffler = MusicShuffleEngine.lapShuffler(mode: .smart, seed: 7)
        for _ in 0..<9 { _ = q.advance(auto: false) }
        let lastTwo = Set(q.entries.suffix(2).map { $0.track.id })
        let next = q.advance(auto: false)?.track.id
        #expect(next != nil)
        #expect(!lastTwo.contains(next ?? ""))
    }

    @Test func aNewLapClearsSpentPlayNextMarks() {
        var q = MusicQueue()
        q.replace(with: tracks(6), startAt: 0)
        q.repeatMode = .all
        q.setShuffle(true)
        q.lapShuffler = MusicShuffleEngine.lapShuffler(mode: .smart, seed: 3)
        let extra = (0..<2).map { MusicTrack(id: "x\($0)", providerID: "p", title: "Extra \($0)", durationMs: 200_000, artists: [MusicArtistRef(id: "ax", name: "Artist X")]) }
        q.playNext([extra[0]])
        q.addToQueue([extra[1]])
        // The test is only meaningful when the marks exist before the lap turns over.
        let markedBefore = q.entries.contains { $0.queued || $0.queuedEnd }
        #expect(markedBefore)
        for _ in 0..<(q.entries.count + 1) { _ = q.advance(auto: true) }
        let marked = q.entries.contains { $0.queued || $0.queuedEnd }
        #expect(!marked)
    }

    @Test func fingerprintFollowsTheShuffleSnapshot() {
        var q = MusicQueue()
        q.replace(with: tracks(5), startAt: 0)
        let a = q.fingerprint()
        q.setShuffle(true)
        let b = q.fingerprint()
        #expect(a != b)
    }
}
