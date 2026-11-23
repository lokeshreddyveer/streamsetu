import SwiftUI
import WebKit
import SafariServices
import AVKit

/// A movie or a series: artwork, summary, play, favourite, and (for a series) its seasons and episodes.
struct DetailView: View {
    let item: LibraryItem
    @Environment(AppState.self) private var state
    @Environment(IOSRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container
    @State private var movie: Movie?
    @State private var detail: SeriesDetail?
    @State private var season = 1
    @State private var error: String?
    @State private var scrollY: CGFloat = 0
    @State private var extras: ProviderExtras?
    @State private var showTrailer = false
    @State private var showSearch = false
    @State private var tmdbTrailer: String?
    @State private var previewClip: URL?
    @State private var showClip = false
    @State private var overviewOpen = false
    @State private var tmdb: TitleDetails?
    @State private var loadedExtras = false
    @State private var hasTMDBKey = true
    @State private var versionsModel = TitleVersionsModel()
    @State private var hub = TitleHubModel()
    @State private var progress: WatchProgress?
    @State private var nextEpisode: Episode?
    @State private var playingTrailer: String?
    @State private var art: HeroArtwork
    @State private var episodeProgress: [String: WatchProgress] = [:]
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.artwork) private var artwork
    @ScaledMetric(relativeTo: .largeTitle) private var titleScale: CGFloat = 1

    init(item: LibraryItem) {
        self.item = item
        _art = State(initialValue: HeroArtwork.preloaded(backdrop: item.backdropURL, poster: item.posterURL))      // a title seen before has its picture in the first frame
    }

    private var reduceMotion: Bool { BrandMotion.reduced(systemReduceMotion) }
    private var artKey: String { (heroBackdrop ?? "") + "|" + (posterValue ?? "") }
    /// A tall picture, under half the screen, with the title low on it, so the rating, credits and story are in view without scrolling.
    private var heroHeight: CGFloat { HeroMetrics.height(wide: sizeClass == .regular, share: 0.45) }

    /// The first episode's picture, the last resort for a series whose provider and TMDB sent no poster or backdrop.
    private var firstStill: String? { detail?.episodes.sorted { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }.compactMap { $0.imageURL.nilIfEmpty }.first }
    /// Backdrop: the provider's, TMDB's own, then the hub's. With none the hero washes the poster (and, with no poster either, the first episode's picture).
    private var backdropValue: String? { (movie?.backdropURL ?? detail?.series.backdropURL ?? item.backdropURL).nilIfEmpty ?? tmdb?.backdropURL ?? hub.backdropURL.nilIfEmpty }
    /// Poster: the provider's cover, TMDB's poster, the hub's, then the first episode's picture; only then the generated tile.
    private var posterValue: String? { (movie?.posterURL ?? detail?.series.posterURL ?? item.posterURL).nilIfEmpty ?? tmdb?.posterURL ?? hub.posterURL.nilIfEmpty ?? (item.isSeries ? firstStill : nil) }
    private var heroBackdrop: String? { backdropValue ?? (posterValue == nil ? firstStill : nil) }

    var body: some View {
        ScrollView {
            Group { if sizeClass == .regular { wideLayout } else { narrowLayout } }
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, v in scrollY = v }
        .ignoresSafeArea(edges: .top).atlasScreen("screen.ios.detail")
        .navigationBarTitleDisplayMode(.inline).clearTopBar()
        .toolbar { TrailingPills { Menu {
            Button("Watch Privately", systemImage: "eye.slash") {
                guard let container else { return }
                if let m = movie ?? asMovie { Play.movie(m, container, privately: true) } else if item.isSeries, let detail { Task { await Play.series(detail.series, container, privately: true) } }
            }
            if let m = movie ?? asMovie {
                Button("Watch Together", systemImage: "shareplay") {
                    guard let container else { return }
                    Play.movie(m, container)
                    SharePlayService.shared.startWhenReady(container)
                }
            }
            if let q = container?.watchQueue {
                if q.contains(item.id) { Button("Remove from Queue", systemImage: "text.badge.minus") { q.remove(item.id) } }
                else {
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { q.add(item, next: true) }
                    Button("Add to Queue", systemImage: "text.badge.plus") { q.add(item) }
                }
            }
            CollectionMenu(itemID: item.id, kind: item.kind)
        } label: { Image(systemName: "ellipsis.circle").pillIcon() }.atlas("control.ios.detail.moreMenu") } }
        .background(ColorTokens.background)
        .fullScreenCover(isPresented: $showTrailer) { if let k = playingTrailer ?? trailerKey { TrailerSheet(key: k, title: item.title) } }
        .fullScreenCover(isPresented: $showClip) { if let u = previewClip { ClipSheet(url: u) } }
        .task { await load() }
        .task(id: artKey) {
            art.peek(backdrop: heroBackdrop, poster: posterValue)
            await art.load(backdrop: heroBackdrop, poster: posterValue, artwork: artwork)
        }
        .task(id: item.id) { await versionsModel.load(item, container: container) }
        .task(id: item.id) { if let container { hub.open(itemID: item.id, isSeries: item.isSeries, container: container) } }
        .onDisappear { hub.close() }
        .onMetadataLanded(for: item.id) {
            Task {
                switch item {
                case .movie(let m): if let x = try? await container?.details.movie(id: m.id) { movie = x }
                case .series(let sr): if let x = try? await container?.details.series(id: sr.id) { detail = x }          // the series page picks up its new backdrop too
                }
            }
        }
        .miniPlayerInset()
    }

    // MARK: layout

    private var narrowLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero(width: 400)
            VStack(alignment: .leading, spacing: 24) {
                playBlock
                versionsBlock
                synopsisBlock
                missingNote
                if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                detailsGrid
                CastSection(item: item, useLinks: true).castRowFocus(item.id)
                if item.isSeries { episodes }
                bottomSections
            }.padding(.top, 8).padding(.horizontal, 16).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    /// iPad: the hero across the top; Play, versions and the story beside the details; then cast, episodes and the rails at full width.
    private var wideLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero(width: 900)
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 22) { playBlock; versionsBlock; synopsisBlock; missingNote }.frame(maxWidth: .infinity, alignment: .leading)
                    detailsGrid.frame(width: 320)
                }
                CastSection(item: item, useLinks: true).castRowFocus(item.id)
                if item.isSeries { episodes }
                bottomSections
            }.padding(.top, 8).padding(.horizontal, 28).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
    }

    private func hero(width: CGFloat) -> some View {
        let compact = sizeClass != .regular
        return ZStack(alignment: .bottomLeading) {
            ParallaxBanner(height: heroHeight, scrollY: reduceMotion ? 0 : scrollY) { TitleHeroBackground(art: art, title: item.cleanTitle) }
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25)).allowsHitTesting(false)          // keeps the clock and the buttons readable
            HStack(alignment: .bottom, spacing: 16) {
                ArtworkImage(url: posterValue, kind: .poster, contentMode: .fill, alignment: .top, tile: ArtworkTile.Content(title: item.cleanTitle, detail: yearValue.map(String.init)))
                    .frame(width: compact ? 96 : 140, height: compact ? 144 : 210).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    titleOrLogo(compact ? 28 : 38)
                    FadingHScroll { HStack(spacing: 8) { TitleChipsRow(chips: chips, rating: credibleRating, spoken: chipsSpoken).fixedSize(horizontal: true, vertical: false); if item.isSeries { NextEpisodeChip(stamp: hub.nextEpisodeStamp, onDark: true).fixedSize() } } }
                    if let g = TitlePageLogic.genreLine(genreNames) { Text(g).font(.subheadline).foregroundStyle(Color.white.opacity(0.72)).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, sizeClass == .regular ? 28 : 16).padding(.bottom, 14)
        }
        .zIndex(0)
    }

    /// The title in type; the hub's logo (when it has one) is drawn over the same space and the text fades out, so nothing moves when it arrives.
    private func titleOrLogo(_ size: CGFloat) -> some View {
        Text(item.cleanTitle).font(.system(size: size * titleScale, weight: .heavy)).lineLimit(3).minimumScaleFactor(0.6).foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 10, y: 2)
            .opacity(hub.logoURL.nilIfEmpty == nil ? 1 : 0)
            .overlay(alignment: .leading) {
                if let logo = hub.logoURL.nilIfEmpty { ArtworkImage(url: logo, kind: .backdrop, contentMode: .fit, alignment: .leading, showsPlaceholder: false).frame(maxWidth: 300, maxHeight: size * titleScale * 1.9, alignment: .leading).accessibilityHidden(true) }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: hub.logoURL)
            .accessibilityLabel(item.cleanTitle).accessibilityAddTraits(.isHeader)
    }

    private var chips: [TitlePageLogic.Chip] {
        TitlePageLogic.chips(year: yearValue, runtimeSeconds: runtimeSeconds, age: ageText, quality: TitlePage.quality([item.title, item.categoryName, item.genre]), seasons: item.isSeries ? detail?.seasons.count : nil)
    }
    private var chipsSpoken: String { TitlePageLogic.chipsSpoken(chips, rating: credibleRating, runtimeSeconds: runtimeSeconds) }

    // MARK: play block

    private var playLabelModel: TitlePageLogic.PlayLabel {
        if item.isSeries {
            guard let e = nextEpisode else { return TitlePageLogic.playLabel(resume: nil) }
            return TitlePageLogic.playLabel(episode: (e.seasonNumber, e.episodeNumber), resume: TitlePageLogic.resume(episodeProgress[e.id]), startedSeries: !episodeProgress.isEmpty)
        }
        return TitlePageLogic.playLabel(resume: TitlePageLogic.resume(progress))
    }

    private var playBlock: some View {
        VStack(spacing: 18) {
            TitlePlayPill(label: playLabelModel, enabled: !(item.isSeries && detail == nil), expand: true) {
                if item.isSeries { playSeries() } else if let container, let m = movie ?? asMovie { Play.movie(m, container) }
            }
            circleActions
        }
    }

    private func circleAction(_ text: String, _ symbol: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) { Image(systemName: symbol).symbolEffect(.bounce, value: active) }.buttonStyle(HeroCircleStyle(active: active, size: 50)).accessibilityLabel(text).atlasCovers("control.ios.detail.trailer")
            Text(text).font(.caption2.weight(.medium)).foregroundStyle(ColorTokens.textSecondary).lineLimit(2).multilineTextAlignment(.center).accessibilityHidden(true)
        }.frame(maxWidth: .infinity)
    }

    private var circleActions: some View {
        let fav = state.isFavorite(item.id), later = state.isWatchLater(item.id)
        return TitleActionRow {
            circleAction("Favourite", fav ? "heart.fill" : "heart", active: fav) { state.toggleFavorite(item.id, kind: item.kind) }
                .accessibilityValue(fav ? "On" : "Off").atlas("control.ios.detail.favourite")
            circleAction("Watch Later", later ? "bookmark.fill" : "bookmark", active: later) { state.toggleWatchLater(item.id, kind: item.kind) }
                .accessibilityValue(later ? "On" : "Off").atlas("control.ios.detail.watchLater")
            if hasTrailer {
                circleAction("Trailer", "play.rectangle") { playingTrailer = nil; if trailerKey != nil { showTrailer = true } else if previewClip != nil { showClip = true } }.atlas("control.ios.detail.trailer")
            }
            if case .movie(let m) = item {
                VStack(spacing: 6) {
                    DownloadButton(itemID: m.id, compact: true) { $0.enqueue(movie: m) }.buttonStyle(HeroCircleStyle(size: 50)).menuStyle(.button).menuIndicator(.hidden).fixedSize()
                    Text("Download").font(.caption2.weight(.medium)).foregroundStyle(ColorTokens.textSecondary).accessibilityHidden(true)
                }.frame(maxWidth: .infinity)
            }
            if let link = item.isSeries ? DeepLink.link(series: item.title) : DeepLink.link(movie: item.title) {
                VStack(spacing: 6) {
                    ShareLink(item: link, subject: Text(item.cleanTitle), message: Text("Open “\(item.cleanTitle)” in StreamSetu")) { Image(systemName: "square.and.arrow.up") }.buttonStyle(HeroCircleStyle(size: 50)).accessibilityLabel("Share")
                    Text("Share").font(.caption2.weight(.medium)).foregroundStyle(ColorTokens.textSecondary).accessibilityHidden(true)
                }.frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private var versionsBlock: some View { TitleVersionsSection(versions: versionsModel.versions, useLinks: true) }

    @ViewBuilder private var synopsisBlock: some View {
        if let t = storyText { MacSynopsis(text: t, tagline: tmdb?.tagline?.nilIfEmpty) }
    }

    private func openFolder() {
        guard let id = item.categoryID else { return }
        dismiss(); router.pendingFolder = (item.kind, id); router.go(item.isSeries ? .series : .movies)
    }

    @ViewBuilder private var detailsGrid: some View {
        let castShown = !(tmdb?.cast.isEmpty ?? true) || !castNames.isEmpty
        let rows = TitlePageLogic.gridRows(TitleDetails_.rows(directors: makerNames, isSeries: item.isSeries, starring: starring, country: extras?.country, studio: nil, released: releasedText, folder: item.categoryName) { openFolder() }, castShown: castShown)
        if !rows.isEmpty {
            TitleDetailsGrid(rows: rows, onPerson: { _ in }, onFolder: item.categoryID == nil ? nil : { openFolder() }, useLinks: true)
        }
    }

    /// Metadata, version picker, Play, actions, synopsis, genres (a series then lists its episodes), details, cast.
    @ViewBuilder private var topBlock: some View {
        metaLine
        versionPicker
        playButton
        actionRow
        synopsis
        GenreChips(genres: genreNames)
        missingNote
        if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
        if item.isSeries { episodes }
    }

    @ViewBuilder private var lowerBlock: some View {
        detailsBlock
        CastSection(item: item, useLinks: true).castRowFocus(item.id)
        bottomSections
    }

    @ViewBuilder private var bottomSections: some View {
        extrasSection
        if case .movie(let m) = item { FranchiseTimeline(currentID: m.id, movie: m, useLinks: true) }
        SimilarRow(item: item, extras: extras)
    }

    // MARK: pieces

    private var credibleRating: Double? {
        DisplayRating.value(tmdbAverage: tmdb?.rating, tmdbVotes: tmdb?.votes, provider: movie?.rating ?? detail?.series.rating ?? { switch item { case .movie(let m): m.rating; case .series(let s): s.rating } }())
    }

    /// One quiet line: year, runtime, age rating, quality, and a star rating only when it is credible.
    private var metaLine: some View {
        let parts = TitlePage.metaParts(year: yearValue, runtimeSeconds: runtimeSeconds, age: ageText, quality: TitlePage.quality([item.title, item.categoryName, item.genre]))
        return HStack(spacing: 8) {
            Text(parts.joined(separator: " · ")).lineLimit(2)
            if item.isSeries { NextEpisodeChip(stamp: hub.nextEpisodeStamp).fixedSize() }
            if let r = credibleRating { RatingLabel(value: r) }
            Spacer(minLength: 0)
        }.font(.subheadline.weight(.medium)).foregroundStyle(ColorTokens.textSecondary)
        .accessibilityElement(children: .combine)
    }

    private var versionPicker: some View { VersionPickerLine(versions: versionsModel.versions, useLinks: true) { _ in } }

    private var playLabel: String {
        if item.isSeries {
            let e = nextEpisode
            return TitlePage.playTitle(remainingSeconds: nil, episode: e.map { ($0.seasonNumber, $0.episodeNumber) })
        }
        if let p = progress, !p.completed, p.positionSeconds > 30 { return TitlePage.playTitle(remainingSeconds: p.durationSeconds - p.positionSeconds, episode: nil) }
        return "Play"
    }

    private var playButton: some View {
        TitlePlayButton(title: playLabel, enabled: !(item.isSeries && detail == nil)) {
            if item.isSeries { playSeries() } else if let container, let m = movie ?? asMovie { Play.movie(m, container) }
        }
    }

    private var actionRow: some View {
        let fav = state.isFavorite(item.id), later = state.isWatchLater(item.id)
        return TitleActionRow {
            Button { state.toggleFavorite(item.id, kind: item.kind) } label: { ActionLabel(text: "Favourite", symbol: fav ? "heart.fill" : "heart", active: fav) }.buttonStyle(.plain)
                .accessibilityLabel(fav ? "Favourite, on" : "Favourite, off").accessibilityHint("Toggles favourite")
                .atlas("control.ios.detail.favourite")
            Button { state.toggleWatchLater(item.id, kind: item.kind) } label: { ActionLabel(text: "Watch Later", symbol: later ? "bookmark.fill" : "bookmark", active: later) }.buttonStyle(.plain)
                .accessibilityLabel(later ? "Watch Later, on" : "Watch Later, off").accessibilityHint("Toggles watch later")
                .atlas("control.ios.detail.watchLater")
            if hasTrailer {
                Button { playingTrailer = nil; if trailerKey != nil { showTrailer = true } else if previewClip != nil { showClip = true } } label: { ActionLabel(text: "Trailer", symbol: "play.rectangle") }.buttonStyle(.plain).atlas("control.ios.detail.trailer")
            }
            if case .movie(let m) = item { DownloadButton(itemID: m.id, tile: true) { $0.enqueue(movie: m) }.buttonStyle(.plain) }
            if let link = item.isSeries ? DeepLink.link(series: item.title) : DeepLink.link(movie: item.title) {
                ShareLink(item: link, subject: Text(item.cleanTitle), message: Text("Open “\(item.cleanTitle)” in StreamSetu")) { ActionLabel(text: "Share", symbol: "square.and.arrow.up") }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var synopsis: some View {
        if let s = storyText { TitleSynopsis(text: s) }
    }

    private var genreNames: [String] {
        let own = ProviderExtras.names(movie?.genre ?? item.genre)
        return own.isEmpty ? (tmdb?.genres ?? []) : own
    }

    private var starring: [PersonRoute] {
        if let c = tmdb?.cast, !c.isEmpty { return c.prefix(6).map { PersonRoute(name: $0.name, tmdbID: $0.tmdbID, fromTitle: item.title, fromYear: item.year) } }
        return castNames.prefix(6).map { PersonRoute(name: $0, fromTitle: item.title, fromYear: item.year) }
    }

    private var releasedText: String? {
        DateText.short(iso: tmdb?.releaseDate) ?? yearValue.map(String.init)
    }

    @ViewBuilder private var detailsBlock: some View {
        let rows = TitleDetails_.rows(directors: makerNames, isSeries: item.isSeries, starring: starring, country: extras?.country, studio: nil, released: releasedText, folder: item.categoryName) {
            if let id = item.categoryID { dismiss(); router.pendingFolder = (item.kind, id); router.go(item.isSeries ? .series : .movies) }
        }
        DetailsBlock(rows: rows, useLinks: true)
    }

    /// Trailers from TMDB, only when there is more than the one the Trailer action plays.
    @ViewBuilder private var extrasSection: some View {
        let list = (tmdb?.trailers ?? []).prefix(4)
        if list.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Trailers & extras").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(Array(list)) { t in
                    Button { playingTrailer = t.key; showTrailer = true } label: {
                        Label(t.name, systemImage: "play.rectangle").font(.subheadline).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    .atlas("control.ios.detail.trailer")
                }
            }
        }
    }

    /// From the provider when it sends one, otherwise from TMDB when a key is set in Settings.
    private var trailerKey: String? { extras?.trailerKey ?? tmdbTrailer }

    private var hasTrailer: Bool { trailerKey != nil || previewClip != nil }

    private var searchURL: URL? {
        var c = URLComponents(string: "https://www.youtube.com/results")
        c?.queryItems = [URLQueryItem(name: "search_query", value: "\(item.title) \(item.year.map(String.init) ?? "") official trailer")]
        return c?.url
    }

    // What the provider did not send is filled in from the movie database (TMDB, when a key is set in Settings, or its saved copy).
    private var castNames: [String] {
        if let c = extras?.cast, !c.isEmpty { return c }
        return tmdb?.cast.map { $0.name } ?? []
    }
    private var makerNames: [String] {
        if let d = extras?.directors, !d.isEmpty { return d }
        return tmdb?.makers ?? []
    }
    private var runtimeSeconds: Double? {
        if let d = movie?.durationSeconds ?? item.durationSeconds, d > 0 { return d }
        if let m = tmdb?.runtimeMinutes, m > 0 { return Double(m) * 60 }
        return nil
    }
    private var ageText: String? {
        if let a = extras?.ageRating, !a.isEmpty { return a }
        if let c = tmdb?.certification, !c.isEmpty { return c }
        return nil
    }
    private var yearValue: Int? { movie?.releaseYear ?? item.year ?? tmdb?.year }
    private var storyText: String? {
        let own = movie?.overview ?? detail?.series.overview ?? item.overview
        if let own, !own.isEmpty { return own }
        return tmdb?.overview.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The whole cast, when there is more than the credits row shows.
    @ViewBuilder private var facts: some View {
        EmptyView()          // the cast is the round-photo row below (CastSection); a plain "Cast: a, b, c" line would repeat it
    }

    private var ratingText: String? { credibleRating.map { String(format: "%.1f", $0) } }

    /// Rating, age rating, year, length and the picture quality, in one row. The year is always shown (the title no longer carries it).
    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let r = ratingText {
                    Label(r, systemImage: "star.fill").labelStyle(.titleAndIcon).foregroundStyle(.yellow).appFont(13, .bold)
                        .padding(.horizontal, 10).frame(height: 28).background(FlatChipBackground())
                }
                if let a = ageText {
                    Text(a).appFont(12, .bold).foregroundStyle(ColorTokens.textPrimary).padding(.horizontal, 8).frame(height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(ColorTokens.lineStrong))
                }
                if let y = yearValue { Text(String(y)).appFont(14, .medium).foregroundStyle(ColorTokens.textSecondary) }
                if let d = runtimeSeconds { Text(DurationFormatter.short(d)).appFont(14, .medium).foregroundStyle(ColorTokens.textSecondary) }
                QualityBadgeRow(texts: [item.title, item.genre])
            }
        }
    }

    /// The genres, as small capsules.
    @ViewBuilder private var genreRow: some View {
        let own = ProviderExtras.names(movie?.genre ?? item.genre)
        let genres = own.isEmpty ? (tmdb?.genres ?? []) : own
        if !genres.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(genres, id: \.self) { g in
                        Text(g).appFont(13, .medium).foregroundStyle(ColorTokens.textPrimary).padding(.horizontal, 12).frame(height: 30)
                            .background(FlatChipBackground())
                    }
                }
            }
        }
    }

    private struct CreditColumn { let label: String; let value: String; let sub: String? }
    private var creditColumns: [CreditColumn] {
        var out: [CreditColumn] = []
        if !makerNames.isEmpty { out.append(CreditColumn(label: item.isSeries ? "Creator" : "Directed by", value: makerNames.prefix(2).joined(separator: ", "), sub: nil)) }
        if !castNames.isEmpty { out.append(CreditColumn(label: "Starring", value: castNames.prefix(2).joined(separator: ", "), sub: castNames.count > 2 ? castNames.dropFirst(2).prefix(2).joined(separator: ", ") : nil)) }
        if let c = extras?.country { out.append(CreditColumn(label: "Country", value: c, sub: nil)) }
        return out
    }

    /// Director, the main cast and the country, as columns with thin dividers.
    @ViewBuilder private var credits: some View {
        let cols = creditColumns
        if !cols.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(cols.enumerated()), id: \.offset) { i, c in
                        if i > 0 { Rectangle().fill(ColorTokens.line).frame(width: 1, height: 46).padding(.horizontal, 16) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.label.uppercased()).appFont(10, .semibold).tracking(1.2).foregroundStyle(ColorTokens.textTertiary)
                            Text(c.value).appFont(14, .semibold).lineLimit(2).foregroundStyle(ColorTokens.textPrimary)
                            if let sub = c.sub { Text(sub).appFont(12).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                        }
                    }
                }
            }
        }
    }

    /// Said plainly when neither the provider nor the movie database has a summary or a cast for the title.
    @ViewBuilder private var missingNote: some View {
        if loadedExtras, storyText == nil, castNames.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(hasTMDBKey ? "No summary or cast is available for this title." : "Your provider sent no summary or cast for this title. Add a details key in Settings, under Artwork and Details, to fill them in.")
                    .appFont(13).foregroundStyle(ColorTokens.textSecondary)
                if !hasTMDBKey {
                    Button("Open Settings") { dismiss(); router.go(.settings) }.appFont(13, .semibold).foregroundStyle(Color.accentColor).atlas("control.ios.detail.openSettings")
                }
            }
        }
    }

    /// The story, three lines to start with and the rest under "More".
    @ViewBuilder private var overviewBlock: some View {
        if let overview = storyText {
            VStack(alignment: .leading, spacing: 6) {
                Text(overview).appFont(14).lineSpacing(3).foregroundStyle(ColorTokens.textPrimary.opacity(0.85)).lineLimit(overviewOpen ? nil : 3)
                if overview.count > 140 {
                    Button(overviewOpen ? "Less" : "More") { withAnimation(.smooth(duration: 0.25)) { overviewOpen.toggle() } }
                        .appFont(13, .semibold).foregroundStyle(ColorTokens.accentDefault)
                        .atlas("control.ios.detail.overview")
                }
            }
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).appFont(12, .semibold).foregroundStyle(.secondary)
            Text(value).appFont(14).foregroundStyle(.white.opacity(0.85))
        }
    }

    private var asMovie: Movie? { if case .movie(let m) = item { m } else { nil } }

    private var meta: String {
        var parts: [String] = []
        if let y = movie?.releaseYear ?? item.year, !item.title.contains(String(y)) { parts.append(String(y)) }
        if let d = movie?.durationSeconds ?? item.durationSeconds, d > 0 { parts.append(DurationFormatter.short(d)) }
        if let g = movie?.genre ?? item.genre { parts.append(g) }
        if let r = movie?.rating ?? detail?.series.rating, !r.isEmpty, Double(r) ?? 0 > 0 { parts.append("★ \(r)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var episodes: some View {
        if let detail {
            let numbers = Array(Set(detail.episodes.map(\.seasonNumber))).sorted()
            let list = detail.episodes.filter { $0.seasonNumber == season }.sorted { $0.episodeNumber < $1.episodeNumber }
            VStack(alignment: .leading, spacing: 14) {
                TitleSectionHeader(title: "Episodes", count: list.isEmpty ? nil : "\(list.count)")
                if numbers.count > 1 {
                    FadingHScroll {
                        HStack(spacing: 8) {
                            ForEach(numbers, id: \.self) { n in
                                TitleChoiceChip(text: "Season \(n)", selected: n == season) { season = n }.accessibilityAddTraits(n == season ? .isSelected : []).atlas("control.ios.detail.season")
                            }
                        }.padding(.vertical, 3).padding(.horizontal, 1)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(list) { e in
                        HStack(spacing: 6) {
                            Button { if let container { Play.episode(e, detail.series, container) } } label: { episodeRow(e, detail.series) }.buttonStyle(.press)
                                .contextMenu {
                                    Text(e.title)          // the full name as the provider sent it
                                    Button("Play", systemImage: "play.fill") { if let container { Play.episode(e, detail.series, container) } }
                                    Button("Watch Privately", systemImage: "eye.slash") { if let container { Play.episode(e, detail.series, container, privately: true) } }
                                }
                                .accessibilityElement(children: .ignore).accessibilityLabel(episodeSpoken(e)).accessibilityHint("Plays this episode")
                                .atlas("control.ios.detail.episode")
                            DownloadButton(itemID: e.id, compact: true) { $0.enqueue(episode: e, series: detail.series) }.buttonStyle(.borderless).font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 44, height: 44)
                        }
                        Divider().overlay(ColorTokens.line)
                    }
                }
            }
        } else if error == nil {
            BrandLoader(size: 32).frame(maxWidth: .infinity).padding()
        }
    }

    private func episodeRow(_ e: Episode, _ series: Series) -> some View {
        let resume = TitlePageLogic.resume(episodeProgress[e.id])
        return HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottom) {
                ArtworkImage(url: e.imageURL ?? series.backdropURL, kind: .still, contentMode: .fill, symbol: "play.rectangle", tile: ArtworkTile.Content(title: e.title, detail: "Episode \(e.episodeNumber)", showsTitle: false))
                if let r = resume {
                    GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(Color.white.opacity(0.25)); Capsule().fill(Color.accentColor).frame(width: g.size.width * r.fraction) } }.frame(height: 3).padding(.horizontal, 6).padding(.bottom, 6)
                }
            }
            .frame(width: 128, height: 72).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topTrailing) { if episodeProgress[e.id]?.completed == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, ColorTokens.success).padding(4) } }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(e.episodeNumber). \(TitlePageLogic.cleanEpisodeTitle(e.title, series: series.title, number: e.episodeNumber))").font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    if nextEpisode?.id == e.id { Text("UP NEXT").font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.accentColor)) }
                }
                if let o = e.overview?.nilIfEmpty { Text(o).font(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(2).multilineTextAlignment(.leading) }
                HStack(spacing: 6) {
                    if let d = e.durationSeconds, d > 0 { Text(DurationFormatter.short(d)) }
                    if let r = resume { Text("· " + TitlePageLogic.remainingText(r.remaining)) }
                }.font(.caption2).foregroundStyle(ColorTokens.textTertiary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 8).contentShape(Rectangle())
    }

    private func episodeSpoken(_ e: Episode) -> String {
        var parts = ["Episode \(e.episodeNumber), \(TitlePageLogic.cleanEpisodeTitle(e.title, series: detail?.series.title ?? item.title, number: e.episodeNumber))", e.title]
        if let d = e.durationSeconds, d > 0 { parts.append(TitlePageLogic.spokenDuration(d)) }
        if episodeProgress[e.id]?.completed == true { parts.append("watched") } else if let r = TitlePageLogic.resume(episodeProgress[e.id]) { parts.append("\(Int(r.fraction * 100)) percent watched") }
        if nextEpisode?.id == e.id { parts.append("up next") }
        return parts.joined(separator: ", ")
    }

    private var resumeEpisode: Episode? { nil }

    private func playSeries() {
        guard let container, let detail else { return }
        let next = (try? container.history.resumeTarget(seriesID: detail.series.id)) ?? detail.episodes.sorted { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }.first
        if let next { Play.episode(next, detail.series, container) }
    }

    /// What the page shows for cast and directors is also kept for search, so a title you have opened is found by the names on it straight away.
    private func rememberPeople(_ container: AppContainer) {
        let names = castNames + makerNames
        guard !names.isEmpty else { return }
        let id = item.id, kind: ContentKind = item.isSeries ? .series : .movie, source = item.sourceID
        Task.detached { try? PeopleIndex(db: container.db).save(itemID: id, kind: kind, sourceID: source, names: names) }
    }

    private func load() async {
        guard let container else { return }
        do {
            switch item {
            case .movie(let m):
                movie = try await container.details.movie(id: m.id)
                progress = try? container.historyRepo.progress(for: m.id)
                extras = await container.details.extras(movie: m.id)
            case .series(let s):
                let d = try await container.details.series(id: s.id)
                detail = d
                episodeProgress = Dictionary(((try? container.historyRepo.progress(forSeries: s.id)) ?? []).map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
                if let first = d.episodes.map(\.seasonNumber).min() { season = first }
                if let r = try? container.history.resumeTarget(seriesID: s.id) { season = r.seasonNumber }
                nextEpisode = ((try? container.history.resumeTarget(seriesID: s.id)) ?? nil) ?? d.episodes.sorted { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }.first
                if let e = d.extras { extras = e } else { extras = await container.details.extras(series: s.id) }
            }
            let c = MetadataMatchService.Candidate(id: item.id, isSeries: item.isSeries, title: item.title, year: item.year)
            let more = await container.metadata.details(for: c)
            tmdb = more
            // A title with no picture anywhere is looked up again once, so the pictures TMDB has are filled in and the page picks them up (it listens for them landing).
            if (item.posterURL.nilIfEmpty ?? item.backdropURL.nilIfEmpty) == nil, more?.posterPath == nil, container.metadata.hasKey, container.metadata.isSendable(item.id) {
                if let again = await container.metadata.details(for: c, maxAge: 0) { tmdb = again }
            }
            hasTMDBKey = container.metadata.hasKey
            loadedExtras = true
            rememberPeople(container)
            if extras?.trailerKey == nil {
                tmdbTrailer = more?.bestTrailer?.key
                if tmdbTrailer == nil, container.metadata.isSendable(item.id) { previewClip = await TrailerLookup.find(title: item.title, year: item.year, isSeries: item.isSeries) }
            }
        } catch {
            self.error = CredentialRedactor.redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// Plays a YouTube trailer inside the app.
struct TrailerSheet: View {
    let key: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            YouTubeView(key: key).ignoresSafeArea(edges: .bottom)
            Button { dismiss() } label: { Image(systemName: "xmark").pillIcon() }.buttonStyle(.press).padding(16).accessibilityLabel("Close trailer").atlas("control.ios.detail.closeTrailer")
        }
    }
}

private struct YouTubeView: UIViewRepresentable {
    let key: String
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.isOpaque = false; v.backgroundColor = .black; v.scrollView.isScrollEnabled = false
        let html = "<html><body style='margin:0;background:#000'><iframe width='100%' height='100%' src='https://www.youtube.com/embed/\(key)?autoplay=1&playsinline=1&rel=0&origin=https://\(Bundle.main.bundleIdentifier ?? "app.streamsetu.ios")' frameborder='0' allow='autoplay; encrypted-media; fullscreen' allowfullscreen style='position:absolute;inset:0;border:0'></iframe></body></html>"
        v.loadHTMLString(html, baseURL: URL(string: "https://\(Bundle.main.bundleIdentifier ?? "app.streamsetu.ios")"))
        return v
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Plays a trailer clip (a plain video file) with the system player.
struct ClipSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player { VideoPlayer(player: player).ignoresSafeArea() }
            Button { dismiss() } label: { Image(systemName: "xmark").pillIcon() }.buttonStyle(.press).padding(16).accessibilityLabel("Close trailer").atlas("control.ios.detail.closeTrailer")
        }
        .onAppear { let p = AVPlayer(url: url); player = p; p.play() }
        .onDisappear { player?.pause(); player = nil }
    }
}


/// "More Like This": titles from the library that share this one's franchise, director, genre, cast or story, each with the reason it was chosen.
struct SimilarRow: View {
    let item: LibraryItem
    let extras: ProviderExtras?
    @Environment(\.container) private var container
    @State private var suggestions: [SimilarSuggestion] = []

    var body: some View {
        // A task on an empty view never runs, so something always exists here: a one-point clear line holds the loading step until there is a row to show.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 1)
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("More Like This").appFont(17, .bold)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(suggestions) { s in
                                NavigationLink(value: s.item) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        PosterCard(item: s.item, width: 110)
                                        Text(s.reason).appFont(11).foregroundStyle(.secondary).lineLimit(1).frame(width: 110, alignment: .leading)
                                    }
                                }.buttonStyle(.plain)
                                .atlas("control.ios.detail.similar")
                            }
                        }
                    }
                }.padding(.top, 8)
            }
        }
        // First from what is in the catalog, then again when the provider has sent the cast and director.
        .task(id: (extras?.cast ?? []) + (extras?.directors ?? []) + [item.id]) {
            guard let container else { return }
            let service = SimilarService(catalog: container.catalog)
            let e = extras
            let first = await Task.detached { service.suggestions(for: item, extras: e) }.value
            suggestions = first
            // The catalog list rarely has cast or genre, so ask the provider about the closest movies and rank again with what comes back.
            guard !item.isSeries, let e, !e.cast.isEmpty || !e.directors.isEmpty else { return }
            var known: [String: ProviderExtras] = [:]
            await withTaskGroup(of: (String, ProviderExtras?).self) { group in
                for s in first.prefix(20) { group.addTask { (s.id, await container.details.extras(movie: s.id)) } }
                for await (id, x) in group { if let x { known[id] = x } }
            }
            guard !known.isEmpty else { return }
            let k = known
            suggestions = await Task.detached { service.suggestions(for: item, extras: e, known: k) }.value
        }
    }
}
