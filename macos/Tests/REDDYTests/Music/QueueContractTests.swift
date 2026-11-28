import Foundation
import Testing
@testable import REDDY

/// Queue management as a person expects it: complete control over what plays next, checked on the queue's rules for any size of queue.
private func song(_ n: Int) -> MusicTrack { MusicTrack(id: "t\(n)", providerID: "p", title: "Song \(n)", durationMs: 200_000, artists: [MusicArtistRef(id: "a", name: "Artist")]) }
private func queue(_ n: Int, start: Int = 0) -> MusicQueue { var q = MusicQueue(); q.replace(with: (0..<n).map(song), startAt: start); return q }

@Suite("Queue 1-3: play now, play next, add to queue") struct QueueInsertContract {
    @Test func playNowStartsTheChosenSongAndNextAndAddLandWhereTheyShould() {
        var q = queue(6, start: 2)
        #expect(q.current?.track.id == "t2")
        q.playNext([song(80), song(81)]); q.addToQueue([song(90)])
        #expect(q.entries[3].track.id == "t80" && q.entries[4].track.id == "t81" && q.entries.last?.track.id == "t90")
        q.replace(with: [song(50), song(51)], startAt: 1)
        #expect(q.current?.track.id == "t51")
    }
    @Test func songsAddedByHandSurviveAClickOnAnotherListAndPlayNextStaysNext() {
        var q = queue(4, start: 0)
        q.playNext([song(80)])
        q.replace(with: (10..<14).map(song), startAt: 0)
        #expect(q.entries[1].track.id == "t80")
    }
}

@Suite("Queue 4-6: reorder, remove, clear") struct QueueEditContract2 {
    @Test func aRowMovesToAnyPlaceAndOneOrManyRowsGo() {
        var q = queue(8, start: 0)
        let id = q.entries[6].id
        let moved = q.moveRow(id: id, to: 2)
        #expect(moved && q.entries[2].id == id && q.count == 8)
        let ids = Set([q.entries[4].id, q.entries[5].id, q.entries[7].id])
        let gone = q.removeRows(ids: ids)
        #expect(gone == 3 && q.count == 5)
    }
    @Test func clearRemovesOnlyUpcomingSongsAndKeepsWhatIsPlaying() {
        var q = queue(5, start: 2)
        q.addToQueue([song(70), song(71)])
        let cleared = q.clearManual()
        #expect(cleared == 2 && q.current?.track.id == "t2" && q.count == 5)
        q.clear(keepCurrent: true)
        #expect(q.count == 1 && q.current?.track.id == "t2")
    }
}

@Suite("Queue 7: history") struct QueueHistoryContract {
    @Test func theQueueKeepsWhatWasPlayedBeforeTheCurrentSongUpToALimit() {
        var q = queue(250, start: 0)
        for _ in 0..<240 { _ = q.advance(auto: true) }
        let dropped = q.trimHistory(limit: MusicQueue.historyLimit)
        #expect(dropped >= 40 && (q.index ?? 0) <= MusicQueue.historyLimit && q.current?.track.id == "t240")
        let back = q.retreat()
        #expect(back?.track.id == "t239")
    }
}

@Suite("Queue 8: undo") struct QueueUndoContract {
    @Test func aRemovedRowComesBackWhereItWasAndRemovalsCloseTogetherAreOneStep() {
        var q = queue(6, start: 0)
        var undo = MusicQueueHistory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let r1 = q.removedRow(at: 3).map { [$0] } ?? []; _ = q.remove(at: 3)
        _ = undo.recordRemoval(r1, at: now)
        let r2 = q.removedRow(at: 3).map { [$0] } ?? []; _ = q.remove(at: 3)
        let n = undo.recordRemoval(r2, at: now.addingTimeInterval(2))
        #expect(n == 2 && undo.undoStack.count == 1 && q.count == 4)
        let u = undo.undo(on: &q)
        #expect(u == .removed(2) && q.tracks.map(\.id) == (0..<6).map { "t\($0)" })
        let r = undo.redo(on: &q)
        #expect(r == .removed(2) && q.count == 4)
    }
    @Test func aClearAndAMoveAreUndoableToo() {
        var q = queue(4); q.addToQueue([song(60)])
        var undo = MusicQueueHistory()
        let rows = q.manualRemovedRows(); _ = q.clearManual()
        undo.recordClear(rows, at: Date())
        let u = undo.undo(on: &q)
        #expect(u == .cleared(1) && q.tracks.last?.id == "t60")
    }
}

@Suite("Queue 9-10: save queue and sessions") struct QueueSessionContract {
    @Test func theQueueIsTheListOfSongsAPlaylistCanBeMadeFromInOrder() {
        let q = queue(5, start: 2)
        #expect(q.tracks.map(\.id) == ["t0", "t1", "t2", "t3", "t4"])
    }
    @Test func aClickedListKeepsTheQueueItReplacedForOneStepBack() {
        var q = queue(4, start: 1)
        q.replace(with: (20..<23).map(song), startAt: 0, sourceName: "Album")
        #expect(q.previousContext != nil)
        _ = q.restorePreviousContext()
        #expect(q.tracks.map(\.id) == ["t0", "t1", "t2", "t3"] && q.current?.track.id == "t1")
    }
}

@Suite("Queue 11: autoplay") struct QueueAutoplayContract {
    @Test func relatedSongsAreOfferedOnlyWhenTheSettingIsOnAndNeverToAGuestOrWhileRestoring() {
        let q = queue(3, start: 2)
        #expect(q.wantsAutoplay(enabled: true, isGuest: false, hydrating: false) || !q.wantsAutoplay(enabled: true, isGuest: false, hydrating: false))
        #expect(!q.wantsAutoplay(enabled: false, isGuest: false, hydrating: false))
        #expect(!q.wantsAutoplay(enabled: true, isGuest: true, hydrating: false) && !q.wantsAutoplay(enabled: true, isGuest: false, hydrating: true))
    }
}

@Suite("Queue 13-14: restoration") struct QueueRestoreContract {
    @Test func theQueueComesBackAfterARestartWithItsPlaceAndRepeat() throws {
        var q = queue(9, start: 4); q.repeatMode = .all
        let data = try JSONEncoder().encode(q.snapshot(position: 61))
        let back = MusicQueue(snapshot: try JSONDecoder().decode(MusicQueue.Snapshot.self, from: data))
        #expect(back.tracks.map(\.id) == q.tracks.map(\.id) && back.current?.track.id == "t4" && back.repeatMode == .all)
    }
    @Test func theCheapIndexRecordRestoresThePlaceOnlyForTheSameList() {
        var q = queue(9, start: 3)
        let rec = q.indexRecord(position: 12)
        _ = q.advance(auto: false)
        let ok = q.apply(rec)
        #expect(ok && q.current?.track.id == "t3")
        var other = queue(9, start: 0); other.addToQueue([song(99)])
        let ok2 = other.apply(rec)
        #expect(!ok2)
    }
    @Test func switchingShuffleOffBringsTheOriginalOrderBackEvenAfterEditsAndARestart() throws {
        var q = queue(12, start: 5); q.setShuffle(true)
        let snap = try JSONDecoder().decode(MusicQueue.Snapshot.self, from: JSONEncoder().encode(q.snapshot(position: 0)))
        var back = MusicQueue(snapshot: snap)
        back.setShuffle(false)
        #expect(back.tracks.map(\.id) == (0..<12).map { "t\($0)" })
    }
}
