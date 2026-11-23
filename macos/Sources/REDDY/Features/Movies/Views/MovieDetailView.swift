import SwiftUI

struct MovieDetailView: View {
    let movie: Movie
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var detail: Movie?
    @State private var person: PersonRoute?
    @State private var model = TitlePageModel()
    @State private var hub = TitleHubModel()
    @State private var art: HeroArtwork

    init(movie: Movie) {
        self.movie = movie
        _art = State(initialValue: HeroArtwork.preloaded(backdrop: movie.backdropURL, poster: movie.posterURL))     // a title seen before has its picture in the first frame
    }

    private var m: Movie { detail ?? movie }
    private var item: LibraryItem { .movie(m) }

    var body: some View {
        MacTitlePage(
            item: item, model: model, hub: hub, art: art, ownOverview: m.overview,
            play: TitlePageLogic.playLabel(resume: TitlePageLogic.resume(model.progress)),
            onPlay: { container?.playback.play(movie: m); router.closeDetail() },
            onClose: { router.closeDetail() },
            onOpenVersion: { PlayActions.open($0, router: router) },
            onOpenFolder: m.categoryID.map { id in { router.movie = nil; router.openFolder(.movies, categoryID: id) } },
            person: $person,
            actions: { actionButtons },
            more: { moreMenu },
            middle: { EmptyView() },
            tail: { FranchiseTimeline(currentID: m.id, movie: m) { PlayActions.open($0, router: router) } }
        )
        .onAppear { model.update(item); model.reloadProgress(container) }          // one indexed row: cheap enough to be in the first frame, so Resume never flashes in late
        .task(id: movie.id) { await model.load(.movie(movie), container: container) }
        .task(id: movie.id) { await refreshDetail() }
        .task(id: movie.id) { if let c = container { hub.open(itemID: movie.id, isSeries: false, container: c) } }
        .onDisappear { hub.close() }
        .onChange(of: detail) { _, _ in model.update(item) }
        .onMetadataLanded(for: movie.id) { Task { await refreshDetail() } }
    }

    @ViewBuilder private var actionButtons: some View {
        let fav = state.isFavorite(m.id), later = state.isWatchLater(m.id)
        HeroCircleButton(symbol: fav ? "heart.fill" : "heart", help: fav ? "Remove from Favourites" : "Add to Favourites", active: fav) { state.toggleFavorite(m.id, kind: .movie) }
            .accessibilityValue(fav ? "On" : "Off")
        HeroCircleButton(symbol: later ? "bookmark.fill" : "bookmark", help: later ? "Remove from Watch Later" : "Add to Watch Later", active: later) { state.toggleWatchLater(m.id, kind: .movie) }
            .accessibilityValue(later ? "On" : "Off")
        DownloadButton(itemID: m.id, compact: true) { $0.enqueue(movie: m) }.buttonStyle(HeroCircleStyle()).menuStyle(.button).menuIndicator(.hidden).fixedSize().help("Download")
        if let link = DeepLink.link(movie: m.title) {
            ShareLink(item: link, subject: Text(m.title), message: Text("Open “\(m.title)” in StreamSetu")) { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(HeroCircleStyle()).help("Share").accessibilityLabel("Share")
        }
    }

    @ViewBuilder private var moreMenu: some View {
        if TitlePageLogic.resume(model.progress) != nil { Button("Start Over", systemImage: "gobackward") { container?.playback.play(movie: m, resume: false); router.closeDetail() } }
        Button("Watch Privately", systemImage: "eye.slash") { container?.playback.play(movie: m, privately: true); router.closeDetail() }
        if model.progress != nil { Button("Mark as Watched", systemImage: "checkmark.circle") { try? container?.historyRepo.markWatched(itemID: m.id, kind: .movie, seriesID: nil, duration: m.durationSeconds ?? 1); model.reloadProgress(container) } }
        CollectionMenu(itemID: m.id, kind: .movie)
    }

    private func refreshDetail() async {
        guard let c = container, let d = try? await c.details.movie(id: movie.id) else { return }
        if d != detail { detail = d }
    }
}
