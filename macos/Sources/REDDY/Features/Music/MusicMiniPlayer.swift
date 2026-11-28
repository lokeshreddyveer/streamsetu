import SwiftUI
import Observation
#if os(macOS)
import AppKit
#endif

// The mini player and the shared state of Music's extra surfaces. The sizes, the anchoring and the screen test are plain functions so they can
// be tested; the floating window is macOS only (iOS gets nothing here). Nothing in these views runs a timer or an animation while idle.

// MARK: layout maths

enum MusicMiniLayout {
    static let full = CGSize(width: 560, height: 180)
    static let compact = CGSize(width: 320, height: 88)
    /// A window narrower than this uses the compact layout.
    static let compactBelowWidth: CGFloat = 440
    static let edgeInset: CGFloat = 24
    static let queueColumnWidth: CGFloat = 256

    static func isCompact(width: CGFloat) -> Bool { width < compactBelowWidth }
    static func size(compact c: Bool) -> CGSize { c ? compact : full }

    /// The frame after a resize that keeps the widget against the screen edges it is parked near. Per axis: when the window's centre is in
    /// the far half of the display (right, lower) it keeps its far edge, otherwise its near edge. Shrinking then growing returns to the same
    /// spot. Coordinates are screen coordinates with the origin at the lower left, as AppKit uses.
    static func resized(frame: CGRect, to size: CGSize, display: CGRect) -> CGRect {
        let x = frame.midX > display.midX ? frame.maxX - size.width : frame.minX
        let y = frame.midY < display.midY ? frame.minY : frame.maxY - size.height
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// A saved position is used only when the window's middle point lies on a display that is connected now.
    static func isOnScreen(origin: CGPoint, size: CGSize, displays: [CGRect]) -> Bool {
        let mid = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        return displays.contains { $0.contains(mid) }
    }

    /// Bottom-right of a display's work area, inset 24 points.
    static func defaultOrigin(size: CGSize, workArea: CGRect) -> CGPoint {
        CGPoint(x: workArea.maxX - size.width - edgeInset, y: workArea.minY + edgeInset)
    }
}

// MARK: shared surface state

/// What is open among Music's extra surfaces. The main view reads it; the buttons write it.
@MainActor @Observable
final class MusicSurfaceState {
    static let shared = MusicSurfaceState()
    var theatre = false
    var showShortcuts = false
    var miniOpen = false
}

/// The buttons that open the mini player and theatre mode. Nothing on iOS except theatre.
struct MusicSurfaceButtons: View {
    let hub: MusicHub
    var light = false
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        let tint = light ? MusicInk.onArtworkSecondary : ColorTokens.textSecondary
        HStack(spacing: MusicSpace.xxs) {
            Button { MusicSurfaceState.shared.theatre = true } label: {
                Image(systemName: "tv").font(MusicTokens.iconSmall).foregroundStyle(tint)
                    .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Theatre mode").musicTooltip("Theatre mode").atlas("control.music.miniPlayerTheatreMode")
            #if os(macOS)
            Button { MusicMiniPlayerController.shared.open(hub: hub) } label: {
                Image(systemName: "pip").font(MusicTokens.iconSmall).foregroundStyle(tint)
                    .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Open the mini player").musicTooltip("Mini player").atlas("control.music.miniPlayerOpenTheMiniPlayer")
            #endif
        }
    }
}

// MARK: the mini player view

struct MusicMiniPlayerView: View {
    let hub: MusicHub
    let compact: Bool
    var onToggleSize: () -> Void = {}
    var onBackToApp: () -> Void = {}
    @State private var tab = Tab.queue
    @State private var hovering = false
    @State private var volumeOpen = false
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    enum Tab { case queue, lyrics }

    private var player: MusicPlayer { hub.player }

    var body: some View {
        Group {
            if let t = player.current { content(t) }
            else { emptyState }
        }
        .frame(width: MusicMiniLayout.size(compact: compact).width, height: MusicMiniLayout.size(compact: compact).height)
        .background(MusicInk.fullscreenBackdrop)
        .clipShape(RoundedRectangle(cornerRadius: MusicCorner.cardLarge, style: .continuous))
        .onHover { hovering = $0 }
    }

    /// Nothing is playing (stopped, or the queue ended): the way back to the app stays on this panel, because the main window was hidden when it opened.
    private var emptyState: some View {
        VStack(spacing: MusicSpace.sm) {
            Text(Localized.string("Nothing playing")).font(Typography.body).foregroundStyle(MusicInk.onArtworkSecondary)
            Button(Localized.string("Back to the app")) { onBackToApp() }
                .buttonStyle(.bordered).atlas("control.music.miniPlayerEmptyBack")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func content(_ t: MusicTrack) -> some View {
        if compact { compactLayout(t) } else { fullLayout(t) }
    }

    // MARK: full 560 x 180

    private func fullLayout(_ t: MusicTrack) -> some View {
        let locked = hub.room.controlsLocked
        let leftWidth = MusicMiniLayout.full.width - MusicMiniLayout.queueColumnWidth
        return HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                cover(t, width: MusicMiniLayout.full.width * 0.56)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        Button { onBackToApp() } label: { miniGlyph("arrow.up.left.and.arrow.down.right") }
                            .buttonStyle(.plain).opacity(hovering ? 1 : 0).accessibilityLabel("Back to the app").atlas("control.music.miniPlayerBackToTheApp")
                        Spacer()
                        topCluster(t)
                    }
                    Spacer()
                    Text(verbatim: MusicDisplayTitle.display(for: t)?.title ?? t.title).font(Typography.heading).lineLimit(1)
                    secondLine(t, font: MusicTypeRole.secondary.font)
                    HStack(spacing: 8) {
                        Button { player.previous() } label: { miniGlyph("backward.end.fill") }.accessibilityLabel(MusicA11yLabels.previous).atlas("control.music.miniPlayerPrevious")
                        MiniSeek(player: player)
                        Button { player.next() } label: { miniGlyph("forward.end.fill") }.accessibilityLabel(MusicA11yLabels.next).atlas("control.music.miniPlayerNext")
                    }
                    .buttonStyle(.plain).musicRoomLocked(locked).padding(.top, MusicSpace.xxs)
                }
                .padding(MusicSpace.xs + 2).foregroundStyle(MusicInk.onArtwork)
            }
            .frame(width: leftWidth)
            VStack(spacing: MusicSpace.xs - 2) {
                Picker("", selection: $tab) { Text(Localized.string("Up next")).tag(Tab.queue); Text(Localized.string("Lyrics")).tag(Tab.lyrics) }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.mini).accessibilityLabel("Queue or lyrics").atlas("control.music.miniPlayerQueueOrLyrics")
                Group {
                    if tab == .queue { upNext } else { MusicLyricsPanel(hub: hub) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: MusicSpace.xl) {
                    Button { player.shuffle.toggle() } label: {
                        MusicIcon(glyph: .shuffle, size: MusicIconSize.large, tint: player.shuffle ? .accent : .custom(MusicInk.onArtworkSecondary))
                            .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
                    }.accessibilityLabel(Localized.string(player.shuffle ? "Shuffle on" : "Shuffle off")).accessibilityAddTraits(player.shuffle ? .isSelected : []).atlas("control.music.miniPlayerShuffle")
                    Button { player.toggle() } label: {
                        MusicPlayPauseIcon(isPlaying: player.isPlaying, size: MusicIconSize.hero, tint: .custom(MusicInk.onArtwork))
                            .frame(width: MusicIconSize.hero + MusicSpace.xs, height: MusicIconSize.hero + MusicSpace.xs).contentShape(Rectangle())
                    }
                    .accessibilityLabel(player.isPlaying ? MusicA11yLabels.pause : MusicA11yLabels.play).atlas("control.music.miniPlayerMusicminiplayerviewfulllayoutButton")
                    Button { player.repeatMode = MusicQueueLogic.nextRepeat(player.repeatMode) } label: {
                        MusicIcon(glyph: player.repeatMode == .one ? .repeatOne : .repeatAll, size: MusicIconSize.large,
                                  tint: player.repeatMode == .off ? .custom(MusicInk.onArtworkSecondary) : .accent)
                            .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
                    }.accessibilityLabel(Localized.string(player.repeatMode == .off ? "Repeat off" : player.repeatMode == .all ? "Repeat all" : "Repeat one")).accessibilityAddTraits(player.repeatMode != .off ? .isSelected : []).atlas("control.music.miniPlayerRepeat")
                }
                .buttonStyle(.plain).foregroundStyle(MusicInk.onArtwork).musicRoomLocked(locked)
            }
            .padding(MusicSpace.xs).frame(width: MusicMiniLayout.queueColumnWidth)
            .background(MusicInk.scrim(.light))
        }
    }

    private func topCluster(_ t: MusicTrack) -> some View {
        HStack(spacing: MusicSpace.xxs) {
            // The volume slider grows to the left of the speaker on hover or while it is open. The wrapper has no gap so it does not collapse mid-move.
            HStack(spacing: 0) {
                if hovering || volumeOpen {
                    PodcastScrubber(fraction: Double(player.volume), onChange: { player.volume = Float($0) }, live: true).frame(width: 80, height: 14)
                        .accessibilityLabel("Volume")
                }
                Button { player.toggleMute() } label: { miniGlyph(player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                    .buttonStyle(.plain).accessibilityLabel(player.volume == 0 ? "Unmute" : "Mute").atlas("control.music.miniPlayerMusicminiplayerviewtopclusterButton")
            }
            .onHover { volumeOpen = $0 }
            Button { onToggleSize() } label: { miniGlyph("arrow.down.right.and.arrow.up.left") }
                .buttonStyle(.plain).accessibilityLabel("Make the mini player smaller").atlas("control.music.miniPlayerMakeTheMiniPlayerSmaller")
            Button { hub.library.toggleLike(t) } label: {
                MusicHeartIcon(filled: hub.library.isLiked(t), size: MusicIconSize.medium)
                    .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(hub.library.isLiked(t) ? MusicA11yLabels.unlike : MusicA11yLabels.like).atlas("control.music.miniPlayerMusicminiplayerviewtopclusterButton")
            Button { dislike(t) } label: { miniGlyph("hand.thumbsdown") }
                .buttonStyle(.plain).disabled(hub.room.controlsLocked).accessibilityLabel(Localized.string("Dislike: remove this song from the queue")).atlas("control.music.miniPlayerDislikeRemoveThisSongFromThe")
        }
    }

    /// The line under the title: the artists, or (for a failed track, a notice or buffering) what is happening, with Retry.
    @ViewBuilder private func secondLine(_ t: MusicTrack, font: Font) -> some View {
        if let e = player.error {
            HStack(spacing: MusicSpace.xs) {
                Text(verbatim: e).font(font).foregroundStyle(ColorTokens.danger).lineLimit(1)
                Button(Localized.string("Retry")) { player.retryCurrent() }.buttonStyle(.plain).font(font).foregroundStyle(accent)
                    .accessibilityLabel(Localized.string("Retry playing this track")).atlas("control.music.miniPlayerRetry")
            }
        } else if let n = player.notice {
            Text(verbatim: n).font(font).foregroundStyle(MusicInk.onArtworkSecondary).lineLimit(1)
        } else if player.isBuffering {
            Text(Localized.string("Buffering")).font(font).foregroundStyle(MusicInk.onArtworkSecondary).lineLimit(1)
        } else {
            Text(verbatim: t.displayArtistLine).font(font).foregroundStyle(MusicInk.onArtworkSecondary).lineLimit(1)
        }
    }

    /// The same gesture as the bar's thumbs-down: while a station plays it teaches the station, otherwise the song leaves the queue. A guest following the host cannot.
    private func dislike(_ t: MusicTrack) {
        guard !hub.room.controlsLocked else { return }
        if hub.radio.isActive { hub.radio.thumbsDown(t) } else { player.purgeUpcoming { $0.uid == t.uid } }
    }

    /// The next rows of the queue. Three fit; the fourth is cut by a fade so the list reads as continuing.
    private var upNext: some View {
        let rows = player.rows
        let start = (player.index ?? -1) + 1
        let slice = start < rows.count ? Array(rows[start...].prefix(4)) : []
        return VStack(spacing: MusicSpace.xs - 2) {
            ForEach(Array(slice.enumerated()), id: \.element.id) { off, e in
                Button { player.jump(to: start + off) } label: {
                    HStack(spacing: MusicSpace.xs) {
                        MusicBarArtwork(thumbs: e.track.thumbnails, size: 36, artworkClass: .trackThumb, corner: MusicCorner.control - 1, track: e.track)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: e.track.title).font(Typography.captionMedium).lineLimit(1)
                            Text(verbatim: e.track.displayArtistLine).font(MusicTypeRole.micro.font).foregroundStyle(MusicInk.onArtworkSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(MusicInk.onArtwork).accessibilityLabel(hub.room.controlsLocked ? Localized.string("Following the host") : Localized.string("Play %@", e.track.title)).atlas("control.music.miniPlayerPlay")
            }
            if slice.isEmpty { Text(Localized.string("Nothing up next")).font(MusicTypeRole.caption.font).foregroundStyle(MusicInk.onArtworkTertiary) }
            Spacer(minLength: 0)
        }
        .musicRoomLocked(hub.room.controlsLocked)
        .mask(LinearGradient(stops: [.init(color: MusicInk.fullscreenBackdrop, location: 0), .init(color: MusicInk.fullscreenBackdrop, location: 0.7), .init(color: MusicInk.clear, location: 1)], startPoint: .top, endPoint: .bottom))
    }

    // MARK: compact 320 x 88

    private func compactLayout(_ t: MusicTrack) -> some View {
        let locked = hub.room.controlsLocked
        return ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                cover(t, width: 88, solidTo: 0.65)
                VStack(alignment: .leading, spacing: MusicSpace.xxs - 1) {
                    Text(verbatim: MusicDisplayTitle.display(for: t)?.title ?? t.title).font(Typography.rowMedium).lineLimit(1)
                    secondLine(t, font: MusicTypeRole.caption.font)
                    Spacer(minLength: 0)
                    HStack(spacing: MusicSpace.xxs) {
                        Button { player.previous() } label: { miniGlyph("backward.end.fill") }.accessibilityLabel(MusicA11yLabels.previous).atlas("control.music.miniPlayerPrevious")
                        Button { player.toggle() } label: {
                            MusicPlayPauseIcon(isPlaying: player.isPlaying, size: MusicIconSize.control, tint: .custom(MusicInk.onArtwork))
                                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
                        }
                        .accessibilityLabel(player.isPlaying ? MusicA11yLabels.pause : MusicA11yLabels.play).atlas("control.music.miniPlayerMusicminiplayerviewcompactlayoutButton")
                        Button { player.next() } label: { miniGlyph("forward.end.fill") }.accessibilityLabel(MusicA11yLabels.next).atlas("control.music.miniPlayerNext")
                    }
                    .buttonStyle(.plain).musicRoomLocked(locked)
                }
                .padding(.vertical, MusicSpace.xs).padding(.trailing, MusicSpace.xs).foregroundStyle(MusicInk.onArtwork)
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    Button { hub.library.toggleLike(t) } label: {
                        MusicHeartIcon(filled: hub.library.isLiked(t), size: MusicIconSize.medium)
                            .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
                    }
                    .accessibilityLabel(hub.library.isLiked(t) ? MusicA11yLabels.unlike : MusicA11yLabels.like).atlas("control.music.miniPlayerMusicminiplayerviewcompactlayoutButton")
                    Button { dislike(t) } label: { miniGlyph("hand.thumbsdown") }.disabled(hub.room.controlsLocked).accessibilityLabel(Localized.string("Dislike")).atlas("control.music.miniPlayerDislike")
                }
                .buttonStyle(.plain).foregroundStyle(MusicInk.onArtwork).padding(.trailing, MusicSpace.xxs).padding(.top, MusicSpace.xl)
            }
            Button { onToggleSize() } label: { miniGlyph("arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.plain).foregroundStyle(MusicInk.onArtworkSecondary).accessibilityLabel("Make the mini player larger").atlas("control.music.miniPlayerMakeTheMiniPlayerLarger")
        }
        // Position as a 2 point line along the bottom edge. Display only; its own view, so a tick does not redraw this one.
        .overlay(alignment: .bottomLeading) { MusicBarCompactLine(player: player, fallbackDuration: t.duration) }
    }

    // MARK: pieces

    /// A small symbol with the platform hit target around it.
    private func miniGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol).font(MusicTokens.iconSmall)
            .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
    }

    /// The cover under the left part, fading out to the right (opaque to 70 percent) with a dark shade behind white text.
    private func cover(_ t: MusicTrack, width: CGFloat, solidTo: Double = 0.7) -> some View {
        ZStack {
            MusicBarArtwork(thumbs: t.thumbnails, size: max(MusicMiniLayout.full.height, width), artworkClass: .mini, corner: 0, track: t)
                .frame(width: width, height: MusicMiniLayout.size(compact: compact).height, alignment: .leading).clipped()
                .id(t.uid)
                .transition(.opacity)
            LinearGradient(stops: [.init(color: MusicInk.scrim(.heavy), location: 0), .init(color: MusicInk.scrim(.strong), location: solidTo), .init(color: MusicInk.clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .frame(width: width, height: MusicMiniLayout.size(compact: compact).height)
        .mask(LinearGradient(stops: [.init(color: MusicInk.fullscreenBackdrop, location: 0), .init(color: MusicInk.fullscreenBackdrop, location: solidTo), .init(color: MusicInk.clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        .animation(MusicMotion.animation(.artwork, reduce: BrandMotion.reduced(systemReduceMotion)), value: t.uid)
        .accessibilityHidden(true)
    }
}

/// The seek bar of the mini player, listening-time based like the main bar. Split out so only it re-evaluates as the position ticks.
private struct MiniSeek: View {
    let player: MusicPlayer

    var body: some View {
        let known = player.listeningDuration
        let dur = known > 0 ? known : 1
        // With no known length a click would restart the song at zero.
        PodcastScrubber(fraction: MusicTime.fraction(position: player.listeningPosition, duration: dur), onChange: { if known > 0 { player.seekListening(to: $0 * dur) } })
            .frame(height: MusicTokens.hitTarget).accessibilityLabel(MusicA11yLabels.seek)
    }
}

// MARK: the floating window (macOS)

#if os(macOS)
private final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the mini player window. Opening hides the main window only after the widget is on screen, so a failed build never leaves the app
/// without a window. Restoring is one routine: it closes the mini player first, then shows and focuses the main window.
@MainActor
final class MusicMiniPlayerController {
    static let shared = MusicMiniPlayerController()
    private var panel: MiniPanel?
    private weak var mainWindow: NSWindow?
    private var hubRef: MusicHub?
    var isOpen: Bool { panel != nil }
    /// True while the mini player is open, and during the hand-over between it and the main window (no window is visible for a moment).
    private(set) var transitioning = false
    var keepsAppAlive: Bool { isOpen || transitioning }

    func open(hub: MusicHub) {
        guard panel == nil else { panel?.makeKeyAndOrderFront(nil); return }
        transitioning = true
        defer { DispatchQueue.main.async { self.transitioning = false } }
        hubRef = hub
        let compact = hub.library.settings.player.miniCompact
        let size = MusicMiniLayout.size(compact: compact)
        let displays = NSScreen.screens.map(\.frame)
        let p = hub.library.settings.player
        var origin: CGPoint
        if let x = p.miniPositionX, let y = p.miniPositionY, MusicMiniLayout.isOnScreen(origin: CGPoint(x: x, y: y), size: size, displays: displays) {
            origin = CGPoint(x: x, y: y)
        } else {
            let screen = (NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first)
            origin = MusicMiniLayout.defaultOrigin(size: size, workArea: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
        }
        let panel = MiniPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "StreamSetu Music Mini Player"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        panel.isReleasedWhenClosed = false
        self.panel = panel
        refreshContent(compact: compact)
        let host = NSApp.windows.first { $0.isVisible && $0 !== panel && $0.canBecomeMain }
        panel.orderFrontRegardless()
        MusicSurfaceState.shared.miniOpen = true
        mainWindow = host
        host?.orderOut(nil)
    }

    /// Saves the position and closes the widget. `showMain` brings the main window back.
    func close(showMain: Bool = true) {
        transitioning = true
        defer { DispatchQueue.main.async { self.transitioning = false } }
        if let p = panel, let hub = hubRef {
            hub.library.settings.player.miniPositionX = Double(p.frame.origin.x)
            hub.library.settings.player.miniPositionY = Double(p.frame.origin.y)
        }
        panel?.orderOut(nil)
        panel = nil
        MusicSurfaceState.shared.miniOpen = false
        if showMain { showMainWindow() }
    }

    func showMainWindow() {
        transitioning = true
        defer { DispatchQueue.main.async { self.transitioning = false } }
        if panel != nil { close(showMain: false) }
        let w = mainWindow ?? NSApp.windows.first { $0.canBecomeMain }
        NSApp.activate(ignoringOtherApps: true)
        if w?.isMiniaturized == true { w?.deminiaturize(nil) }
        w?.makeKeyAndOrderFront(nil)
    }

    private func toggleCompact() {
        guard let panel, let hub = hubRef else { return }
        let compact = !hub.library.settings.player.miniCompact
        hub.library.settings.player.miniCompact = compact
        let display = (panel.screen ?? NSScreen.main)?.frame ?? panel.frame
        panel.setFrame(MusicMiniLayout.resized(frame: panel.frame, to: MusicMiniLayout.size(compact: compact), display: display), display: true)
        refreshContent(compact: compact)
    }

    private func refreshContent(compact: Bool) {
        guard let panel, let hub = hubRef else { return }
        let view = MusicMiniPlayerView(hub: hub, compact: compact, onToggleSize: { [weak self] in self?.toggleCompact() },
                                       onBackToApp: { [weak self] in self?.showMainWindow() })
        panel.contentView = NSHostingView(rootView: view)
    }
}
#endif
