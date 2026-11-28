import Testing
import Foundation
@testable import REDDY

/// "Stop after this song": the mark sits on one queue row (by the row's own id), moves when asked again elsewhere, goes away when asked twice or when the
/// queue it belonged to is replaced, and the bar shows the next song, waiting, once playback has stopped. The moment a song really ends needs real audio, so
/// that part is checked in the player's source (see the last test) and is the one thing here that is not driven end to end.
@MainActor
@Suite("Flow: Stop after this song", .serialized)
struct StopAfterThisSongFlowTests {
    private func make() throws -> FlowRig { try FlowRig() }

    @Test func marksTheShownRowAndTakesItBack() throws {
        let rig = try make(); defer { rig.cleanup() }
        rig.hub.play(FlowRig.songs(4), at: 0)
        let shown = try #require(rig.shownRowID)

        rig.player.toggleStopAfterCurrent()
        #expect(rig.player.stopAfterEntryID == shown)

        rig.player.toggleStopAfterCurrent()
        #expect(rig.player.stopAfterEntryID == nil)
    }

    @Test func aLaterRowCanBeMarkedAndTheMarkMovesWithoutStacking() throws {
        let rig = try make(); defer { rig.cleanup() }
        rig.hub.play(FlowRig.songs(4), at: 0)
        let later = rig.player.rows[2].id

        rig.player.toggleStopAfter(entryID: later)
        #expect(rig.player.stopAfterEntryID == later)

        rig.player.toggleStopAfterCurrent()                      // one mark at a time: it moves to the shown row
        #expect(rig.player.stopAfterEntryID == rig.shownRowID)
        #expect(rig.player.stopAfterEntryID != later)
    }

    @Test func aSecondCopyOfTheSameSongIsNotMarkedToo() throws {
        let rig = try make(); defer { rig.cleanup() }
        let one = FlowRig.songs(1)[0]
        rig.hub.play([one, one], at: 0)
        #expect(rig.player.rows.count == 2)
        let first = rig.player.rows[0].id, second = rig.player.rows[1].id
        #expect(first != second)

        rig.player.toggleStopAfter(entryID: first)

        #expect(rig.player.stopAfterEntryID == first)
        #expect(rig.player.stopAfterEntryID != second)
    }

    @Test func replacingTheQueueDropsAMarkOnARowThatIsGone() throws {
        let rig = try make(); defer { rig.cleanup() }
        rig.hub.play(FlowRig.songs(4), at: 0)
        rig.player.toggleStopAfter(entryID: rig.player.rows[3].id)
        #expect(rig.player.stopAfterEntryID != nil)

        rig.hub.play(FlowRig.songs(3, prefix: "other"), at: 0)

        #expect(rig.player.stopAfterEntryID == nil, "a stale mark would stop the next queue for no reason")
    }

    @Test func aRoomGuestCannotMarkTheHostsQueue() throws {
        let rig = try make(); defer { rig.cleanup() }
        rig.hub.play(FlowRig.songs(3), at: 0)
        rig.player.isRoomGuest = true
        rig.player.toggleStopAfter(entryID: rig.player.rows[1].id)
        #expect(rig.player.stopAfterEntryID == nil)
        rig.player.isRoomGuest = false
    }

    /// The stop itself: when a song marked "stop after" ends, the queue moves to the next song and the bar must follow it (so Play starts the song it shows),
    /// and the mark is spent.
    @Test func whenTheMarkedSongEndsTheBarFollowsTheWaitingSong() throws {
        let file = try #require(GuardScanner.files(under: ["Services/Music/Playback"]).first { $0.path.hasSuffix("/MusicPlayer.swift") })
        let code = file.code
        let ended = try #require(code.range(of: "private func trackEnded() {"))
        let tail = String(code[ended.upperBound...])
        let branchEnd = try #require(tail.range(of: "if primedForCrossfade, nextReady"))
        let branch = String(tail[..<branchEnd.lowerBound])
        #expect(branch.contains("stopAfterEntryID = nil"))
        #expect(branch.contains("q.advance(auto: true)"))
        #expect(branch.contains("endOfQueue()"))

        let eoq = try #require(code.range(of: "private func endOfQueue() {"))
        let eoqTail = String(code[eoq.upperBound...])
        let eoqBody = String(eoqTail[..<(eoqTail.range(of: "\n    }\n")?.lowerBound ?? eoqTail.endIndex)])
        #expect(eoqBody.contains("showWaitingRow("), "endOfQueue must bring the bar to the row the queue is on")

        let waiting = try #require(code.range(of: "private func showWaitingRow(replacing shown: UUID?) {"))
        let waitingTail = String(code[waiting.upperBound...].prefix(200))
        #expect(waitingTail.contains("sync()"))
    }
}
