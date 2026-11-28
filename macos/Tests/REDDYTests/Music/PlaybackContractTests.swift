import Foundation
import Testing
@testable import REDDY

/// The playback contract, one suite per expectation of a music app: what a person expects of the player, checked on the rules and state machines under it, for any songs, any
/// length of queue and any language. The parts that need a real audio device (the sound itself) are exercised in the live checks.
private func song(_ n: Int, ms: Int64 = 200_000, title: String? = nil) -> MusicTrack {
    MusicTrack(id: "t\(n)", providerID: "p", title: title ?? "Song \(n)", durationMs: ms, artists: [MusicArtistRef(id: "a\(n % 4)", name: "Artist \(n % 4)")])
}
private func songs(_ n: Int) -> [MusicTrack] { (0..<n).map { song($0) } }
private func queue(_ n: Int, start: Int = 0) -> MusicQueue { var q = MusicQueue(); q.replace(with: songs(n), startAt: start); return q }

@MainActor
private final class Player: MusicSleepPlayback {
    var isPlaying = true, isBuffering = false
    var volume: Float = 0.8
    var position: TimeInterval = 0, duration: TimeInterval = 200
    var currentUID: String? = "p:t0"
    var paused = 0
    func pause() { paused += 1; isPlaying = false }
}
@MainActor private final class Clock { var t = Date(timeIntervalSince1970: 2_000_000); func advance(_ s: TimeInterval) { t = t.addingTimeInterval(s) } }

// 1. Instant playback
@Suite("Playback 1: instant playback") struct InstantPlaybackContract {
    @Test func theStartBufferIsShortAndRelaxesOnceMusicIsFlowing() {
        #expect(MusicFastStart.startBufferSeconds <= 3)
        #expect(!MusicFastStart.shouldRelax(playedSeconds: 0.2, isWaiting: false))
        #expect(MusicFastStart.shouldRelax(playedSeconds: MusicFastStart.relaxAfter, isWaiting: false))
        #expect(MusicFastStart.shouldRelax(playedSeconds: 1, isWaiting: true))      // a stall after real playback widens the buffer at once
    }
    @Test func playingAQueueRowPointsAtThatSongWithoutTouchingTheRest() {
        var q = queue(50)
        q.jump(to: 31)
        #expect(q.current?.track.id == "t31" && q.count == 50)
    }
}

// 2. Play / pause
@Suite("Playback 2: play and pause") @MainActor struct PlayPauseContract {
    @Test func aPausedPlayerStaysPausedAndTheTimerDoesNotResumeIt() {
        let clock = Clock(), p = Player()
        let timer = MusicSleepTimer(player: p, now: { clock.t }, autoTick: false)
        timer.start(.minutes(15))
        p.isPlaying = false
        timer.tick(); timer.tick()                       // two quiet ticks: the person paused by hand
        #expect(!timer.isRunning && p.paused == 0)
    }
}

// 3. Next / previous
@Suite("Playback 3: next and previous") struct NextPreviousContract {
    @Test func nextAndPreviousWalkTheQueueInOrderAndStopAtTheEnds() {
        var q = queue(5)
        for i in 1..<5 { #expect(q.advance(auto: false)?.track.id == "t\(i)") }
        #expect(q.advance(auto: true) == nil)             // the end of the queue with repeat off
        #expect(q.current?.track.id == "t4")
        for i in stride(from: 3, through: 0, by: -1) { #expect(q.retreat()?.track.id == "t\(i)") }
        #expect(q.retreat() == nil)                        // row 0: the caller replays it
    }
    @Test func nextOnTheLastSongOfARepeatingQueueWrapsToTheFirst() {
        var q = queue(3, start: 2); q.repeatMode = .all
        #expect(q.hasNext && q.advance(auto: false)?.track.id == "t0")
    }
    @Test func anySizeOfQueueHasEveryRowReachable() {
        for n in [1, 2, 3, 10, 200] {
            var q = queue(n); var seen = [q.current!.track.id]
            while let e = q.advance(auto: true) { seen.append(e.track.id) }
            #expect(seen.count == n && Set(seen).count == n)
        }
    }
}

// 4. Seeking
@Suite("Playback 4: seeking") struct SeekingContract {
    @Test func aDragFractionMapsToTheShownLengthAndNeverLeavesTheSong() {
        #expect(MusicStreamLength.seekTarget(fraction: 0.5, shown: 200) == 100)
        #expect(MusicStreamLength.seekTarget(fraction: -3, shown: 200) == 0)
        #expect(MusicStreamLength.seekTarget(fraction: 9, shown: 200) == 200)
        #expect(MusicStreamLength.seekTarget(fraction: 0.5, shown: 0) == 0)          // an unknown length never produces a wild jump
    }
}

// 5. Shuffle
@Suite("Playback 5: shuffle") struct ShuffleContract {
    @Test func aShuffledQueuePlaysEverySongOnceKeepsTheCurrentOneAndUndoesCleanly() {
        for n in [2, 7, 50] {
            var q = queue(n, start: n / 2)
            let before = q.tracks.map(\.id), current = q.current!.track.id
            q.setShuffle(true)
            #expect(q.shuffle && q.current?.track.id == current && Set(q.tracks.map(\.id)) == Set(before) && q.count == n)
            q.setShuffle(false)
            #expect(!q.shuffle && q.tracks.map(\.id) == before)
        }
    }
    @Test func aRepeatingShuffleStartsEachLapFromTheSongsNotJustHeard() {
        // The real lap engine, not a stub: a stub that reverses the lap would open the new lap with the song that just ended.
        for seed in 1...12 {
            var q = queue(10); q.repeatMode = .all
            q.setShuffle(true)
            q.lapShuffler = MusicShuffleEngine.lapShuffler(mode: .smart, seed: UInt64(seed))
            let first = (0..<9).compactMap { _ in q.advance(auto: true)?.id }
            #expect(first.count == 9)
            // Captured BEFORE the final advance: the last row of lap one and the 20% heard last.
            let lastOfLapOne = q.current?.id
            let recent = Set(q.entries.suffix(2).map(\.id))
            let lapTwoStart = q.advance(auto: true)
            #expect(lapTwoStart != nil && lastOfLapOne != nil)
            #expect(lapTwoStart?.id != lastOfLapOne, "the new lap must not open with the song that just ended")
            #expect(!recent.contains(lapTwoStart?.id ?? UUID()), "nor with anything from the last fifth of the lap")
        }
    }
}

// 6. Repeat
@Suite("Playback 6: repeat") struct RepeatContract {
    @Test func repeatOneReplaysAtTheEndButNextStillMovesOn() {
        var q = queue(3, start: 1); q.repeatMode = .one
        #expect(q.advance(auto: true)?.track.id == "t1")
        #expect(q.peekNext() == nil)                                  // the file loops itself: nothing to preload
        #expect(q.advance(auto: false)?.track.id == "t2")
    }
    @Test func repeatAllWrapsAndRepeatOffEnds() {
        var all = queue(2, start: 1); all.repeatMode = .all
        #expect(all.advance(auto: true)?.track.id == "t0")
        var off = queue(2, start: 1)
        #expect(off.advance(auto: true) == nil)
    }
    @Test func theThreeModesAreTheOnesTheButtonCyclesThrough() {
        #expect(Set(MusicRepeat.allCases) == [.off, .all, .one])
    }
}

// 7. Gapless
@Suite("Playback 7: gapless playback") struct GaplessContract {
    @Test func theNextSongIsPreparedAheadUnlessThereIsNothingToPrepare() {
        #expect(MusicGaplessState.skipReason(repeatMode: .off, hasNext: true, currentIsLive: false, nextIsLive: false) == .none)
        #expect(MusicGaplessState.skipReason(repeatMode: .one, hasNext: true, currentIsLive: false, nextIsLive: false) == .repeatOne)
        #expect(MusicGaplessState.skipReason(repeatMode: .off, hasNext: false, currentIsLive: false, nextIsLive: false) == .noNext)
        #expect(MusicGaplessState.skipReason(repeatMode: .off, hasNext: true, currentIsLive: true, nextIsLive: false) == .liveCurrent)
    }
    @Test func aPreparedRowThatIsNoLongerNextIsStaleAndAnExplicitPlayDiscardsLateWork() {
        var g = MusicGaplessState(); let a = UUID(), b = UUID()
        let gen = g.begin(for: a)!
        #expect(g.canCommit(generation: gen, id: a, nextRowID: a))
        g.commit(a)
        #expect(g.isStale(nextRowID: b) && !g.isStale(nextRowID: a))
        let late = g.begin(for: b)!
        g.bump()
        #expect(!g.canCommit(generation: late, id: b, nextRowID: b))
    }
}

// 8. Crossfade
@Suite("Playback 8: crossfade") struct CrossfadeContract {
    @Test func offBelowOneSecondAndClampedToTenForEverySetting() {
        for s in [0.0, 0.4, .nan, -2] { #expect(MusicCrossfade.length(setting: s) == 0) }
        #expect(MusicCrossfade.length(setting: 1) == 1 && MusicCrossfade.length(setting: 99) == MusicCrossfade.maxSeconds)
    }
    @Test func aFadeNeverExceedsHalfTheSongAndStartsOnlyWhenTheEndIsNear() {
        #expect(MusicCrossfade.plannedLength(setting: 10, duration: 8) <= 4)
        #expect(MusicCrossfade.rampLength(setting: 5, position: 10, duration: 200) == nil)
        let r = MusicCrossfade.rampLength(setting: 5, position: 196, duration: 200)
        #expect(r != nil && r! <= 5 && r! > 0)
        #expect(MusicCrossfade.rampLength(setting: 5, position: 0, duration: .infinity) == nil)    // a live stream is never faded
    }
}

// 9. Background playback
@Suite("Playback 9: background playback") struct BackgroundContract {
    @Test func theSystemMediaKeysAndNowPlayingAreWiredToThePlayer() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/REDDY/Services/Music/Playback/MusicPlayer.swift"), encoding: .utf8)
        #expect(src.contains("MPNowPlayingInfoCenter") || src.contains("NowPlaying"))
    }
}

// 10. Playback recovery
@Suite("Playback 10: recovery") struct RecoveryContract {
    @Test func aFailedSongIsRetriedOnceThenSkippedAndAStreakOfFailuresStopsPlayback() {
        var ladder = MusicFailureLadder(); let row = UUID()
        #expect(ladder.decide(.thisTrack, row: row, title: "A", resolveFailure: true, atTail: false) == .retry)
        if case .skip = ladder.decide(.thisTrack, row: row, title: "A", resolveFailure: true, atTail: false) {} else { Issue.record("expected a skip") }
        var stopped = false
        for _ in 0..<MusicFailureLadder.maxConsecutiveFailures {
            let r = UUID()
            _ = ladder.decide(.thisTrack, row: r, title: "x", resolveFailure: true, atTail: false)
            if case .stopSeveral = ladder.decide(.thisTrack, row: r, title: "x", resolveFailure: true, atTail: false) { stopped = true }
        }
        #expect(stopped)
    }
    @Test func aLostAudioDeviceHoldsInsteadOfSkippingThroughTheQueue() {
        var ladder = MusicFailureLadder()
        #expect(ladder.decide(.deviceLost, row: UUID(), title: "A", resolveFailure: false, atTail: false) == .holdForDevice)
    }
    @Test func theOfflineRetryLadderBacksOffAndResets() {
        var l = MusicOfflineLadder(); let now = Date()
        let first = l.nextDelay(now: now), second = l.nextDelay(now: now.addingTimeInterval(1))
        #expect(first != nil && second != nil && second! >= first!)
        l.reset()
        #expect(l.nextDelay(now: now.addingTimeInterval(2)) == first)
    }
}

// 11. Volume normalization
@Suite("Playback 11: volume normalization") struct NormalizationContract {
    @Test func loudTracksAreTurnedDownQuietOnesUpWithinLimitsAndUnknownIsLeftAlone() {
        #expect(MusicLoudnessMath.gainDB(loudness: -4) < 0)
        #expect(MusicLoudnessMath.gainDB(loudness: -12) > 0 && MusicLoudnessMath.gainDB(loudness: -40) == MusicLoudnessMath.maxGainDB)
        #expect(MusicLoudnessMath.gainDB(loudness: 40) == MusicLoudnessMath.minGainDB)
        #expect(MusicLoudnessMath.gainDB(loudness: .nan) == 0 && MusicLoudnessMath.gainDB(loudness: MusicLoudnessMath.targetLUFS) == 0)
        #expect(MusicLoudnessMath.needsLimiter(gainDB: 2) && !MusicLoudnessMath.needsLimiter(gainDB: -2))
    }
}

// 12. Playback persistence
@Suite("Playback 12: persistence") struct PersistenceContract {
    @Test func theQueueShuffleRepeatAndPositionComeBackAsTheyWere() throws {
        var q = queue(12, start: 5); q.repeatMode = .all; q.setShuffle(true)
        let data = try JSONEncoder().encode(q.snapshot(position: 73.5))
        let snap = try JSONDecoder().decode(MusicQueue.Snapshot.self, from: data)
        let back = MusicQueue(snapshot: snap)
        #expect(back.tracks.map(\.id) == q.tracks.map(\.id) && back.current?.track.id == q.current?.track.id)
        #expect(back.repeatMode == .all && back.shuffle && snap.position == 73.5)
        var undone = back; undone.setShuffle(false)
        #expect(undone.tracks.map(\.id) == (0..<12).map { "t\($0)" })      // un-shuffle still works after a restart
    }
    @Test func aQueueFileFromAnOlderVersionStillOpens() throws {
        let old = MusicQueue.Snapshot(tracks: songs(4), index: 2, shuffle: false, repeatMode: .off, position: 10)
        let q = MusicQueue(snapshot: old)
        #expect(q.count == 4 && q.current?.track.id == "t2")
    }
}

// 13. Sleep timer
@Suite("Playback 13: sleep timer") @MainActor struct SleepContract {
    @Test func aTimedSleepFadesThenPausesAndGivesTheVolumeBack() {
        let clock = Clock(), p = Player()
        let t = MusicSleepTimer(player: p, now: { clock.t }, autoTick: false)
        t.start(.minutes(30))
        clock.advance(30 * 60 - 5); t.tick()
        #expect(p.volume < 0.8 && p.paused == 0)
        clock.advance(6); t.tick()
        #expect(p.paused == 1 && p.volume == 0.8 && !t.isRunning)
    }
    @Test func endOfTrackStopsWhenTheNextSongStartsAndEveryPresetExists() {
        let clock = Clock(), p = Player()
        let t = MusicSleepTimer(player: p, now: { clock.t }, autoTick: false)
        p.position = 190; t.start(.endOfTrack)
        p.currentUID = "p:t1"; t.tick()                      // the song changed: stop here
        #expect(p.paused == 1)
        #expect(MusicSleepPreset.all.contains(.endOfTrack) && MusicSleepPreset.all.count >= 6)
    }
    @Test func theFadeIsFlatThenLinearAndNeverNegative() {
        #expect(MusicSleepLogic.fadeFactor(remaining: 60) == 1)
        #expect(MusicSleepLogic.fadeFactor(remaining: 5) == 0.5 && MusicSleepLogic.fadeFactor(remaining: -3) == 0)
    }
}

// 14. Queue integrity under editing (the "queue" half of the expectations: add, reorder, remove while playing)
@Suite("Playback 14: the queue while playing") struct QueueEditContract {
    @Test func playNextAndAddToQueueLandWhereTheyShouldAndRemovingTheCurrentRowKeepsPlayingSomething() {
        var q = queue(5, start: 1)
        q.playNext([song(90)]); q.addToQueue([song(91)])
        #expect(q.entries[2].track.id == "t90" && q.entries.last?.track.id == "t91")
        let before = q.count
        _ = q.remove(at: q.index!)
        #expect(q.count == before - 1 && q.current != nil)
    }
}
