import SwiftUI
import WebKit
import AVKit

/// A title's trailer and the extra facts its provider sends (age rating, country, director, cast), for the movie and series pages.
/// The trailer comes from the provider, or from TMDB when a key is set; with neither, the button searches YouTube in a window of its own.
struct TrailerSection: View {
    let itemID: String
    let title: String
    let year: Int?
    let isSeries: Bool
    @Environment(\.container) private var container
    @State private var extras: ProviderExtras?
    @State private var tmdbTrailer: String?
    @State private var show: TrailerPage?
    @State private var clip: URL?
    @State private var showClip = false

    private struct TrailerPage: Identifiable { let url: URL; let embed: String?; var id: URL { url } }
    private var key: String? { extras?.trailerKey ?? tmdbTrailer }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SecondaryButton(title: key != nil || clip != nil ? "Watch Trailer" : "Find Trailer on YouTube", symbol: key != nil || clip != nil ? "play.rectangle.fill" : "magnifyingglass") {
                if key == nil, clip != nil { showClip = true; return }
                show = key.map { TrailerPage(url: URL(string: "https://www.youtube.com/watch?v=\($0)")!, embed: $0) } ?? searchPage
            }
            if let e = extras {
                let line = [e.ageRating, e.country].compactMap { $0 }.joined(separator: " · ")
                if !line.isEmpty { Text(line).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                if !e.directors.isEmpty { fact(isSeries ? "Creator" : "Director", e.directors.joined(separator: ", ")) }
                if !e.cast.isEmpty { fact("Cast", e.cast.prefix(12).joined(separator: ", ")) }
            }
        }
        .task(id: itemID) { await load() }
        .sheet(isPresented: $showClip) {
            ZStack(alignment: .topTrailing) {
                if let clip { VideoPlayer(player: AVPlayer(url: clip)).frame(minWidth: 820, minHeight: 480) }
                IconButton(symbol: "xmark", help: "Close") { showClip = false }.padding(Spacing.md)
            }
        }
        .sheet(item: $show) { page in
            ZStack(alignment: .topTrailing) {
                TrailerWebView(url: page.url, embedKey: page.embed).frame(minWidth: 820, minHeight: 500)
                IconButton(symbol: "xmark", help: "Close") { show = nil }.padding(Spacing.md)
            }
        }
    }

    private var searchPage: TrailerPage? {
        var c = URLComponents(string: "https://www.youtube.com/results")
        c?.queryItems = [URLQueryItem(name: "search_query", value: "\(title) \(year.map(String.init) ?? "") official trailer")]
        return c?.url.map { TrailerPage(url: $0, embed: nil) }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            Text(value).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load() async {
        guard let c = container else { return }
        extras = isSeries ? await c.details.extras(series: itemID) : await c.details.extras(movie: itemID)
        if extras?.trailerKey == nil {
            let cand = MetadataMatchService.Candidate(id: itemID, isSeries: isSeries, title: title, year: year)
            tmdbTrailer = await c.metadata.details(for: cand)?.bestTrailer?.key
            if tmdbTrailer == nil { clip = await TrailerLookup.find(title: title, year: year, isSeries: isSeries) }
        }
    }
}

private struct TrailerWebView: NSViewRepresentable {
    let url: URL
    let embedKey: String?

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: cfg)
        if let k = embedKey {
            let origin = "https://\(Bundle.main.bundleIdentifier ?? "app.streamsetu.mac")"
            let html = "<html><body style='margin:0;background:#000'><iframe width='100%' height='100%' src='https://www.youtube.com/embed/\(k)?autoplay=1&rel=0&origin=\(origin)' frameborder='0' allow='autoplay; encrypted-media; fullscreen' allowfullscreen style='position:absolute;inset:0;border:0'></iframe></body></html>"
            v.loadHTMLString(html, baseURL: URL(string: origin))
        } else {
            v.load(URLRequest(url: url))
        }
        return v
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
