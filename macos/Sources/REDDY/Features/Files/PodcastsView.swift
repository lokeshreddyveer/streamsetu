import SwiftUI

/// What the Podcasts screens do, with no layout: the shows followed, the search of the public directory (or a pasted feed address), and unfollowing.
/// The Files window list and the main-window screen both use it, so there is one behaviour over the one `PodcastService`.
@MainActor @Observable
final class PodcastsBrowseModel {
    var subscriptions: [PodcastSubscription] = []
    var term = ""
    var found: [PodcastSubscription] = []
    var searching = false
    var message: String?
    var service: PodcastService?
    private var task: Task<Void, Never>?

    func reload() { subscriptions = service?.subscriptions() ?? [] }

    func unfollow(_ s: PodcastSubscription) { service?.unsubscribe(s.feedURL); reload() }

    func search() {
        let words = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let service else { return }
        task?.cancel()
        message = nil; found = []; searching = true
        task = Task {
            defer { searching = false }
            do {
                if let url = URL(string: words), url.scheme?.hasPrefix("http") == true {          // a feed address
                    let sub = try await service.subscribe(url)
                    reload(); term = ""; message = "Following \(sub.title)."
                } else {
                    let r = try await service.search(words)
                    guard !Task.isCancelled else { return }
                    found = r; if r.isEmpty { message = "No shows found." }
                }
            } catch { message = error.localizedDescription }
        }
    }

    func cancel() { task?.cancel() }
}

/// Podcasts: the shows the person follows, a search of Apple's public directory, and a way to paste a feed address.
struct PodcastsView: View {
    @Environment(\.container) private var container
    @State private var model = PodcastsBrowseModel()

    var body: some View {
        List {
            if !model.subscriptions.isEmpty {
                Section("Following") {
                    ForEach(model.subscriptions) { s in
                        NavigationLink { PodcastDetailView(show: s) } label: { PodcastRow(show: s) }
                            .contextMenu { Button("Unfollow", role: .destructive) { model.unfollow(s) } }.atlas("context.podcasts.show")
                    }
                    .onDelete { idx in idx.map { model.subscriptions[$0] }.forEach { model.unfollow($0) } }
                }
            }
            Section {
                TextField("Search shows, or paste a feed address", text: $model.term).onSubmit { model.search() }
                if model.searching { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking…").foregroundStyle(.secondary) } }
                ForEach(model.found) { s in
                    NavigationLink { PodcastDetailView(show: s) } label: { PodcastRow(show: s) }.atlas("screen.podcasts")
                }
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
            } header: { Text("Find a show") } footer: { Text("Search uses Apple's public podcast directory. Nothing about you is sent besides the words you search for.") }
        }
        .navigationTitle("Podcasts")
        .onAppear { model.service = container?.podcasts; model.reload() }
    }
}

struct PodcastRow: View {
    let show: PodcastSubscription
    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(url: show.artwork?.absoluteString, kind: .poster, contentMode: .fill, symbol: "mic.fill")
                .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title).lineLimit(2)
                if !show.author.isEmpty { Text(show.author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}

/// One show: its episodes, whether it is followed, and playing an episode (the player remembers the place).
@MainActor @Observable
final class PodcastShowModel {
    let show: PodcastSubscription
    var feed: PodcastFeed?
    var error: String?
    var following = false
    var container: AppContainer?

    init(show: PodcastSubscription) { self.show = show }

    func load() async {
        following = container?.podcasts.isSubscribed(show.feedURL) ?? false
        do { feed = try await container?.podcasts.load(show.feedURL) } catch { self.error = error.localizedDescription }
    }

    func toggle() {
        guard let service = container?.podcasts else { return }
        if following { service.unsubscribe(show.feedURL); following = false }
        else { Task { if (try? await service.subscribe(show.feedURL)) != nil { following = true } } }
    }

    func play(_ e: PodcastEpisode) {
        #if os(macOS)
        PodcastsHub.shared.play(e, of: show, showArtwork: feed?.artwork)          // the audio player: no video dialog
        #else
        FilesPlayer.play(file: e.audioURL, title: e.title, container: container)
        #endif
    }
}

/// One show: follow or unfollow it, and play its episodes.
struct PodcastDetailView: View {
    let show: PodcastSubscription
    @Environment(\.container) private var container
    @State private var model: PodcastShowModel

    init(show: PodcastSubscription) { self.show = show; _model = State(initialValue: PodcastShowModel(show: show)) }

    var body: some View {
        List {
            if let feed = model.feed {
                Section {
                    ForEach(feed.episodes.prefix(200)) { e in
                        Button { model.play(e) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(e.title).font(.body.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                                Text([e.published.map { $0.formatted(date: .abbreviated, time: .omitted) }, e.duration.map(Self.length)].compactMap { $0 }.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary)
                                if !e.summary.isEmpty { Text(e.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).atlas("control.podcasts.play")
                    }
                } header: { Text("\(feed.episodes.count) episodes") }
            } else if let error = model.error {
                Text(error).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading episodes…").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(show.title)
        .toolbar {
            ToolbarItem { Button(model.following ? "Unfollow" : "Follow") { model.toggle() }.disabled(model.feed == nil && !model.following).atlas("control.podcasts.follow") }
        }
        .task { model.container = container; await model.load() }
    }

    static func length(_ s: TimeInterval) -> String {
        let t = Int(s); let h = t / 3600, m = (t % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(max(m, 1)) min"
    }
}
