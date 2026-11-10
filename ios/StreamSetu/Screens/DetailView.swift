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
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// A tall picture, under half the screen, with the title low on it, so the rating, credits and story are in view without scrolling.
    private var heroHeight: CGFloat { HeroMetrics.height(wide: sizeClass == .regular, share: 0.45) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    ParallaxBanner(height: heroHeight, scrollY: scrollY) {
                        ArtworkImage(url: (movie?.backdropURL ?? item.backdropURL) ?? item.posterURL, kind: .backdrop, contentMode: .fill, symbol: "film", alignment: .top)
                    }
                    LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.2))          // keeps the clock and the buttons readable
                    LinearGradient(stops: [.init(color: .clear, location: 0.42), .init(color: ColorTokens.background.opacity(0.55), location: 0.66),
                                           .init(color: ColorTokens.background.opacity(0.92), location: 0.88), .init(color: ColorTokens.background, location: 1)], startPoint: .top, endPoint: .bottom)
                    Text(item.cleanTitle).appFont(28, .heavy).lineLimit(3).minimumScaleFactor(0.7).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 2)
                        .padding(.horizontal, 20).padding(.bottom, 12)
                }
                .zIndex(0)
                VStack(alignment: .leading, spacing: 14) {
                    chipRow
                    genreRow
                    credits
                    overviewBlock
                    missingNote
                    Button { if item.isSeries { playSeries() } else if let container, let m = movie ?? asMovie { Play.movie(m, container) } } label: {
                        Label(item.isSeries && resumeEpisode != nil ? "Resume" : "Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SolidPlayStyle()).disabled(item.isSeries && detail == nil)
                    HStack(spacing: 14) {
                        Button { state.toggleFavorite(item.id, kind: item.kind) } label: { Image(systemName: state.isFavorite(item.id) ? "heart.fill" : "heart").frame(width: 24, height: 24).symbolEffect(.bounce, value: state.isFavorite(item.id)) }
                            .buttonStyle(ActionCircleStyle(tint: state.isFavorite(item.id) ? .pink : nil)).accessibilityLabel(state.isFavorite(item.id) ? "Remove from favourites" : "Add to favourites")
                        Button { state.toggleWatchLater(item.id, kind: item.kind) } label: { Image(systemName: state.isWatchLater(item.id) ? "bookmark.fill" : "bookmark").frame(width: 24, height: 24).symbolEffect(.bounce, value: state.isWatchLater(item.id)) }
                            .buttonStyle(ActionCircleStyle(tint: state.isWatchLater(item.id) ? .orange : nil)).accessibilityLabel(state.isWatchLater(item.id) ? "Remove from Watch Later" : "Add to Watch Later")
                        QueueButton(item: item)
                        if case .movie(let m) = item { DownloadButton(itemID: m.id, compact: true) { $0.enqueue(movie: m) }.buttonStyle(ActionCircleStyle()) }
                        trailerButton
                    }.frame(maxWidth: .infinity)
                    FolderPathButton(name: item.categoryName) { if let id = item.categoryID { dismiss(); router.pendingFolder = (item.kind, id); router.go(item.isSeries ? .series : .movies) } }
                    facts
                    if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                    if item.isSeries { episodes }
                    if case .movie(let m) = item { FranchiseTimeline(currentID: m.id, movie: m, useLinks: true) }
                    SimilarRow(item: item, extras: extras)
                }.padding(.top, -20).padding(.horizontal, 16).frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity).background(ColorTokens.background).zIndex(1)      // slides over the banner as it recedes
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, v in scrollY = v }
        .ignoresSafeArea(edges: .top)
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
            CollectionMenu(itemID: item.id, kind: item.kind)
        } label: { Image(systemName: "ellipsis.circle").pillIcon() } } }
        .background(ColorTokens.background)
        .task { await load() }
        .miniPlayerInset()
    }

    /// From the provider when it sends one, otherwise from TMDB when a key is set in Settings.
    private var trailerKey: String? { extras?.trailerKey ?? tmdbTrailer }

    private var hasTrailer: Bool { trailerKey != nil || previewClip != nil }

    private var trailerButton: some View {
        Button {
            if trailerKey != nil { showTrailer = true } else if previewClip != nil { showClip = true } else { showSearch = true }
        } label: {
            Image(systemName: hasTrailer ? "play.rectangle.fill" : "magnifyingglass").frame(width: 24, height: 24)
        }
        .buttonStyle(ActionCircleStyle())
        .accessibilityLabel(hasTrailer ? "Watch Trailer" : "Find Trailer on YouTube")
        .fullScreenCover(isPresented: $showTrailer) { if let k = trailerKey { TrailerSheet(key: k, title: item.title) } }
        .fullScreenCover(isPresented: $showClip) { if let u = previewClip { ClipSheet(url: u) } }
        .sheet(isPresented: $showSearch) { if let u = searchURL { SafariView(url: u).ignoresSafeArea() } }
    }

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
        if castNames.count > 2 { fact("Cast", castNames.prefix(12).joined(separator: ", ")) }
    }

    private var ratingText: String? {
        let own = (movie?.rating ?? detail?.series.rating).flatMap { Double($0) } ?? item.ratingValue
        guard let v = own ?? tmdb?.rating, v > 0 else { return nil }
        return String(format: "%.1f", v)
    }

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
                Text(hasTMDBKey ? "No summary or cast is available for this title." : "Your provider sent no summary or cast for this title. Add a TMDB key in Settings, under Artwork and Details, to fill them in.")
                    .appFont(13).foregroundStyle(ColorTokens.textSecondary)
                if !hasTMDBKey {
                    Button("Open Settings") { dismiss(); router.go(.settings) }.appFont(13, .semibold).foregroundStyle(Color.accentColor)
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
            if numbers.count > 1 {
                Picker("Season", selection: $season) { ForEach(numbers, id: \.self) { Text("Season \($0)").tag($0) } }.pickerStyle(.menu)
            }
            VStack(spacing: 0) {
                ForEach(detail.episodes.filter { $0.seasonNumber == season }.sorted { $0.episodeNumber < $1.episodeNumber }) { e in
                    HStack(spacing: 6) {
                    Button { if let container { Play.episode(e, detail.series, container) } } label: {
                        HStack(spacing: 12) {
                            ArtworkImage(url: e.imageURL ?? detail.series.backdropURL, kind: .still, contentMode: .fill, symbol: "play.rectangle").frame(width: 112, height: 63).clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(e.episodeNumber). \(e.title)").appFont(14, .medium).lineLimit(2).multilineTextAlignment(.leading)
                                if let d = e.durationSeconds, d > 0 { Text(DurationFormatter.short(d)).appFont(12).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "play.circle").foregroundStyle(.secondary)
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.press)
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") { if let container { Play.episode(e, detail.series, container) } }
                        Button("Watch Privately", systemImage: "eye.slash") { if let container { Play.episode(e, detail.series, container, privately: true) } }
                    }
                    DownloadButton(itemID: e.id, compact: true) { $0.enqueue(episode: e, series: detail.series) }.buttonStyle(.borderless).font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 44, height: 44)
                    }
                    Divider().overlay(ColorTokens.line)
                }
            }
        } else if error == nil {
            ProgressView().frame(maxWidth: .infinity).padding()
        }
    }

    private var resumeEpisode: Episode? { nil }

    private func playSeries() {
        guard let container, let detail else { return }
        let next = (try? container.history.resumeTarget(seriesID: detail.series.id)) ?? detail.episodes.sorted { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }.first
        if let next { Play.episode(next, detail.series, container) }
    }

    private func load() async {
        guard let container else { return }
        do {
            switch item {
            case .movie(let m):
                movie = try await container.details.movie(id: m.id)
                extras = await container.details.extras(movie: m.id)
            case .series(let s):
                let d = try await container.details.series(id: s.id)
                detail = d
                if let first = d.episodes.map(\.seasonNumber).min() { season = first }
                if let r = try? container.history.resumeTarget(seriesID: s.id) { season = r.seasonNumber }
                if let e = d.extras { extras = e } else { extras = await container.details.extras(series: s.id) }
            }
            let c = MetadataMatchService.Candidate(id: item.id, isSeries: item.isSeries, title: item.title, year: item.year)
            let more = await container.metadata.details(for: c)
            tmdb = more
            hasTMDBKey = container.metadata.hasKey
            loadedExtras = true
            if extras?.trailerKey == nil {
                tmdbTrailer = more?.bestTrailer?.key
                if tmdbTrailer == nil { previewClip = await TrailerLookup.find(title: item.title, year: item.year, isSeries: item.isSeries) }
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
            Button { dismiss() } label: { Image(systemName: "xmark").pillIcon() }.buttonStyle(.press).padding(16).accessibilityLabel("Close trailer")
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

/// An in-app browser page (used for the YouTube search when no trailer is known).
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
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
            Button { dismiss() } label: { Image(systemName: "xmark").pillIcon() }.buttonStyle(.press).padding(16).accessibilityLabel("Close trailer")
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
