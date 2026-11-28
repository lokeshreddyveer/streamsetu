import Foundation
import Testing
@testable import REDDY

// The shuffle engine and queue after the shuffle audit: a Shuffle Play hears every track, restore keeps what was not heard, a restart keeps
// reshuffling each lap, the playing song's artist does not follow it, and the cheap lookahead stays true.

private func track(_ n: Int, artist: String? = nil, album: String? = nil, uid: String? = nil) -> MusicTrack {
    let a = artist ?? "artist\(n)"
    return MusicTrack(id: uid ?? "t\(n)", providerID: "p", title: "Song \(n)", durationMs: 200_000,
                      artists: [MusicArtistRef(id: "ar-\(a)", name: a)],
                      album: album.map { MusicAlbumRef(id: "al-\($0)", title: $0) })
}
private func tracks(_ n: Int) -> [MusicTrack] { (0..<n).map { track($0) } }
private let reverse: MusicQueue.Shuffler = { $0.reverse() }
private let keep: MusicQueue.Shuffler = { _ in }

private func started(_ list: [MusicTrack], at k: Int) -> MusicQueue {
    var q = MusicQueue()
    q.replace(with: list, startAt: k)
    return q
}

private func ids(_ q: MusicQueue) -> [String] { q.tracks.map(\.id) }

@Suite("Shuffle audit: a Shuffle Play hears every track") struct FreshShuffleTests {
    @Test func everyOtherRowIsStillToComeForAnyOpener() {
        let n = 12
        for k in [0, 5, n - 1] {
            var q = started(tracks(n), at: k)
            q.setShuffle(true, fresh: true, shuffler: reverse)
            #expect(q.shuffle && q.index == 0 && q.current?.track.id == "t\(k)")
            let upcoming = Set(q.entries.dropFirst().map(\.track.id))
            let expected = Set((0..<n).filter { $0 != k }.map { "t\($0)" })
            #expect(upcoming == expected, "opener \(k): rows before it must be upcoming too")
            #expect(q.count == n && q.rowsRemaining == n - 1)
        }
    }

    @Test func theNormalToggleStillTreatsRowsBeforeThePointerAsPlayed() {
        var q = started(tracks(8), at: 5)
        q.setShuffle(true, shuffler: reverse)
        #expect(Array(ids(q).prefix(6)) == ["t0", "t1", "t2", "t3", "t4", "t5"])
        #expect(q.rowsRemaining == 2)
    }

    @Test func playingThroughHearsEachTrackExactlyOnceWithTheRealEngine() {
        for k in [0, 7, 19] {
            var q = started(tracks(20), at: k)
            let lead = q.current?.track
            let engine = MusicShuffleEngine.shuffler(mode: .smart, seed: UInt64(k) + 1, lead: lead)
            q.setShuffle(true, fresh: true, shuffler: engine)
            var heard = [q.current!.track.id]
            while let e = q.advance(auto: true) { heard.append(e.track.id) }
            #expect(heard.count == 20 && Set(heard).count == 20, "opener \(k)")
            #expect(heard.first == "t\(k)")
        }
    }

    @Test func duplicateRowsAreAllKept() {
        var list = tracks(8)
        list.append(list[1])                                     // the same recording twice, on rows 1 and 8
        var q = started(list, at: 8)
        q.setShuffle(true, fresh: true, shuffler: reverse)
        #expect(q.count == 9 && q.rowsRemaining == 8)
        let twice = q.entries.filter { $0.track.uid == list[1].uid }.count
        #expect(twice == 2)
        q.setShuffle(false)
        #expect(q.count == 9 && q.entries.filter { $0.track.uid == list[1].uid }.count == 2)
    }

    @Test func playNextRowsStayPinnedAheadOfTheShuffledRest() {
        var q = MusicQueue()
        q.replace(with: tracks(3), startAt: 0)
        q.playNext([track(100)]); q.playNext([track(101)])
        q.replace(with: (10..<20).map { track($0) }, startAt: 6)   // the Play next rows are carried to the new list
        q.setShuffle(true, fresh: true, shuffler: reverse)
        #expect(q.current?.track.id == "t16")
        #expect(Array(ids(q).dropFirst().prefix(2)) == ["t100", "t101"])
        let rest = Set(ids(q).dropFirst(3))
        #expect(rest == Set((10..<20).filter { $0 != 16 }.map { "t\($0)" }))
    }

    @Test func restoringTheOrderKeepsTheOpenerPlayingAndTheRestInListOrder() {
        var q = started(tracks(8), at: 5)
        q.setShuffle(true, fresh: true, shuffler: reverse)
        q.setShuffle(false)
        #expect(q.current?.track.id == "t5" && !q.shuffle)
        #expect(ids(q) == ["t5", "t0", "t1", "t2", "t3", "t4", "t6", "t7"])
    }
}

@Suite("Shuffle audit: restore the original order") struct UnshuffleTests {
    @Test func skippedRowsComeBackInOriginalOrderAndPlayedRowsStayHistory() {
        let rotate: MusicQueue.Shuffler = { $0 = $0.count > 2 ? Array($0[2...] + $0[..<2]) : $0 }
        var q = started(tracks(6), at: 0)
        q.setShuffle(true, shuffler: rotate)                   // t0 t3 t4 t5 t1 t2
        q.advance(auto: true)                                  // t3 playing
        q.setShuffle(false)
        #expect(ids(q) == ["t0", "t3", "t1", "t2", "t4", "t5"])
        #expect(q.retreat()?.track.id == "t0")
    }

    @Test func legitimateDuplicateRowsSurvive() {
        var list = tracks(5)
        list.append(list[0])
        var q = started(list, at: 0)
        q.setShuffle(true, shuffler: reverse)
        q.setShuffle(false)
        #expect(q.count == 6 && ids(q) == ["t0", "t1", "t2", "t3", "t4", "t0"])
    }

    @Test func aPlayingSuggestionStillRestoresTheWholeSnapshot() {
        var q = started(tracks(8), at: 0)
        q.setShuffle(true, shuffler: keep)
        let pick = MusicAutoplayPick(track: track(900), reason: MusicAutoplayReason(.artist, "S"))
        let placed = q.insertSuggestions([pick], seed: 4)
        #expect(placed == 1)
        let at = q.entries.firstIndex { $0.suggested }!
        q.jump(to: at)
        #expect(q.current?.suggested == true)
        q.setShuffle(false)
        #expect(!q.shuffle)
        #expect(ids(q) == ["t0", "t900", "t1", "t2", "t3", "t4", "t5", "t6", "t7"])
    }

    @Test func playNextStillGoesRightAfterThePlayingRow() {
        var q = started(tracks(6), at: 0)
        q.setShuffle(true, shuffler: reverse)
        q.playNext([track(50)])
        q.advance(auto: true)                                  // t50 playing
        q.setShuffle(false)
        #expect(ids(q) == ["t0", "t50", "t1", "t2", "t3", "t4", "t5"])
    }

    @Test func movingARowToPlayNextKeepsItWithPlayNextAfterUnshuffle() {
        var q = started(tracks(6), at: 0)
        q.setShuffle(true, shuffler: keep)
        let moved = q.moveToPlayNext(from: 4)
        #expect(moved && q.preShuffle?.first { $0.track.id == "t4" }?.queued == true)
        q.setShuffle(false)
        #expect(ids(q) == ["t0", "t4", "t1", "t2", "t3", "t5"])
    }
}

@Suite("Shuffle audit: laps, jumps and the lookahead") struct LapAndJumpTests {
    @Test func aRestoredRepeatAllShuffleStillReshufflesEachLap() throws {
        var q = started(tracks(20), at: 0)
        q.repeatMode = .all
        q.setShuffle(true, shuffler: MusicShuffleEngine.shuffler(mode: .smart, seed: 3))
        let data = try JSONEncoder().encode(q.snapshot(position: 0))
        var back = MusicQueue(snapshot: try JSONDecoder().decode(MusicQueue.Snapshot.self, from: data))
        #expect(back.lapShuffler == nil && back.shuffle && back.repeatMode == .all)   // closures are not saved
        let lap1 = ids(back)
        for _ in 0..<19 { back.advance(auto: true) }
        let lastOfLapOne = back.current?.id
        let recent = Set(back.entries.suffix(4).map(\.id))
        let first = back.advance(auto: true)
        #expect(first != nil && first?.id != lastOfLapOne && !recent.contains(first?.id ?? UUID()))
        #expect(ids(back) != lap1, "the next lap must be a new order, not the same one again")
        #expect(Set(ids(back)) == Set(lap1))
    }

    @Test func aRowAddedOnTheLastRowKeepsLookaheadAndAdvanceInAgreement() {
        for seed in 1...6 {
            var q = started(tracks(10), at: 0)
            q.repeatMode = .all
            q.setShuffle(true, shuffler: keep)
            q.lapShuffler = MusicShuffleEngine.lapShuffler(mode: .smart, seed: UInt64(seed))
            for _ in 0..<9 { q.advance(auto: true) }
            q.remove(at: 0)                                    // an edit that leaves the pointer on the last row
            q.refreshPendingLap()
            let peek = q.peekNext()
            let first = q.advance(auto: true)
            #expect(peek != nil && first?.id == peek?.id, "seed \(seed)")
        }
    }

    @Test func jumpingForwardUnderShuffleKeepsSkippedRowsToCome() {
        var q = started(tracks(8), at: 0)
        q.setShuffle(true, shuffler: keep)
        q.jump(to: 4)
        #expect(ids(q) == ["t0", "t4", "t1", "t2", "t3", "t5", "t6", "t7"])
        #expect(q.current?.track.id == "t4" && q.retreat()?.track.id == "t0")
    }

    @Test func jumpingWithoutShuffleLeavesTheOrderAlone() {
        var q = started(tracks(8), at: 0)
        q.jump(to: 4)
        #expect(ids(q) == (0..<8).map { "t\($0)" } && q.current?.track.id == "t4")
    }

    @Test func nextLapNeverOpensWithTheSameRecordingEvenOnAnotherRow() {
        var list = tracks(10)
        list[9] = list[0]                                      // the same recording on the first and the last row
        let es = list.map { MusicQueue.Entry(track: $0) }
        let tail = Set(es.suffix(2).map(\.track.uid))
        for mode in [MusicShuffleMode.smart, .random] {
            for seed in 0..<30 {
                let next = MusicShuffleEngine.lap(es, mode: mode, seed: UInt64(seed))
                #expect(!tail.contains(next.first?.track.uid ?? ""), "\(mode) seed \(seed)")
            }
        }
    }
}

@Suite("Shuffle audit: the playing song leads the order") struct LeadTests {
    @Test func theFirstUpcomingRowsAvoidTheLeadsArtist() {
        let lead = track(0, artist: "Lead")
        var list: [MusicTrack] = []
        for i in 0..<30 { list.append(track(i + 1, artist: ["Lead", "B", "C"][i % 3])) }
        let es = list.map { MusicQueue.Entry(track: $0) }
        var withLead = 0, without = 0
        for seed in 0..<40 {
            let a = MusicShuffleEngine.order(es, mode: .smart, seed: UInt64(seed), lead: lead).prefix(2)
            let b = MusicShuffleEngine.order(es, mode: .smart, seed: UInt64(seed)).prefix(2)
            withLead += a.filter { $0.track.artists.first?.name == "Lead" }.count
            without += b.filter { $0.track.artists.first?.name == "Lead" }.count
        }
        #expect(withLead == 0)
        #expect(without > 0, "the same orders without the lead do start with its artist, so the check can fail")
    }

    @Test func theFirstUpcomingRowsAvoidTheLeadsAlbum() {
        let lead = track(0, artist: "x", album: "Album X")
        let list = (0..<24).map { track($0 + 1, album: $0 % 2 == 0 ? "Album X" : "Other \($0)") }
        let es = list.map { MusicQueue.Entry(track: $0) }
        for seed in 0..<40 {
            let first = MusicShuffleEngine.order(es, mode: .smart, seed: UInt64(seed), lead: lead).prefix(2)
            #expect(first.allSatisfy { $0.track.album?.title != "Album X" }, "seed \(seed)")
        }
    }

    @Test func aLeadSharedByEveryRowChangesNothingAndLosesNoRow() {
        let lead = track(0, artist: "Same")
        let es = (1...6).map { MusicQueue.Entry(track: track($0, artist: "Same")) }
        let out = MusicShuffleEngine.order(es, mode: .smart, seed: 3, lead: lead)
        #expect(Set(out.map(\.id)) == Set(es.map(\.id)))
    }

    @Test func orderingALargeQueueKeepsEveryRowOnce() {
        let list = (0..<3000).map { track($0, artist: "artist\($0 % 97)", album: "album\($0 % 311)") }
        let es = list.map { MusicQueue.Entry(track: $0) }
        for mode in [MusicShuffleMode.smart, .random] {
            let out = MusicShuffleEngine.order(es, mode: mode, seed: 5, lead: list[0])
            #expect(out.count == 3000 && Set(out.map(\.id)) == Set(es.map(\.id)))
        }
    }

    @Test func keysAreComputedOncePerCallAndTheScoreStillSeesPreviousPairs() {
        let es = (0..<8).map { MusicQueue.Entry(track: track($0)) }
        var sig = MusicShuffleSignals()
        sig.previousOrder = es.map(\.track.uid)
        let same = MusicShuffleEngine.score(es, signals: sig)
        let other = MusicShuffleEngine.score(Array(es.reversed()), signals: sig)
        #expect(other > same)
    }
}

@Suite("Shuffle audit: wiring in the player") struct PlayerWiringTests {
    private static func source(_ rel: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        return try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/" + rel), encoding: .utf8)
    }

    @Test func playUsesAFreshCycleAndRestoreRebuildsTheLapShuffler() throws {
        let p = try Self.source("Services/Music/Playback/MusicPlayer.swift")
        #expect(p.contains("fresh: true"))
        let restore = p.components(separatedBy: "private func restore()").dropFirst().first ?? ""
        #expect(restore.prefix(2500).contains("installLapShuffler()"))
        #expect(p.contains("setShuffleFlag(false); stickyShuffleWanted = false; stopAfterEntryID = nil; dropPreload(); sync()"), "clearing the queue also ends the shuffle and its marks")
    }
}
