import SwiftUI

struct MovieDetailView: View {
    let movie: Movie
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @Environment(\.reddyAccent) private var accent
    @State private var detail: Movie?
    @State private var progress: WatchProgress?
    @State private var loading = true

    private var m: Movie { detail ?? movie }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    ZStack(alignment: .bottomLeading) {
                        ArtworkImage(url: m.backdropURL ?? m.posterURL, kind: .backdrop, symbol: "film").frame(height: 300).frame(maxWidth: .infinity).clipped()
                        LinearGradient(colors: [.clear, ColorTokens.background], startPoint: .top, endPoint: .bottom)
                    }
                    IconButton(symbol: "xmark", help: "Close") { router.closeDetail() }.padding(Spacing.lg)
                }
                HStack(alignment: .top, spacing: Spacing.xl) {
                    ArtworkImage(url: m.posterURL, kind: .poster, symbol: "film").frame(width: 150, height: 225)
                        .clipShape(RoundedRectangle(cornerRadius: LayoutTokens.radius, style: .continuous)).shadow(radius: 12).offset(y: -60)
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        Text(m.title).font(Typography.display).lineLimit(3)
                        metaLine
                        QualityBadgeRow(texts: [m.title, m.categoryName])
                        FolderPathButton(name: m.categoryName) { if let id = m.categoryID { router.movie = nil; router.openFolder(.movies, categoryID: id) } }
                        if let o = m.overview { Text(o).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true) }
                        else if loading { SkeletonBlock(height: 14); SkeletonBlock(width: 280, height: 14) }
                        actions
                        TrailerSection(itemID: m.id, title: m.title, year: m.releaseYear, isSeries: false)
                        if let p = progress, !p.completed, p.positionSeconds > 30 {
                            HStack { ProgressBar(fraction: p.fraction).frame(width: 220); Text("\(DurationFormatter.short(p.durationSeconds - p.positionSeconds)) left").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                        }
                        Text("Audio and subtitle tracks appear in the player once the movie starts.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                    }.padding(.top, Spacing.lg)
                }
                .padding(.horizontal, Spacing.section).padding(.bottom, Spacing.md)
                FranchiseTimeline(currentID: m.id, movie: m) { PlayActions.open($0, router: router) }.padding(.horizontal, Spacing.section).padding(.bottom, Spacing.md)
                SimilarSection(item: .movie(m)).padding(.horizontal, Spacing.section).padding(.bottom, Spacing.section)
            }
        }
        .frame(width: 860, height: 640).background(ColorTokens.background)
        .task { await load() }
    }

    private var metaLine: some View {
        let year = m.releaseYear.flatMap { m.title.contains(String($0)) ? nil : String($0) }      // not twice: "Only Me (2026) · 2026"
        let duration = m.durationSeconds.flatMap { $0 > 0 ? DurationFormatter.short($0) : nil }
        return HStack(spacing: 8) {
            Text([year, duration, m.genre ?? m.categoryName].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
            if let r = m.rating, let v = Double(r), v > 0 { Label(String(format: "%.1f", v), systemImage: "star.fill").foregroundStyle(ColorTokens.warning) }
        }.font(Typography.bodyMedium).foregroundStyle(ColorTokens.textSecondary)
    }

    private var actions: some View {
        HStack {
            if let p = progress, !p.completed, p.positionSeconds > 30 {
                PrimaryButton(title: "Resume \(DurationFormatter.clock(p.positionSeconds))", symbol: "play.fill") { container?.playback.play(movie: m); router.closeDetail() }
                SecondaryButton(title: "Start Over", symbol: "gobackward") { container?.playback.play(movie: m, resume: false); router.closeDetail() }
            } else {
                PrimaryButton(title: "Play", symbol: "play.fill") { container?.playback.play(movie: m); router.closeDetail() }
            }
            FavoriteButton(isFavorite: state.isFavorite(m.id)) { state.toggleFavorite(m.id, kind: .movie) }
            WatchLaterButton(isSaved: state.isWatchLater(m.id)) { state.toggleWatchLater(m.id, kind: .movie) }
            Menu { CollectionMenu(itemID: m.id, kind: .movie) } label: { Label("My List", systemImage: "plus") }.menuStyle(.button).buttonStyle(SecondaryButtonStyle()).fixedSize()
            DownloadButton(itemID: m.id) { $0.enqueue(movie: m) }.menuStyle(.button).buttonStyle(SecondaryButtonStyle()).fixedSize()
            if progress != nil {
                IconButton(symbol: "checkmark.circle", help: "Mark as watched") { try? container?.historyRepo.markWatched(itemID: m.id, kind: .movie, seriesID: nil, duration: m.durationSeconds ?? 1); reloadProgress() }
            }
        }
    }

    private func load() async {
        guard let c = container else { return }
        reloadProgress()
        detail = try? await c.details.movie(id: movie.id)
        loading = false
    }

    private func reloadProgress() { progress = try? container?.historyRepo.progress(for: movie.id) }
}
