import SwiftUI

struct SeriesDetailView: View {
    let series: Series
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var vm = SeriesDetailViewModel()

    private var s: Series { vm.detail?.series ?? series }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                ZStack(alignment: .topTrailing) {
                    ZStack(alignment: .bottomLeading) {
                        ArtworkImage(url: s.backdropURL ?? s.posterURL, kind: .backdrop, symbol: "rectangle.stack").frame(height: 260).frame(maxWidth: .infinity).clipped()
                        LinearGradient(colors: [.clear, ColorTokens.background], startPoint: .top, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(s.title).font(Typography.display).lineLimit(2)
                            Text([s.releaseYear.flatMap { s.title.contains(String($0)) ? nil : String($0) }, s.genre ?? s.categoryName, vm.detail.map { "\($0.seasons.count) season\($0.seasons.count == 1 ? "" : "s")" }].compactMap { $0 }.joined(separator: " · "))
                                .font(Typography.bodyMedium).foregroundStyle(ColorTokens.textSecondary)
                        }.padding(Spacing.section)
                    }
                    IconButton(symbol: "xmark", help: "Close") { router.closeDetail() }.padding(Spacing.lg)
                }
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    if let o = s.overview { Text(o).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true) }
                    HStack {
                        if let t = vm.resumeTarget, let c = container {
                            let p = vm.progress[t.id]
                            PrimaryButton(title: playTitle(t, p), symbol: "play.fill") { c.playback.play(episode: t, series: s); router.closeDetail() }
                        }
                        FavoriteButton(isFavorite: state.isFavorite(s.id)) { state.toggleFavorite(s.id, kind: .series) }
            WatchLaterButton(isSaved: state.isWatchLater(s.id)) { state.toggleWatchLater(s.id, kind: .series) }
                        Menu { CollectionMenu(itemID: s.id, kind: .series) } label: { Label("My List", systemImage: "plus") }.menuStyle(.button).buttonStyle(SecondaryButtonStyle()).fixedSize()
                        Spacer()
                        if let d = vm.detail, d.seasons.count > 0 {
                            Menu {
                                ForEach(d.seasons) { se in Button { vm.selectedSeason = se.number } label: { Label(se.name ?? "Season \(se.number)", systemImage: se.number == vm.selectedSeason ? "checkmark" : "") } }
                            } label: { Label("Season \(vm.selectedSeason)", systemImage: "list.number") }.menuStyle(.button).buttonStyle(SecondaryButtonStyle()).fixedSize()
                        }
                    }
                    TrailerSection(itemID: s.id, title: s.title, year: s.releaseYear, isSeries: true)
                    if vm.loading && vm.detail == nil { ForEach(0..<5, id: \.self) { _ in SkeletonBlock(height: 72, radius: 10) } }
                    else if let e = vm.error, vm.detail == nil { EmptyStateView(symbol: "exclamationmark.triangle", title: "Couldn't load episodes", message: e, actionTitle: "Try Again") { Task { if let c = container { await vm.load(series, c) } } }.frame(height: 220) }
                    else if vm.episodesInSeason.isEmpty { Text("No episodes available.").foregroundStyle(ColorTokens.textSecondary) }
                    else {
                        LazyVStack(spacing: Spacing.sm) {
                            ForEach(vm.episodesInSeason) { ep in
                                EpisodeRow(episode: ep, progress: vm.progress[ep.id], onPlay: { container?.playback.play(episode: ep, series: s); router.closeDetail() },
                                           onToggleWatched: { watched in if let c = container { vm.markWatched(ep, s, c, watched: watched) } })
                            }
                        }
                    }
                    SimilarSection(item: .series(s))
                }.padding(.horizontal, Spacing.section).padding(.bottom, Spacing.section)
            }
        }
        .frame(width: 880, height: 680).background(ColorTokens.background)
        .task { if let c = container { await vm.load(series, c) } }
    }

    private func playTitle(_ e: Episode, _ p: WatchProgress?) -> String {
        if let p, !p.completed, p.positionSeconds > 30 { return "Resume S\(e.seasonNumber) E\(e.episodeNumber)" }
        return vm.progress.isEmpty ? "Play S\(e.seasonNumber) E\(e.episodeNumber)" : "Play Next · S\(e.seasonNumber) E\(e.episodeNumber)"
    }
}

struct EpisodeRow: View {
    let episode: Episode
    let progress: WatchProgress?
    var onPlay: () -> Void
    var onToggleWatched: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Spacing.lg) {
            ZStack {
                ArtworkImage(url: episode.imageURL, kind: .still, symbol: "play.rectangle").frame(width: 150, height: 84)
                Image(systemName: "play.fill").foregroundStyle(.white).opacity(hovering ? 1 : 0)
            }.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(episode.episodeNumber). \(episode.title)").font(Typography.bodyMedium).lineLimit(1)
                    Spacer()
                    if let d = episode.durationSeconds, d > 0 { Text(DurationFormatter.short(d)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                    if progress?.completed == true { Label("Watched", systemImage: "checkmark.circle.fill").font(Typography.caption).foregroundStyle(ColorTokens.success).labelStyle(.iconOnly) }
                }
                if let o = episode.overview { Text(o).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(2) }
                if let p = progress, !p.completed, p.positionSeconds > 5 { ProgressBar(fraction: p.fraction).frame(maxWidth: 220) }
            }
        }
        .padding(Spacing.md).background(hovering ? ColorTokens.card : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle()).onHover { hovering = $0 }.onTapGesture(perform: onPlay)
        .contextMenu {
            Button("Play", action: onPlay)
            if progress?.completed == true { Button("Mark as Unwatched") { onToggleWatched(false) } } else { Button("Mark as Watched") { onToggleWatched(true) } }
            if progress != nil { Button("Reset Progress") { onToggleWatched(false) } }
        }
    }
}
