import SwiftUI
#if os(macOS)
import AppKit
#endif

// Theatre mode: the cover large on a dark stage, with optional lyrics and queue columns and a dock of controls that goes quiet after a few
// seconds. The sizes are plain functions. Nothing animates while the dock is calm and the track is paused or playing without changes.

enum MusicTheatreLayout {
    /// 1 rem is 16 points. A column needs a window at least 64 rem wide; both columns only from 90 rem.
    static let oneColumnWidth: CGFloat = 1024
    static let twoColumnWidth: CGFloat = 1440
    /// Windows at most 50 rem tall get a slimmer header and dock.
    static let shortHeight: CGFloat = 800
    static let calmDelay: TimeInterval = 3.5
    static let columnsGrowDelay: TimeInterval = 0.5
    static let flashDuration: TimeInterval = 0.22
    static let upNextWindow: TimeInterval = 20
    static let upNextMinTrack: TimeInterval = 30

    /// Which columns can be shown for the settings and the window width. Below two columns' width they share one column, and the one the
    /// person turned on last wins (`preferLyrics`).
    static func columns(width: CGFloat, lyrics: Bool, queue: Bool, preferLyrics: Bool = true) -> (lyrics: Bool, queue: Bool) {
        guard width >= oneColumnWidth else { return (false, false) }
        if width >= twoColumnWidth { return (lyrics, queue) }
        if lyrics && queue { return preferLyrics ? (true, false) : (false, true) }
        return (lyrics, queue)
    }

    static func headerHeight(windowHeight h: CGFloat) -> CGFloat { h <= shortHeight ? 64 : 80 }
    static func dockHeight(windowHeight h: CGFloat) -> CGFloat { h <= shortHeight ? 96 : 120 }

    /// The square cover's side: the column width, or the height left after the title block (104 in a column, 128 in the spotlight, plus
    /// 42 or 56 more when the title wraps to two lines), whichever is less, and at most 544 (34 rem) in columns or 704 (44 rem) alone.
    static func coverSide(columnWidth: CGFloat, availableHeight: CGFloat, spotlight: Bool, titleWraps: Bool) -> CGFloat {
        let block: CGFloat = (spotlight ? 128 : 104) + (titleWraps ? (spotlight ? 56 : 42) : 0)
        let cap: CGFloat = spotlight ? 704 : 544
        return max(0, min(columnWidth, availableHeight - block, cap))
    }

    /// The hint for the next track: the last 20 seconds of a track longer than 30 seconds, never when the queue column is shown or on repeat-one.
    static func showsUpNext(position: TimeInterval, duration: TimeInterval, queueColumn: Bool, repeatMode: MusicRepeat) -> Bool {
        guard duration > upNextMinTrack, !queueColumn, repeatMode != .one else { return false }
        return duration - position <= upNextWindow && duration - position > 0
    }

    /// "9:41 PM" or "21:41" by the chosen format ("auto" follows the system).
    static func clockText(_ date: Date, format: String) -> String {
        let f = DateFormatter()
        switch format {
        case "12": f.dateFormat = "h:mm a"
        case "24": f.dateFormat = "HH:mm"
        default: f.timeStyle = .short; f.dateStyle = .none
        }
        return f.string(from: date)
    }
}

struct MusicTheatreView: View {
    let hub: MusicHub
    var onClose: () -> Void
    @State private var calm = false
    @State private var calmTask: Task<Void, Never>?
    @State private var onDock = false
    @State private var flash = false
    @State private var hasLyrics: Bool?
    @State private var enteredFullScreen = false
    @State private var preferLyrics = true
    @Environment(\.reddyAccent) private var accent

    private var player: MusicPlayer { hub.player }
    private var prefs: MusicPlayerPrefs { hub.library.settings.player }

    var body: some View {
        GeometryReader { geo in
            let cols = MusicTheatreLayout.columns(width: geo.size.width, lyrics: prefs.theatreLyrics, queue: prefs.theatreQueue, preferLyrics: preferLyrics)
            // A song with no lyrics found gets the spotlight picture instead of an empty column. Decided only after a fetch answered.
            let showLyrics = cols.lyrics && hasLyrics != false
            let spotlight = !showLyrics && !cols.queue
            ZStack {
                Color.black.ignoresSafeArea()
                if let t = player.current {
                    VStack(spacing: 0) {
                        header(height: MusicTheatreLayout.headerHeight(windowHeight: geo.size.height))
                        stage(t, geo: geo, lyrics: showLyrics, queue: cols.queue, spotlight: spotlight)
                        dock(t, height: MusicTheatreLayout.dockHeight(windowHeight: geo.size.height), queueOn: prefs.theatreQueue)
                    }
                    MusicTheatreUpNextHost(player: player, queueColumn: cols.queue) { upNext($0) }
                }
                Button("Close") { onClose() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true).atlas("control.music.theatreClose")
            }
            .foregroundStyle(.white)
            .onContinuousHover { phase in if case .active = phase { wake() } }
            .onAppear { wake(); enterFullScreen() }
            .onDisappear { calmTask?.cancel(); leaveFullScreen() }
            .task(id: player.current?.uid) {
                hasLyrics = nil
                guard let t = player.current, prefs.theatreLyrics else { return }
                let l = await hub.lyrics.lyrics(for: t)
                if !Task.isCancelled { hasLyrics = (l?.isEmpty == false) }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Theatre mode")
        }
    }

    // MARK: pieces

    private func header(height: CGFloat) -> some View {
        HStack {
            Button { onClose() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32).background(Color.white.opacity(0.14), in: Circle()) }
                .buttonStyle(.plain).accessibilityLabel("Close theatre mode").atlas("control.music.theatreCloseTheatreMode")
            if prefs.theatreClock && prefs.theatreClockSide == "left" { clock }
            Spacer()
            if prefs.theatreClock && prefs.theatreClockSide == "right" { clock }
        }
        .padding(.horizontal, 24).frame(height: height)
        .opacity(calm ? 0 : 1)
    }

    private var clock: some View {
        TimelineView(.everyMinute) { ctx in
            Text(verbatim: MusicTheatreLayout.clockText(ctx.date, format: prefs.theatreClockFormat)).font(Typography.heading).monospacedDigit()
        }
        .accessibilityLabel("Clock")
    }

    private func stage(_ t: MusicTrack, geo: GeometryProxy, lyrics: Bool, queue: Bool, spotlight: Bool) -> some View {
        let columnCount = (lyrics ? 1 : 0) + (queue ? 1 : 0)
        let colWidth = columnCount == 0 ? geo.size.width - 96 : (geo.size.width - 96 - CGFloat(columnCount) * 24) / CGFloat(columnCount + 1)
        let avail = geo.size.height - MusicTheatreLayout.headerHeight(windowHeight: geo.size.height) - MusicTheatreLayout.dockHeight(windowHeight: geo.size.height)
        let side = MusicTheatreLayout.coverSide(columnWidth: colWidth, availableHeight: avail, spotlight: spotlight, titleWraps: t.title.count > 38)
        return HStack(alignment: .center, spacing: 24) {
            VStack(spacing: 14) {
                Button { player.toggle(); flashIcon() } label: {
                    MusicArtwork(track: t, size: side, corner: 14).shadow(color: .black.opacity(0.6), radius: 24, y: 10)
                        .overlay { if flash { Image(systemName: player.isPlaying ? "play.fill" : "pause.fill").font(.system(size: 44)).padding(24).background(.black.opacity(0.5), in: Circle()) } }
                }
                .buttonStyle(.plain).musicRoomLocked(hub.room.controlsLocked).accessibilityLabel(player.isPlaying ? "Pause" : "Play").atlas("control.music.theatreMusictheatreviewstageButton")
                VStack(spacing: 3) {
                    Text(verbatim: t.title).font(Typography.display).lineLimit(2).multilineTextAlignment(.center)
                    MusicTrackArtistLine(track: t, hub: hub, font: Typography.heading, rest: .white.opacity(0.7), hover: .white)
                }
            }
            .frame(width: max(side, 200))
            if lyrics { MusicLyricsPanel(hub: hub).frame(maxWidth: .infinity, maxHeight: .infinity) }
            if queue { MusicQueuePanel(hub: hub).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .padding(.horizontal, 48).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dock(_ t: MusicTrack, height: CGFloat, queueOn: Bool) -> some View {
        let locked = hub.room.controlsLocked
        let dur = player.listeningDuration > 0 ? player.listeningDuration : MusicVolumeCurve.listening(t.duration, tempo: player.tempo)
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(verbatim: MusicTime.clock(player.listeningPosition)).font(Typography.timestamp).frame(width: 52, alignment: .trailing)
                PodcastScrubber(fraction: MusicTime.fraction(position: player.listeningPosition, duration: dur), onChange: { player.seekListening(to: $0 * dur) })
                    .frame(height: 14).accessibilityLabel("Seek").musicRoomLocked(locked)
                Text(verbatim: MusicTime.remaining(position: player.listeningPosition, duration: dur)).font(Typography.timestamp).frame(width: 56, alignment: .leading)
            }
            HStack(spacing: 24) {
                Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(player.shuffle ? accent : .white) }.accessibilityLabel(Localized.string("Shuffle")).accessibilityValue(Localized.string(player.shuffle ? "On" : "Off")).atlas("control.music.theatreShuffle")
                Button { player.previous() } label: { Image(systemName: "backward.end.fill") }.accessibilityLabel("Previous").atlas("control.music.theatrePrevious")
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 40)) }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play").atlas("control.music.theatreMusictheatreviewdockButton")
                Button { player.next() } label: { Image(systemName: "forward.end.fill") }.accessibilityLabel("Next").atlas("control.music.theatreNext")
                Button { player.repeatMode = MusicQueueLogic.nextRepeat(player.repeatMode) } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(player.repeatMode == .off ? .white : accent)
                }.accessibilityLabel(Localized.string("Repeat")).accessibilityValue(Localized.string(player.repeatMode == .off ? "Off" : (player.repeatMode == .one ? "Repeat one" : "On"))).atlas("control.music.theatreRepeat")
            }
            .buttonStyle(.plain).musicRoomLocked(locked)
            HStack(spacing: 18) {
                Button { hub.library.toggleLike(t) } label: { Image(systemName: hub.library.isLiked(t) ? "heart.fill" : "heart").foregroundStyle(hub.library.isLiked(t) ? accent : .white) }
                    .accessibilityLabel(hub.library.isLiked(t) ? "Remove from Liked" : "Like").atlas("control.music.theatreMusictheatreviewdockButton")
                MusicEffectsButton(hub: hub)
                Spacer()
                Button { hub.library.settings.player.theatreLyrics.toggle(); preferLyrics = true } label: { Image(systemName: "text.quote").foregroundStyle(prefs.theatreLyrics ? accent : .white) }
                    .accessibilityLabel("Lyrics column").atlas("control.music.theatreLyricsColumn")
                Button { hub.library.settings.player.theatreQueue.toggle(); preferLyrics = false } label: { Image(systemName: "list.bullet").foregroundStyle(queueOn ? accent : .white) }
                    .accessibilityLabel("Queue column").atlas("control.music.theatreQueueColumn")
                Button { player.toggleMute() } label: { Image(systemName: player.volume == 0 ? "speaker.slash" : "speaker.wave.2") }.accessibilityLabel(player.volume == 0 ? "Unmute" : "Mute").atlas("control.music.theatreMusictheatreviewdockButton")
                PodcastScrubber(fraction: Double(player.volume), onChange: { player.volume = Float($0) }, live: true).frame(width: 90, height: 14).accessibilityLabel("Volume")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 48).padding(.bottom, 12).frame(height: height)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        .opacity(calm ? 0 : 1)
        .onHover { onDock = $0; if $0 { wake() } }
    }

    private func upNext(_ t: MusicTrack) -> some View {
        HStack(spacing: 10) {
            MusicArtwork(track: t, size: 44, corner: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text("Up next").font(Typography.micro).foregroundStyle(.white.opacity(0.6))
                Text(verbatim: t.title).font(Typography.captionMedium).lineLimit(1)
            }
        }
        .padding(10).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous)).frame(maxWidth: 260)
        .accessibilityElement(children: .combine).accessibilityLabel("Up next: \(t.title)")
    }

    // MARK: behaviour

    /// Any movement or key wakes the dock; it goes quiet again 3.5 seconds later, only while playing and not while the pointer is on the dock.
    private func wake() {
        if calm { calm = false }
        calmTask?.cancel()
        calmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(MusicTheatreLayout.calmDelay * 1_000_000_000))
            if !Task.isCancelled, player.isPlaying, !onDock { calm = true }
        }
    }

    private func flashIcon() {
        flash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(MusicTheatreLayout.flashDuration * 1_000_000_000))
            flash = false
        }
    }

    private func enterFullScreen() {
        #if os(macOS)
        guard let w = NSApp.keyWindow, !w.styleMask.contains(.fullScreen) else { return }
        w.toggleFullScreen(nil)
        enteredFullScreen = true
        #endif
    }

    /// Leaves full screen only when theatre mode entered it.
    private func leaveFullScreen() {
        #if os(macOS)
        guard enteredFullScreen, let w = NSApp.keyWindow, w.styleMask.contains(.fullScreen) else { return }
        w.toggleFullScreen(nil)
        #endif
    }
}

/// The "Up next" card in its own view: it alone reads the playback position (four times a second), so the rest of the Theatre is not
/// re-evaluated on every tick.
private struct MusicTheatreUpNextHost<Card: View>: View {
    let player: MusicPlayer
    let queueColumn: Bool
    let card: (MusicTrack) -> Card

    var body: some View {
        if MusicTheatreLayout.showsUpNext(position: player.position, duration: player.duration, queueColumn: queueColumn, repeatMode: player.repeatMode),
           let next = player.rows.dropFirst((player.index ?? -1) + 1).first ?? (player.repeatMode == .all ? player.rows.first : nil) {
            card(next.track).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.bottom, 140).padding(.trailing, 24)
        }
    }
}
