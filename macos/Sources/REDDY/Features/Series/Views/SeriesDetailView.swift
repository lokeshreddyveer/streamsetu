import SwiftUI

struct SeriesDetailView: View {
    let series: Series
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var vm = SeriesDetailViewModel()
    @State private var person: PersonRoute?
    @State private var model = TitlePageModel()
    @State private var hub = TitleHubModel()
    @State private var art: HeroArtwork
    @State private var focusedResume = false

    init(series: Series) {
        self.series = series
        _art = State(initialValue: HeroArtwork.preloaded(backdrop: series.backdropURL, poster: series.posterURL))
    }

    private var s: Series { vm.detail?.series ?? series }
    private var item: LibraryItem { .series(s) }

    private var playLabel: TitlePageLogic.PlayLabel {
        guard let t = vm.resumeTarget else { return TitlePageLogic.playLabel(resume: nil) }
        return TitlePageLogic.playLabel(episode: (t.seasonNumber, t.episodeNumber), resume: TitlePageLogic.resume(vm.progress[t.id]), startedSeries: !vm.progress.isEmpty)
    }

    var body: some View {
        MacTitlePage(
            item: item, model: model, hub: hub, art: art, ownOverview: s.overview,
            play: playLabel, playEnabled: vm.resumeTarget != nil,
            onPlay: { if let t = vm.resumeTarget, let c = container { c.playback.play(episode: t, series: s); router.closeDetail() } },
            onClose: { router.closeDetail() },
            onOpenVersion: { PlayActions.open($0, router: router) },
            onOpenFolder: s.categoryID.map { id in { router.series = nil; router.openFolder(.series, categoryID: id) } },
            person: $person,
            actions: { actionButtons },
            more: { CollectionMenu(itemID: s.id, kind: .series) },
            middle: { episodesSection },
            tail: { EmptyView() }
        )
        .onAppear { model.update(item, seasons: vm.detail?.seasons.count) }
        .task(id: series.id) { await model.load(.series(series), container: container) }
        .task(id: series.id) { if let c = container { await vm.load(series, c) } }
        .task(id: series.id) { if let c = container { hub.open(itemID: series.id, isSeries: true, container: c) } }
        .onDisappear { hub.close() }
        .onChange(of: vm.detail?.series) { _, _ in model.update(item, seasons: vm.detail?.seasons.count) }
        .onChange(of: vm.detail?.seasons.count) { _, n in model.update(item, seasons: n) }
        .onMetadataLanded(for: series.id) { if let c = container { Task { await vm.load(series, c) } } }          // a backdrop or summary filled in after the page opened
    }

    @ViewBuilder private var actionButtons: some View {
        let fav = state.isFavorite(s.id), later = state.isWatchLater(s.id)
        HeroCircleButton(symbol: fav ? "heart.fill" : "heart", help: fav ? "Remove from Favourites" : "Add to Favourites", active: fav) { state.toggleFavorite(s.id, kind: .series) }
            .accessibilityValue(fav ? "On" : "Off")
        HeroCircleButton(symbol: later ? "bookmark.fill" : "bookmark", help: later ? "Remove from Watch Later" : "Add to Watch Later", active: later) { state.toggleWatchLater(s.id, kind: .series) }
            .accessibilityValue(later ? "On" : "Off")
        if let link = DeepLink.link(series: s.title) {
            ShareLink(item: link, subject: Text(s.title), message: Text("Open “\(s.title)” in StreamSetu")) { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(HeroCircleStyle()).help("Share").accessibilityLabel("Share")
        }
    }

    // MARK: episodes

    @ViewBuilder private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TitleSectionHeader(title: "Episodes", count: vm.episodesInSeason.isEmpty ? nil : "\(vm.episodesInSeason.count)")
            seasonPicker
            if vm.loading && vm.detail == nil {
                FadingHScroll { HStack(alignment: .top, spacing: 14) { ForEach(0..<4, id: \.self) { _ in EpisodeCardSkeleton() } }.padding(.vertical, 4) }
            } else if let e = vm.error, vm.detail == nil {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "Couldn't load episodes", message: e, actionTitle: "Try Again") { Task { if let c = container { await vm.load(series, c) } } }.frame(height: 200)
            } else if vm.episodesInSeason.isEmpty {
                Text("No episodes available.").foregroundStyle(ColorTokens.textSecondary)
            } else {
                ScrollViewReader { proxy in
                    FadingHScroll {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(vm.episodesInSeason) { ep in
                                EpisodeCard(episode: ep, series: s, progress: vm.progress[ep.id], isNext: vm.resumeTarget?.id == ep.id,
                                            onPlay: { container?.playback.play(episode: ep, series: s); router.closeDetail() },
                                            onToggleWatched: { watched in if let c = container { vm.markWatched(ep, s, c, watched: watched) } },
                                            onPlayPrivately: { container?.playback.play(episode: ep, series: s, privately: true); router.closeDetail() })
                                    .id(ep.id)
                            }
                        }.padding(.vertical, 4).padding(.horizontal, 1)
                    }
                    // The rail opens at the episode Play will start, once.
                    .task(id: vm.episodesInSeason.count) {
                        guard !focusedResume, let t = vm.resumeTarget, t.seasonNumber == vm.selectedSeason, vm.episodesInSeason.contains(where: { $0.id == t.id }) else { return }
                        focusedResume = true
                        proxy.scrollTo(t.id, anchor: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder private var seasonPicker: some View {
        if let d = vm.detail, d.seasons.count > 1 {
            if TitlePageLogic.seasonsAsChips(d.seasons.count) {
                FadingHScroll {
                    HStack(spacing: 8) {
                        ForEach(d.seasons) { se in
                            TitleChoiceChip(text: se.name ?? "Season \(se.number)", selected: se.number == vm.selectedSeason) { vm.selectedSeason = se.number }
                                .accessibilityAddTraits(se.number == vm.selectedSeason ? .isSelected : [])
                        }
                    }.padding(.vertical, 3).padding(.horizontal, 1)
                }
            } else {
                Menu {
                    ForEach(d.seasons) { se in Button { vm.selectedSeason = se.number } label: { Label(se.name ?? "Season \(se.number)", systemImage: se.number == vm.selectedSeason ? "checkmark" : "") } }
                } label: { Label("Season \(vm.selectedSeason)", systemImage: "list.number") }.menuStyle(.button).buttonStyle(SecondaryButtonStyle()).fixedSize().atlas("control.series.seasonPicker")
            }
        }
    }
}
