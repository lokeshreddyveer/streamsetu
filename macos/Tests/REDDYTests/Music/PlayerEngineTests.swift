import Testing
import Foundation
@testable import REDDY

private func song(_ n: Int, durationMs: Int64 = 200_000) -> MusicTrack {
    MusicTrack(id: "t\(n)", providerID: "p", title: "Song \(n)", durationMs: durationMs, artists: [MusicArtistRef(id: "a\(n)", name: "Artist \(n)")])
}
private func songs(_ r: ClosedRange<Int>) -> [MusicTrack] { r.map { song($0) } }
private let reverse: MusicQueue.Shuffler = { $0.reverse() }
private let keep: MusicQueue.Shuffler = { _ in }

private func queue(_ n: Int, at start: Int = 0) -> MusicQueue {
    var q = MusicQueue()
    q.replace(with: songs(0...(n - 1)), startAt: start)
    return q
}
private func ids(_ q: MusicQueue) -> [String] { q.tracks.map(\.id) }

// MARK: queue

@Suite("Queue: adding")
struct QueueAddingTests {
    @Test func playNextIsFirstInFirstOutRightAfterThePlayingRow() {
        var q = queue(4)
        q.playNext([song(10)]); q.playNext([song(11)])
        #expect(ids(q) == ["t0", "t10", "t11", "t1", "t2", "t3"])
        #expect(q.entries[1].queued && q.entries[2].queued && !q.entries[3].queued)
    }

    @Test func addToQueueSitsBehindThePlaylistAndAheadOfAutoplay() {
        var q = queue(3)
        q.append([song(50)], auto: true)
        q.addToQueue([song(20)]); q.addToQueue([song(21)])
        #expect(ids(q) == ["t0", "t1", "t2", "t20", "t21", "t50"])
        #expect(q.entries[3].queuedEnd)
    }

    @Test func playNextStaysAheadOfAddToQueueRows() {
        var q = queue(3)
        q.addToQueue([song(20)])
        q.playNext([song(10)])
        #expect(ids(q) == ["t0", "t10", "t1", "t2", "t20"])
    }

    @Test func radioQueueAddsGoAfterManualAddsAndAheadOfTheRadio() {
        var q = MusicQueue()
        q.replace(with: songs(0...4), startAt: 0, isRadio: true)
        q.playNext([song(10)])
        q.addToQueue([song(20)])
        q.addToQueue([song(21)])
        #expect(ids(q) == ["t0", "t10", "t20", "t21", "t1", "t2", "t3", "t4"])
    }

    @Test func addingTracksAlreadyWaitingMovesThemInsteadOfDoubling() {
        var q = queue(3)
        q.addToQueue([song(20), song(21)])
        q.addToQueue([song(20)])
        #expect(ids(q) == ["t0", "t1", "t2", "t21", "t20"])
        q.playNext([song(21)])
        #expect(ids(q) == ["t0", "t21", "t1", "t2", "t20"])
    }

    @Test func preventDuplicatesRemovesEveryOtherCopyAndThePointerFollows() {
        var q = queue(5, at: 2)
        let opts = MusicQueue.Options(preventDuplicates: true)
        q.playNext([song(4), song(0)], options: opts)
        #expect(ids(q) == ["t1", "t2", "t4", "t0", "t3"])
        #expect(q.current?.track.id == "t2")
        // The playing row is never removed, even when it is added again.
        q.addToQueue([song(2)], options: opts)
        #expect(q.current?.track.id == "t2")
        #expect(ids(q).filter { $0 == "t2" }.count == 2)
    }

    @Test func addingToAnEmptyQueueStartsRowZero() {
        var q = MusicQueue()
        let r = q.addToQueue([song(1), song(2)])
        #expect(r.startedEmpty && r.added == 2)
        #expect(q.current?.track.id == "t1" && !q.entries[0].queuedEnd)
    }

    @Test func clearQueueRemovesOnlyUpcomingManualRows() {
        var q = queue(4, at: 1)
        q.playNext([song(10)]); q.addToQueue([song(11)])
        #expect(q.hasManualUpcoming)
        #expect(q.clearManual() == 2)
        #expect(ids(q) == ["t0", "t1", "t2", "t3"])
        #expect(!q.hasManualUpcoming)
    }

    @Test func sameSongCanBeInTheQueueTwiceWithDistinctRows() {
        var q = queue(2)
        q.append([song(0)])
        #expect(q.count == 3 && Set(q.entries.map(\.id)).count == 3)
    }

    @Test func addsAlsoGoOntoTheShuffleSnapshotInRealOrder() {
        var q = queue(4)
        q.setShuffle(true, shuffler: reverse)
        q.playNext([song(10)])
        q.setShuffle(false)
        #expect(ids(q).contains("t10"))
        #expect(q.entries[(q.index ?? 0) + 1].track.id == "t10")
    }
}

@Suite("Queue: shuffle")
struct QueueShuffleTests {
    @Test func onlyUpcomingRowsMoveAndThePlayedPrefixStays() {
        var q = queue(6, at: 2)
        q.setShuffle(true, shuffler: reverse)
        #expect(ids(q) == ["t0", "t1", "t2", "t5", "t4", "t3"])
        #expect(q.current?.track.id == "t2")
    }

    @Test func playNextRunStaysPinnedAndAnAddedAlbumShufflesInsideItself() {
        var q = queue(4)
        q.playNext([song(10)])
        q.playNext([song(11), song(12), song(13)], from: "Album")
        q.setShuffle(true, shuffler: reverse)
        // Single add first and in order; the album run (same queuedFrom) is reversed inside itself; the rest follows shuffled.
        #expect(ids(q) == ["t0", "t10", "t13", "t12", "t11", "t3", "t2", "t1"])
    }

    @Test func groupsAreContextThenAddToQueueThenAutoplay() {
        var q = queue(4)
        q.addToQueue([song(20), song(21)])
        q.append([song(50), song(51)], auto: true)
        q.setShuffle(true, shuffler: keep)
        #expect(ids(q) == ["t0", "t1", "t2", "t3", "t20", "t21", "t50", "t51"])
        q.setShuffle(false)
        q.setShuffle(true, wholeQueue: true, shuffler: reverse)
        #expect(ids(q) == ["t0", "t21", "t20", "t3", "t2", "t1", "t51", "t50"])
    }

    // Rule changed on purpose: un-shuffle used to drop every row whose original index was before the playing row's. Now every row that
    // was not played yet comes back as upcoming, in its original relative order, after the played rows (kept as history in play order).
    @Test func unshuffleRestoresOrderForEverythingNotPlayedYet() {
        let rotate: MusicQueue.Shuffler = { $0 = $0.count > 2 ? Array($0[2...] + $0[..<2]) : $0 }
        var q = queue(6)
        q.setShuffle(true, shuffler: rotate)               // t0 t3 t4 t5 t1 t2
        #expect(ids(q) == ["t0", "t3", "t4", "t5", "t1", "t2"])
        q.advance(auto: true)                              // t3 playing; t0 played
        q.setShuffle(false)
        #expect(!q.shuffle && q.current?.track.id == "t3")
        let upcoming = q.entries[((q.index ?? 0) + 1)...].map(\.track.id)
        #expect(upcoming == ["t1", "t2", "t4", "t5"])      // t1 and t2 were skipped, so they are still to come, in original order
        #expect(ids(q) == ["t0", "t3", "t1", "t2", "t4", "t5"])   // the played row stays behind as history
    }

    @Test func unshuffleDoesNotBringPlayedTracksBackAsUpNext() {
        var q = queue(6)
        q.setShuffle(true, shuffler: reverse)              // t0 t5 t4 t3 t2 t1
        q.advance(auto: true); q.advance(auto: true)       // t4 playing; t0 and t5 played
        q.setShuffle(false)
        // (old rule asserted rowsRemaining == 0: the three unplayed rows were lost) now: they are upcoming in original order
        #expect(q.current?.track.id == "t4" && q.rowsRemaining == 3)
        #expect(ids(q) == ["t0", "t5", "t4", "t1", "t2", "t3"])
    }

    @Test func unshuffleKeepsPlayNextRightAfterThePlayingRowAndAddsAtTheEnd() {
        var q = queue(5)
        q.addToQueue([song(20)])
        q.playNext([song(10)])
        q.setShuffle(true, shuffler: reverse)
        q.setShuffle(false)
        #expect(ids(q) == ["t0", "t10", "t1", "t2", "t3", "t4", "t20"])
    }

    @Test func shuffleSurvivesSavingAndStillReverses() throws {
        var q = queue(5)
        q.setShuffle(true, shuffler: reverse)
        let data = try JSONEncoder().encode(q.snapshot(position: 12))
        var back = MusicQueue(snapshot: try JSONDecoder().decode(MusicQueue.Snapshot.self, from: data))
        #expect(back.shuffle)
        back.setShuffle(false)
        #expect(ids(back) == ["t0", "t1", "t2", "t3", "t4"])
    }

    @Test func removingARowAlsoRemovesItFromTheSnapshot() {
        var q = queue(4)
        q.setShuffle(true, shuffler: reverse)
        q.remove(at: 1)
        q.setShuffle(false)
        #expect(!ids(q).contains("t3"))
    }
}

@Suite("Queue: moving through it")
struct QueueMovementTests {
    @Test func plainOrderEndsWithRepeatOff() {
        var q = queue(3)
        #expect(q.advance(auto: true)?.track.id == "t1")
        #expect(q.advance(auto: true)?.track.id == "t2")
        #expect(q.advance(auto: true) == nil)
        #expect(q.current?.track.id == "t2" && !q.hasNext)
    }

    @Test func repeatAllWrapsAndRepeatOneReplaysOnAutoButManualNextEscapes() {
        var q = queue(2)
        q.repeatMode = .all
        q.advance(auto: true)
        #expect(q.advance(auto: true)?.track.id == "t0")
        q.repeatMode = .one
        #expect(q.advance(auto: true)?.track.id == "t0")
        #expect(q.advance(auto: false)?.track.id == "t1")
        #expect(q.advance(auto: false)?.track.id == "t0")
        #expect(q.peekNext() == nil)
    }

    @Test func retreatStopsAtRowZero() {
        var q = queue(3, at: 1)
        #expect(q.retreat()?.track.id == "t0")
        #expect(q.retreat() == nil)
    }

    @Test func removingTheCurrentRowPicksTheNeighbour() {
        var q = queue(3, at: 1)
        let hoisted215 = q.remove(at: 1); #expect(hoisted215)
        #expect(q.current?.track.id == "t2")
        let hoisted217 = q.remove(at: 0); #expect(!hoisted217)
    }

    @Test func clearKeepingCurrentLeavesOneRow() {
        var q = queue(3, at: 2)
        q.clear(keepCurrent: true)
        #expect(ids(q) == ["t2"])
    }

    @Test func movesAreUpcomingOnlyAndClearTheAutoFlag() {
        var q = queue(3)
        q.append([song(50), song(51)], auto: true)
        let hoisted229 = q.moveUpcoming(from: 0, to: 2); #expect(!hoisted229)
        let hoisted230 = q.moveUpcoming(from: 2, to: 2); #expect(!hoisted230)
        let hoisted231 = q.moveUpcoming(from: 2, to: 9); #expect(!hoisted231)
        let hoisted232 = q.moveUpcoming(from: 4, to: 1); #expect(hoisted232)
        #expect(q.entries[1].track.id == "t51" && !q.entries[1].auto)
        #expect(q.current?.track.id == "t0")
    }

    @Test func playedHistoryBeyondTwoHundredIsTrimmedAndOnlyWithoutShuffle() {
        var q = queue(300, at: 250)
        #expect(q.trimHistory() == 50)
        #expect(q.index == 200 && q.count == 250)
        // Under shuffle the same rows leave the snapshot too, so neither list grows without bound.
        var s = queue(300, at: 250)
        s.setShuffle(true, shuffler: keep)
        let trimmed = s.trimHistory()
        #expect(trimmed == 50 && s.count == 250 && s.preShuffle?.count == 250)
    }
}

@Suite("Queue: previous queue and autoplay")
struct QueueContextTests {
    @Test func aReplacedQueueCanBeRestoredOnlyWhileThePointerIsOnRowZero() {
        var q = queue(4, at: 2)
        q.setSource(name: "Road Trip")
        q.replace(with: songs(10...12), startAt: 0, leavingPosition: 42)
        #expect(q.backTitle == "Road Trip")
        #expect(q.restorePreviousContext() == 42)
        #expect(q.current?.track.id == "t2" && q.backTitle == nil && q.count == 4)

        q.replace(with: songs(10...12), startAt: 0)
        q.advance(auto: false)
        #expect(q.previousContext == nil && q.backTitle == nil)
    }

    @Test func carriedManualAddsSurviveASwitch() {
        var q = queue(3)
        q.playNext([song(10)]); q.addToQueue([song(20)])
        q.replace(with: songs(30...32), startAt: 0)
        #expect(ids(q) == ["t30", "t10", "t31", "t32", "t20"])
        // A manual add the new list already contains is not carried a second time.
        var r = queue(2)
        r.playNext([song(31)])
        r.replace(with: songs(30...32), startAt: 0)
        #expect(ids(r) == ["t30", "t31", "t32"])
    }

    @Test func epochChangesOnlyWhenAnotherQueueReplacesThisOne() {
        var q = queue(3)
        let e = q.epoch
        q.advance(auto: false); q.playNext([song(9)])
        #expect(q.epoch == e)
        q.replace(with: songs(5...6), startAt: 0)
        #expect(q.epoch == e + 1)
    }

    @Test func autoplayRunsWhenTwoRowsOrFewerRemain() {
        var q = queue(5)
        #expect(!q.wantsAutoplay(enabled: true, isGuest: false, hydrating: false))
        q.jump(to: 2)
        #expect(q.wantsAutoplay(enabled: true, isGuest: false, hydrating: false))
        #expect(!q.wantsAutoplay(enabled: false, isGuest: false, hydrating: false))
        #expect(!q.wantsAutoplay(enabled: true, isGuest: true, hydrating: false))
        #expect(!q.wantsAutoplay(enabled: true, isGuest: false, hydrating: true))
        q.repeatMode = .all
        #expect(!q.wantsAutoplay(enabled: true, isGuest: false, hydrating: false))
    }

    @Test func autoplayMergeDedupesCapsAtTwentyAndPutsFreshTracksFirst() {
        var q = queue(2)
        let now = Date()
        let page = songs(0...40)          // t0 and t1 are already queued
        let heard = ["p:t5": now.addingTimeInterval(-86_400), "p:t6": now.addingTimeInterval(-3 * 86_400), "p:t7": now.addingTimeInterval(-60 * 86_400)]
        let added = q.mergeAutoplay(page, lastHeard: heard, now: now)
        #expect(added == 20)
        let auto = q.entries.filter(\.auto).map(\.track.id)
        // t7 was heard long ago so it counts as fresh; t5 and t6 are heard within 30 days and are cut by the cap.
        #expect(auto.first == "t2" && auto.contains("t7"))
        #expect(!auto.contains("t5") && !auto.contains("t6") && !auto.contains("t0"))
    }

    @Test func heardTracksFollowLeastRecentFirst() {
        let now = Date()
        let order = MusicAutoplayOrder.freshFirst([song(1), song(2), song(3)], lastHeard: ["p:t1": now.addingTimeInterval(-100), "p:t2": now.addingTimeInterval(-9_000)], now: now)
        #expect(order.map(\.id) == ["t3", "t2", "t1"])
    }

    @Test func switchingAutoplayOffKeepsRowsThePersonPlaced() {
        var q = queue(2)
        q.append([song(50), song(51)], auto: true)
        q.moveUpcoming(from: 3, to: 1)       // t51 is now the person's
        q.clearAuto()
        #expect(ids(q) == ["t0", "t51", "t1"])
    }

    @Test func remainingSummary() {
        var rows = queue(4).entries
        #expect(MusicQueueLogic.remainingSummary(rows: rows, current: 0) == "3 songs left - 10 min")
        rows = Array(rows.prefix(2))
        #expect(MusicQueueLogic.remainingSummary(rows: rows, current: 0) == "1 song left - 3 min")
        #expect(MusicQueueLogic.remainingSummary(rows: rows, current: 1) == "")
    }
}

@Suite("Queue: saving")
struct QueuePersistenceTests {
    @Test func fingerprintIgnoresTitlesButNotMarkersOrOrder() {
        var a = queue(3)
        var b = queue(3)
        #expect(a.fingerprint() == b.fingerprint())
        a.playNext([song(9)])
        #expect(a.fingerprint() != b.fingerprint())
        b.append([song(9)])
        #expect(a.fingerprint() != b.fingerprint())
        var t = song(0); t.title = "Renamed"
        var c = MusicQueue(); c.replace(with: [t, song(1), song(2)], startAt: 0)
        #expect(c.fingerprint() == queue(3).fingerprint())
    }

    @Test func theSmallRecordIsTrustedOnlyForTheRowsItWasWrittenFor() throws {
        var q = queue(4, at: 2)
        let rec = q.indexRecord(position: 31)
        var same = queue(4)
        #expect(same.apply(rec) && same.index == 2)
        var other = queue(5)
        #expect(!other.apply(rec) && other.index == 0)
        q.playNext([song(9)])
        let hoisted354 = q.apply(rec); #expect(!hoisted354)
    }

    @Test func markersAndSourceSurviveARoundTrip() throws {
        var q = queue(3)
        q.setSource(name: "Mix", id: "pl1", radioSeed: "seed", isRadio: true)
        q.playNext([song(10)], from: "Album")
        let back = MusicQueue(snapshot: try JSONDecoder().decode(MusicQueue.Snapshot.self, from: JSONEncoder().encode(q.snapshot(position: 3))))
        #expect(back.entries[1].queued && back.entries[1].queuedFrom == "Album")
        #expect(back.sourceName == "Mix" && back.sourceID == "pl1" && back.radioSeed == "seed" && back.isRadio)
        #expect(back.fingerprint() == q.fingerprint())
    }

    @Test func aQueueFileFromAnOlderBuildStillLoads() throws {
        let legacy = MusicQueue.Snapshot(tracks: [song(0), song(1)], index: 1, shuffle: false, repeatMode: .all, position: 9, autoIndices: [1])
        let q = MusicQueue(snapshot: try JSONDecoder().decode(MusicQueue.Snapshot.self, from: JSONEncoder().encode(legacy)))
        #expect(q.count == 2 && q.index == 1 && q.repeatMode == .all && q.entries[1].auto && !q.shuffle)
        let bare = #"{"tracks":[],"shuffle":false,"repeatMode":"off","position":0}"#
        #expect((try JSONDecoder().decode(MusicQueue.Snapshot.self, from: Data(bare.utf8))).rows == nil)
    }
}

// MARK: drag and drop

@Suite("Queue drag math")
struct QueueDragTests {
    @Test func dropTargetExamples() {
        #expect(MusicQueueDrag.moveTarget(from: 2, dropAt: 6) == 5)
        #expect(MusicQueueDrag.moveTarget(from: 6, dropAt: 2) == 2)
        #expect(MusicQueueDrag.moveTarget(from: 2, dropAt: 9) == 8)
        #expect(MusicQueueDrag.moveTarget(from: 4, dropAt: 4) == nil)
        #expect(MusicQueueDrag.moveTarget(from: 4, dropAt: 5) == nil)
    }

    @Test func topHalfMeansThisRowBottomHalfMeansTheNext() {
        #expect(MusicQueueDrag.dropIndex(overRow: 3, yInRow: 10) == 3)
        #expect(MusicQueueDrag.dropIndex(overRow: 3, yInRow: 40) == 4)
    }

    @Test func autoScrollRampsLinearlyAndStaysAtTheMaximumBeyondTheEdge() {
        #expect(MusicQueueDrag.autoScrollSpeed(pointerY: 300, boxHeight: 600) == 0)
        #expect(MusicQueueDrag.autoScrollSpeed(pointerY: 96, boxHeight: 600) == 0)
        #expect(MusicQueueDrag.autoScrollSpeed(pointerY: 48, boxHeight: 600) == -900)
        #expect(MusicQueueDrag.autoScrollSpeed(pointerY: 0, boxHeight: 600) == -1800)
        #expect(MusicQueueDrag.autoScrollSpeed(pointerY: -400, boxHeight: 600) == -1800)
        #expect(MusicQueueDrag.autoScrollSpeed(pointerY: 552, boxHeight: 600) == 900)
        #expect(MusicQueueDrag.autoScrollSpeed(pointerY: 900, boxHeight: 600) == 1800)
        // A box shorter than two zones: the top wins.
        #expect(MusicQueueDrag.autoScrollSpeed(pointerY: 90, boxHeight: 150) < 0)
    }

    @Test func oneStepCountsAtMostOneHundredMilliseconds() {
        #expect(MusicQueueDrag.autoScrollDistance(speed: 1800, elapsed: 0.016) == 28.8)
        #expect(MusicQueueDrag.autoScrollDistance(speed: 1800, elapsed: 2) == 180)
    }

    @Test func onlyUpcomingRowsCanBeDraggedAndNotByAGuest() {
        #expect(MusicQueueDrag.canDrag(row: 5, playing: 2, editingAllowed: true))
        #expect(!MusicQueueDrag.canDrag(row: 2, playing: 2, editingAllowed: true))
        #expect(!MusicQueueDrag.canDrag(row: 5, playing: 2, editingAllowed: false))
    }
}

// MARK: crossfade, volume, loudness

@Suite("Crossfade math")
struct CrossfadeTests {
    @Test func lengthIsAWholeNumberOfSecondsFromOneToTenAndOffUnderOne() {
        #expect(MusicCrossfade.length(setting: 0) == 0)
        #expect(MusicCrossfade.length(setting: 0.9) == 0)
        #expect(MusicCrossfade.length(setting: 5) == 5)
        #expect(MusicCrossfade.length(setting: 99) == 10)
        #expect(MusicCrossfade.length(setting: .nan) == 0)
    }

    @Test func startsExactlyWhenTheRemainingTimeReachesTheLength() {
        #expect(MusicCrossfade.rampLength(setting: 5, position: 175.0, duration: 180) == 5)
        #expect(MusicCrossfade.rampLength(setting: 5, position: 174.9, duration: 180) == nil)
        // Starting late fades for what is left.
        let late = MusicCrossfade.rampLength(setting: 5, position: 179.5, duration: 180)
        #expect(late != nil && abs(late! - 0.5) < 1e-9)
        // Never more than half the track.
        #expect(MusicCrossfade.rampLength(setting: 10, position: 6, duration: 12) == 6)
        #expect(MusicCrossfade.rampLength(setting: 10, position: 5.9, duration: 12) == nil)
        // No fade without a real, finite length over one second.
        #expect(MusicCrossfade.rampLength(setting: 5, position: 0, duration: 0) == nil)
        #expect(MusicCrossfade.rampLength(setting: 5, position: 0.5, duration: 1) == nil)
        #expect(MusicCrossfade.rampLength(setting: 5, position: 1, duration: .infinity) == nil)
    }

    @Test func tempoMakesItListeningSeconds() {
        // At 2x a 180 s file lasts 90 s; the fade starts when 5 listening seconds (10 file seconds) remain.
        #expect(MusicCrossfade.rampLength(setting: 5, position: 170, duration: 180, tempo: 2) == 5)
        #expect(MusicCrossfade.rampLength(setting: 5, position: 169, duration: 180, tempo: 2) == nil)
    }

    @Test func incomingRampIsCappedAtHalfItsOwnLength() {
        #expect(MusicCrossfade.incomingRamp(5, incomingDuration: 6) == 3)
        #expect(MusicCrossfade.incomingRamp(5, incomingDuration: 200) == 5)
    }

    @Test func equalPowerNeverDipsInTheMiddle() {
        let steps = MusicCrossfade.steps(for: 5)
        #expect(steps == 100)
        for s in 0...steps {
            let g = MusicCrossfade.gains(step: s, of: steps)
            #expect(abs(g.outgoing * g.outgoing + g.incoming * g.incoming - 1) < 1e-5)
        }
        let half = MusicCrossfade.gains(step: 50, of: 100)
        #expect(abs(half.outgoing - 0.70710678) < 1e-5 && abs(half.incoming - 0.70710678) < 1e-5)
        #expect(MusicCrossfade.gains(step: 0, of: 100).outgoing == 1 && MusicCrossfade.gains(step: 100, of: 100).incoming == 1)
        #expect(abs(MusicCrossfade.cubicControl(forAmplitude: 0.125) - 0.5) < 1e-6)
    }

    @Test func gateNeedsEveryConditionAndSuspendsInARoom() {
        var g = MusicCrossfadeGate(enabled: true, nextReady: true, fadeRunning: false, repeatOne: false, paused: false, live: false, inRoom: false)
        #expect(g.canStart)
        g.nextReady = false; #expect(!g.canStart); g.nextReady = true
        g.inRoom = true; #expect(!g.canStart); g.inRoom = false
        g.repeatOne = true; #expect(!g.canStart); g.repeatOne = false
        g.paused = true; #expect(!g.canStart)
    }
}

@Suite("Volume curve and listening time")
struct VolumeCurveTests {
    @Test func attenuationFollowsTheCurve() {
        #expect(MusicVolumeCurve.attenuationDB(slider: 1) == 0)
        #expect(abs(MusicVolumeCurve.attenuationDB(slider: 0.5) - (-21.2132)) < 0.01)
        #expect(abs(MusicVolumeCurve.attenuationDB(slider: 0.25) - (-38.97)) < 0.05)
        #expect(abs(MusicVolumeCurve.attenuationDB(slider: 0.01) - (-59.1)) < 0.05)
        #expect(MusicVolumeCurve.attenuationDB(slider: 0) == -.infinity)
        #expect(MusicVolumeCurve.amplitude(slider: 0) == 0)
        #expect(MusicVolumeCurve.amplitude(slider: 1) == 1)
    }

    @Test func itNeverGetsLouderWhenTheSliderGoesDown() {
        var last: Float = 2
        for i in stride(from: 100, through: 0, by: -1) {
            let a = MusicVolumeCurve.amplitude(slider: Double(i) / 100)
            #expect(a <= last)
            last = a
        }
    }

    @Test func nudgesAreFivePercentAndClamped() {
        #expect(MusicVolumeCurve.nudged(0.5, by: 0.05) == 0.55)
        #expect(MusicVolumeCurve.nudged(0.98, by: 0.05) == 1)
        #expect(MusicVolumeCurve.nudged(0.02, by: -0.05) == 0)
        var v: Float = 1
        for _ in 0..<7 { v = MusicVolumeCurve.nudged(v, by: -0.05) }
        #expect(v == 0.65)
    }

    @Test func muteReturnsToTheLastNonZeroLevel() {
        var m = MusicMuteMemory()
        m.observe(0.6); m.observe(0)
        #expect(m.toggled(from: 0.6) == 0)
        #expect(m.toggled(from: 0) == 0.6)
        #expect(MusicMuteMemory().toggled(from: 0) == 1)
    }

    @Test func listeningSecondsAreFileSecondsOverTempo() {
        #expect(MusicVolumeCurve.listening(180, tempo: 1.5) == 120)
        #expect(MusicVolumeCurve.listening(60, tempo: 0.5) == 120)
        #expect(MusicVolumeCurve.trackSeconds(fromListening: 60, tempo: 1.5) == 90)
        #expect(MusicVolumeCurve.listening(.nan, tempo: 1) == 0)
    }
}

@Suite("Loudness rule")
struct LoudnessRuleTests {
    @Test func reportedLoudnessExamples() {
        #expect(abs(MusicLoudnessMath.gainDB(reported: 7.77) - (-0.77)) < 1e-9)
        #expect(MusicLoudnessMath.gainDB(reported: 7.0) == 0)
        #expect(abs(MusicLoudnessMath.gainDB(reported: 6.35) - 0.65) < 1e-9)
        #expect(MusicLoudnessMath.gainDB(reported: 0.11) == 3)
        #expect(MusicLoudnessMath.gainDB(reported: 40) == -24)
        #expect(MusicLoudnessMath.gainDB(reported: .nan) == 0)
    }

    @Test func aBoostCarriesTheLimiterAndACutDoesNot() {
        #expect(MusicLoudnessMath.needsLimiter(gainDB: 0.65))
        #expect(!MusicLoudnessMath.needsLimiter(gainDB: -3))
        #expect(!MusicLoudnessMath.needsLimiter(gainDB: 0))
    }

    @Test func changesUnderAFiftiethOfADecibelAreIgnored() {
        #expect(!MusicLoudnessMath.isAudible(change: 0.049))
        #expect(MusicLoudnessMath.isAudible(change: 0.05))
        #expect(MusicLoudnessMath.gainDB(loudness: -7.04) == 0)
    }

    @Test func playerPathKeepsThreeDecibelsOfHeadroomSoABoostIsPossible() {
        #expect(MusicLoudnessMath.headroomDB == MusicLoudnessMath.maxGainDB)
        #expect(abs(MusicLoudnessMath.volumeFactor(gainDB: 3) - 1) < 1e-6)
        #expect(abs(MusicLoudnessMath.engineAmplitude(gainDB: 3) - 1.4125) < 0.001)
    }

    @Test func normalisationIsOnByDefaultAndOldFilesDecode() throws {
        #expect(MusicSettings().normalizeVolume)
        let s = try JSONDecoder().decode(MusicSettings.self, from: Data("{}".utf8))
        #expect(s.normalizeVolume && s.player == MusicPlayerPrefs())
        let off = try JSONDecoder().decode(MusicSettings.self, from: Data(#"{"normalizeVolume":false}"#.utf8))
        #expect(!off.normalizeVolume)
    }
}

// MARK: effects

@Suite("Effects")
struct EffectsTests {
    @Test func valuesOutsideTheRangesAreRejectedAsAWhole() {
        #expect(throws: MusicEffectError.invalidValues) { try MusicEffectSettings(speed: 2.5).validate() }
        #expect(throws: MusicEffectError.invalidValues) { try MusicEffectSettings(speed: 0.4).validate() }
        #expect(throws: MusicEffectError.invalidValues) { try MusicEffectSettings(speed: .nan).validate() }
        #expect(throws: MusicEffectError.invalidValues) { try MusicEffectSettings(semitones: 13).validate() }
        var bad = MusicEffectSettings(); bad.reverb.damping = 100
        #expect(throws: MusicEffectError.invalidValues) { try bad.validate() }
        var inf = MusicEffectSettings(); inf.reverb.decay = .infinity
        #expect(throws: MusicEffectError.invalidValues) { try inf.validate() }
        #expect(MusicEffectSettings.original.isValid)
        #expect(MusicEffectError.invalidValues.errorDescription == "Invalid playback effect values")
    }

    @Test func defaultsMatchTheSpec() {
        let s = MusicEffectSettings()
        #expect(s.speed == 1 && s.semitones == 0 && !s.reverb.enabled)
        #expect(s.reverb.preset == 3 && s.reverb.dry == 100 && s.reverb.wet == 25 && s.reverb.decay == 1.1)
        #expect(s.reverb.preDelay == 0 && s.reverb.damping == 8000 && s.reverb.reflections == 100)
        #expect(!s.isActive && s.isOriginal)
        #expect(MusicReverbRoom.allCases.map(\.naturalDecay) == [0.4, 0.7, 1.1, 1.8, 3.2, 1.8])
    }

    @Test func choosingARoomTurnsReverbOnAndSetsItsNaturalDecayButKeepsTheRest() {
        var s = MusicEffectSettings()
        s.reverb.wet = 60; s.reverb.decay = 5; s.reverb.damping = 4000
        s.chooseRoom(.largeHall)
        #expect(s.reverb.enabled && s.reverb.preset == 5 && s.reverb.decay == 3.2 && s.reverb.wet == 60 && s.reverb.damping == 4000)
    }

    @Test func pitchIsTwoToTheSemitonesOverTwelveAndOnlyPitchOrReverbNeedTheEngine() {
        #expect(abs(MusicEffectSettings(semitones: 12).pitchFactor - 2) < 1e-12)
        #expect(abs(MusicEffectSettings(semitones: -12).pitchFactor - 0.5) < 1e-12)
        #expect(!MusicEffectSettings(speed: 1.5).needsEngine)
        #expect(MusicEffectSettings(semitones: 1).needsEngine)
        var r = MusicEffectSettings(); r.reverb.enabled = true
        #expect(r.needsEngine)
        r.reverb.wet = 0
        #expect(!r.needsEngine)
    }

    @Test func signalPathOrderAndNeverTwoStretchers() {
        var s = MusicEffectSettings(speed: 1.2, semitones: 3)
        s.chooseRoom(.plate)
        let plan = MusicEffectsChain.plan(s, gainDB: 1.5)
        #expect(plan.count == 4)
        #expect(plan[0] == .gain(db: 1.5, limiter: true))
        if case .timePitch(let rate, let cents) = plan[1] { #expect(rate == 1.2 && cents == 300) } else { Issue.record("time-pitch comes second") }
        if case .reverb(let room, _, _, _, _) = plan[2] { #expect(room == .plate) } else { Issue.record("reverb comes third") }
        #expect(plan[3] == .outputLimiter)
        #expect(plan.filter { if case .timePitch = $0 { true } else { false } }.count == 1)
        // Neutral tempo and pitch: no time-stretch stage. No gain to apply: no gain stage. Reverb with zero wet: no room.
        #expect(MusicEffectsChain.plan(.original, gainDB: 0.02).isEmpty)
        var silent = MusicEffectSettings(); silent.reverb.enabled = true; silent.reverb.wet = 0
        #expect(MusicEffectsChain.plan(silent, gainDB: 0).isEmpty)
    }

    @Test func sameSoundIgnoresReverbDetailsWhileReverbIsOff() {
        var a = MusicEffectSettings(speed: 0.75), b = MusicEffectSettings(speed: 0.75)
        a.reverb.wet = 80; a.reverb.decay = 9
        #expect(a.sameSound(as: b))
        b.reverb.enabled = true
        #expect(!a.sameSound(as: b))
    }

    @Test func labelsAndSnapping() {
        #expect(MusicEffectSettings.speedLabel(1) == "Normal" && MusicEffectSettings.speedLabel(1.2) == "1.20x")
        #expect(MusicEffectSettings.pitchLabel(3) == "+3" && MusicEffectSettings.pitchLabel(-3) == "-3" && MusicEffectSettings.pitchLabel(0) == "0")
        #expect(MusicEffectSettings.snappedSpeed(1.23) == 1.25)
        #expect(MusicEffectSettings.snappedSpeed(5) == 2 && MusicEffectSettings.snappedSpeed(0.1) == 0.5)
    }

    @Test func roomForcesTempoToOne() {
        #expect(MusicEffectSettings(speed: 1.5, semitones: 2).inRoom() == MusicEffectSettings(speed: 1, semitones: 2))
    }
}

@Suite("Effect presets")
struct EffectPresetTests {
    @Test func builtInsHaveTheExactValues() {
        let by = Dictionary(uniqueKeysWithValues: MusicEffectPresets.builtIn.map { ($0.id, $0.settings) })
        #expect(MusicEffectPresets.builtIn.map(\.id) == ["original", "slowed", "nightcore", "practice", "hall"])
        #expect(by["original"] == .original)
        let slowed = by["slowed"]!
        #expect(slowed.speed == 0.85 && slowed.semitones == -3 && slowed.reverb.enabled && slowed.reverb.preset == 4 && slowed.reverb.decay == 1.8 && slowed.reverb.wet == 40)
        let night = by["nightcore"]!
        #expect(night.speed == 1.2 && night.semitones == 3 && night.reverb.preset == 6 && night.reverb.wet == 15 && night.reverb.decay == 1.2 && night.reverb.preDelay == 20)
        let practice = by["practice"]!
        #expect(practice.speed == 0.75 && practice.semitones == 0 && !practice.reverb.enabled)
        let hall = by["hall"]!
        #expect(hall.speed == 1 && hall.reverb.enabled && hall.reverb.preset == 5 && hall.reverb.decay == 3.2 && hall.reverb.wet == 25)
        #expect(MusicEffectPresets.builtIn.allSatisfy { $0.settings.isValid })
    }

    @Test func activeChipIsTheFirstBuiltInThenTheFirstSaved() {
        let saved = [MusicEffectPreset(name: "Mine", settings: MusicEffectSettings(speed: 0.6))]
        #expect(MusicEffectPresets.activeChip(for: MusicEffectSettings(speed: 0.75), saved: saved) == "practice")
        #expect(MusicEffectPresets.activeChip(for: MusicEffectSettings(speed: 0.6), saved: saved) == "saved:mine")
        #expect(MusicEffectPresets.activeChip(for: MusicEffectSettings(speed: 1.35), saved: saved) == nil)
    }

    private func json(_ presets: [[String: Any]]) -> Data { (try? JSONSerialization.data(withJSONObject: presets)) ?? Data() }
    private func preset(_ name: String, speed: Double = 1, semitones: Int = 0, reverb: [String: Any]? = nil) -> [String: Any] {
        ["name": name, "speed": speed, "semitones": semitones,
         "reverb": reverb ?? ["enabled": false, "preset": 3, "dry": 100, "wet": 25, "decay": 1.1, "preDelay": 0, "damping": 8000, "reflections": 100]]
    }

    @Test func readingAcceptsAGoodFileAndRaisesOldTempos() {
        let ok = MusicEffectPresets.parse(json([preset("  Night  ", speed: 0.25), preset("Other", semitones: -12)]))
        #expect(ok?.count == 2 && ok?[0].name == "Night" && ok?[0].speed == 0.5)
    }

    @Test func oneBadPresetRejectsTheWholeFile() {
        #expect(MusicEffectPresets.parse(json([preset("A"), preset("a")])) == nil)                 // duplicate ignoring case
        #expect(MusicEffectPresets.parse(json([preset("   ")])) == nil)                           // empty after trimming
        #expect(MusicEffectPresets.parse(json([preset(String(repeating: "x", count: 81))])) == nil)
        #expect(MusicEffectPresets.parse(json([preset("A", speed: 2.5)])) == nil)
        #expect(MusicEffectPresets.parse(json([preset("A", speed: 0.2)])) == nil)
        #expect(MusicEffectPresets.parse(json([preset("A", semitones: 13)])) == nil)
        #expect(MusicEffectPresets.parse(json([preset("A", semitones: 2)] + [["name": "B", "speed": 1, "semitones": 1.5, "reverb": [:]]])) == nil)
        #expect(MusicEffectPresets.parse(json([preset("A", reverb: ["enabled": true, "preset": 7, "dry": 100, "wet": 25, "decay": 1, "preDelay": 0, "damping": 8000, "reflections": 100])])) == nil)
        #expect(MusicEffectPresets.parse(json([preset("A", reverb: ["enabled": true, "preset": 3, "dry": 100.5, "wet": 25, "decay": 1, "preDelay": 0, "damping": 8000, "reflections": 100])])) == nil)
        #expect(MusicEffectPresets.parse(Data("not json".utf8)) == nil)
        #expect(MusicEffectPresets.parse(Data("[]".utf8)) == [])
    }

    @MainActor @Test func savingRulesAndPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fx-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MusicEffectPresetStore(directory: dir)
        let mine = MusicEffectSettings(speed: 0.6, semitones: 2)
        #expect(store.save(name: "  ", settings: mine) == .invalidName)
        #expect(store.save(name: String(repeating: "n", count: 81), settings: mine) == .invalidName)
        #expect(store.save(name: "Mine", settings: mine) == .saved)
        #expect(store.save(name: "MINE", settings: MusicEffectSettings(speed: 0.7), replace: false) == .needsReplace)
        #expect(store.save(name: "MINE", settings: MusicEffectSettings(speed: 0.7), replace: true) == .replaced)
        #expect(store.presets.count == 1 && store.presets[0].name == "MINE" && store.presets[0].speed == 0.7)
        // The same sound as a built-in or a saved one cannot be saved again.
        #expect(store.save(name: "Same", settings: MusicEffectSettings(speed: 0.75)) == .nothingToSave)
        #expect(store.save(name: "Same", settings: MusicEffectSettings(speed: 0.7)) == .nothingToSave)
        // In a room the preset keeps its own stored tempo.
        #expect(store.save(name: "Room", settings: MusicEffectSettings(speed: 1, semitones: 4), storedTempo: 1.4) == .saved)
        #expect(store.presets.last?.speed == 1.4)
        let reloaded = MusicEffectPresetStore(directory: dir)
        #expect(reloaded.presets.map(\.name) == ["MINE", "Room"])
        // Loading never touches the saved copy, and a room forces tempo 1.
        let loaded = MusicEffectPresetStore.settings(for: reloaded.presets[1], inRoom: true)
        #expect(loaded.speed == 1 && reloaded.presets[1].speed == 1.4)
        reloaded.delete(reloaded.presets[0])
        #expect(MusicEffectPresetStore(directory: dir).presets.count == 1)
    }

    @MainActor @Test func anUnreadableFileTurnsSavingOffAndIsNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fx-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("effect-presets.json")
        try Data("garbage".utf8).write(to: file)
        let store = MusicEffectPresetStore(directory: dir)
        #expect(store.loadError != nil && !store.canSave)
        #expect(store.save(name: "A", settings: MusicEffectSettings(speed: 0.6)) == .unavailable)
        #expect((try? Data(contentsOf: file)) == Data("garbage".utf8))
    }

    @Test func tailBarsGetTallerForALongerDecay() {
        let short = MusicEffectsLogic.tailBars(decay: 0.4), long = MusicEffectsLogic.tailBars(decay: 3.2)
        #expect(short.count == 9 && long.count == 9)
        #expect(zip(short, long).allSatisfy { $0 <= $1 })
        #expect(MusicEffectsLogic.songLength(duration: 180, tempo: 1.5) == "2:00")
        #expect(MusicEffectsLogic.songLength(duration: 180, tempo: 1) == nil)
        #expect(MusicEffectsLogic.kHz(8000) == "8.0 kHz")
    }
}

// MARK: lookahead and failures

@Suite("Gapless lookahead")
struct GaplessTests {
    @Test func skipReasons() {
        #expect(MusicGaplessState.skipReason(repeatMode: .one, hasNext: true, currentIsLive: false, nextIsLive: false) == .repeatOne)
        #expect(MusicGaplessState.skipReason(repeatMode: .off, hasNext: true, currentIsLive: true, nextIsLive: false) == .liveCurrent)
        #expect(MusicGaplessState.skipReason(repeatMode: .off, hasNext: true, currentIsLive: false, nextIsLive: true) == .liveNext)
        #expect(MusicGaplessState.skipReason(repeatMode: .off, hasNext: false, currentIsLive: false, nextIsLive: false) == .noNext)
        #expect(MusicGaplessState.skipReason(repeatMode: .all, hasNext: true, currentIsLive: false, nextIsLive: false) == .none)
    }

    @Test func aDuplicatePrimeIsRefusedAndALateOneCannotCommit() {
        var g = MusicGaplessState()
        let a = UUID(), b = UUID()
        let gen = g.begin(for: a)
        #expect(gen != nil && g.begin(for: a) == nil)
        #expect(g.canCommit(generation: gen!, id: a, nextRowID: a))
        #expect(!g.canCommit(generation: gen!, id: a, nextRowID: b))          // the slot changed meanwhile
        g.invalidate()
        #expect(!g.canCommit(generation: gen!, id: a, nextRowID: a))          // invalidated meanwhile
        let g2 = g.begin(for: a)!
        g.commit(a)
        #expect(!g.canCommit(generation: g2, id: a, nextRowID: a))            // already primed: no second entry
        #expect(g.primedID == a && g.begin(for: a) == nil)
    }

    @Test func aPrimedRowThatIsNoLongerNextIsStale() {
        var g = MusicGaplessState()
        let a = UUID()
        let gen = g.begin(for: a)!
        #expect(g.canCommit(generation: gen, id: a, nextRowID: a))
        g.commit(a)
        #expect(!g.isStale(nextRowID: a))
        #expect(g.isStale(nextRowID: UUID()) && g.isStale(nextRowID: nil))
        #expect(g.isGaplessAdvance(nextRowID: a, engineIdle: false))
        #expect(!g.isGaplessAdvance(nextRowID: a, engineIdle: true))
        #expect(!g.isGaplessAdvance(nextRowID: UUID(), engineIdle: false))
    }

    @Test func atMostThreeRowsAreRemovedPerPrime() {
        var b = MusicPrimeBudget()
        for _ in 0..<3 { #expect(b.canRemoveAnother); b.recordRemoval() }
        #expect(!b.canRemoveAnother)
    }
}

@Suite("Failure ladder")
struct FailureLadderTests {
    @Test func aStreamFailureRetriesOnceThenSkipsAndTheMarkerClearsWhenThePointerMoves() {
        var l = MusicFailureLadder()
        let row = UUID()
        #expect(l.decide(.thisTrack, row: row, title: "A", resolveFailure: false, atTail: false) == .retry)
        #expect(l.decide(.thisTrack, row: row, title: "A", resolveFailure: false, atTail: false) == .skip("Skipped (unavailable): A"))
        l.pointerMoved()
        #expect(l.decide(.thisTrack, row: row, title: "A", resolveFailure: false, atTail: false) == .retry)
    }

    @Test func skipsStopAtTheTailEvenUnderRepeatAll() {
        var l = MusicFailureLadder()
        let a = UUID(), b = UUID()
        #expect(l.decide(.thisTrack, row: a, title: "A", resolveFailure: true, atTail: true) == .retry)
        #expect(l.decide(.thisTrack, row: a, title: "A", resolveFailure: true, atTail: true) == .stopWithError)
        #expect(l.decide(.needsSignIn, row: b, title: "Mine", resolveFailure: true, atTail: false) == .retry)
        #expect(l.decide(.needsSignIn, row: b, title: "Mine", resolveFailure: true, atTail: false) == .skip("Skipped (sign-in needed): Mine"))
    }

    @Test func offlineAndAccountFailuresNeverSkipOrDelete() {
        var l = MusicFailureLadder()
        for resolve in [true, false] {
            #expect(l.decide(.affectsEveryTrack, row: UUID(), title: "A", resolveFailure: resolve, atTail: false) == .stay)
        }
    }

    @Test func aLostDeviceNeverRetriesOrSkips() {
        var l = MusicFailureLadder()
        let row = UUID()
        for _ in 0..<3 { #expect(l.decide(.deviceLost, row: row, title: "A", resolveFailure: false, atTail: false) == .holdForDevice) }
        #expect(MusicPlaybackMessages.deviceLost == "Your audio device is unavailable. Press play once it's back.")
    }

    @Test func aMissingLocalFileIsRemovedWithANote() {
        var l = MusicFailureLadder()
        #expect(l.decide(.missingLocalFile, row: UUID(), title: "Demo", resolveFailure: true, atTail: false) == .removeRow("Demo is no longer on your disk"))
    }

    @Test func errorsAreClassified() {
        #expect(MusicFailureKind.classify(MusicError.network("x")) == .affectsEveryTrack)
        #expect(MusicFailureKind.classify(MusicError.noPlayableSource("x")) == .thisTrack)
        #expect(MusicFailureKind.classify(MusicError.notSignedIn("p")) == .needsSignIn)
        #expect(MusicFailureKind.classify(URLError(.notConnectedToInternet)) == .affectsEveryTrack)
        #expect(MusicFailureKind.classify(URLError(.fileDoesNotExist)) == .thisTrack)
        #expect(MusicFailureKind.classify(MusicLocalFileMissing(title: "x")) == .missingLocalFile)
    }

    @Test func offlineLadderIsTwoFourEightFifteenThenThirtyAndResetsAfterFiveQuietMinutes() {
        var l = MusicOfflineLadder()
        let t0 = Date()
        var seen: [TimeInterval] = []
        for i in 0..<10 { if let d = l.nextDelay(now: t0.addingTimeInterval(Double(i))) { seen.append(d) } }
        #expect(seen == [2, 4, 8, 15, 30, 30, 30, 30, 30, 30])
        #expect(l.nextDelay(now: t0.addingTimeInterval(11)) == nil)
        #expect(l.nextDelay(now: t0.addingTimeInterval(11 + 301)) == 2)
    }
}

// MARK: proxy

@Suite("Stream proxy chunking")
struct ProxyChunkingTests {
    @Test func windowsAreBoundedToFourMebibytesAndCoverTheRangeExactly() {
        let mib: Int64 = 1_048_576
        let w = MusicProxyChunker.windows(start: 0, end: 10 * mib - 1)
        #expect(w.count == 3 && w[0] == 0...(4 * mib - 1) && w[1] == (4 * mib)...(8 * mib - 1) && w[2] == (8 * mib)...(10 * mib - 1))
        #expect(MusicProxyChunker.windows(start: 5, end: 5) == [5...5])
        #expect(MusicProxyChunker.windows(start: 10, end: 5).isEmpty)
        let odd = MusicProxyChunker.windows(start: 123, end: 9_000_000)
        #expect(odd.first?.lowerBound == 123 && odd.last?.upperBound == 9_000_000)
        #expect(zip(odd, odd.dropFirst()).allSatisfy { $0.upperBound + 1 == $1.lowerBound })
        #expect(odd.allSatisfy { $0.upperBound - $0.lowerBound + 1 <= 4 * mib })
    }

    @Test func aChunkCountsOnlyAs206WithExactlyTheRequestedBytes() {
        #expect(MusicProxyChunker.accepts(status: 206, body: 100, window: 0...99))
        #expect(!MusicProxyChunker.accepts(status: 200, body: 100, window: 0...99))
        #expect(!MusicProxyChunker.accepts(status: 206, body: 99, window: 0...99))
    }

    /// A stub upstream that serves a byte pattern by range, standing in for the host.
    private func stub(_ window: ClosedRange<Int64>, total: Int) -> Data {
        Data((window.lowerBound...min(window.upperBound, Int64(total - 1))).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    @Test func fetchingChunkByChunkRebuildsTheExactFile() {
        let total = 9_500_000
        let want = MusicProxyHTTP.resolve(MusicByteRange(start: 1_000_000, end: nil), total: Int64(total))!
        var assembled = Data()
        for w in MusicProxyChunker.windows(start: want.start, end: want.end) {
            let body = stub(w, total: total)
            #expect(MusicProxyChunker.accepts(status: 206, body: body.count, window: w))
            assembled.append(body)
        }
        #expect(assembled == stub(1_000_000...Int64(total - 1), total: total))
    }

    @Test func suffixAndOpenRangesResolveAgainstTheTotal() {
        #expect(MusicProxyHTTP.parseRange("bytes=-500") == MusicByteRange(start: 0, end: nil, suffix: 500))
        let s = MusicProxyHTTP.resolve(MusicProxyHTTP.parseRange("bytes=-500"), total: 10_000)
        #expect(s?.start == 9_500 && s?.end == 9_999)
        let all = MusicProxyHTTP.resolve(MusicProxyHTTP.parseRange("bytes=-99999"), total: 1_000)
        #expect(all?.start == 0 && all?.end == 999)
        #expect(MusicProxyHTTP.resolve(MusicProxyHTTP.parseRange("bytes=1000-"), total: 1_000) == nil)    // answered 416
        #expect(MusicProxyHTTP.parseRange("bytes=0-9,20-29") == MusicByteRange(start: 0, end: 9))      // the first of several
        #expect(MusicProxyHTTP.parseRange("bytes=junk") == nil)
        #expect(MusicProxyHTTP.resolve(MusicByteRange(start: 0, end: 5_000_000), total: 1_000)?.end == 999)
    }

    @Test func bypassForAUserProxyLiveAndPlaylistStreams() throws {
        let file = try #require(URL(string: "https://host.example/a.m4a"))
        #expect(!MusicProxyChunker.shouldBypass(proto: .progressive, url: file, userProxyActive: false))
        #expect(MusicProxyChunker.shouldBypass(proto: .progressive, url: file, userProxyActive: true))
        #expect(MusicProxyChunker.shouldBypass(proto: .hls, url: file, userProxyActive: false))
        #expect(MusicProxyChunker.shouldBypass(proto: .progressive, url: URL(fileURLWithPath: "/tmp/a.m4a"), userProxyActive: false))
    }

    @Test func throttlingHostsAreRecognised() throws {
        #expect(MusicProxyChunker.throttlesOpenRanges(try #require(URL(string: "https://rr1---sn.googlevideo.com/videoplayback?x=1"))))
        #expect(MusicProxyChunker.throttlesOpenRanges(try #require(URL(string: "https://piped.example/videoplayback?id=1"))))
        #expect(!MusicProxyChunker.throttlesOpenRanges(try #require(URL(string: "https://cdn.example/a.mp3"))))
        #expect(MusicProxyChunker.chunkBytes == 4 * 1_048_576 && MusicProxyChunker.stallSeconds == 20 && MusicProxyChunker.headerTimeoutSeconds == 15)
    }
}

// MARK: keys and windows

@Suite("Shortcuts and hotkeys")
struct ShortcutTests {
    private func key(_ c: String, code: UInt16 = 0, cmd: Bool = false, shift: Bool = false, alt: Bool = false, ctrl: Bool = false,
                     typing: Bool = false, arrowOwner: Bool = false, playing: Bool = true) -> MusicKeyEvent {
        MusicKeyEvent(character: c, keyCode: code, command: cmd, shift: shift, option: alt, control: ctrl, typing: typing, arrowOwner: arrowOwner, somethingPlaying: playing)
    }

    @Test func inAppTable() {
        #expect(MusicShortcutTable.action(for: key(" ")) == .playPause)
        #expect(MusicShortcutTable.action(for: key(";")) == .playPause)
        #expect(MusicShortcutTable.action(for: key("", code: 123)) == .seekBack)
        #expect(MusicShortcutTable.action(for: key("", code: 124)) == .seekForward)
        #expect(MusicShortcutTable.action(for: key("", code: 126)) == .volumeUp)
        #expect(MusicShortcutTable.action(for: key("", code: 125)) == .volumeDown)
        #expect(MusicShortcutTable.action(for: key("", code: 124, cmd: true)) == .next)
        #expect(MusicShortcutTable.action(for: key("d", cmd: true)) == .previous)
        #expect(MusicShortcutTable.action(for: key("s", cmd: true)) == .shuffle)
        #expect(MusicShortcutTable.action(for: key("r", cmd: true)) == .repeatCycle)
        #expect(MusicShortcutTable.action(for: key("l", cmd: true)) == .like)
        #expect(MusicShortcutTable.action(for: key("m", cmd: true, shift: true)) == .mute)
        #expect(MusicShortcutTable.action(for: key("m", cmd: true)) == nil)
        #expect(MusicShortcutTable.action(for: key(".", cmd: true)) == .volumeUp)
        #expect(MusicShortcutTable.action(for: key(",", cmd: true)) == .volumeDown)
        #expect(MusicShortcutTable.action(for: key("k", cmd: true)) == .search)
        #expect(MusicShortcutTable.action(for: key("e", cmd: true)) == .toggleNowPlaying)
        #expect(MusicShortcutTable.action(for: key("/", cmd: true)) == .showShortcuts)
        #expect(MusicShortcutTable.action(for: key("", code: 96)) == .reload)
        #expect(MusicShortcutTable.action(for: key("", code: 53)) == .escape)
        #expect(MusicShortcutTable.action(for: key("m", ctrl: true), mac: false) == .mute)
    }

    @Test func guardsKeepTypingAndOtherControlsSafe() {
        #expect(MusicShortcutTable.action(for: key(" ", typing: true)) == nil)
        #expect(MusicShortcutTable.action(for: key("", code: 123, arrowOwner: true)) == nil)
        #expect(MusicShortcutTable.action(for: key("", code: 123, playing: false)) == nil)
        #expect(MusicShortcutTable.action(for: key(" ", shift: true)) == nil)
        #expect(MusicShortcutTable.action(for: key(" ", alt: true)) == nil)
        // Ctrl+Alt belongs to the global hotkeys.
        #expect(MusicShortcutTable.action(for: key("f", cmd: true, alt: true)) == nil)
        #expect(MusicShortcutTable.action(for: key("e", cmd: true, playing: false)) == nil)
    }

    @Test func roomLockCoversTransportButNotVolumeMuteOrLike() {
        for a in MusicShortcutAction.allCases {
            let locked: Set<MusicShortcutAction> = [.playPause, .seekBack, .seekForward, .next, .previous, .shuffle, .repeatCycle]
            #expect(a.followsRoomHost == locked.contains(a))
        }
    }

    @Test func globalBindingsParseAndValidate() throws {
        let b = try MusicHotkeyBinding.parse("Ctrl+Alt+Space")
        #expect(b.keyCode == 49 && b.control && b.option && !b.command && b.carbonModifiers == 4096 + 2048)
        #expect(b.text == "Ctrl+Alt+Space")
        #expect(try MusicHotkeyBinding.parse("super+shift+ctrl+alt+left").text == "Ctrl+Alt+Shift+Super+Left")
        #expect(try MusicHotkeyBinding.parse("F7").isFunctionKey)
        #expect(throws: MusicHotkeyBinding.ParseError.needsModifier) { try MusicHotkeyBinding.parse("Shift+A") }
        #expect(throws: MusicHotkeyBinding.ParseError.needsModifier) { try MusicHotkeyBinding.parse("Space") }
        #expect(throws: MusicHotkeyBinding.ParseError.mediaKey) { try MusicHotkeyBinding.parse("Ctrl+MediaPlayPause") }
        #expect(throws: MusicHotkeyBinding.ParseError.empty) { try MusicHotkeyBinding.parse("  ") }
        #expect(throws: MusicHotkeyBinding.ParseError.self) { try MusicHotkeyBinding.parse("Ctrl+Banana") }
        #expect(MusicHotkeyBinding.token(forKeyCode: 49) == "Space" && MusicHotkeyBinding.token(forKeyCode: 123) == "Left")
    }

    @Test func defaultsAreOffAndMuteShuffleRepeatStartUnbound() {
        let c = MusicHotkeyConfig()
        #expect(!c.enabled)
        #expect(c.binding(for: .playPause) == "Ctrl+Alt+Space" && c.binding(for: .showApp) == "Ctrl+Alt+Home")
        #expect(c.binding(for: .seekForward) == "Ctrl+Alt+PageUp" && c.binding(for: .seekBackward) == "Ctrl+Alt+PageDown")
        for a in [MusicGlobalHotkeyAction.muteToggle, .toggleShuffle, .toggleRepeat] { #expect(c.binding(for: a).isEmpty) }
        for a in MusicGlobalHotkeyAction.allCases where !a.defaultBinding.isEmpty { #expect((try? MusicHotkeyBinding.parse(a.defaultBinding)) != nil) }
    }

    @Test func duplicatesAreFoundIgnoringCase() throws {
        var c = MusicHotkeyConfig()
        c.bindings["mute_toggle"] = "ctrl+alt+space"
        let b = try MusicHotkeyBinding.parse("Ctrl+Alt+Space")
        #expect(c.holder(of: b, except: .toggleShuffle) == .playPause || c.holder(of: b, except: .toggleShuffle) == .muteToggle)
        #expect(c.holder(of: b, except: .playPause) == .muteToggle)
    }
}

@Suite("Mini player, theatre and desktop rules")
struct SurfaceRuleTests {
    @Test func sizesAndTheCompactSwitch() {
        #expect(MusicMiniLayout.full == CGSize(width: 560, height: 180) && MusicMiniLayout.compact == CGSize(width: 320, height: 88))
        #expect(MusicMiniLayout.isCompact(width: 439) && !MusicMiniLayout.isCompact(width: 440))
    }

    @Test func resizingKeepsTheEdgesTheWidgetIsParkedNear() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Bottom right: keeps the right and bottom edges.
        let br = CGRect(x: 1440 - 24 - 560, y: 24, width: 560, height: 180)
        let small = MusicMiniLayout.resized(frame: br, to: MusicMiniLayout.compact, display: display)
        #expect(small.maxX == br.maxX && small.minY == br.minY)
        #expect(MusicMiniLayout.resized(frame: small, to: MusicMiniLayout.full, display: display) == br)
        // Top left: keeps the left and top edges.
        let tl = CGRect(x: 24, y: 900 - 24 - 180, width: 560, height: 180)
        let t2 = MusicMiniLayout.resized(frame: tl, to: MusicMiniLayout.compact, display: display)
        #expect(t2.minX == tl.minX && t2.maxY == tl.maxY)
    }

    @Test func aSavedPositionCountsOnlyWhenItsMiddleIsOnAConnectedDisplay() {
        let displays = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        #expect(MusicMiniLayout.isOnScreen(origin: CGPoint(x: 100, y: 100), size: MusicMiniLayout.full, displays: displays))
        #expect(!MusicMiniLayout.isOnScreen(origin: CGPoint(x: 3000, y: 100), size: MusicMiniLayout.full, displays: displays))
        #expect(MusicMiniLayout.defaultOrigin(size: MusicMiniLayout.full, workArea: CGRect(x: 0, y: 25, width: 1440, height: 850)) == CGPoint(x: 856, y: 49))
    }

    @Test func theatreColumnsNeedWidthAndShareOneColumnBelowTheTwoColumnWidth() {
        #expect(MusicTheatreLayout.columns(width: 900, lyrics: true, queue: true) == (false, false))
        #expect(MusicTheatreLayout.columns(width: 1100, lyrics: true, queue: true) == (true, false))
        #expect(MusicTheatreLayout.columns(width: 1100, lyrics: true, queue: true, preferLyrics: false) == (false, true))
        #expect(MusicTheatreLayout.columns(width: 1500, lyrics: true, queue: true) == (true, true))
        #expect(MusicTheatreLayout.headerHeight(windowHeight: 800) == 64 && MusicTheatreLayout.headerHeight(windowHeight: 801) == 80)
    }

    @Test func coverSideAndUpNextHint() {
        #expect(MusicTheatreLayout.coverSide(columnWidth: 2000, availableHeight: 2000, spotlight: false, titleWraps: false) == 544)
        #expect(MusicTheatreLayout.coverSide(columnWidth: 2000, availableHeight: 2000, spotlight: true, titleWraps: false) == 704)
        #expect(MusicTheatreLayout.coverSide(columnWidth: 2000, availableHeight: 604, spotlight: false, titleWraps: true) == 458)
        #expect(MusicTheatreLayout.showsUpNext(position: 170, duration: 190, queueColumn: false, repeatMode: .off))
        #expect(!MusicTheatreLayout.showsUpNext(position: 100, duration: 190, queueColumn: false, repeatMode: .off))
        #expect(!MusicTheatreLayout.showsUpNext(position: 170, duration: 190, queueColumn: true, repeatMode: .off))
        #expect(!MusicTheatreLayout.showsUpNext(position: 170, duration: 190, queueColumn: false, repeatMode: .one))
        #expect(!MusicTheatreLayout.showsUpNext(position: 20, duration: 28, queueColumn: false, repeatMode: .off))
    }

    @Test func windowTitleAndNotificationRules() {
        #expect(MusicDesktopRules.windowTitle(for: nil) == "StreamSetu Music")
        #expect(MusicDesktopRules.windowTitle(for: song(1)) == "Song 1 \u{2014} Artist 1")
        var bare = song(2); bare.artists = []
        #expect(MusicDesktopRules.windowTitle(for: bare) == "Song 2")
        // Background: always (except the restored track). Focused: only for songs that started on their own, and only with the option on.
        #expect(MusicDesktopRules.shouldNotify(change: .picked, enabled: true, focusedOption: false, appFocused: false))
        #expect(!MusicDesktopRules.shouldNotify(change: .picked, enabled: true, focusedOption: true, appFocused: true))
        #expect(MusicDesktopRules.shouldNotify(change: .gapless, enabled: true, focusedOption: true, appFocused: true))
        #expect(!MusicDesktopRules.shouldNotify(change: .gapless, enabled: true, focusedOption: false, appFocused: true))
        #expect(!MusicDesktopRules.shouldNotify(change: .restored, enabled: true, focusedOption: true, appFocused: false))
        #expect(!MusicDesktopRules.shouldNotify(change: .picked, enabled: false, focusedOption: true, appFocused: false))
    }

    @Test func playerPrefsDefaultsAndOldFiles() throws {
        let p = try JSONDecoder().decode(MusicPlayerPrefs.self, from: Data("{}".utf8))
        #expect(!p.preventDuplicates && !p.stickyShuffle && p.shuffleWholeQueue && !p.playOnStart)
        #expect(p.crossfadeLength == 5 && !p.trackNotifications && !p.trackNotificationsFocused)
        #expect(p.windowTitleFollowsTrack && !p.menuBarItem && !p.miniCompact && p.miniPositionX == nil)
        #expect(p.theatreLyrics && !p.theatreQueue && !p.theatreClock && p.theatreClockSide == "right" && p.theatreClockFormat == "auto")
        #expect(!p.globalHotkeys.enabled)
        let clamped = try JSONDecoder().decode(MusicPlayerPrefs.self, from: Data(#"{"crossfadeLength":50}"#.utf8))
        #expect(clamped.crossfadeLength == 10)
    }
}
