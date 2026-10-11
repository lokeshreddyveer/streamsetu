import Testing
import Foundation
@testable import REDDY

@Suite("Player features: sleep, Now Playing, per-channel memory, switcher, picture") @MainActor struct PlayerFeatureTests {
    // MARK: sleep and wake

    @Test func onlyRunningVideoKeepsTheScreenAwake() {
        for s in [PlaybackState.playing, .buffering, .recovering, .resolving, .preparing, .seeking] { #expect(SleepPolicy.shouldKeepAwake(state: s, hasPlayback: true), "\(s)") }
        for s in [PlaybackState.idle, .paused, .ended, .failed(PlaybackError(.network))] { #expect(!SleepPolicy.shouldKeepAwake(state: s, hasPlayback: true), "\(s)") }
        #expect(!SleepPolicy.shouldKeepAwake(state: .playing, hasPlayback: false))
    }

    @Test func wakeReconnectsOnlyWhatWasRunning() {
        #expect(SleepPolicy.shouldReconnectAfterWake(wasRunningBeforeSleep: true, hasPlayback: true))
        #expect(!SleepPolicy.shouldReconnectAfterWake(wasRunningBeforeSleep: false, hasPlayback: true), "a paused stream stays paused")
        #expect(!SleepPolicy.shouldReconnectAfterWake(wasRunningBeforeSleep: true, hasPlayback: false))
    }

    @Test func sleepGuardHoldsAndReleases() {
        let g = SleepGuard()
        g.update(hold: true); #expect(g.isHolding)
        g.update(hold: true); #expect(g.isHolding, "asking twice doesn't stack")
        g.update(hold: false); #expect(!g.isHolding)
    }

    @Test func sleepAndWakeWithNothingPlayingDoNothing() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-pf-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        c.playback.systemWillSleep(); c.playback.systemDidWake()
        #expect(c.playback.state == .idle && c.playback.current == nil)
    }

    // MARK: Now Playing

    @Test func nowPlayingKeysDependOnWhatIsPlaying() {
        func snap(live: Bool, queue: Bool = true, next: Bool = false, duration: Double? = 100) -> NowPlayingSnapshot {
            NowPlayingSnapshot(title: "T", subtitle: "S", isLive: live, isPlaying: true, position: 10, duration: duration, rate: 1, hasQueue: queue, hasNextEpisode: next, artworkURL: nil)
        }
        let live = snap(live: true).commands
        #expect(live.next && live.previous && !live.skip && !live.seek, "live: next/previous channel, no scrubbing")
        #expect(!snap(live: true, queue: false).commands.next, "one channel has nothing to skip to")
        let vod = snap(live: false, next: true).commands
        #expect(vod.skip && vod.seek && vod.next && vod.previous)
        #expect(!snap(live: false, duration: nil).commands.seek)
        #expect(snap(live: false).info[MPNowPlayingInfoKeys.elapsed] != nil && snap(live: true).info[MPNowPlayingInfoKeys.elapsed] == nil)
        #expect((snap(live: true).info[MPNowPlayingInfoKeys.rate] as? Double) == 1)
    }

    /// The crash fix: macOS asks for artwork from a background queue. This asks the same way and must not trap.
    @Test func artworkCanBeRequestedFromABackgroundQueue() async throws {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        struct Box: @unchecked Sendable { let item: MPMediaItemArtwork }
        let box = Box(item: NowPlayingService.makeArtwork(ctx.makeImage()!))
        let got = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { c.resume(returning: box.item.image(at: CGSize(width: 4, height: 4)) != nil) }
        }
        #expect(got)
    }

    // MARK: per-channel memory

    @Test func channelPreferencesPersistClampAndStayBounded() {
        let d = UserDefaults(suiteName: "chp-\(UUID().uuidString)")!
        let p = ChannelPlaybackPrefs(defaults: d, limit: 5)
        p.update("a") { $0.volumeTrim = -0.3; $0.engine = PlaybackEnginePreference.mpv.rawValue }
        let again = ChannelPlaybackPrefs(defaults: d, limit: 5).pref(for: "a")
        #expect(again.volumeTrim == -0.3 && again.engineChoice == .mpv)
        p.update("loud") { $0.volumeTrim = -9 }
        #expect(p.pref(for: "loud").volumeTrim == -0.5, "kept within ±50%")
        p.update("a") { $0.volumeTrim = 0; $0.engine = nil }
        #expect(p.count == 1, "a channel set back to default is forgotten")
        for i in 0..<20 { p.update("c\(i)") { $0.volumeTrim = 0.1 } }
        #expect(p.count <= 5, "the oldest entries are dropped past the limit")
        #expect(p.pref(for: "never-seen").isDefault)
    }

    @Test func effectiveVolumeIsTheMainVolumeMovedByTheTrim() {
        #expect(ChannelVolume.effective(master: 0.8, trim: -0.3) == 0.5)
        #expect(ChannelVolume.effective(master: 0.9, trim: 0.5) == 1, "never above full")
        #expect(ChannelVolume.effective(master: 0.1, trim: -0.5) == 0, "never below silent")
    }

    @Test func engineChoiceGoesChannelThenPlaylistThenApp() {
        let both: Set<PlaybackEngineKind> = [.avPlayer, .mpv]
        func pick(app: PlaybackEnginePreference, playlist: PlaybackEnginePreference?, channel: PlaybackEnginePreference?) -> PlaybackEngineKind {
            EngineSelector.select(container: .hls, preference: app, playlistPreference: playlist, channelPreference: channel, available: both)
        }
        #expect(pick(app: .automatic, playlist: nil, channel: .mpv) == .mpv)
        #expect(pick(app: .mpv, playlist: .avPlayer, channel: nil) == .avPlayer)
        #expect(pick(app: .mpv, playlist: .avPlayer, channel: .automatic) == .avPlayer, "automatic at channel level defers to the playlist")
        #expect(pick(app: .mpv, playlist: .avPlayer, channel: .avPlayer) == .avPlayer)
        #expect(pick(app: .avPlayer, playlist: .mpv, channel: .avPlayer) == .avPlayer, "the channel beats the playlist")
    }

    // MARK: switcher

    @Test func switcherMovesWrapsAndLoadsAWindow() {
        var m = ChannelSwitcherModel(count: 5, current: 1)
        #expect(m.selected == 1)
        m.move(by: -2); #expect(m.selected == 4, "wraps past the top")
        m.move(by: 1); #expect(m.selected == 0, "wraps past the bottom")
        m.move(by: 8); #expect(m.selected == 3)
        #expect(ChannelSwitcherModel(count: 0, current: nil).selected == 0)
        #expect(ChannelSwitcherModel(count: 200, current: 100).window(radius: 10) == 90..<111)
        #expect(ChannelSwitcherModel(count: 200, current: 2).window(radius: 10) == 0..<13)
        #expect(ChannelSwitcherModel(count: 3, current: 99).selected == 2, "an out-of-range start is clamped")
    }

    @Test func fullscreenKeysSwitchBetweenChannelsAndTheSwitcher() {
        func key(_ code: UInt16, open: Bool, live: Bool = true, full: Bool = true) -> PlayerCommand? {
            PlayerShortcuts.resolve(keyCode: code, PlayerShortcutContext(hasPlayback: true, isFullscreen: full, isLive: live, switcherOpen: open))
        }
        #expect(key(48, open: false) == .toggleSwitcher && key(8, open: false) == .toggleSwitcher)
        #expect(key(126, open: false) == .channelUp, "closed: arrows still zap")
        #expect(key(126, open: true) == .switcherMove(-1) && key(125, open: true) == .switcherMove(1))
        #expect(key(36, open: true) == .switcherCommit && key(53, open: true) == .closeSwitcher)
        #expect(key(48, open: false, live: false) == nil, "no switcher for a movie")
        #expect(key(48, open: false, full: false) == nil, "or outside full screen")
        #expect(key(49, open: true) == .togglePause, "space still pauses")
    }

    // MARK: picture, tone mapping, subtitles

    @Test func pictureAdjustmentsAreClampedAndPersist() {
        #expect(PictureAdjustments(brightness: 500, contrast: -500, saturation: 5, gamma: 0, hue: 100).clamped() == PictureAdjustments(brightness: 100, contrast: -100, saturation: 5, gamma: 0, hue: 100))
        #expect(PictureAdjustments().isDefault)
        let d = UserDefaults(suiteName: "pic-\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        s.picture = PictureAdjustments(brightness: 12, contrast: -7, saturation: 30, gamma: 0, hue: 0); s.toneMapping = .hable
        let again = AppSettings(defaults: d)
        #expect(again.picture.brightness == 12 && again.picture.saturation == 30 && again.toneMapping == .hable)
        again.resetPlayback()
        #expect(again.picture.isDefault && again.toneMapping == .automatic)
    }

    @Test func mpvGetsToneMappingAndSubtitleEncodingDetection() {
        var c = MPVConfiguration()
        c.toneMapping = .mobius
        let o = Dictionary(c.options.map { ($0.0, $0.1) }, uniquingKeysWith: { _, b in b })
        #expect(o["tone-mapping"] == "mobius" && o["sub-codepage"] == "auto")
        #expect(HDRToneMapping.allCases.map(\.mpvValue).contains("bt.2390"))
    }

    @Test func engineCapabilitiesSayWhatIsReallySupported() throws {
        let av = PlaybackCapabilities(containers: [.hls], pictureInPicture: true, airPlay: true, screenshot: true, qualitySelection: true)
        #expect(!av.externalSubtitles && !av.pictureAdjustments, "AVPlayer can't load subtitle files or adjust colour")
    }
}

/// The system's own key names, so the tests don't depend on MediaPlayer being imported twice.
import MediaPlayer
private enum MPNowPlayingInfoKeys {
    static let elapsed = MPNowPlayingInfoPropertyElapsedPlaybackTime
    static let rate = MPNowPlayingInfoPropertyPlaybackRate
}

@Suite("Quality-variant fallback") struct VariantFallbackTests {
    func channel(_ n: Int) -> Channel { TestSupport.channel(PlaylistSource(name: "T", type: .m3uRemote, baseURL: "http://x"), "v\(n)", "Chan \(n)") }

    @Test func triesEachCopyOnceInOrderThenStops() {
        let v = [(variant: channel(1), label: "FHD"), (variant: channel(2), label: "HD"), (variant: channel(3), label: "SD")]
        var tried: Set<String> = [v[0].variant.id]
        let second = VariantFallback.next(variants: v, tried: tried, errorKind: .network)
        #expect(second?.label == "HD")
        tried.insert(second!.variant.id)
        let third = VariantFallback.next(variants: v, tried: tried, errorKind: .timeout)
        #expect(third?.label == "SD")
        tried.insert(third!.variant.id)
        let none = VariantFallback.next(variants: v, tried: tried, errorKind: .network)
        #expect(none == nil, "all three tried: give up")
    }

    @Test func aSignInProblemOrMissingEngineIsNotRetriedOnAnotherCopy() {
        let v = [(variant: channel(1), label: "HD"), (variant: channel(2), label: "SD")]
        let auth = VariantFallback.next(variants: v, tried: [v[0].variant.id], errorKind: .authorization)
        let engine = VariantFallback.next(variants: v, tried: [v[0].variant.id], errorKind: .engineUnavailable)
        #expect(auth == nil && engine == nil)
        let notFound = VariantFallback.next(variants: v, tried: [v[0].variant.id], errorKind: .notFound)
        #expect(notFound != nil, "a dead stream is exactly when another copy helps")
    }

    @Test func aChannelWithOneCopyHasNothingToFallBackTo() {
        let only = [(variant: channel(1), label: "HD")]
        let r = VariantFallback.next(variants: only, tried: [only[0].variant.id], errorKind: .network)
        #expect(r == nil)
    }
}

@Suite("Channel numbers") @MainActor struct ChannelNumberTests {
    func channels(_ n: Int) -> [Channel] { (1...n).map { TestSupport.channel(PlaylistSource(name: "T", type: .m3uRemote, baseURL: "http://x"), "n\($0)", "Chan \($0)") } }

    @Test func aNumberIsAPlaceInTheListFromOne() {
        let q = channels(12)
        #expect(PlaybackCoordinator.channel(number: 1, in: q)?.name == "Chan 1")
        #expect(PlaybackCoordinator.channel(number: 12, in: q)?.name == "Chan 12")
        #expect(PlaybackCoordinator.channel(number: 0, in: q) == nil && PlaybackCoordinator.channel(number: 13, in: q) == nil)
        #expect(PlaybackCoordinator.channel(number: 1, in: []) == nil)
    }

    @Test func digitsAreCapturedOnlyWhileWatchingLiveAndFinishedByReturnOrEsc() {
        func key(_ code: UInt16, _ chars: String?, live: Bool = true, playing: Bool = true, typing: Bool = false, switcher: Bool = false) -> PlayerCommand? {
            PlayerShortcuts.resolve(keyCode: code, characters: chars, PlayerShortcutContext(hasPlayback: playing, isFullscreen: false, isLive: live, switcherOpen: switcher, numberEntryActive: typing))
        }
        #expect(key(18, "1") == .digit(1) && key(29, "0") == .digit(0) && key(84, "5") == .digit(5))
        #expect(key(18, "1", live: false) == nil, "no channel numbers for a movie")
        #expect(key(18, "1", playing: false) == nil)
        #expect(key(18, "1", switcher: true) == nil, "the open channel list has its own keys")
        #expect(key(36, nil, typing: true) == .numberCommit && key(53, nil, typing: true) == .numberCancel)
        #expect(key(36, nil, typing: false) == nil, "Return does nothing when no number is being typed")
        #expect(key(0, "a") == nil)
    }
}

@Suite("Sleep timer") struct SleepTimerTests {
    @Test func endsAfterTheChosenTimeAndFadesInTheLastTenSeconds() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let t = SleepTimer(minutes: 45, from: start)
        #expect(t.remaining(at: start) == 45 * 60 && !t.hasEnded(at: start))
        #expect(t.volumeFactor(at: start.addingTimeInterval(44 * 60)) == 1, "no fade until the end is near")
        #expect(abs(t.volumeFactor(at: start.addingTimeInterval(45 * 60 - 5)) - 0.5) < 0.001)
        #expect(t.volumeFactor(at: start.addingTimeInterval(45 * 60 - 1)) < 0.11)
        #expect(t.hasEnded(at: start.addingTimeInterval(45 * 60)) && t.volumeFactor(at: start.addingTimeInterval(45 * 60 + 9)) == 0)
        #expect(t.remaining(at: start.addingTimeInterval(99999)) == 0)
    }

    @Test func minutesAreKeptInARange() {
        let now = Date()
        #expect(SleepTimer(minutes: 0, from: now).endsAt == now.addingTimeInterval(60))
        #expect(SleepTimer(minutes: 99999, from: now).endsAt == now.addingTimeInterval(600 * 60))
        #expect(SleepTimer.label(forRemaining: 42 * 60) == "42 min" && SleepTimer.label(forRemaining: 45) == "45 s" && SleepTimer.label(forRemaining: 100) == "2 min")
    }

    @MainActor @Test func theTimerRunsFadesAndStopsPlayback() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-sleep-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let p = c.playback
        #expect(p.sleepTimer == nil)
        p.startSleepTimer(SleepTimer(until: Date().addingTimeInterval(0.6)))
        #expect(p.sleepTimer != nil)
        try await Task.sleep(nanoseconds: 1_800_000_000)
        #expect(p.sleepTimer == nil, "it ended on its own")
        p.startSleepTimer(minutes: 30); p.cancelSleepTimer()
        #expect(p.sleepTimer == nil && p.effectiveVolume == p.volume, "cancelling restores the volume")
    }
}

@Suite("Radio mode") @MainActor struct RadioModeTests {
    func audioOnly(_ s: PlaybackState, w: Int, secs: Double, radio: Bool = false, live: Bool = true) -> Bool {
        PlaybackCoordinator.audioOnly(state: s, videoWidth: w, secondsPlaying: secs, looksLikeRadio: radio, isLive: live)
    }

    @Test func aStreamWithSoundAndNoPictureIsRadio() {
        #expect(audioOnly(.playing, w: 0, secs: 5))
        #expect(!audioOnly(.playing, w: 0, secs: 1), "give video a few seconds to report its size")
        #expect(!audioOnly(.playing, w: 1920, secs: 30), "a picture means it isn't radio")
        #expect(!audioOnly(.playing, w: 0, secs: 30, live: false), "only live channels")
        #expect(!audioOnly(.paused, w: 0, secs: 30) && !audioOnly(.failed(PlaybackError(.network)), w: 0, secs: 30))
    }

    @Test func aRadioFolderShowsTheRadioViewImmediately() {
        #expect(audioOnly(.playing, w: 0, secs: 0.2, radio: true))
        #expect(audioOnly(.buffering, w: 0, secs: 0, radio: true), "not a black box while it loads")
        #expect(!audioOnly(.buffering, w: 0, secs: 0, radio: false))
        #expect(!audioOnly(.playing, w: 640, secs: 0.2, radio: true), "a radio-named folder with real video shows the video")
    }
}
