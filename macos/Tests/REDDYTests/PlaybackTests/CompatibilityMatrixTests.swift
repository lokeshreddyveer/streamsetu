import Testing
import Foundation
@testable import REDDY

/// The engine each kind of stream is sent to, on this platform. A change here changes how streams play, so it has to be deliberate.
@Suite struct CompatibilityMatrixTests {
    private let both: Set<PlaybackEngineKind> = [.avPlayer, .mpv]
    private let appleOnly: Set<PlaybackEngineKind> = [.avPlayer]

    @Test func formatsAppleCanPlayStayOnApplesPlayer() {
        for c in [StreamContainer.hls, .mp4] {
            #expect(EngineSelector.select(container: c, preference: .automatic, available: both) == .avPlayer)
        }
    }

    @Test func formatsAppleCannotPlayNeedMPVWhenItIsThere() {
        for c in [StreamContainer.mkv, .rtsp, .dash] {
            #expect(EngineSelector.select(container: c, preference: .automatic, available: both) == .mpv)
            #expect(EngineSelector.select(container: c, preference: .automatic, available: appleOnly) == .avPlayer)   // best effort without it
        }
    }

    @Test func transportStreamsFollowThePlatform() {
        let expected: PlaybackEngineKind = EngineSelector.preferMPVForTransportStream ? .mpv : .avPlayer
        #expect(EngineSelector.select(container: .mpegTS, preference: .automatic, available: both) == expected)
        #expect(EngineSelector.select(container: .mpegTS, preference: .automatic, available: appleOnly) == .avPlayer)
    }

    @Test func aChosenEngineWinsInOrderChannelPlaylistApp() {
        #expect(EngineSelector.select(container: .hls, preference: .mpv, available: both) == .mpv)
        #expect(EngineSelector.select(container: .hls, preference: .mpv, playlistPreference: .avPlayer, available: both) == .avPlayer)
        #expect(EngineSelector.select(container: .hls, preference: .mpv, playlistPreference: .avPlayer, channelPreference: .mpv, available: both) == .mpv)
        #expect(EngineSelector.select(container: .hls, preference: .mpv, available: appleOnly) == .avPlayer)         // not installed
    }

    @Test func everyFailureKindHasAMessageAndSomethingToTry() {
        let kinds: [PlaybackError.Kind] = [.network, .timeout, .authorization, .unsupportedFormat, .providerUnavailable, .notFound, .engineUnavailable, .unknown]
        for k in kinds {
            let e = PlaybackError(k)
            #expect(!e.message.isEmpty && !e.advice.isEmpty)
        }
    }

    @Test func loginsNeverAppearInFailureDetail() {
        let e = PlaybackError(.unknown, detail: "failed http://host/live/user/secretpass/123.ts")
        #expect(!(e.detail ?? "").contains("secretpass"))
    }
}

@Suite struct ContainerDetectionTests {
    @Test func extensionsMapToTheRightPath() {
        func c(_ s: String) -> StreamContainer { StreamCapabilities.container(for: URL(string: s)!) }
        #expect(c("http://h/a.m3u8") == .hls && c("http://h/a.mp4") == .mp4 && c("http://h/a.mov") == .mp4)
        for e in ["mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "vob"] { #expect(c("http://h/a.\(e)") == .mkv) }
        #expect(c("http://h/a.ts") == .mpegTS && c("http://h/a.mpd") == .dash && c("rtsp://h/a") == .rtsp && c("rtmp://h/a") == .rtsp)
    }
}
