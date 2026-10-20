import Testing
import Foundation
import AVFoundation
import CoreVideo
@testable import REDDY

/// "Watch Privately": a play started that way leaves nothing behind, and the same play started normally does (so the test would notice if privacy stopped working).
@MainActor @Suite struct PrivateWatchTests {
    /// A short H.264 video, written without any network or tools.
    private func makeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-private-\(UUID().uuidString).mp4")
        let w = 160, h = 90, fps = 10, seconds = 6
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for frame in 0..<(fps * seconds) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let b = buffer else { continue }
            CVPixelBufferLockBaseAddress(b, [])
            if let base = CVPixelBufferGetBaseAddress(b) { memset(base, Int32(frame * 4 % 256), CVPixelBufferGetBytesPerRow(b) * h) }
            CVPixelBufferUnlockBaseAddress(b, [])
            adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    private func count(_ c: AppContainer, _ table: String) -> Int { (try? c.db.read { try $0.queryOne("SELECT COUNT(*) FROM \(table)", []) { $0.int(0) } }) ?? -1 }

    /// Plays, waits until it is really playing and past the first second, then stops (which is when a position would be saved).
    private func watch(_ c: AppContainer, _ video: URL, privately: Bool) async throws {
        c.playback.play(file: video, title: "Test film", privately: privately)
        for _ in 0..<200 { if c.playback.state == .playing { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        try #require(c.playback.state == .playing, "the test video did not start")
        c.playback.seek(to: 3)
        for _ in 0..<60 { if c.playback.position >= 2.5 { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        c.playback.stop()
    }

    @Test func aPrivatePlayLeavesNoHistoryNoResumePointAndNothingToSync() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-pw-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let video = try await makeVideo()
        c.playback.persistProgress()
        try await watch(c, video, privately: true)
        #expect(count(c, "watch_history") == 0)
        #expect(count(c, "watch_progress") == 0)
        #expect(count(c, "recently_watched") == 0)
        #expect(count(c, "playback_sessions") == 0)
        #expect(count(c, "lan_log") == 0 && count(c, "sync_outbox") == 0)
        #expect(!c.playback.isPrivate, "stopping ends the private watch")
    }

    @Test func theSamePlayStartedNormallyDoesLeaveARecord() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-pw-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let video = try await makeVideo()
        try await watch(c, video, privately: false)
        #expect(count(c, "watch_history") == 1)
        #expect(count(c, "watch_progress") == 1)
    }

    @Test func theLockScreenShowsNothingAboutAPrivateWatch() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-pw-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let video = try await makeVideo()
        let nowPlaying = NowPlayingService(playback: c.playback, artwork: nil)
        c.playback.play(file: video, title: "Secret film", privately: true)
        for _ in 0..<200 { if c.playback.state == .playing { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        let snap = try #require(nowPlaying.snapshot())
        #expect(snap.title == "Private viewing" && snap.subtitle == nil && snap.artworkURL == nil)
        c.playback.stop()
    }
}
