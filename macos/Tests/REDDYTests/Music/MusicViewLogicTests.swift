import Testing
import Foundation
@testable import REDDY

@Suite("Music view logic") struct MusicViewLogicTests {
    @Test func clockFormatsMinutesAndHours() {
        #expect(MusicTime.clock(0) == "0:00")
        #expect(MusicTime.clock(65) == "1:05")
        #expect(MusicTime.clock(3725) == "1:02:05")
        #expect(MusicTime.clock(-4) == "0:00")
        #expect(MusicTime.clock(.nan) == "0:00")
    }

    @Test func remainingAndFractionAreClamped() {
        #expect(MusicTime.remaining(position: 30, duration: 90) == "-1:00")
        #expect(MusicTime.remaining(position: 100, duration: 90) == "-0:00")
        #expect(MusicTime.fraction(position: 45, duration: 90) == 0.5)
        #expect(MusicTime.fraction(position: 10, duration: 0) == 0)
        #expect(MusicTime.fraction(position: 500, duration: 90) == 1)
    }

    @Test func streamBadge() {
        #expect(MusicStreamLabel.text(MusicStream(url: "u", codec: "aac", container: "m4a", bitrate: 256)) == "AAC 256 kbps")
        #expect(MusicStreamLabel.text(MusicStream(url: "u", codec: "flac", container: "flac", sampleRate: 44100)) == "FLAC 44.1 kHz")
        #expect(MusicStreamLabel.text(MusicStream(url: "u", codec: "", container: "mp3")) == "Audio")
    }

    @Test func lyricLineSelection() {
        let lines = [MusicLyricLine(timeMs: 1000, text: "a"), MusicLyricLine(timeMs: 5000, text: "b"), MusicLyricLine(timeMs: 9000, text: "c")]
        #expect(MusicLyricsLogic.lineIndex(in: lines, atMs: 0) == nil)
        #expect(MusicLyricsLogic.lineIndex(in: lines, atMs: 1000) == 0)
        #expect(MusicLyricsLogic.lineIndex(in: lines, atMs: 4999) == 0)
        #expect(MusicLyricsLogic.lineIndex(in: lines, atMs: 5000) == 1)
        #expect(MusicLyricsLogic.lineIndex(in: lines, atMs: 99_000) == 2)
        #expect(MusicLyricsLogic.lineIndex(in: [], atMs: 10) == nil)
    }

    @Test func queueMoveAndUpNext() {
        #expect(MusicQueueLogic.finalIndex(from: 1, insertionOffset: 4) == 3)
        #expect(MusicQueueLogic.finalIndex(from: 3, insertionOffset: 1) == 1)
        #expect(MusicQueueLogic.finalIndex(from: 2, insertionOffset: 2) == 2)
        #expect(MusicQueueLogic.upNext(count: 5, current: 1) == 2..<5)
        #expect(MusicQueueLogic.upNext(count: 5, current: 4).isEmpty)
        #expect(MusicQueueLogic.upNext(count: 3, current: nil) == 0..<3)
        #expect(MusicQueueLogic.nextRepeat(.off) == .all)
        #expect(MusicQueueLogic.nextRepeat(.all) == .one)
        #expect(MusicQueueLogic.nextRepeat(.one) == .off)
    }

    @Test func orderMovesOneStepAndStopsAtEnds() {
        let ids = ["a", "b", "c"]
        #expect(MusicOrderLogic.moved(ids, id: "b", by: -1) == ["b", "a", "c"])
        #expect(MusicOrderLogic.moved(ids, id: "b", by: 1) == ["a", "c", "b"])
        #expect(MusicOrderLogic.moved(ids, id: "a", by: -1) == ids)
        #expect(MusicOrderLogic.moved(ids, id: "c", by: 1) == ids)
        #expect(MusicOrderLogic.moved(ids, id: "zz", by: 1) == ids)
    }

    @Test func downloadStatusFromStateName() {
        #expect(MusicDownloadStatus.classify("failed(\"x\")") == .failed)
        #expect(MusicDownloadStatus.classify("completed") == .done)
        #expect(MusicDownloadStatus.classify("queued") == .waiting)
        #expect(MusicDownloadStatus.classify("downloading") == .active)
        #expect(MusicDownloadStatus.classify("paused") == .paused)
        #expect(MusicDownloadsLogic.percent(0.456) == 46)
        #expect(MusicDownloadsLogic.percent(2) == 100)
        #expect(MusicDownloadsLogic.percent(.nan) == 0)
    }

    @Test func totalBytesIgnoresMissingFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("music-view-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.bin")
        try Data(count: 1234).write(to: f)
        #expect(MusicDownloadsLogic.totalBytes([f, dir.appendingPathComponent("missing.bin")]) == 1234)
    }

    @Test func historyLabels() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(MusicHistoryLogic.dayLabel(now, now: now, calendar: cal) == "Today")
        #expect(MusicHistoryLogic.dayLabel(now.addingTimeInterval(-86_400), now: now, calendar: cal) == "Yesterday")
    }

    @Test func artistAndAlbumLinksKeepProvider() {
        let a = MusicLinks.artist(MusicArtistRef(id: "x", name: "N"), providerID: "jiosaavn")
        #expect(a.uid == "jiosaavn:x")
        let al = MusicLinks.album(MusicAlbumRef(id: "y", title: "T"), providerID: "jiosaavn")
        #expect(al.uid == "jiosaavn:y")
    }
}

@Suite("Music paged list") @MainActor struct MusicPagedListTests {
    private func track(_ i: Int) -> MusicTrack { MusicTrack(id: "\(i)", providerID: "p", title: "T\(i)", durationMs: 1, artists: []) }

    @Test func loadsFirstPageThenMoreUntilNoNext() async {
        let list = MusicPagedList<MusicTrack> { page in
            switch page {
            case nil: MusicPage(items: [self.track(1), self.track(2)], next: .offset(offset: 2, limit: 2))
            default: MusicPage(items: [self.track(3)], next: nil)
            }
        }
        await list.loadIfNeeded()
        #expect(list.state == .loaded)
        #expect(list.items.count == 2 && list.hasMore)
        await list.loadMore()
        #expect(list.items.map(\.id) == ["1", "2", "3"])
        #expect(!list.hasMore)
        await list.loadMore()
        #expect(list.items.count == 3)
    }

    @Test func failureShowsFriendlyMessageAndReloadRecovers() async {
        var fail = true
        let list = MusicPagedList<MusicTrack>(describe: { _ in "Try again" }) { _ in
            if fail { throw MusicError.network("down") }
            return MusicPage(items: [self.track(1)])
        }
        await list.reload()
        #expect(list.state == .failed("Try again"))
        fail = false
        await list.reload()
        #expect(list.state == .loaded && list.items.count == 1)
    }
}
