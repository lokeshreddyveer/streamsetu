import SwiftUI

/// Rules for the resume hint on a Continue tile: only a long listen (a podcast episode, a mix of twenty minutes or more) shows how far along it is.
enum MusicHomeContinueRules {
    static let longFormSeconds: Double = 20 * 60

    static func showsProgress(isPodcast: Bool?, durationSeconds: Double) -> Bool { isPodcast == true || durationSeconds >= longFormSeconds }

    static func fraction(position: Double, duration: Double) -> Double? {
        guard duration > 0, position >= 5 else { return nil }
        return min(max(position / duration, 0), 1)
    }
}

/// Continue listening: the song in the player first (tap to resume or pause), then the last few played, as a grid of compact tiles with artwork.
/// One column on a narrow window, two on a medium one, three from there. Tiles have one fixed height, so the grid never changes size under the cursor.
struct MusicHomeContinue: View {
    let items: [HomeItem]
    let hub: MusicHub
    @Environment(\.musicLayoutClass) private var layoutClass

    var body: some View {
        let spec = MusicHomeLayout.spec(for: layoutClass)
        let tracks = items.compactMap(\.track)
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSectionTitle(title: Localized.string("Continue listening"))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: MusicSpace.sm, alignment: .top), count: spec.continueColumns), alignment: .leading, spacing: MusicSpace.sm) {
                ForEach(items.prefix(MusicHomeLayout.continueLimit), id: \.id) { item in
                    if let t = item.track { MusicHomeContinueCard(track: t, queue: tracks, hub: hub) }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct MusicHomeContinueCard: View {
    let track: MusicTrack
    let queue: [MusicTrack]
    let hub: MusicHub
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var isCurrent: Bool { hub.player.current?.uid == track.uid }
    private var playing: Bool { isCurrent && hub.player.isPlaying }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MusicCorner.compactCard, style: .continuous)
        Button(action: activate) {
            HStack(spacing: MusicSpace.sm) {
                MusicArtwork(track: track, size: MusicHomeLayout.continueArtwork, corner: MusicCorner.control)
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(verbatim: track.title).musicText(.card).foregroundStyle(isCurrent ? accent : ColorTokens.textPrimary).lineLimit(1)
                    Text(verbatim: track.displayArtistLine).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                    if isCurrent, MusicHomeContinueRules.showsProgress(isPodcast: track.isPodcast, durationSeconds: Double(track.durationMs) / 1000) { MusicHomeContinueProgress(hub: hub) }
                }
                Spacer(minLength: 0)
                if isCurrent { Image(systemName: playing ? "pause.fill" : "play.fill").font(MusicTokens.iconMedium).foregroundStyle(accent).accessibilityHidden(true) }
            }
            .padding(MusicSpace.xs)
            .frame(maxWidth: .infinity, minHeight: MusicHomeLayout.continueHeight, maxHeight: MusicHomeLayout.continueHeight, alignment: .leading)
            .background(ColorTokens.card, in: shape)
            .musicElevation(.edge, cornerRadius: MusicCorner.compactCard)
            .musicHoverLift(hovering, cornerRadius: MusicCorner.compactCard)
            .overlay(shape.strokeBorder(accent, lineWidth: 2).opacity(focused ? 1 : 0).allowsHitTesting(false))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovering = $0 }
        .musicAnimation(.hover, reduce: reduceMotion, value: hovering)
        .contextMenu { MusicTrackMenuContent(track: track, hub: hub) }
        .accessibilityLabel(label)
        .accessibilityHint(isCurrent ? Localized.string("Resumes or pauses playback") : Localized.string("Plays this song"))
        .atlas("control.music.homeContinueCard")
    }

    private var label: String {
        let base = "\(track.title), \(track.artistLine)"
        guard isCurrent else { return base }
        return playing ? Localized.string("%@, playing now", base) : Localized.string("%@, paused", base)
    }

    private func activate() {
        MusicDebugLog.log("home", "continue tile tapped: \(track.title) current=\(isCurrent)")
        if isCurrent { hub.player.toggle(); return }
        if let i = queue.firstIndex(where: { $0.uid == track.uid }) { hub.play(queue, at: i) } else { hub.play([track], at: 0) }
    }
}

/// How far along a long listen is. Its own view, so the page does not redraw as the position moves.
private struct MusicHomeContinueProgress: View {
    let hub: MusicHub
    @Environment(\.reddyAccent) private var accent
    var body: some View {
        if let f = MusicHomeContinueRules.fraction(position: hub.player.position, duration: hub.player.duration) {
            Capsule().fill(ColorTokens.line).frame(height: MusicSpace.xxs)
                .overlay(alignment: .leading) { GeometryReader { g in Capsule().fill(accent).frame(width: g.size.width * f) } }
                .accessibilityElement()
                .accessibilityLabel(Localized.string("Progress"))
                .accessibilityValue(Localized.string("%@ percent", Int(f * 100).formatted()))
        }
    }
}
