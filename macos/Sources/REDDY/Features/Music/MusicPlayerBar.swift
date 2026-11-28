import SwiftUI

// The Music player bar: one bar hosted once by the shell. Left: artwork, title, artist and the heart in fixed geometry. Centre: transport and a
// thin progress line with its own scrub state. Right: a cluster that folds into the "..." menu as the width drops (MusicBarCollapse).
// The bar body never reads `player.position`: the progress lives in its own small views, so a position tick redraws only those.

/// Where focus returns after a popover or menu from the bar closes.
enum MusicBarFocus: Hashable { case quality, output, more, effects }

struct MusicPlayerBar: View {
    let hub: MusicHub
    var layout: MusicLayoutClass
    @Binding var panel: MusicPanel?
    var player: MusicPlayer { hub.player }

    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    /// Observable (the Settings switch redraws the bar at once); the static read in `MusicAccessibilityPrefs` is not.
    @AppStorage(MusicAccessibilityPrefs.simplifiedKey) private var simplified = false

    /// Heights and the old width constant stay under their names so the shell and the root view keep compiling.
    static let height: CGFloat = MusicBarMetrics.heightFull
    static let compactHeight: CGFloat = MusicBarMetrics.heightCompact

    /// The shell's form: no panel binding (queue and lyrics are then opened through `onPanel`, or do nothing).
    init(hub: MusicHub, layout: MusicLayoutClass, panel: Binding<MusicPanel?> = .constant(nil)) {
        self.hub = hub
        self.layout = layout
        self._panel = panel
    }

    /// The form the per-screen bar used before the shell hosted it. `narrow` maps to the compact class, anything else to the medium one.
    init(hub: MusicHub, panel: Binding<MusicPanel?>, narrow: Bool = false) {
        self.init(hub: hub, layout: narrow ? .compact : .medium, panel: panel)
    }

    private var reduce: Bool { BrandMotion.reduced(systemReduceMotion) }
    /// The width the bar really has (the slot beside the sidebar and an inline panel), measured, not the window's. Zero until the first measure.
    @State private var availableWidth: CGFloat = 0

    /// The layout class the bar draws: never wider than the class its slot allows. The window's class alone is not enough: with the sidebar and the panel open the slot is narrower than
    /// the window, and a pill drawn for the window's class would be wider than its glass (the cover and buttons sticking out of the capsule while the window is resized).
    private var cls: MusicLayoutClass {
        if hub.miniPlayer { return .compact }
        guard availableWidth > 0 else { return layout }
        let fitting = [MusicLayoutClass.wide, .expanded, .medium].first { Self.pillWidth(for: $0) + 2 * MusicSpace.lg <= availableWidth }
        return min(layout, fitting ?? .compact)
    }

    var body: some View {
        if let t = player.current {
            Group {
                if cls == .compact { compactBar(t).musicWheelVolume(player, enabled: !hub.expandedPlayer && !MusicSurfaceState.shared.theatre) } else { pillBar(t) }
            }
            .frame(height: MusicBarMetrics.height(for: cls))
            .frame(maxWidth: .infinity)
            .background(GeometryReader { g in Color.clear.onAppear { availableWidth = g.size.width }.onChange(of: g.size.width) { _, w in availableWidth = w } })
            // The wide bar is a floating pill (the slot behind it is clear); the compact bar keeps its full-width strip.
            .background { if cls == .compact { PodcastBarBackground() } }
            .overlay(alignment: .top) {
                if contrast == .increased { Rectangle().fill(ColorTokens.lineStrong).frame(height: 1).allowsHitTesting(false) }
            }
            .musicFocusRegion(Localized.string("Player"))
            .onChange(of: snapshot(t), initial: true) { _, s in MusicAnnouncer.shared.observe(s) }
        }
    }

    /// What the announcer compares. Position is not in it, so progress ticks never announce.
    private func snapshot(_ t: MusicTrack) -> MusicAnnouncer.Snapshot {
        MusicAnnouncer.Snapshot(trackID: t.uid, title: t.title, artist: t.artistLine, isPlaying: player.isPlaying)
    }

    // MARK: layouts

    /// The floating pill, in the three zones every player uses: the song on the left (cover, title, artist, heart) taking whatever room is left, the transport in the middle with
    /// the progress line directly under it, and the right-hand buttons hugging their own width. A rounded glass capsule that sits clear of the window edge, centred, never wider
    /// than `pillWidth(for:)`.
    static func pillWidth(for cls: MusicLayoutClass) -> CGFloat {
        switch cls { case .wide: 940; case .expanded: 820; case .medium: 660; case .compact: 480 }
    }
    /// The width of the middle zone (transport above the progress line).
    static func pillCentreWidth(for cls: MusicLayoutClass) -> CGFloat {
        switch cls { case .wide: 340; case .expanded: 300; case .medium: 250; case .compact: 220 }
    }
    /// The right-hand buttons get less room in the narrower pills; what does not fit folds into the "…" menu.
    /// What is left of the pill for the buttons: the pill's inner width minus the song zone's minimum, the middle zone, the two gaps and the "..." button. (A fixed 150 or 196 let only
    /// three buttons show even in the widest pill, so the volume slider never appeared.)
    static func pillBudget(for cls: MusicLayoutClass) -> CGFloat {
        let inner = pillWidth(for: cls) - 2 * MusicSpace.lg
        return max(0, inner - 180 - pillCentreWidth(for: cls) - 2 * MusicSpace.md - MusicBarMetrics.moreWidth)
    }
    private func pillBar(_ t: MusicTrack) -> some View {
        let resolved = MusicBarCollapse.resolve(available: Self.pillBudget(for: cls), present: presentControls(t))
        let clusterWidth = resolved.shown.reduce(CGFloat(0)) { $0 + MusicBarMetrics.width(of: $1) } + MusicBarMetrics.moreWidth
        return HStack(spacing: MusicSpace.md) {
            HStack(spacing: MusicSpace.sm) {
                Button { panel = panel == .nowPlaying ? nil : .nowPlaying } label: {
                    MusicBarArtwork(thumbs: t.thumbnails, size: 42, artworkClass: .mini, corner: MusicCorner.control, track: t)
                }
                .buttonStyle(.plain).accessibilityLabel(MusicA11yLabels.nowPlaying(title: t.title, artist: t.artistLine)).accessibilityHint(MusicA11yLabels.openPlayerHint)
                .musicTooltip("Open Now Playing").atlas("control.music.playerAndQueueOpenNowPlaying")
                VStack(alignment: .leading, spacing: 0) {
                    MusicMarquee(text: MusicDisplayTitle.display(for: t)?.title ?? t.title, font: MusicTypeRole.card.font, playing: player.isPlaying, hugging: true)
                    if player.error != nil || player.notice != nil || player.isBuffering { status(t) } else { artistLine(t) }   // a failed track, a notice or buffering is said where the person looks
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                likeButton(t)
                if !simplified { MusicRadioThumbs(hub: hub, track: t) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 4) {
                HStack(spacing: MusicSpace.xxs) {
                    if !simplified { shuffleButton }
                    previousButton
                    playButton(size: 34 * MusicAccessibilityPrefs.controlScale, shortcutID: .full)
                    nextButton
                    if !simplified { repeatButton }
                }
                .musicRoomLocked(hub.room.controlsLocked)
                .animation(MusicMotion.animation(.toggle, reduce: reduce), value: player.shuffle)
                .animation(MusicMotion.animation(.toggle, reduce: reduce), value: player.repeatMode)
                MusicBarProgress(hub: hub, fallbackDuration: t.duration, showsTimes: cls >= .expanded).frame(height: 8)
            }
            .frame(width: Self.pillCentreWidth(for: cls))
            if simplified {
                // The simplified bar keeps one control: the more menu, which then carries everything the cluster would show.
                MusicBarMoreMenu(hub: hub, track: t, panel: $panel, overflow: MusicBarCollapse.displayOrder.filter { presentControls(t).contains($0) }, compactExtras: true)
            } else {
                rightCluster(t, budget: Self.pillBudget(for: cls)).frame(width: clusterWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, MusicSpace.lg).padding(.vertical, MusicSpace.xs)
        .frame(height: 60 * (MusicAccessibilityPrefs.largeControls ? 1.35 : 1))
        .frame(maxWidth: Self.pillWidth(for: cls))
        .musicWheelVolume(player, enabled: !hub.expandedPlayer && !MusicSurfaceState.shared.theatre)   // the wheel changes the volume over the pill only; the clear slot beside it still scrolls the page
        .background {
            // A capsule is half its height in radius, so it sits concentric with the window's rounded corner. Content scrolls under it, so the glass is dense enough to read over any
            // cover. Every colour is a theme token (the bar fill, the lines, the accent), so the app theme and Music's artwork-adaptive palette both carry through.
            Capsule(style: .continuous).fill(.regularMaterial)
                .overlay(Capsule(style: .continuous).fill(ColorTokens.barFill.opacity(0.62)))
                .overlay(Capsule(style: .continuous).fill(accent.opacity(0.07)))
                .overlay(Capsule(style: .continuous).strokeBorder(LinearGradient(colors: [ColorTokens.lineStrong, ColorTokens.line], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                .shadow(color: ColorTokens.background.opacity(0.6), radius: 16, y: 5)
        }
        // Centred in the window, 20 pt from each side when the window is narrow, and 12 pt clear of the bottom edge (the bar slot is 76 pt: 4 above, 60 bar, 12 below).
        .padding(.horizontal, MusicSpace.lg)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// Artwork, title, artist, play and pause, an optional next, and "...". Everything else is in the menu. A thin progress line sits on top.
    private func compactBar(_ t: MusicTrack) -> some View {
        GeometryReader { g in
            HStack(spacing: MusicSpace.sm) {
                trackBlock(t)
                HStack(spacing: MusicSpace.xs) {
                    playButton(size: 32 * MusicAccessibilityPrefs.controlScale, shortcutID: .compact)
                    if MusicBarCollapse.compactShowsNext(width: g.size.width) { nextButton }
                }
                .musicRoomLocked(hub.room.controlsLocked)
                MusicBarMoreMenu(hub: hub, track: t, panel: $panel, overflow: overflowControls(t), compactExtras: true, barIsCompact: true,
                                 menuHasNext: !MusicBarCollapse.compactShowsNext(width: g.size.width))
            }
            .padding(.horizontal, MusicSpace.sm)
            .frame(maxHeight: .infinity)
        }
        .overlay(alignment: .top) { MusicBarCompactLine(player: player, fallbackDuration: t.duration) }
    }

    // MARK: left block

    /// The compact bar's left block (the wider layouts show the pill instead).
    private func trackBlock(_ t: MusicTrack) -> some View {
        let size = MusicBarMetrics.artworkCompact
        return HStack(spacing: MusicSpace.sm) {
            Button {
                hub.expandedPlayer = true
            } label: {
                MusicBarArtwork(thumbs: t.thumbnails, size: size, artworkClass: .mini, corner: MusicCorner.control, track: t)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(MusicA11yLabels.nowPlaying(title: t.title, artist: t.artistLine))
            .accessibilityHint(MusicA11yLabels.openPlayerHint)
            .musicTooltip("Open Now Playing")
            .atlas("control.music.playerAndQueueOpenFullWindowNowPlaying")
            .atlasCovers("control.music.playerAndQueueOpenNowPlaying")
            VStack(alignment: .leading, spacing: MusicSpace.xxs / 2) {
                MusicMarquee(text: MusicDisplayTitle.display(for: t)?.title ?? t.title, font: MusicTypeRole.card.font, playing: player.isPlaying, hugging: false)
                // A failed track, a notice or buffering is said where the person looks, in the compact bar too.
                if player.error != nil || player.notice != nil || player.isBuffering { status(t) } else { artistLine(t) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The shared artist line: only real credited artists are links, anything else stays plain text (never "Unknown Artist" or "Various Artists" pages).
    private func artistLine(_ t: MusicTrack) -> some View {
        MusicTrackArtistLine(track: t, hub: hub, font: MusicTypeRole.caption.font)
    }

    private func likeButton(_ t: MusicTrack) -> some View {
        let liked = hub.library.isLiked(t)
        return Button { hub.library.toggleLike(t) } label: {
            MusicHeartIcon(filled: liked, size: MusicIconSize.large + 2)
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(liked ? MusicA11yLabels.unlike : MusicA11yLabels.like)
        .accessibilityAddTraits(liked ? .isSelected : [])
        .musicTooltip(verbatim: liked ? MusicA11yLabels.unlike : MusicA11yLabels.like)
        .atlas("control.music.playerAndQueueMusicplayerbartrackinfoButton")
    }

    @ViewBuilder private func status(_ t: MusicTrack) -> some View {
        if let e = player.error {
            HStack(spacing: MusicSpace.xs - 2) {
                Text(verbatim: e).font(MusicTypeRole.micro.font).foregroundStyle(ColorTokens.danger).lineLimit(1)
                Button("Retry") { player.retryCurrent() }.buttonStyle(.plain).font(MusicTypeRole.micro.font).foregroundStyle(accent)
                    .accessibilityLabel("Retry playing this track").atlas("control.music.playerAndQueueRetryPlayingThisTrack")
            }
        } else if let n = player.notice {
            Text(verbatim: n).font(MusicTypeRole.micro.font).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
        } else if player.isBuffering {
            HStack(spacing: MusicSpace.xxs) { MusicLoadingIcon(size: MusicIconSize.tiny); Text("Buffering").font(MusicTypeRole.micro.font).foregroundStyle(ColorTokens.textTertiary) }
        }
    }

    // MARK: transport

    private enum ShortcutSlot { case compact, full }

    private func playButton(size: CGFloat, shortcutID: ShortcutSlot) -> some View {
        Button { player.toggle() } label: {
            ZStack {
                Circle().fill(ColorTokens.textPrimary)
                MusicPlayPauseIcon(isPlaying: player.isPlaying, size: size * 0.55, tint: .custom(ColorTokens.background))
            }
            .frame(width: size, height: size)
            .frame(minWidth: MusicTokens.hitTarget, minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(MusicBarPressStyle())
        .accessibilityLabel(player.isPlaying ? MusicA11yLabels.pause : MusicA11yLabels.play)
        .musicTooltip(verbatim: player.isPlaying ? MusicA11yLabels.pause : MusicA11yLabels.play, shortcut: "\u{2325}Space")
        .keyboardShortcut(.space, modifiers: [.option])
        .atlas(shortcutID == .compact ? "control.music.playerAndQueueMusicplayerbarcompactbarKeyboardShortcut" : "control.music.playerAndQueueMusicplayerbartransportKeyboardShortcut")
        .atlasCovers("control.music.playerAndQueueMusicplayerbartransportKeyboardShortcut")
    }

    private var nextButton: some View {
        Button { player.next() } label: {
            Image(systemName: "forward.end.fill").font(MusicTokens.iconLarge).foregroundStyle(ColorTokens.textPrimary)
                .scaleEffect(MusicAccessibilityPrefs.controlScale)
                .frame(width: MusicTokens.hitTarget * MusicAccessibilityPrefs.controlScale, height: MusicTokens.hitTarget * MusicAccessibilityPrefs.controlScale).contentShape(Rectangle())
        }
        .buttonStyle(MusicBarPressStyle())
        .accessibilityLabel(MusicA11yLabels.next).accessibilityHint(MusicA11yLabels.nextHint)
        .musicTooltip(verbatim: MusicA11yLabels.next)
        .atlas("control.music.playerAndQueueNext")
    }

    private var previousButton: some View {
        Button { player.previous() } label: {
            Image(systemName: "backward.end.fill").font(MusicTokens.iconLarge).foregroundStyle(ColorTokens.textPrimary)
                .scaleEffect(MusicAccessibilityPrefs.controlScale)
                .frame(width: MusicTokens.hitTarget * MusicAccessibilityPrefs.controlScale, height: MusicTokens.hitTarget * MusicAccessibilityPrefs.controlScale).contentShape(Rectangle())
        }
        .buttonStyle(MusicBarPressStyle())
        .accessibilityLabel(MusicA11yLabels.previous).accessibilityHint(MusicA11yLabels.previousHint)
        .musicTooltip(verbatim: MusicA11yLabels.previous)
        .atlas("control.music.playerAndQueuePrevious")
    }

    private var shuffleButton: some View {
        Button { player.shuffle.toggle() } label: {
            MusicIcon(glyph: .shuffle, size: MusicIconSize.large, tint: player.shuffle ? .accent : .secondary)
                .overlay(alignment: .bottom) { stateDot(on: player.shuffle).offset(y: MusicSpace.xxs + 2) }
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(MusicBarPressStyle())
        .accessibilityLabel(Localized.string(player.shuffle ? "Shuffle on" : "Shuffle off"))
        .musicTooltip(verbatim: MusicA11yLabels.shuffle)
        .contextMenu { MusicShuffleMenuContent(hub: hub) }
        .accessibilityHint(Localized.string("Open the menu for shuffle styles and Autoplay"))
        .atlas("control.music.playerAndQueueMusicplayerbartransportButton")
    }

    private var repeatButton: some View {
        let mode = player.repeatMode
        return Button { player.repeatMode = MusicQueueLogic.nextRepeat(mode) } label: {
            MusicIcon(glyph: mode == .one ? .repeatOne : .repeatAll, size: MusicIconSize.large, tint: mode == .off ? .secondary : .accent)
                .overlay(alignment: .bottom) { stateDot(on: mode != .off).offset(y: MusicSpace.xxs + 2) }
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(MusicBarPressStyle())
        .accessibilityLabel(Localized.string(mode == .off ? "Repeat off" : mode == .all ? "Repeat all" : "Repeat one"))
        .musicTooltip(verbatim: MusicA11yLabels.repeat)
        .atlas("control.music.playerAndQueueMusicplayerbartransportButton")
    }

    /// A small dot under an active toggle, so the state is never colour alone.
    private func stateDot(on: Bool) -> some View {
        Circle().fill(accent).frame(width: MusicSpace.xxs - 1, height: MusicSpace.xxs - 1).opacity(on ? 1 : 0)
    }

    // MARK: right cluster

    private func presentControls(_ t: MusicTrack) -> Set<MusicBarControl> {
        var s: Set<MusicBarControl> = [.queue, .lyrics, .output, .volume, .expand, .effects, .sleep, .surfaces]
        if MusicQualityFacts.make(stream: player.currentStream).chip != nil { s.insert(.quality) }
        if t.videoID != nil, YouTubeMusicAccountBuiltIns.manager != nil { s.insert(.comments) }
        return s
    }

    private func overflowControls(_ t: MusicTrack) -> [MusicBarControl] {
        let r = MusicBarCollapse.resolve(available: 0, present: presentControls(t))   // only the compact bar asks: it has no cluster, everything is in the menu
        return r.overflow
    }

    private func rightCluster(_ t: MusicTrack, budget: CGFloat) -> some View {
        let r = MusicBarCollapse.resolve(available: budget, present: presentControls(t))
        return HStack(spacing: MusicSpace.xxs) {
            ForEach(MusicBarCollapse.displayOrder.filter { r.shown.contains($0) }, id: \.self) { c in clusterControl(c, t) }
            MusicBarMoreMenu(hub: hub, track: t, panel: $panel, overflow: r.overflow, compactExtras: false)
        }
    }

    @ViewBuilder private func clusterControl(_ c: MusicBarControl, _ t: MusicTrack) -> some View {
        switch c {
        case .queue: panelToggle(.queue, glyph: .queue, label: MusicA11yLabels.queue, hint: MusicA11yLabels.openQueueHint, id: "control.music.playerAndQueueQueue")
        case .lyrics: panelToggle(.lyrics, glyph: .lyrics, label: MusicA11yLabels.lyrics, hint: MusicA11yLabels.lyricsHint, id: "control.music.playerAndQueueLyrics")
        case .output: MusicOutputControl(hub: hub)
        case .volume: MusicBarVolume(player: player)
        case .expand:
            Button { hub.expandedPlayer = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textSecondary)
                    .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Open Full Window").accessibilityHint(MusicA11yLabels.openPlayerHint)
            .musicTooltip("Open Full Window").atlas("control.music.playerAndQueueOpenFullWindow")
        case .quality: MusicQualityButton(hub: hub)
        case .effects: MusicBarEffectsButton(hub: hub)
        case .sleep: MusicSleepMenu(hub: hub) { MusicSleepMenuLabel(timer: hub.sleepTimer) }
        case .surfaces: MusicSurfaceButtons(hub: hub)
        case .comments:
            Button { MusicBarComments.toggle(player.current) } label: {
                Image(systemName: "text.bubble").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textSecondary)
                    .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Comments").musicTooltip("Comments").atlas("control.music.playerAndQueueComments")
        }
    }

    private func panelToggle(_ target: MusicPanel, glyph: MusicGlyph, label: String, hint: String, id: String) -> some View {
        let on = panel == target
        return Button { panel = on ? nil : target } label: {
            MusicIcon(glyph: glyph, size: MusicIconSize.toolbar, tint: on ? .accent : .secondary)
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label).accessibilityHint(hint).accessibilityAddTraits(on ? .isSelected : [])
        .musicTooltip(verbatim: label)
        .atlas(id).atlasCovers("control.music.playerAndQueueQueue")
    }
}

// MARK: pieces

/// A cover sized for the bar, requested through its artwork class so the image is right-sized.
struct MusicBarArtwork: View {
    let thumbs: [MusicThumbnail]
    let size: CGFloat
    var artworkClass: MusicArtworkClass = .mini
    var corner: CGFloat = MusicCorner.compactCard
    /// The song, so a missing cover shows its album's or film's picture.
    var track: MusicTrack?

    var body: some View {
        MusicCoverImage(thumbs: thumbs, artworkClass: artworkClass, size: size, corner: corner).artwork(of: track.map { MusicArtworkSubject.derive($0) })
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
            .accessibilityHidden(true)
    }
}

/// Press feedback for the bar's plain buttons: a short dim, nothing at all with Reduce Motion.
private struct MusicBarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { MusicBarPressBody(configuration: configuration) }

    private struct MusicBarPressBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.6 : 1)
                .scaleEffect(configuration.isPressed && !BrandMotion.reduced(systemReduceMotion) ? 0.94 : 1)
                .animation(MusicMotion.animation(.press, reduce: BrandMotion.reduced(systemReduceMotion)), value: configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, down in if down { PremiumFeedback.tick() } }
        }
    }
}

/// What "Hide player" and "Stop playback" do. Hide only hides: audio, remote commands and the sleep timer are untouched.
@MainActor enum MusicBarActions {
    static func hide() { MusicBarVisibilityModel.shared.hide() }
    static func stopPlayback(_ hub: MusicHub) {
        guard !hub.room.controlsLocked else { return }   // a guest follows the host: nothing stops, so nothing closes either
        hub.expandedPlayer = false
        hub.player.stopAndClear()
        MusicBarVisibilityModel.shared.stopped()
    }
}

/// The bar while the Now Playing tab is open beside the page: only a thin progress line. Observes the position itself.
struct MusicBarThinLine: View {
    let player: MusicPlayer
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        let dur = player.duration > 0 ? player.duration : player.current?.duration ?? 0
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(ColorTokens.line)
                Rectangle().fill(accent).frame(width: g.size.width * MusicTime.fraction(position: player.position, duration: dur))
            }
        }
        .frame(height: MusicBarVisibility.lineHeight).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The compact bar's progress: a 2 pt line along the top edge. Display only, and the only part of the compact bar that follows the position.
struct MusicBarCompactLine: View {
    let player: MusicPlayer
    let fallbackDuration: TimeInterval
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        let dur = player.duration > 0 ? player.duration : fallbackDuration
        GeometryReader { g in
            Rectangle().fill(accent).frame(width: g.size.width * MusicTime.fraction(position: player.position, duration: dur), height: 2)
        }
        .frame(height: 2).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Elapsed time, the scrubber and the time left. Observes the player's position itself, so the bar around it does not redraw on a tick.
/// Playback and the finger are separate (`MusicScrubState`): while dragging, the position ticks do not move the thumb.
struct MusicBarProgress: View {
    let hub: MusicHub
    let fallbackDuration: TimeInterval
    var showsTimes = true

    @State private var scrub = MusicScrubState()
    @AppStorage(MusicShellKeys.showTotalTime) private var showsTotal = false
    @State private var hovering = false
    @State private var hoverFraction: CGFloat?
    @FocusState private var focused: Bool
    /// True only while focus came from the keyboard; a click never shows the ring.
    @State private var keyboardFocus = false
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var player: MusicPlayer { hub.player }
    private static let thin: CGFloat = 3
    private static let thick: CGFloat = 5
    private static let thumb: CGFloat = 12

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var body: some View {
        let dur = player.listeningDuration > 0 ? player.listeningDuration : MusicVolumeCurve.listening(fallbackDuration, tempo: player.tempo)
        let pos = player.listeningPosition
        let playback = MusicTime.fraction(position: pos, duration: dur)
        let f = scrub.displayFraction(playback: playback, now: now)
        let shown = scrub.isScrubbing ? f * dur : pos
        let width = MusicBarTimeLabel.width(forDuration: dur)
        let locked = hub.room.controlsLocked
        HStack(spacing: MusicSpace.xs) {
            if showsTimes {
                Text(verbatim: MusicTime.clock(shown)).font(Typography.timestamp).monospacedDigit().foregroundStyle(ColorTokens.textSecondary)
                    .frame(width: width, alignment: .trailing).accessibilityHidden(true)
            }
            seekControl(fraction: f, duration: dur, position: pos)
                .background { SoundCloudWaveformBackdrop(track: player.current, fraction: f) }
                .musicRoomLocked(locked)
            if showsTimes {
                // The time left, or the song's whole length: a press swaps them and the choice is remembered.
                Button { showsTotal.toggle() } label: {
                    Text(verbatim: showsTotal ? MusicTime.clock(dur) : MusicTime.remaining(position: shown, duration: dur)).font(Typography.timestamp).monospacedDigit()
                        .foregroundStyle(ColorTokens.textSecondary).frame(width: width + MusicSpace.xs, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsTotal ? Localized.string("Total length %@. Press to show the time left.", MusicTime.clock(dur))
                                               : Localized.string("Time left %@. Press to show the total length.", MusicTime.remaining(position: shown, duration: dur)))
                .musicTooltip(verbatim: Localized.string(showsTotal ? "Show time left" : "Show total length")).atlas("control.music.playerTimeToggle")
            }
        }
        .onChange(of: pos) { _, p in scrub.settle(playback: MusicTime.fraction(position: p, duration: dur), now: now) }
    }

    @ViewBuilder private func seekControl(fraction f: Double, duration dur: TimeInterval, position pos: TimeInterval) -> some View {
        if hub.library.settings.player.wavySeekBar {
            MusicWavySeekBar(fraction: f, playing: player.isPlaying,
                             onScrub: { keyboardFocus = false; scrub.update($0) },
                             onChange: { r in
                                 scrub.update(r)
                                 if let target = scrub.end(r, now: now) { commitSeek(target, dur: dur) }
                             })
                .frame(height: MusicTokens.hitTarget)
        } else {
            scrubber(fraction: f, duration: dur, position: pos)
        }
    }

    private func scrubber(fraction f: Double, duration dur: TimeInterval, position pos: TimeInterval) -> some View {
        let active = hovering || scrub.isScrubbing || focused
        let reduce = BrandMotion.reduced(systemReduceMotion)
        return GeometryReader { g in
            let w = max(1, g.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(ColorTokens.textPrimary.opacity(0.18)).frame(height: active ? Self.thick : Self.thin)
                Capsule().fill(accent).frame(width: w * f, height: active ? Self.thick : Self.thin)
                Circle().fill(ColorTokens.textPrimary).frame(width: Self.thumb, height: Self.thumb)
                    .offset(x: max(0, w * f - Self.thumb / 2)).opacity(active ? 1 : 0)
            }
            .frame(maxHeight: .infinity).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in keyboardFocus = false; scrub.update(v.location.x / w) }
                .onEnded { v in
                    if let target = scrub.end(v.location.x / w, now: now) { commitSeek(target, dur: dur) }
                })
        }
        .frame(height: MusicTokens.hitTarget)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hovering = true; hoverFraction = p.x
            case .ended: hovering = false; hoverFraction = nil
            }
        }
        .overlay(alignment: .topLeading) {
            // The time under the pointer, so a click's target is known before it is made (the slider pattern's tooltip).
            GeometryReader { g in
                if let x = hoverFraction, !scrub.isScrubbing, dur > 0 {
                    let w = max(1, g.size.width)
                    let t = max(0, min(1, x / w)) * dur
                    Text(verbatim: MusicTime.clock(t)).font(Typography.timestamp).monospacedDigit().foregroundStyle(ColorTokens.textPrimary)
                        .padding(.horizontal, MusicSpace.xs).padding(.vertical, 2)
                        .background(Capsule().fill(ColorTokens.surface))
                        .position(x: min(max(x, 22), w - 22), y: g.size.height + 2)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
        .animation(MusicMotion.animation(.hover, reduce: reduce), value: active)
        .focusable().focused($focused)
        .focusEffectDisabled()
        .onChange(of: focused) { _, now in keyboardFocus = now && !hovering }
        .overlay {
            if MusicBarFocusRing.visible(focused: focused, keyboard: keyboardFocus) {
                Capsule().strokeBorder(accent, lineWidth: MusicBarFocusRing.lineWidth(increasedContrast: contrast == .increased))
                    .padding(.vertical, MusicSpace.xs).padding(.horizontal, -MusicSpace.xxs).allowsHitTesting(false)
            }
        }
        .onKeyPress(.leftArrow) { keyboardFocus = true; nudge(from: f, forward: false, dur: dur); return .handled }
        .onKeyPress(.rightArrow) { keyboardFocus = true; nudge(from: f, forward: true, dur: dur); return .handled }
        .onKeyPress(.home) { keyboardFocus = true; seek(from: f, to: 0, dur: dur); return .handled }
        .onKeyPress(.end) { keyboardFocus = true; seek(from: f, to: 1, dur: dur); return .handled }
        .onKeyPress(.pageUp) { keyboardFocus = true; seek(from: f, to: MusicScrubState.paged(f, forward: true), dur: dur); return .handled }
        .onKeyPress(.pageDown) { keyboardFocus = true; seek(from: f, to: MusicScrubState.paged(f, forward: false), dur: dur); return .handled }
        .accessibilityElement()
        .accessibilityLabel(MusicA11yLabels.seek)
        .accessibilityValue(MusicBarTimeLabel.spoken(position: pos, duration: dur))
        .accessibilityAdjustableAction { d in nudge(from: f, forward: d == .increment, dur: dur) }
    }

    private func nudge(from f: Double, forward: Bool, dur: TimeInterval) {
        seek(from: f, to: MusicScrubState.nudged(f, forward: forward), dur: dur)
    }

    private func seek(from f: Double, to target: Double, dur: TimeInterval) {
        scrub.begin(f)
        if let t = scrub.end(target, now: now) { commitSeek(t, dur: dur) }
    }

    /// A seek needs a known length: with none (a track still resolving, a stream without one) every click would restart the song at zero.
    private func commitSeek(_ target: Double, dur: TimeInterval) {
        guard let seconds = MusicSeekGuard.target(fraction: target, duration: dur) else { scrub.cancel(); return }
        player.seekListening(to: seconds)
    }
}

/// Mute button and a volume slider.
struct MusicBarVolume: View {
    let player: MusicPlayer

    var body: some View {
        HStack(spacing: 0) {
            Button { player.toggleMute() } label: {
                Image(systemName: player.volume == 0 ? "speaker.slash" : "speaker.wave.2").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textSecondary)
                    .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.volume == 0 ? Localized.string("Unmute") : MusicA11yLabels.mute)
            .musicTooltip(verbatim: player.volume == 0 ? Localized.string("Unmute") : MusicA11yLabels.mute)
            .atlas("control.music.playerAndQueueMusicplayerbarextrasButton")
            PodcastScrubber(fraction: Double(player.volume), onChange: { player.volume = Float($0) }, live: true)
                .frame(width: MusicBarMetrics.volumeSlider, height: MusicTokens.hitTarget)
                .accessibilityLabel(MusicA11yLabels.volume)
        }
    }
}

/// The tune button: the same popover as `MusicEffectsButton`, with the bar's hit target.
struct MusicBarEffectsButton: View {
    let hub: MusicHub
    @State private var open = false
    @FocusState private var focus: MusicBarFocus?
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        let e = hub.player.effects
        let on = e.isActive || hub.player.equalizer.enabled
        Button { open.toggle() } label: {
            HStack(spacing: MusicSpace.xxs) {
                Image(systemName: "slider.horizontal.3").font(MusicTokens.iconSmall).foregroundStyle(on ? accent : ColorTokens.textSecondary)
                if e.speed != 1 { Text(verbatim: MusicEffectSettings.speedLabel(e.speed)).font(Typography.timestamp).foregroundStyle(accent) }
            }
            .frame(minWidth: MusicTokens.hitTarget, minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focus, equals: .effects)
        .accessibilityLabel(Localized.string(e.isActive ? "Playback effects, on" : "Playback effects"))
        .musicTooltip("Tempo, pitch and reverb")
        .popover(isPresented: $open, arrowEdge: .top) { MusicEffectsPopover(hub: hub) { open = false } }
        .musicRestoreFocus(after: open, to: .effects, focus: $focus)
        .atlas("control.music.effectsTempoPitchAndReverb")
    }
}

// MARK: quality and output

/// The quality chip. Shown only when the stream reports something; opens the facts popover.
struct MusicQualityButton: View {
    let hub: MusicHub
    @State private var open = false
    @FocusState private var focus: MusicBarFocus?

    var body: some View {
        let facts = MusicQualityFacts.make(stream: hub.player.currentStream, effectsActive: hub.player.effects.isActive || hub.player.equalizer.enabled, route: routeName)
        if let chip = facts.chip {
            Button { open.toggle() } label: {
                HStack(spacing: MusicSpace.xxs) {
                    MusicIcon(glyph: .quality, size: MusicIconSize.medium, tint: .tertiary)
                    Text(verbatim: chip).font(MusicTypeRole.micro.font).foregroundStyle(ColorTokens.textTertiary).lineLimit(1)
                }
                .padding(.horizontal, MusicSpace.xs - 2).padding(.vertical, MusicSpace.xxs / 2)
                .overlay(Capsule().strokeBorder(ColorTokens.line))
                .frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .quality)
            .accessibilityLabel(Localized.string("Audio quality, %@", chip))
            .musicTooltip("Audio quality")
            .popover(isPresented: $open, arrowEdge: .top) { MusicQualityPopover(facts: facts) }
            .musicRestoreFocus(after: open, to: .quality, focus: $focus)
            .atlas("control.music.playerBarAudioQuality")
        }
    }

    private var routeName: String? {
        #if os(macOS)
        let o = hub.player.outputs
        return MusicOutputRoute.label(resolution: o.resolution, chosenName: o.chosenName)
        #else
        return nil
        #endif
    }
}

/// The facts behind the chip: one row per fact the stream or the output reports, and nothing else.
struct MusicQualityPopover: View {
    let facts: MusicQualityFacts

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text("Audio quality").font(MusicTypeRole.section.font)
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                ForEach(facts.rows) { r in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: r.label).font(MusicTypeRole.caption.font).foregroundStyle(ColorTokens.textSecondary)
                        Spacer(minLength: MusicSpace.md)
                        Text(verbatim: r.value).font(MusicTypeRole.secondary.font).multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Shows only what this stream reports.").font(MusicTypeRole.micro.font).foregroundStyle(ColorTokens.textTertiary)
        }
        .padding(MusicSpace.md).frame(width: 260)
        .musicDialogAccessibility(Localized.string("Audio quality"))
    }
}

/// Where Music plays: a menu of the connected outputs on the Mac, the system route picker on iPhone and iPad.
struct MusicOutputControl: View {
    let hub: MusicHub
    @FocusState private var focus: MusicBarFocus?

    var body: some View {
        #if os(macOS)
        let outputs = hub.player.outputs
        Menu { MusicOutputItems(hub: hub) } label: {
            MusicIcon(glyph: .devices, size: MusicIconSize.toolbar, tint: outputs.chosenUID == nil ? .secondary : .accent)
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .focused($focus, equals: .output)
        .accessibilityLabel(Localized.string("Output device")).musicTooltip("Output device")
        .onAppear { outputs.start() }
        .atlas("control.music.playerBarOutput")
        #else
        MusicRoutePickerButton().frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget)
        #endif
    }
}

#if os(macOS)
/// The rows of the output menu: the system output, every connected output, and the chosen one while it is unplugged.
struct MusicOutputItems: View {
    let hub: MusicHub

    var body: some View {
        let outputs = hub.player.outputs
        Button { outputs.choose(nil) } label: {
            if outputs.chosenUID == nil { Label("System default", systemImage: "checkmark") } else { Text("System default") }
        }
        .atlas("control.music.playerBarOutputDevice")
        ForEach(outputs.available) { d in
            Button { outputs.choose(d.uid) } label: {
                if outputs.chosenUID == d.uid { Label { Text(verbatim: d.name) } icon: { Image(systemName: "checkmark") } } else { Text(verbatim: d.name) }
            }
            .atlas("control.music.playerBarOutputDevice")
        }
        if let c = outputs.chosenUID, !outputs.available.contains(where: { $0.uid == c }) {
            Text(verbatim: Localized.string("%@ (not connected)", outputs.chosenName ?? c))
        }
    }
}
#endif

// MARK: sleep timer and the bar's menu

/// The moon button. While a timer runs its label shows the time left; this is the only view that updates each second.
struct MusicSleepMenuLabel: View {
    let timer: MusicSleepTimer
    @Environment(\.reddyAccent) private var accent
    var body: some View {
        Group {
            if let left = timer.remaining {
                HStack(spacing: MusicSpace.xxs) {
                    Image(systemName: "moon.zzz.fill").font(MusicTokens.iconSmall)
                    Text(verbatim: MusicSleepLogic.label(remaining: left)).font(Typography.timestamp).monospacedDigit()
                }
                .foregroundStyle(accent).accessibilityLabel(Localized.string("Sleep timer, %@ left", MusicSleepLogic.label(remaining: left)))
            } else {
                Image(systemName: "moon.zzz").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel(Localized.string("Sleep timer"))
            }
        }
        .frame(minWidth: MusicTokens.hitTarget, minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
    }
}

/// The sleep timer's presets as a menu around any label.
struct MusicSleepMenu<Label: View>: View {
    let hub: MusicHub
    @Environment(\.reddyAccent) private var accent
    @ViewBuilder var label: () -> Label
    var body: some View {
        Menu { MusicSleepItems(hub: hub) } label: { label() }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tint(hub.sleepTimer.isRunning ? accent : ColorTokens.textSecondary).musicTooltip("Sleep timer").atlas("control.music.playerAndQueueSleepTimer")
    }
}

/// Menu rows: cancel (while running) and the presets. Shared by the sleep button and the bar's overflow menu.
struct MusicSleepItems: View {
    let hub: MusicHub
    var body: some View {
        if hub.sleepTimer.isRunning {
            Button("Cancel Sleep Timer", systemImage: "xmark.circle") { hub.sleepTimer.cancel() }.atlas("control.music.playerAndQueueCancelSleepTimer")
            Divider()
        }
        ForEach(MusicSleepPreset.all) { p in
            Button(p.title) { hub.sleepTimer.start(p) }.atlas("control.music.playerAndQueueMusicsleepitemsbodyButton")
        }
    }
}

/// What a popover opened from the "..." menu shows.
enum MusicBarPopover: String, Identifiable { case quality, effects; var id: String { rawValue } }

/// The "..." menu: the controls the cluster had no room for (priority order), then the actions that always live here. In the compact bar it
/// also carries like, previous, shuffle and repeat, so nothing the full bar offers is out of reach.
struct MusicBarMoreMenu: View {
    let hub: MusicHub
    let track: MusicTrack
    @Binding var panel: MusicPanel?
    var overflow: [MusicBarControl] = []
    var compactExtras = false
    /// The bar is already drawn compact (a narrow window): the choice would change nothing visible, so it is not offered unless it is the one that forced the compact form.
    var barIsCompact = false
    /// The bar has no room for its own Next button (a very narrow compact bar), so the menu carries it.
    var menuHasNext = false
    @State private var popover: MusicBarPopover?
    @FocusState private var focus: MusicBarFocus?

    private var player: MusicPlayer { hub.player }

    var body: some View {
        Menu {
            if compactExtras { compactItems; Divider() }
            if hub.radio.isActive { radioItems; Divider() }
            ForEach(overflow, id: \.self) { c in overflowItem(c) }
            if !overflow.isEmpty { Divider() }
            Button("Choose Another Audio Source…", systemImage: "waveform.badge.magnifyingglass") { hub.chooseAudioSource(for: track) }.atlas("control.music.playerAndQueueChooseAnotherAudioSource")
            Divider()
            Button("Hide player", systemImage: "chevron.down.square") { MusicBarActions.hide() }.atlas("control.music.playerHide")
            Button("Stop playback", systemImage: "stop.fill") { MusicBarActions.stopPlayback(hub) }.disabled(hub.room.controlsLocked).atlas("control.music.playerStop")
            if hub.miniPlayer || !barIsCompact { Divider() }
            if hub.miniPlayer || !barIsCompact { Button(hub.miniPlayer ? "Use Full Player Bar" : "Use Compact Player Bar", systemImage: hub.miniPlayer ? "rectangle.expand.vertical" : "rectangle.compress.vertical") { hub.miniPlayer.toggle() }.atlas("control.music.playerAndQueueUseFullPlayerBar") }
        } label: {
            Image(systemName: "ellipsis").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textSecondary)
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(ColorTokens.textSecondary)
        .focused($focus, equals: .more)
        .accessibilityLabel("More player actions").musicTooltip("More player actions")
        .popover(item: $popover, arrowEdge: .top) { p in
            switch p {
            case .quality: MusicQualityPopover(facts: MusicQualityFacts.make(stream: player.currentStream, effectsActive: player.effects.isActive || player.equalizer.enabled, route: routeName))
            case .effects: MusicEffectsPopover(hub: hub) { popover = nil }
            }
        }
        .musicRestoreFocus(after: popover != nil, to: .more, focus: $focus)
        .atlas("control.music.playerAndQueueMorePlayerActions")
    }

    private var routeName: String? {
        #if os(macOS)
        let o = player.outputs
        return MusicOutputRoute.label(resolution: o.resolution, chosenName: o.chosenName)
        #else
        return nil
        #endif
    }

    /// A station's feedback for the bar forms that have no thumbs of their own (compact, Simplified), and "Not for a while", which no bar form draws.
    @ViewBuilder private var radioItems: some View {
        Button(Localized.string("Thumbs up"), systemImage: "hand.thumbsup") { hub.radio.thumbsUp(track) }.disabled(hub.room.controlsLocked).atlas("control.music.radioThumbUp")
        Button(Localized.string("Thumbs down, skip and don't play on this station"), systemImage: "hand.thumbsdown") { hub.radio.thumbsDown(track) }
            .disabled(hub.room.controlsLocked).atlas("control.music.radioThumbDown")
        Button(Localized.string("Not for a while"), systemImage: "moon.zzz") { hub.radio.notForAWhile(track) }.disabled(hub.room.controlsLocked).atlas("control.music.radioNotForAWhile")
    }

    @ViewBuilder private var compactItems: some View {
        let liked = hub.library.isLiked(track)
        if player.error != nil {
            Button("Retry", systemImage: "arrow.clockwise") { player.retryCurrent() }.atlas("control.music.playerAndQueueRetryPlayingThisTrack")
        }
        Button(liked ? MusicA11yLabels.unlike : MusicA11yLabels.like, systemImage: liked ? "heart.fill" : "heart") { hub.library.toggleLike(track) }
            .atlas("control.music.playerAndQueueMusicplayerbartrackinfoButton")
        Button(MusicA11yLabels.previous, systemImage: "backward.end.fill") { player.previous() }.disabled(hub.room.controlsLocked).atlas("control.music.playerAndQueuePrevious")
        if menuHasNext {
            Button(MusicA11yLabels.next, systemImage: "forward.end.fill") { player.next() }.disabled(hub.room.controlsLocked).atlas("control.music.playerAndQueueNext")
        }
        Button(Localized.string(player.shuffle ? "Shuffle on" : "Shuffle off"), systemImage: "shuffle") { player.shuffle.toggle() }.disabled(hub.room.controlsLocked).atlas("control.music.playerAndQueueMusicplayerbartransportButton")
        Button(Localized.string(player.repeatMode == .off ? "Repeat off" : player.repeatMode == .all ? "Repeat all" : "Repeat one"), systemImage: player.repeatMode == .one ? "repeat.1" : "repeat") {
            player.repeatMode = MusicQueueLogic.nextRepeat(player.repeatMode)
        }.disabled(hub.room.controlsLocked).atlas("control.music.playerAndQueueMusicplayerbartransportButton")
    }

    @ViewBuilder private func overflowItem(_ c: MusicBarControl) -> some View {
        switch c {
        case .queue:
            Button("Queue", systemImage: "list.bullet") { panel = panel == .queue ? nil : .queue }.atlas("control.music.playerAndQueueQueue")
        case .lyrics:
            Button("Lyrics", systemImage: "text.quote") { panel = panel == .lyrics ? nil : .lyrics }.atlas("control.music.playerAndQueueLyrics")
        case .output:
            #if os(macOS)
            Menu("Output device", systemImage: "hifispeaker") { MusicOutputItems(hub: hub) }.atlas("control.music.playerBarOutput")
            #else
            EmptyView()
            #endif
        case .volume:
            Button(player.volume == 0 ? "Unmute" : "Mute", systemImage: player.volume == 0 ? "speaker.slash" : "speaker.wave.2") { player.toggleMute() }.atlas("control.music.playerAndQueueMusicplayerbarextrasButton")
            Button("Volume Up", systemImage: "speaker.plus") { player.nudgeVolume(by: 0.1) }.atlas("control.music.playerBarVolumeStep")
            Button("Volume Down", systemImage: "speaker.minus") { player.nudgeVolume(by: -0.1) }.atlas("control.music.playerBarVolumeStep")
        case .expand:
            Button("Open Full Window", systemImage: "arrow.up.left.and.arrow.down.right") { hub.expandedPlayer = true }.atlas("control.music.playerAndQueueOpenFullWindow")
        case .quality:
            Button("Audio quality", systemImage: "waveform") { popover = .quality }.atlas("control.music.playerBarAudioQuality")
        case .effects:
            Button("Tempo, pitch and reverb", systemImage: "slider.horizontal.3") { popover = .effects }.atlas("control.music.effectsTempoPitchAndReverb")
        case .sleep:
            Menu("Sleep Timer", systemImage: "moon.zzz") { MusicSleepItems(hub: hub) }.atlas("control.music.playerAndQueueSleepTimer")
        case .surfaces:
            Button("Theatre mode", systemImage: "tv") { MusicSurfaceState.shared.theatre = true }.atlas("control.music.miniPlayerTheatreMode")
            #if os(macOS)
            Button("Mini player", systemImage: "pip") { MusicMiniPlayerController.shared.open(hub: hub) }.atlas("control.music.miniPlayerOpenTheMiniPlayer")
            #endif
        case .comments:
            Button("Comments", systemImage: "text.bubble") { MusicBarComments.toggle(player.current) }.atlas("control.music.playerAndQueueComments")
        }
    }
}
