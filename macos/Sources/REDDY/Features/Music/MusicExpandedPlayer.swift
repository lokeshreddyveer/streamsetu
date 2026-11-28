import SwiftUI

/// Full-window Now Playing: a blurred copy of the cover as the backdrop, the large cover and transport on the left, synced lyrics on the right and a
/// queue drawer on demand. Escape closes it. The blur is drawn once per track and never animates, so an idle player costs nothing.
struct MusicExpandedPlayer: View {
    @Bindable var hub: MusicHub
    @State private var showQueue = false
    /// The person's choice between lyrics and cover in a narrow window; nil until they choose. A narrow window opens on the cover, because the transport lives under it.
    @State private var lyricsChoice: Bool?
    @Environment(\.reddyAccent) private var accent

    /// Below this width the lyrics and the cover take turns instead of sitting side by side.
    static let sideBySideWidth: CGFloat = 860

    var body: some View {
        if let t = hub.player.current {
            GeometryReader { geo in
                let wide = geo.size.width >= Self.sideBySideWidth
                let showLyrics = lyricsChoice ?? false
                ZStack {
                    backdrop(t)
                    HStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 32) {
                            if wide || !showLyrics { coverColumn(t, size: min(380, max(180, geo.size.height - 330))) }
                            if wide || showLyrics {
                                VStack(spacing: 16) {
                                    MusicLyricsPanel(hub: hub, style: .expanded, ink: MusicInk.fullscreenInk).frame(maxWidth: .infinity, maxHeight: .infinity)
                                    // In a narrow window the cover column (and the transport in it) steps aside for the lyrics: play, skip and seek stay under them.
                                    if !wide { MusicExpandedTransport(hub: hub, track: t) }
                                }
                            }
                        }
                        .padding(.horizontal, 40).padding(.top, 64).padding(.bottom, 32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if showQueue {
                            MusicQueuePanel(hub: hub).padding(16).frame(width: 340).frame(maxHeight: .infinity)
                                .background(MusicInk.scrim(.light))
                                .overlay(alignment: .leading) { Rectangle().fill(ColorTokens.line).frame(width: 1) }
                        }
                    }
                    topBar(wide: wide, showLyrics: showLyrics)
                    Button(Localized.string("Close")) { close() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true).atlas("control.music.expandedPlayerClose")
                }
            }
            .background(ColorTokens.background)
            .transition(.opacity)
            // The full window carries the lyrics itself: the strip behind it closes, so it does not pop back unasked and the bar's Lyrics button is not "on" for a card nobody sees.
            .onAppear { MusicContextPanelState.shared.lyricsStripOpen = false }
            .accessibilityElement(children: .contain).accessibilityLabel(Localized.string("Now Playing, full window"))
        }
    }

    private func close() { hub.expandedPlayer = false }

    private func backdrop(_ t: MusicTrack) -> some View {
        ZStack {
            MusicCoverImage(thumbs: t.thumbnails, corner: 0, pixelHint: 256).artwork(of: .derive(t), slot: .backdrop)
                .blur(radius: 70).scaleEffect(1.3).clipped()
            Rectangle().fill(MusicInk.scrim(.strong))
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }

    private func topBar(wide: Bool, showLyrics: Bool) -> some View {
        VStack {
            HStack(spacing: 10) {
                Button { close() } label: { chip("chevron.down") }.buttonStyle(.plain).accessibilityLabel(Localized.string("Close full-window Now Playing")).atlas("control.music.expandedPlayerCloseFullWindowNowPlaying")
                Spacer()
                if !wide {
                    Button { lyricsChoice = !showLyrics } label: { chip(showLyrics ? "photo" : "text.quote") }.buttonStyle(.plain)
                        .accessibilityLabel(Localized.string(showLyrics ? "Show cover" : "Show lyrics")).atlas("control.music.expandedPlayerMusicexpandedplayertopbarButton")
                }
                MusicSurfaceButtons(hub: hub, light: true)
                MusicSleepMenu(hub: hub, label: { chip(hub.sleepTimer.isRunning ? "moon.zzz.fill" : "moon.zzz", on: hub.sleepTimer.isRunning) })
                Button { showQueue.toggle() } label: { chip("list.bullet", on: showQueue) }.buttonStyle(.plain)
                    .accessibilityLabel(Localized.string(showQueue ? "Hide queue" : "Show queue")).atlas("control.music.expandedPlayerMusicexpandedplayertopbarButton")
            }
            .padding(14)
            Spacer()
        }
    }

    private func chip(_ symbol: String, on: Bool = false) -> some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32)
            .foregroundStyle(on ? accent : MusicInk.onArtwork)
            .background(MusicInk.fillOnArtwork, in: Circle())
            .frame(minWidth: MusicTokens.hitTarget, minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
    }

    @AppStorage(MusicMotionPrefs.motionKey) private var motionArtOn = false

    private func coverColumn(_ t: MusicTrack, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The picture of a music video replaces the cover only while the player holds one (the mode is on, the track is a video and the
            // stream has a picture); otherwise this is the cover, as always.
            Group {
                if let video = hub.player.videoPlayer {
                    MusicVideoStage(player: video, isPlaying: hub.player.isPlaying, cover: t.thumbnails).frame(width: size, height: size * 9 / 16 + 40)
                } else if motionArtOn {
                    MusicMotionArtView(track: t, corner: 20).frame(width: size, height: size).shadow(color: MusicInk.scrim(.medium), radius: 24, y: 10)
                } else {
                    MusicArtwork(track: t, size: size, corner: 20).shadow(color: MusicInk.scrim(.medium), radius: 24, y: 10)
                }
            }
            .musicWheelVolume(hub.player)
            Text(verbatim: MusicDisplayTitle.display(for: t)?.title ?? t.title).font(Typography.display).foregroundStyle(MusicInk.fullscreenInk).lineLimit(2)
            MusicTrackArtistLine(track: t, hub: hub, font: Typography.heading, rest: MusicInk.onArtworkSecondary, hover: MusicInk.onArtwork)
            MusicExpandedTransport(hub: hub, track: t)
        }
        .frame(width: size)
    }
}

/// Seek bar and the main controls, sized for the expanded player. Split out so only this view updates as the position ticks.
private struct MusicExpandedTransport: View {
    let hub: MusicHub
    let track: MusicTrack
    var player: MusicPlayer { hub.player }
    @Environment(\.reddyAccent) private var accent

    /// A transport glyph in a button of at least the hit-target size.
    private func glyph(_ name: String, size: CGFloat = 16, tint: Color? = nil) -> some View {
        Image(systemName: name).font(.system(size: size))
            .foregroundStyle(tint ?? MusicInk.fullscreenInk)
            .frame(minWidth: MusicTokens.hitTarget, minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
    }

    var body: some View {
        let dur = player.listeningDuration > 0 ? player.listeningDuration : MusicVolumeCurve.listening(track.duration, tempo: player.tempo)
        let locked = hub.room.controlsLocked
        VStack(spacing: 10) {
            Group {
                let f = MusicTime.fraction(position: player.listeningPosition, duration: dur)
                // With no known length every click would restart the song at zero, so a seek needs one.
                if hub.library.settings.player.wavySeekBar {
                    MusicWavySeekBar(fraction: f, playing: player.isPlaying, onChange: { if dur > 0 { player.seekListening(to: $0 * dur) } })
                } else {
                    PodcastScrubber(fraction: f, onChange: { if dur > 0 { player.seekListening(to: $0 * dur) } })
                }
            }
            .frame(height: MusicTokens.hitTarget).accessibilityLabel(MusicA11yLabels.seek).musicRoomLocked(locked)
            HStack {
                Text(verbatim: MusicTime.clock(player.listeningPosition)).font(Typography.timestamp)
                Spacer()
                if player.tempo != 1 { Text(verbatim: MusicEffectSettings.speedLabel(player.tempo)).font(Typography.timestamp).foregroundStyle(accent) }
                Spacer()
                Text(verbatim: MusicTime.remaining(position: player.listeningPosition, duration: dur)).font(Typography.timestamp)
            }
            .foregroundStyle(MusicInk.fullscreenInkSecondary)
            HStack(spacing: 18) {
                Button { player.shuffle.toggle() } label: { glyph("shuffle", tint: player.shuffle ? accent : MusicInk.fullscreenInkSecondary) }
                    .accessibilityLabel(Localized.string(player.shuffle ? "Shuffle on" : "Shuffle off")).accessibilityAddTraits(player.shuffle ? .isSelected : [])
                    .atlas("control.music.expandedPlayerMusicexpandedtransportbodyButton")
                Button { player.previous() } label: { glyph("backward.end.fill", size: 20) }.accessibilityLabel(Localized.string("Previous")).atlas("control.music.expandedPlayerPrevious")
                Button { player.toggle() } label: { glyph(player.isPlaying ? "pause.circle.fill" : "play.circle.fill", size: 52) }
                    .accessibilityLabel(Localized.string(player.isPlaying ? "Pause" : "Play")).atlas("control.music.expandedPlayerMusicexpandedtransportbodyButton")
                Button { player.next() } label: { glyph("forward.end.fill", size: 20) }.accessibilityLabel(Localized.string("Next")).atlas("control.music.expandedPlayerNext")
                Button { player.repeatMode = MusicQueueLogic.nextRepeat(player.repeatMode) } label: {
                    glyph(player.repeatMode == .one ? "repeat.1" : "repeat", tint: player.repeatMode == .off ? MusicInk.fullscreenInkSecondary : accent)
                }
                .accessibilityLabel(Localized.string(player.repeatMode == .off ? "Repeat off" : player.repeatMode == .all ? "Repeat all" : "Repeat one"))
                .accessibilityAddTraits(player.repeatMode != .off ? .isSelected : [])
                .atlas("control.music.expandedPlayerMusicexpandedtransportbodyButton")
            }
            .buttonStyle(.plain).foregroundStyle(MusicInk.fullscreenInk).frame(maxWidth: .infinity)
            .musicRoomLocked(locked)
            if let e = player.error {
                HStack(spacing: MusicSpace.xs) {
                    Text(verbatim: e).font(Typography.caption).foregroundStyle(ColorTokens.danger).lineLimit(2)
                    Button(Localized.string("Retry")) { player.retryCurrent() }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent)
                        .frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                        .accessibilityLabel(Localized.string("Retry playing this track")).atlas("control.music.expandedPlayerRetry")
                }
            } else if let n = player.notice {
                Text(verbatim: n).font(Typography.caption).foregroundStyle(MusicInk.fullscreenInkSecondary).lineLimit(2)
            }
            HStack(spacing: 14) {
                let liked = hub.library.isLiked(track)
                Button { hub.library.toggleLike(track) } label: { glyph(liked ? "heart.fill" : "heart", tint: liked ? accent : MusicInk.onArtworkSecondary) }
                    .accessibilityLabel(Localized.string(liked ? "Remove from Liked" : "Like")).accessibilityAddTraits(liked ? .isSelected : [])
                    .atlas("control.music.expandedPlayerMusicexpandedtransportbodyButton")
                MusicRadioThumbs(hub: hub, track: track, onDark: true, showsTired: true)
                Button { hub.chooseAudioSource(for: track) } label: { glyph("waveform.badge.magnifyingglass", tint: MusicInk.onArtworkSecondary) }
                    .help(Localized.string("Choose another audio source")).accessibilityLabel(Localized.string("Choose another audio source")).atlas("control.music.expandedPlayerChooseAnotherAudioSource")
                MusicEffectsButton(hub: hub)
                Spacer()
                Button { player.toggleMute() } label: { glyph(player.volume == 0 ? "speaker.slash" : "speaker.wave.2", tint: MusicInk.fullscreenInkSecondary) }
                    .accessibilityLabel(Localized.string(player.volume == 0 ? "Unmute" : "Mute")).atlas("control.music.expandedPlayerMusicexpandedtransportbodyButton")
                PodcastScrubber(fraction: Double(player.volume), onChange: { player.volume = Float($0) }, live: true).frame(width: 90, height: MusicTokens.hitTarget)
                    .accessibilityLabel(MusicA11yLabels.volume)
            }
            .buttonStyle(.plain)
            if locked { Text(verbatim: MusicRoomSession.lockExplanation).font(Typography.caption).foregroundStyle(MusicInk.fullscreenInkSecondary).multilineTextAlignment(.leading) }
        }
    }
}
