import SwiftUI

struct BottomPlayerState {
    var title: String
    var meta: String
    var status: String
    var artworkURL: String?
    var isLive: Bool
    var isPlaying: Bool
    var isBusy: Bool
    var failed: Bool
    var position: TimeInterval
    /// nil for live streams and anything that cannot be sought, so no fabricated duration or seek bar is shown.
    var duration: TimeInterval?
    var volume: Double
    var muted: Bool
    var canSeek: Bool { !isLive && (duration ?? 0) > 0 }
}

enum BottomPlayerLayout {
    /// Movies and series get a taller bar with a live video thumbnail and a full scrubber; live keeps the slim bar.
    static func height(isLive: Bool) -> CGFloat { isLive ? LayoutTokens.playerBarHeight : 96 }
}

/// The persistent bottom bar. It describes the *playing* item and nothing the user is merely browsing.
struct ReddyBottomPlayer: View {
    let state: BottomPlayerState
    var onTitle: () -> Void
    var onTogglePlay: () -> Void
    var onToggleMute: () -> Void
    var onVolume: (Double) -> Void
    var onSeek: (TimeInterval) -> Void
    var onExpand: () -> Void
    var onStop: () -> Void
    /// When set, movies and series show their real video in the thumbnail (it is the one video surface).
    var videoPlayback: PlaybackCoordinator?
    var onSkip: (TimeInterval) -> Void = { _ in }
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        if state.isLive { liveBar } else { vodBar }
    }

    // MARK: movies & series

    private var vodBar: some View {
        HStack(spacing: 16) {
            Button(action: onExpand) {
                ZStack {
                    if let videoPlayback { VideoSurface(playback: videoPlayback, owner: .bar) } else { PosterArt(title: state.title, url: state.artworkURL, kind: .backdrop) }
                    if state.isBusy { ProgressView().controlSize(.small) }
                }
                .frame(width: 136, height: 76).background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9, weight: .bold)).padding(5)
                        .background(.black.opacity(0.6), in: Circle()).padding(5).foregroundStyle(.white.opacity(0.9))
                }
            }
            .buttonStyle(.plain).accessibilityLabel("Play \(state.title) full screen")

            VStack(alignment: .leading, spacing: 6) {
                Button(action: onTitle) { Text(state.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).accessibilityLabel("Details for \(state.title)")
                Text(state.meta.isEmpty ? state.status : "\(state.meta) · \(state.status)").font(.system(size: 10)).lineLimit(1)
                    .foregroundStyle(state.failed ? ColorTokens.warning : ColorTokens.textSecondary)
                HStack(spacing: 8) {
                    Text(DurationFormatter.clock(state.position)).font(Typography.timestamp).foregroundStyle(ColorTokens.textSecondary).frame(width: 46, alignment: .trailing)
                    if state.canSeek { SeekLine(position: state.position, duration: state.duration ?? 1, onSeek: onSeek) }
                    else { Capsule().fill(Color.white.opacity(0.12)).frame(height: 3) }
                    Text(state.duration.map(DurationFormatter.clock) ?? "--:--").font(Typography.timestamp).foregroundStyle(ColorTokens.textSecondary).frame(width: 46, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                dockButton("gobackward.10", "Back 10 seconds") { onSkip(-10) }
                dockButton(state.isPlaying ? "pause.fill" : "play.fill", state.isPlaying ? "Pause" : "Play", action: onTogglePlay, large: true)
                dockButton("goforward.10", "Forward 10 seconds") { onSkip(10) }
                dockButton(state.muted || state.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", state.muted ? "Unmute" : "Mute", action: onToggleMute)
                Slider(value: Binding(get: { state.muted ? 0 : state.volume }, set: onVolume), in: 0...1).controlSize(.mini).frame(width: 60).tint(accent).accessibilityLabel("Volume")
                dockButton("arrow.up.left.and.arrow.down.right", "Full screen", action: onExpand)
                dockButton("xmark", "Stop and close player", action: onStop)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .frame(height: BottomPlayerLayout.height(isLive: false))
        .background(barBackground)
        .accessibilityElement(children: .contain).accessibilityLabel("Now playing")
    }

    // MARK: live

    private var liveBar: some View {
        HStack(spacing: 13) {
            Button(action: onExpand) {
                ZStack {
                    PosterArt(title: state.title, url: state.artworkURL, kind: .backdrop)
                    if state.isBusy { ProgressView().controlSize(.small) }
                    else if !state.isLive { Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)) }
                }
                .frame(width: 76, height: 46).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain).accessibilityLabel("Expand player")

            VStack(alignment: .leading, spacing: 4) {
                Button(action: onTitle) { Text(state.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).accessibilityLabel("Details for \(state.title)")
                HStack(spacing: 6) {
                    if state.isLive { LiveBadge() }
                    Text(state.meta.isEmpty ? state.status : "\(state.meta) · \(state.status)").font(.system(size: 10)).lineLimit(1)
                        .foregroundStyle(state.failed ? ColorTokens.warning : ColorTokens.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                if let d = state.duration, !state.isLive {
                    Text("\(DurationFormatter.clock(state.position)) / \(DurationFormatter.clock(d))").font(Typography.timestamp).foregroundStyle(ColorTokens.textSecondary).padding(.trailing, 2)
                }
                dockButton(state.isPlaying ? "pause.fill" : "play.fill", state.isPlaying ? "Pause" : "Play", action: onTogglePlay)
                dockButton(state.muted || state.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", state.muted ? "Unmute" : "Mute", action: onToggleMute)
                Slider(value: Binding(get: { state.muted ? 0 : state.volume }, set: onVolume), in: 0...1).controlSize(.mini).frame(width: 65).tint(accent).accessibilityLabel("Volume")
                dockButton("arrow.up.left.and.arrow.down.right", "Expand player", action: onExpand)
                dockButton("xmark", "Stop and close player", action: onStop)
            }
        }
        .padding(.horizontal, 20).padding(.top, 13).padding(.bottom, 11)
        .frame(height: LayoutTokens.playerBarHeight)
        .background(barBackground)
        .overlay(alignment: .top) { if state.canSeek { SeekLine(position: state.position, duration: state.duration ?? 1, onSeek: onSeek).offset(y: -4) } }
        .accessibilityElement(children: .contain).accessibilityLabel("Now playing")
    }

    private var barBackground: some View {
        ZStack {
            if ColorTokens.nativeGlass { NativeGlass(shape: Rectangle(), tint: ColorTokens.barFill.opacity(0.2)) }
            else { Rectangle().fill(.ultraThinMaterial); Rectangle().fill(ColorTokens.barFill.opacity(ColorTokens.glassy ? 0.58 : 0.90)) }
            GlossSheen(streak: false)
        }
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.13)).frame(height: 1) }
    }

    private func dockButton(_ symbol: String, _ label: String, action: @escaping () -> Void, large: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: large ? 14 : 12, weight: .semibold)).frame(width: large ? 36 : 30, height: large ? 36 : 30)
                .background(Color.white.opacity(0.06), in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}

/// Seek line along the top edge of the bar.
struct SeekLine: View {
    let position: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    @State private var dragging: Double?
    @State private var hovering = false
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        GeometryReader { g in
            let f = dragging ?? min(1, max(0, position / max(1, duration)))
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.14)).frame(height: hovering ? 4 : 3)
                Rectangle().fill(accent).frame(width: g.size.width * f, height: hovering ? 4 : 3)
                Circle().fill(.white).frame(width: 11, height: 11).offset(x: max(0, g.size.width * f - 5.5)).opacity(hovering || dragging != nil ? 1 : 0)
            }
            .frame(maxHeight: .infinity).contentShape(Rectangle()).onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragging = min(1, max(0, $0.location.x / max(1, g.size.width))) }
                .onEnded { v in let t = min(1, max(0, v.location.x / max(1, g.size.width))) * duration; dragging = nil; onSeek(t) })
        }
        .frame(height: 10)
        .accessibilityElement().accessibilityLabel("Playback position")
        .accessibilityValue("\(DurationFormatter.clock(position)) of \(DurationFormatter.clock(duration))")
        .accessibilityAdjustableAction { dir in
            switch dir { case .increment: onSeek(min(duration, position + 10)); case .decrement: onSeek(max(0, position - 10)); @unknown default: break }
        }
    }
}
