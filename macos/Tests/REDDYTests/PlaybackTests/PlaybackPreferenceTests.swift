import Testing
import Foundation
@testable import REDDY

@Suite("Playback preferences: engine choice, MPV options, per-playlist overrides") @MainActor struct PlaybackPreferenceTests {
    let both: Set<PlaybackEngineKind> = [.avPlayer, .mpv]
    let av: Set<PlaybackEngineKind> = [.avPlayer]

    @Test func automaticChoiceFollowsTheStreamType() {
        func pick(_ c: StreamContainer, _ a: Set<PlaybackEngineKind>) -> PlaybackEngineKind { EngineSelector.select(container: c, preference: .automatic, available: a) }
        #expect(pick(.hls, both) == .avPlayer && pick(.mp4, both) == .avPlayer)
        #expect(pick(.mpegTS, both) == .mpv, "raw MPEG-TS is read directly by MPV")
        #expect(pick(.mpegTS, av) == .avPlayer, "without MPV it goes through the AVPlayer bridge")
        #expect(pick(.mkv, both) == .mpv && pick(.rtsp, both) == .mpv && pick(.dash, both) == .mpv)
        #expect(pick(.mkv, av) == .avPlayer, "never picks an engine that isn't installed")
    }

    @Test func aPlaylistChoiceBeatsTheAppWideOne() {
        #expect(EngineSelector.select(container: .hls, preference: .automatic, playlistPreference: .mpv, available: both) == .mpv)
        #expect(EngineSelector.select(container: .mkv, preference: .mpv, playlistPreference: .avPlayer, available: both) == .avPlayer)
        #expect(EngineSelector.select(container: .mkv, preference: .mpv, playlistPreference: .automatic, available: both) == .mpv, "“automatic” for a playlist defers to the app setting")
        #expect(EngineSelector.select(container: .hls, preference: .automatic, playlistPreference: .mpv, available: av) == .avPlayer)
    }

    @Test func authorisationFailuresAreReportedNotRetriedOnAnotherEngine() {
        let r = PlaybackRecoveryService()
        let auth = PlaybackError(.authorization)
        #expect(r.decide(error: auth, attempt: 0, current: .avPlayer, available: both, isLive: true) == .giveUp)
        #expect(r.decide(error: PlaybackError(.unsupportedFormat), attempt: 0, current: .avPlayer, available: both, isLive: true) == .switchEngine(.mpv))
        #expect(r.decide(error: PlaybackError(.unsupportedFormat), attempt: 1, current: .mpv, available: both, isLive: true) == .giveUp)
    }

    @Test func mpvOptionsFollowTheSettings() {
        var c = MPVConfiguration()
        func opts() -> [String: String] { Dictionary(c.options.map { ($0.0, $0.1) }, uniquingKeysWith: { _, b in b }) }
        c.renderingProfile = .performance
        #expect(opts()["scale"] == "bilinear" && opts()["correct-downscaling"] == "no")
        c.renderingProfile = .highQuality
        #expect(opts()["scale"] == "ewa_lanczossharp" && opts()["dscale"] == "mitchell")
        #expect(opts()["audio-channels"] == nil, "surround stays surround by default")
        c.stereoDownmix = true
        #expect(opts()["audio-channels"] == "stereo")
        c.lowLatency = true
        #expect(opts()["profile"] == "low-latency" && opts()["cache-pause"] == "no")
        c.hardwareDecoding = .software
        #expect(opts()["hwdec"] == "no")
        #expect(opts()["load-scripts"] == "no", "scripting stays off")
    }

    @Test func playlistOverridesPersistAndClear() {
        let d = UserDefaults(suiteName: "pp-\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        let a = UUID(), b = UUID()
        #expect(s.engineOverride(for: a) == nil && s.bufferingOverride(for: a) == nil)
        s.setEngineOverride(.mpv, for: a); s.setBufferingOverride(.large, for: a)
        let again = AppSettings(defaults: d)
        #expect(again.engineOverride(for: a) == .mpv && again.bufferingOverride(for: a) == .large)
        #expect(again.engineOverride(for: b) == nil, "another playlist is unaffected")
        again.setEngineOverride(nil, for: a)
        #expect(AppSettings(defaults: d).engineOverride(for: a) == nil)
    }

    @Test func newPlaybackSettingsPersistBackUpAndReset() {
        let d = UserDefaults(suiteName: "pp-\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        s.renderingProfile = .highQuality; s.stereoDownmix = true; s.subtitleOutline = false
        let again = AppSettings(defaults: d)
        #expect(again.renderingProfile == .highQuality && again.stereoDownmix && !again.subtitleOutline)
        #expect(again.subtitleStyle.outline == false)
        let fresh = AppSettings(defaults: UserDefaults(suiteName: "pp-\(UUID().uuidString)")!)
        fresh.apply(snapshot: again.snapshot())
        #expect(fresh.renderingProfile == .highQuality && fresh.stereoDownmix)
        again.resetPlayback()
        #expect(again.renderingProfile == .balanced && !again.stereoDownmix && again.subtitleOutline)
        d.set("Nonsense", forKey: "settings.rendering")
        #expect(AppSettings(defaults: d).renderingProfile == .balanced)
    }
}

@Suite("Buffering tuning") struct BufferingTuningTests {
    @Test func resumeThresholdGrowsWithTheStabilityMode() {
        #expect(BufferingMode.lowLatency.mpvResumeThreshold(live: true) < BufferingMode.automatic.mpvResumeThreshold(live: true))
        #expect(BufferingMode.automatic.mpvResumeThreshold(live: true) < BufferingMode.standard.mpvResumeThreshold(live: true))
        #expect(BufferingMode.standard.mpvResumeThreshold(live: true) < BufferingMode.large.mpvResumeThreshold(live: true))
        #expect(BufferingMode.automatic.mpvResumeThreshold(live: true) > BufferingMode.automatic.mpvResumeThreshold(live: false), "live restarts wait a little longer so they don't thrash")
    }

    @Test func mpvReconnectsAndWaitsForTheThreshold() {
        var c = MPVConfiguration()
        c.resumeThreshold = 4
        let o = Dictionary(c.options.map { ($0.0, $0.1) }, uniquingKeysWith: { _, b in b })
        #expect(o["cache-pause-wait"] == "4.0")
        #expect(o["stream-lavf-o"]?.contains("reconnect=1") == true && o["stream-lavf-o"]?.contains("reconnect_streamed=1") == true)
    }
}
