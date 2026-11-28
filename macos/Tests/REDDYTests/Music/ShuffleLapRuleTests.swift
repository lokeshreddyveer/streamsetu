import Testing
@testable import REDDY

@Suite("Shuffle lap rule over many seeds") struct ShuffleLapRuleTests {
    /// Ten songs by four artists (so the artist-spacing preferences have real work to do). A repeating shuffle's new lap must never open with the song that just ended or with anything
    /// from the end of the lap before, for any seed: the lap rule outranks the artist-spacing preference.
    @Test func aNewLapNeverOpensWithWhatWasJustHeardForAnySeed() {
        var bad: [Int] = []
        for seed in 1...400 {
            var q = MusicQueue()
            let ts = (0..<10).map { MusicTrack(id: "t\($0)", providerID: "p", title: "Song \($0)", durationMs: 200_000, artists: [MusicArtistRef(id: "a\($0 % 4)", name: "Artist \($0 % 4)")]) }
            q.replace(with: ts, startAt: 0)
            q.repeatMode = .all
            q.setShuffle(true)
            q.lapShuffler = MusicShuffleEngine.lapShuffler(mode: .smart, seed: UInt64(seed))
            for _ in 0..<9 { _ = q.advance(auto: true) }
            let just = q.current?.track.id
            let lastTwo = Set(q.entries.suffix(2).map { $0.track.id })
            let next = q.advance(auto: true)?.track.id
            if next == nil || next == just || lastTwo.contains(next ?? "") { bad.append(seed) }
        }
        #expect(bad.isEmpty, "seeds that opened the new lap with a just-heard song: \(bad.prefix(8))")
    }
}
