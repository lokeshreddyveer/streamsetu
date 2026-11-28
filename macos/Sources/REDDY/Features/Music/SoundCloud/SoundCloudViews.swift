import SwiftUI

/// The shape of a SoundCloud track's loudness, drawn behind the player bar's progress line. It draws nothing until the samples arrive, and
/// nothing at all for songs from other sources, so the normal bar is what the person sees whenever there is no waveform. It never takes a click.
struct SoundCloudWaveformBackdrop: View {
    let track: MusicTrack?
    let fraction: Double
    @State private var samples: [Float] = []
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        let played = accent.opacity(0.5), unplayed = ColorTokens.textPrimary.opacity(0.14), share = min(max(fraction, 0), 1)
        // A task on an empty view never runs, so something always exists here to hold it until there is something to show.
        return ZStack {
            Color.clear
            if !samples.isEmpty {
                Canvas { context, size in
                    let barWidth: CGFloat = 2, gap: CGFloat = 1.5
                    let count = max(1, Int(size.width / (barWidth + gap)))
                    let bars = SoundCloudWaveform.bars(samples, count: count)
                    let playedCount = Int((Double(bars.count) * share).rounded())
                    for (i, v) in bars.enumerated() {
                        let h = max(2, CGFloat(v) * size.height * 0.9)
                        let rect = CGRect(x: CGFloat(i) * (barWidth + gap), y: (size.height - h) / 2, width: barWidth, height: h)
                        let color = i < playedCount ? played : unplayed
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                    }
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .task(id: track?.uid) { await load() }
    }

    private func load() async {
        samples = []
        guard SoundCloudWaveform.isEligible(track), let id = track?.id else { return }
        let found = await SoundCloudExtras.shared.waveform(trackID: id)
        if !Task.isCancelled { samples = found ?? [] }
    }
}

/// The tracklist of a long SoundCloud mix or DJ set, read from its description or the uploader's timed comments. Choosing a line jumps there.
/// Nothing shows for short tracks, for songs from other sources, or when fewer than three chapters could be read.
struct SoundCloudChaptersSection: View {
    let hub: MusicHub
    @State private var chapters: [SoundCloudChapter] = []
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        let current = SoundCloudChapters.index(at: hub.player.position, in: chapters)
        // A task on an empty view never runs, so something always exists here to hold it until there is something to show.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if !chapters.isEmpty {
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text("Chapters").font(Typography.heading).foregroundStyle(ColorTokens.textPrimary)
                        .padding(.bottom, MusicSpace.xxs).accessibilityAddTraits(.isHeader)
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { i, c in
                        Button { hub.player.seek(to: c.startSeconds) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: MusicSpace.sm) {
                                Text(verbatim: MusicTime.clock(c.startSeconds)).font(Typography.timestamp).monospacedDigit()
                                    .foregroundStyle(i == current ? accent : ColorTokens.textTertiary).frame(width: 52, alignment: .trailing)
                                Text(verbatim: c.title).font(i == current ? Typography.bodyMedium : Typography.body)
                                    .foregroundStyle(i == current ? ColorTokens.textPrimary : ColorTokens.textSecondary).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).hoverHighlight()
                        .accessibilityLabel(Text(verbatim: "\(c.title), \(MusicTime.clock(c.startSeconds))"))
                        .accessibilityAddTraits(i == current ? .isSelected : [])
                        .atlas("control.music.soundcloudChapter")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, MusicSpace.md)
            }
        }
        .task(id: hub.player.current?.uid) { await load() }
    }

    private func load() async {
        chapters = []
        guard let t = hub.player.current, SoundCloudWaveform.isEligible(t), Double(t.durationMs) / 1000 >= SoundCloudChapters.longTrackSeconds else { return }
        let found = await SoundCloudExtras.shared.chapters(trackID: t.id)
        if !Task.isCancelled { chapters = Array(found.prefix(150)) }
    }
}

/// "More on SoundCloud" on an artist's page: the artist's own uploads, only when one SoundCloud profile is confidently that artist.
struct SoundCloudMoreShelf: View {
    let hub: MusicHub
    let name: String
    @State private var tracks: [MusicTrack] = []

    var body: some View {
        // A task on an empty view never runs, so something always exists here to hold it until there is something to show.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if tracks.count >= 3 {
                MusicShelf(title: Localized.string("More from %@", name)) {
                    ForEach(tracks) { t in MusicCard(track: t, queue: tracks, hub: hub) }
                }
                .atlas("control.music.soundcloudMoreShelf")
            }
        }
        .task(id: name) { await load() }
    }

    private func load() async {
        tracks = []
        guard hub.registry.isEnabled(SoundCloudProvider.providerID),
              let p = hub.registry.provider(id: SoundCloudProvider.providerID) as? SoundCloudProvider else { return }
        let found = await p.moreFromArtist(named: name)
        if !Task.isCancelled { tracks = found }
    }
}
