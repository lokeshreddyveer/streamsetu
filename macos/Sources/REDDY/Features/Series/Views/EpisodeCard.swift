import SwiftUI

/// One episode in the rail: its still, number and title, a line of the story, length, and how far you are. Play on click; the context menu keeps the rest.
struct EpisodeCard: View {
    static let width: CGFloat = 244
    static let stillHeight: CGFloat = 137
    let episode: Episode
    let series: Series
    let progress: WatchProgress?
    var isNext = false
    let onPlay: () -> Void
    let onToggleWatched: (Bool) -> Void
    let onPlayPrivately: () -> Void
    @Environment(\.reddyAccent) private var accent
    @State private var hover = false

    private var resume: TitlePageLogic.Resume? { TitlePageLogic.resume(progress) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onPlay) { still }.buttonStyle(.plain)
            Text("\(episode.episodeNumber). \(episode.title)").font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            Text(episode.overview ?? " ").font(.system(size: 12)).foregroundStyle(ColorTokens.textSecondary).lineLimit(2).frame(height: 32, alignment: .top)
            HStack(spacing: 6) {
                if let d = episode.durationSeconds, d > 0 { Text(DurationFormatter.short(d)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(ColorTokens.textTertiary) }
                if let r = resume { Text("· " + TitlePageLogic.remainingText(r.remaining)).font(.system(size: 11.5)).foregroundStyle(ColorTokens.textTertiary) }
                Spacer(minLength: 0)
                DownloadButton(itemID: episode.id, compact: true) { $0.enqueue(episode: episode, series: series) }
                    .buttonStyle(.plain).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(ColorTokens.textSecondary)
            }.frame(height: 18)
        }
        .frame(width: Self.width, alignment: .leading)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Play", action: onPlay)
            Button("Watch Privately", systemImage: "eye.slash", action: onPlayPrivately)
            if progress?.completed == true { Button("Mark as Unwatched") { onToggleWatched(false) } } else { Button("Mark as Watched") { onToggleWatched(true) } }
            if progress != nil { Button("Reset Progress") { onToggleWatched(false) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken).atlas("context.series.episode")
    }

    private var still: some View {
        ZStack(alignment: .bottom) {
            ArtworkImage(url: episode.imageURL, kind: .still, contentMode: .fill, symbol: "play.rectangle", tile: ArtworkTile.Content(title: episode.title, detail: "Episode \(episode.episodeNumber)", showsTitle: false))
            Circle().fill(.ultraThinMaterial).frame(width: 44, height: 44).overlay(Image(systemName: "play.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(.white))
                .opacity(hover ? 1 : 0).frame(maxWidth: .infinity, maxHeight: .infinity)
            if let r = resume { ProgressBar(fraction: r.fraction, height: 3).padding(.horizontal, 8).padding(.bottom, 8) }
        }
        .frame(width: Self.width, height: Self.stillHeight)
        .overlay(alignment: .topLeading) {
            if isNext { Text("UP NEXT").font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(accent)).padding(8) }
        }
        .overlay(alignment: .topTrailing) {
            if progress?.completed == true { Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, ColorTokens.success).shadow(radius: 3).padding(8) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hover ? accent : Color.white.opacity(0.08), lineWidth: hover ? 2 : 1))
        .animation(.easeOut(duration: 0.14), value: hover)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var spoken: String {
        var parts = ["Episode \(episode.episodeNumber), \(episode.title)"]
        if let d = episode.durationSeconds, d > 0 { parts.append(TitlePageLogic.spokenDuration(d)) }
        if progress?.completed == true { parts.append("watched") } else if let r = resume { parts.append("\(Int(r.fraction * 100)) percent watched") }
        if isNext { parts.append("up next") }
        return parts.joined(separator: ", ")
    }
}

/// Same size as an episode card, still while the episodes are found.
struct EpisodeCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBlock(width: EpisodeCard.width, height: EpisodeCard.stillHeight, radius: 12)
            SkeletonBlock(width: 150, height: 14)
            SkeletonBlock(width: EpisodeCard.width, height: 12); SkeletonBlock(width: 180, height: 12)
        }.accessibilityHidden(true)
    }
}
