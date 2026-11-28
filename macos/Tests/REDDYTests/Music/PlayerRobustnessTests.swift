import Testing
import Foundation
@testable import REDDY

private func track(_ n: Int) -> MusicTrack {
    MusicTrack(id: "t\(n)", providerID: "p", title: "Song \(n)", durationMs: 200_000, artists: [MusicArtistRef(id: "a", name: "Artist")])
}

private func queue(_ n: Int, playing: Int = 0) -> MusicQueue {
    var q = MusicQueue()
    q.replace(with: (0..<n).map(track), startAt: playing)
    return q
}

private func titles(_ q: MusicQueue) -> [String] { q.entries.map(\.track.title) }

// MARK: seek coalescing

@Suite("Seek coalescing")
struct SeekCoalescingTests {
    @Test func theFirstSeekGoesOutAndLaterOnesReplaceEachOtherWhileItIsInFlight() {
        var g = MusicSeekCoalescer()
        #expect(g.request(10) == 10)
        #expect(g.request(20) == nil)
        #expect(g.request(30) == nil)
        #expect(g.waiting == 30)
        #expect(g.landed() == 30)
        #expect(g.landed() == nil)
        #expect(!g.isBusy)
    }

    @Test func reportsFromBeforeTheSeekAreIgnoredUntilTheToleranceIsSpent() {
        var g = MusicSeekCoalescer()
        _ = g.request(100)
        #expect(g.report(12) == .ignore)
        #expect(g.report(12.25) == .ignore)
        #expect(g.report(12.5) == .resend(100))
    }

    @Test func aReportAtTheTargetCountsAsLanded() {
        var g = MusicSeekCoalescer()
        _ = g.request(100)
        #expect(g.report(100.05) == .accept(100))
    }

    @Test func aReportJustBeforeTheTargetIsShownAsTheTarget() {
        var g = MusicSeekCoalescer()
        _ = g.request(50)
        _ = g.landed()
        #expect(g.report(49.95) == .accept(50))
        // Only the first report after landing is snapped.
        #expect(g.report(49.95) == .accept(49.95))
    }

    @Test func aReportFarFromTheTargetAfterLandingIsTrusted() {
        var g = MusicSeekCoalescer()
        _ = g.request(50)
        _ = g.landed()
        #expect(g.report(50.4) == .accept(50.4))
    }

    @Test func resetForgetsEverything() {
        var g = MusicSeekCoalescer()
        _ = g.request(5); _ = g.request(6)
        g.reset()
        #expect(g == MusicSeekCoalescer())
    }
}

// MARK: stale pause and echo

@Suite("Stale pause and echo guard")
struct StalePauseTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func fiveMinutesOfPauseIsStale() {
        var s = MusicStalePause()
        s.paused(at: start)
        #expect(!s.isStale(at: start.addingTimeInterval(299)))
        #expect(s.isStale(at: start.addingTimeInterval(300)))
    }

    @Test func aClockSetBackCountsAsStale() {
        var s = MusicStalePause()
        s.paused(at: start)
        #expect(s.isStale(at: start.addingTimeInterval(-60)))
    }

    @Test func aSecondPauseKeepsTheEarlierMomentAndClearEndsIt() {
        var s = MusicStalePause()
        s.paused(at: start)
        s.paused(at: start.addingTimeInterval(200))
        #expect(s.isStale(at: start.addingTimeInterval(301)))
        s.clear()
        #expect(!s.isStale(at: start.addingTimeInterval(9_999)))
    }

    @Test func anOppositeOutsideCommandWithinTwoSecondsIsAnEcho() {
        var e = MusicPlayPauseEcho()
        let t = Date(timeIntervalSince1970: 5_000)
        e.pressed(playing: false, at: t)
        #expect(e.isEcho(wantsPlaying: true, at: t.addingTimeInterval(1.9)))
        #expect(!e.isEcho(wantsPlaying: true, at: t.addingTimeInterval(2)))
        #expect(!e.isEcho(wantsPlaying: false, at: t.addingTimeInterval(0.5)))
    }

    @Test func aRemotePressIsNeverTreatedAsTheEchoOfItself() {
        var e = MusicPlayPauseEcho()
        let t = Date(timeIntervalSince1970: 5_000)
        e.pressed(playing: true, at: t, remote: true)
        #expect(!e.isEcho(wantsPlaying: false, at: t.addingTimeInterval(0.5)))
    }
}

// MARK: throttled sources and the tail rule

@Suite("Throttled source branch")
struct ThrottleBranchTests {
    @Test func waitsDoubleFromTwoToThirtySecondsThenHold() {
        var t = MusicThrottleLadder()
        var waits: [TimeInterval] = []
        var announced: [Bool] = []
        for _ in 0..<MusicThrottleLadder.maxRefusals {
            if case .wait(let s, let a) = t.refused() { waits.append(s); announced.append(a) }
        }
        #expect(waits == [2, 4, 8, 16, 30, 30])
        #expect(announced == [true, false, false, false, false, false])
        #expect(t.refused() == .hold)
    }

    @Test func aSourceWaitIsHonouredButCapped() {
        var t = MusicThrottleLadder()
        #expect(t.refused(retryAfter: 10) == .wait(10, announce: true))
        #expect(t.refused(retryAfter: 500) == .wait(30, announce: false))
    }

    @Test func rateLimitedIsItsOwnKindAndNeverSkips() {
        #expect(MusicFailureKind.classify(MusicError.rateLimited(retryAfter: nil)) == .throttled)
        var l = MusicFailureLadder()
        let row = UUID()
        for _ in 0..<MusicThrottleLadder.maxRefusals {
            let a = l.decide(.throttled, row: row, title: "T", resolveFailure: true, atTail: false)
            if case .waitAndRetry = a {} else { Issue.record("expected a wait, got \(a)") }
        }
        if case .holdThrottled = l.decide(.throttled, row: row, title: "T", resolveFailure: true, atTail: false) {} else { Issue.record("expected a hold") }
        #expect(l.consecutive == 0, "a throttled track is not a failed track")
    }

    @Test func aSongThatPlaysOrAPressOfPlayRestartsTheWaits() {
        var l = MusicFailureLadder()
        let row = UUID()
        _ = l.decide(.throttled, row: row, title: "T", resolveFailure: true, atTail: false)
        _ = l.decide(.throttled, row: row, title: "T", resolveFailure: true, atTail: false)
        l.playbackStarted()
        #expect(l.decide(.throttled, row: row, title: "T", resolveFailure: true, atTail: false) == .waitAndRetry(2, announce: true))
        _ = l.decide(.throttled, row: row, title: "T", resolveFailure: true, atTail: false)
        l.userRetried()
        #expect(l.decide(.throttled, row: row, title: "T", resolveFailure: true, atTail: false) == .waitAndRetry(2, announce: true))
    }

    @Test func aRefusedNetworkHoldsInPlace() {
        // A single refused request skips to the next candidate; the hold only applies when the ladder is told the whole network is refused.
        #expect(MusicFailureKind.classify(MusicError.refused("example.org")) == .thisTrack)
        var l = MusicFailureLadder()
        if case .holdNetworkRefused = l.decide(.networkRefused, row: UUID(), title: "T", resolveFailure: true, atTail: false) {} else { Issue.record("expected a hold") }
    }

    @Test func existingKindsAreUnchanged() {
        #expect(MusicFailureKind.classify(MusicError.network("x")) == .affectsEveryTrack)
        #expect(MusicFailureKind.classify(MusicError.notSignedIn("p")) == .needsSignIn)
        #expect(MusicFailureKind.classify(MusicError.noPlayableSource("x")) == .thisTrack)
    }

    @Test func repeatAllWrapsOnlyWhileSomeOtherRowIsPlayable() {
        #expect(MusicWrapRule.wraps(repeatMode: .all, current: 2, playable: [true, false, true]))
        #expect(!MusicWrapRule.wraps(repeatMode: .all, current: 2, playable: [false, false, true]))
        #expect(!MusicWrapRule.wraps(repeatMode: .off, current: 2, playable: [true, true, true]))
        #expect(!MusicWrapRule.wraps(repeatMode: .all, current: 5, playable: [true]))
    }

    @Test func aFailureAtTheWrappingTailSkipsInsteadOfStopping() {
        var l = MusicFailureLadder()
        let row = UUID()
        _ = l.decide(.thisTrack, row: row, title: "T", resolveFailure: true, atTail: false)
        if case .skip = l.decide(.thisTrack, row: row, title: "T", resolveFailure: true, atTail: false) {} else { Issue.record("expected a skip") }
        var m = MusicFailureLadder()
        _ = m.decide(.thisTrack, row: row, title: "T", resolveFailure: true, atTail: true)
        #expect(m.decide(.thisTrack, row: row, title: "T", resolveFailure: true, atTail: true) == .stopWithError)
    }
}

// MARK: output device

@MainActor
@Suite("Output device")
struct OutputDeviceTests {
    private let speakers = MusicOutputDeviceInfo(uid: "spk", name: "Speakers")
    private let dac = MusicOutputDeviceInfo(uid: "dac", name: "USB DAC")

    @Test func noChoiceFollowsTheSystemOutput() {
        #expect(MusicOutputDevicePolicy().resolve(available: [speakers, dac]) == .systemDefault)
    }

    @Test func aChosenDeviceThatIsMissingYieldsAndComesBack() {
        var p = MusicOutputDevicePolicy(chosen: "dac")
        #expect(p.resolve(available: [speakers]) == .yieldedMissing("dac"))
        #expect(p.resolve(available: [speakers, dac]) == .device("dac"))
        p.choose(nil)
        #expect(p.resolve(available: [speakers, dac]) == .systemDefault)
    }

    @Test func aDeviceThatWouldNotOpenIsSkippedUntilChosenAgainOrReturned() {
        var p = MusicOutputDevicePolicy(chosen: "dac")
        p.openFailed("dac")
        #expect(p.resolve(available: [dac]) == .yieldedFailed("dac"))
        p.listChanged(available: [dac])
        #expect(p.resolve(available: [dac]) == .yieldedFailed("dac"), "still listed, still skipped")
        p.listChanged(available: [speakers])
        #expect(p.resolve(available: [speakers, dac]) == .device("dac"), "left and came back: a fresh try")
        p.openFailed("dac")
        p.choose("dac")
        #expect(p.resolve(available: [dac]) == .device("dac"), "chosen again: a fresh try")
    }

    @Test func theControllerAppliesTheChoiceRemembersFailuresAndRecovers() throws {
        let suite = "music.output.test.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        var listed = [speakers, dac]
        var opens: [String?] = []
        var refuse: Set<String> = []
        let o = MusicOutputDevices(defaults: d, lister: { listed })
        o.apply = { uid in opens.append(uid); return uid.map { !refuse.contains($0) } ?? true }
        o.refresh()
        o.choose("dac")
        #expect(opens.last == "dac" && o.resolution == .device("dac"))
        #expect(d.string(forKey: MusicOutputDevices.uidKey) == "dac")
        // Unplugged: the system output takes over.
        listed = [speakers]
        o.refresh()
        #expect(o.resolution == .yieldedMissing("dac") && opens.last.map { $0 == nil } == true)
        // Plugged in again but it will not open: remembered, system output stays.
        refuse = ["dac"]
        listed = [speakers, dac]
        o.refresh()
        #expect(o.resolution == .yieldedFailed("dac") && opens.last.map { $0 == nil } == true)
        let opensBefore = opens.count
        o.refresh()
        #expect(opens.count == opensBefore, "no pointless reopen while nothing changed")
        // Gone and back with the fault cleared: used again.
        listed = [speakers]; o.refresh()
        refuse = []; listed = [speakers, dac]; o.refresh()
        #expect(o.resolution == .device("dac") && opens.last == "dac")
        // A new controller reads the remembered choice.
        let again = MusicOutputDevices(defaults: d, lister: { listed })
        #expect(again.chosenUID == "dac")
    }

    @Test func theNewKeysAreClassifiedInTheDefaultsList() {
        #expect(MusicDefaultsKeys.deviceSettings.contains(MusicOutputDevices.uidKey))
        #expect(MusicDefaultsKeys.deviceSettings.contains(MusicOutputDevices.nameKey))
    }
}

// MARK: queue undo

@Suite("Queue undo")
struct QueueUndoTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    @Test func undoingARemovalPutsTheRowBackAfterTheRowItFollowed() {
        var q = queue(5)
        var h = MusicQueueHistory()
        let row = q.removedRow(at: 2)!
        q.remove(at: 2)
        h.recordRemoval([row], at: t0)
        #expect(titles(q) == ["Song 0", "Song 1", "Song 3", "Song 4"])
        #expect(h.undo(on: &q) == .removed(1))
        #expect(titles(q) == ["Song 0", "Song 1", "Song 2", "Song 3", "Song 4"])
        #expect(h.redo(on: &q) == .removed(1))
        #expect(titles(q) == ["Song 0", "Song 1", "Song 3", "Song 4"])
    }

    @Test func removalsWithinTheToastWindowMergeIntoOneStepRestoredNewestFirst() {
        var q = queue(6)
        var h = MusicQueueHistory()
        for (i, at) in [(4, 0.0), (2, 3.0), (1, 6.0)] {
            let r = q.removedRow(at: i)!
            q.remove(at: i)
            h.recordRemoval([r], at: t0.addingTimeInterval(at))
        }
        #expect(h.undoStack.count == 1)
        #expect(titles(q) == ["Song 0", "Song 3", "Song 5"])
        #expect(h.undo(on: &q) == .removed(3))
        #expect(titles(q) == (0..<6).map { "Song \($0)" })
    }

    @Test func aRemovalAfterTheWindowIsAStepOfItsOwn() {
        var q = queue(4)
        var h = MusicQueueHistory()
        h.recordRemoval([q.removedRow(at: 1)!], at: t0); q.remove(at: 1)
        h.recordRemoval([q.removedRow(at: 1)!], at: t0.addingTimeInterval(MusicQueueHistory.mergeWindow + 1)); q.remove(at: 1)
        #expect(h.undoStack.count == 2)
        _ = h.undo(on: &q)
        #expect(titles(q) == ["Song 0", "Song 2", "Song 3"])
    }

    @Test func clearAndUndoBringBackTheUpcomingRowsAndLeaveThePlayingOne() {
        var q = queue(5, playing: 1)
        var h = MusicQueueHistory()
        let rows = q.upcomingRemovedRows()
        q.clear(keepCurrent: true)
        h.recordClear(rows, at: t0)
        #expect(titles(q) == ["Song 1"])
        #expect(h.undo(on: &q) == .cleared(3))
        #expect(titles(q) == ["Song 1", "Song 2", "Song 3", "Song 4"])
        #expect(q.current?.track.title == "Song 1")
    }

    @Test func playedRowsAreNotRestored() {
        var q = queue(4, playing: 2)
        var h = MusicQueueHistory()
        let played = q.removedRow(at: 0)!
        q.remove(at: 0)
        h.recordRemoval([played], at: t0)
        #expect(h.undo(on: &q) == .removed(0))
        #expect(titles(q) == ["Song 1", "Song 2", "Song 3"])
    }

    @Test func aRestoredRowIsClampedWhenItsNeighbourIsGone() {
        var q = queue(4)
        var h = MusicQueueHistory()
        h.recordRemoval([q.removedRow(at: 3)!], at: t0); q.remove(at: 3)
        h.recordRemoval([q.removedRow(at: 2)!], at: t0.addingTimeInterval(20)); q.remove(at: 2)
        q.remove(at: 1)
        _ = h.undo(on: &q)
        _ = h.undo(on: &q)
        #expect(Set(titles(q)) == ["Song 0", "Song 2", "Song 3"])
        #expect(q.current?.track.title == "Song 0")
    }

    @Test func aReorderUndoesAndRedoes() {
        var q = queue(5)
        var h = MusicQueueHistory()
        let id = q.entries[1].id
        let moved = q.moveUpcoming(from: 1, to: 3)
        #expect(moved)
        h.recordMove(id: id, from: 1, to: 3, at: t0)
        #expect(titles(q) == ["Song 0", "Song 2", "Song 3", "Song 1", "Song 4"])
        #expect(h.undo(on: &q) == .moved)
        #expect(titles(q) == (0..<5).map { "Song \($0)" })
        #expect(h.redo(on: &q) == .moved)
        #expect(titles(q) == ["Song 0", "Song 2", "Song 3", "Song 1", "Song 4"])
    }

    @Test func aNewEditClearsRedoAndAResetClearsEverything() {
        var q = queue(4)
        var h = MusicQueueHistory()
        h.recordRemoval([q.removedRow(at: 2)!], at: t0); q.remove(at: 2)
        _ = h.undo(on: &q)
        #expect(h.canRedo)
        h.recordRemoval([q.removedRow(at: 3)!], at: t0.addingTimeInterval(30)); q.remove(at: 3)
        #expect(!h.canRedo)
        h.reset()
        #expect(!h.canUndo && !h.canRedo)
    }

    @Test func undoPutsARowBackIntoTheShuffleSnapshotToo() {
        var q = queue(5)
        q.setShuffle(true, shuffler: { _ in })
        var h = MusicQueueHistory()
        let r = q.removedRow(at: 3)!
        q.remove(at: 3)
        h.recordRemoval([r], at: t0)
        _ = h.undo(on: &q)
        #expect(q.preShuffle?.count == 5)
    }

    @Test func theHistoryIsCapped() {
        var q = queue(2)
        var h = MusicQueueHistory()
        for i in 0..<(MusicQueueHistory.limit + 5) { h.recordMove(id: q.entries[1].id, from: 1, to: 1 + (i % 2 == 0 ? 1 : 0), at: t0.addingTimeInterval(Double(i) * 100)) }
        #expect(h.undoStack.count <= MusicQueueHistory.limit)
    }
}

// MARK: strings

@Suite("Robustness strings")
struct RobustnessStringsTests {
    @Test func everyNewUIStringHasHindiAndTelugu() throws {
        let keys = ["Output device", "Play through", "%@ (not connected)", "Following the system output", "Playing on %@", "Redo", "Queue cleared",
                    "Removed from queue", "Removed %d songs from queue", "Queue order changed",
                    MusicPlaybackMessages.throttledFirst, MusicPlaybackMessages.throttledHold, MusicPlaybackMessages.networkRefused]
        for code in ["hi", "te"] {
            let url = ServiceSources.root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localization/\(code).lproj/Localizable.strings")
            let text = try String(contentsOf: url, encoding: .utf8)
            for k in keys { #expect(text.contains("\"\(k)\" ="), "\(code) is missing: \(k)") }
        }
    }
}
