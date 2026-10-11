import SwiftUI
import WebKit
import SafariServices
import AVKit

/// A movie or a series: artwork, summary, play, favourite, and (for a series) its seasons and episodes.
struct DetailView: View {
    let item: LibraryItem
    @Environment(AppState.self) private var state
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
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    ParallaxBanner(height: sizeClass == .regular ? 360 : 230, scrollY: scrollY) {
                        ArtworkImage(url: (movie?.backdropURL ?? item.backdropURL) ?? item.posterURL, kind: .backdrop, contentMode: .fill, symbol: "film")
                    }
                    LinearGradient(colors: [.clear, ColorTokens.background.opacity(0.6), ColorTokens.background], startPoint: .center, endPoint: .bottom)
                }
                .zIndex(0)
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).appFont(26, .bold)
                    Text(meta).appFont(13).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if item.isSeries {
                            Button { playSeries() } label: { Label(resumeEpisode == nil ? "Play" : "Resume", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large)
                                .disabled(detail == nil)
                        } else {
                            Button { if let container, let m = movie ?? asMovie { Play.movie(m, container) } } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large)
                        }
                        Button { state.toggleFavorite(item.id, kind: item.kind) } label: { Image(systemName: state.isFavorite(item.id) ? "heart.fill" : "heart").frame(width: 24, height: 24).symbolEffect(.bounce, value: state.isFavorite(item.id)) }
                            .buttonStyle(.bordered).controlSize(.large).tint(state.isFavorite(item.id) ? .pink : nil).accessibilityLabel(state.isFavorite(item.id) ? "Remove from favourites" : "Add to favourites")
                    }
                    if let overview = (movie?.overview ?? detail?.series.overview ?? item.overview), !overview.isEmpty {
                        Text(overview).appFont(14).foregroundStyle(.white.opacity(0.85))
                    }
                    trailerButton
                    facts
                    if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                    if item.isSeries { episodes }
                }.padding(.horizontal, 16).frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity).background(ColorTokens.background).zIndex(1)      // slides over the banner as it recedes
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, v in scrollY = v }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline).clearTopBar()
        .toolbar { TrailingPills { Menu { CollectionMenu(itemID: item.id, kind: item.kind) } label: { Image(systemName: "ellipsis.circle").pillIcon() } } }
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
            Label(hasTrailer ? "Watch Trailer" : "Find Trailer on YouTube", systemImage: hasTrailer ? "play.rectangle.fill" : "magnifyingglass")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).controlSize(.large)
        .fullScreenCover(isPresented: $showTrailer) { if let k = trailerKey { TrailerSheet(key: k, title: item.title) } }
        .fullScreenCover(isPresented: $showClip) { if let u = previewClip { ClipSheet(url: u) } }
        .sheet(isPresented: $showSearch) { if let u = searchURL { SafariView(url: u).ignoresSafeArea() } }
    }

    private var searchURL: URL? {
        var c = URLComponents(string: "https://www.youtube.com/results")
        c?.queryItems = [URLQueryItem(name: "search_query", value: "\(item.title) \(item.year.map(String.init) ?? "") official trailer")]
        return c?.url
    }

    /// What the playlist provider says about the title: age rating, country, director and cast.
    @ViewBuilder private var facts: some View {
        if let e = extras {
            VStack(alignment: .leading, spacing: 8) {
                let line = [e.ageRating, e.country].compactMap { $0 }.joined(separator: " · ")
                if !line.isEmpty { Text(line).appFont(13).foregroundStyle(.secondary) }
                if !e.directors.isEmpty { fact(item.isSeries ? "Creator" : "Director", e.directors.joined(separator: ", ")) }
                if !e.cast.isEmpty { fact("Cast", e.cast.prefix(12).joined(separator: ", ")) }
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
            if extras?.trailerKey == nil {
                let c = MetadataMatchService.Candidate(id: item.id, isSeries: item.isSeries, title: item.title, year: item.year)
                tmdbTrailer = await container.metadata.details(for: c)?.bestTrailer?.key
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
