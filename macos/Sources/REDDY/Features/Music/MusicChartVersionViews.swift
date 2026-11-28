import SwiftUI

// One row per song in a chart: when the chart listed the same song under several video ids (audio, lyric video, official video), the row shows a
// small "N versions" chip. The chip and the row menu's "Choose version" list the copies so the person can pick one; the pick plays at once.

/// One copy of a chart song as the picker lists it.
struct MusicChartVersionChoice: Identifiable, Equatable {
    let track: MusicTrack
    var id: String { track.uid }
    init(_ track: MusicTrack) { self.track = track }

    /// "Audio", "Lyric video", "Video", "Album track".
    var kind: String { MusicSongIdentity.versionLabel(MusicSongIdentity.classify(track)) }
    /// The upload's own title cleaned for display; the raw title is the tooltip.
    var title: String { MusicDisplayTitle.display(for: track)?.title ?? track.title }
}

/// The buttons of the picker, shared by the chip and the row's context menu.
struct MusicChartVersionButtons: View {
    let hooks: MusicChartRowHooks
    var body: some View {
        ForEach(hooks.versions) { v in
            Button {
                hooks.choose?(v.track)
            } label: {
                Text(verbatim: v.kind + " · " + v.title)
            }
            .help(v.track.title)
            .accessibilityLabel(Localized.string("%1$@: %2$@", v.kind, v.track.title))
            .atlas("control.music.chartChooseVersion")
        }
    }
}

/// "3 versions": a quiet chip next to the title; clicking it opens the picker.
struct MusicChartVersionChip: View {
    let hooks: MusicChartRowHooks
    var body: some View {
        let n = hooks.versions.count
        Menu { MusicChartVersionButtons(hooks: hooks) } label: {
            Text(verbatim: Localized.plural(n, one: "%@ version", other: "%@ versions"))
                .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(ColorTokens.elevated, in: Capsule())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(Localized.plural(n, one: "%@ version of this song, choose one", other: "%@ versions of this song, choose one"))
        .musicTooltip(verbatim: Localized.string("Choose version"))
        .atlas("control.music.chartVersionChip")
    }
}

