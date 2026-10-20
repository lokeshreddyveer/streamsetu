import SwiftUI

/// Podcasts: the shows the person follows, a search of Apple's public directory, and a way to paste a feed address.
struct PodcastsView: View {
    @Environment(\.container) private var container
    @State private var subscriptions: [PodcastSubscription] = []
    @State private var term = ""
    @State private var found: [PodcastSubscription] = []
    @State private var searching = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?

    private var service: PodcastService? { container?.podcasts }

    var body: some View {
        List {
            if !subscriptions.isEmpty {
                Section("Following") {
                    ForEach(subscriptions) { s in
                        NavigationLink { PodcastDetailView(show: s) } label: { PodcastRow(show: s) }
                            .contextMenu { Button("Unfollow", role: .destructive) { service?.unsubscribe(s.feedURL); reload() } }
                    }
                    .onDelete { idx in idx.map { subscriptions[$0] }.forEach { service?.unsubscribe($0.feedURL) }; reload() }
                }
            }
            Section {
                TextField("Search shows, or paste a feed address", text: $term).onSubmit { search() }
                if searching { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking…").foregroundStyle(.secondary) } }
                ForEach(found) { s in
                    NavigationLink { PodcastDetailView(show: s) } label: { PodcastRow(show: s) }
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            } header: { Text("Find a show") } footer: { Text("Search uses Apple's public podcast directory. Nothing about you is sent besides the words you search for.") }
        }
        .navigationTitle("Podcasts")
        .onAppear { reload() }
    }

    private func reload() { subscriptions = service?.subscriptions() ?? [] }

    private func search() {
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
}

private struct PodcastRow: View {
    let show: PodcastSubscription
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: show.artwork) { img in img.resizable().scaledToFill() } placeholder: { Rectangle().fill(.quaternary).overlay(Image(systemName: "mic.fill").foregroundStyle(.secondary)) }
                .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title).lineLimit(2)
                if !show.author.isEmpty { Text(show.author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}

/// One show: follow or unfollow it, and play its episodes.
struct PodcastDetailView: View {
    let show: PodcastSubscription
    @Environment(\.container) private var container
    @State private var feed: PodcastFeed?
    @State private var error: String?
    @State private var following = false

    var body: some View {
        List {
            if let feed {
                Section {
                    ForEach(feed.episodes.prefix(200)) { e in
                        Button { play(e) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(e.title).font(.body.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                                Text([e.published.map { $0.formatted(date: .abbreviated, time: .omitted) }, e.duration.map(Self.length)].compactMap { $0 }.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary)
                                if !e.summary.isEmpty { Text(e.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                } header: { Text("\(feed.episodes.count) episodes") }
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading episodes…").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(show.title)
        .toolbar {
            ToolbarItem { Button(following ? "Unfollow" : "Follow") { toggle() }.disabled(feed == nil && !following) }
        }
        .task {
            following = container?.podcasts.isSubscribed(show.feedURL) ?? false
            do { feed = try await container?.podcasts.load(show.feedURL) } catch { self.error = error.localizedDescription }
        }
    }

    private func toggle() {
        guard let service = container?.podcasts else { return }
        if following { service.unsubscribe(show.feedURL); following = false }
        else { Task { if (try? await service.subscribe(show.feedURL)) != nil { following = true } } }
    }

    private func play(_ e: PodcastEpisode) { FilesPlayer.play(file: e.audioURL, title: e.title, container: container) }

    static func length(_ s: TimeInterval) -> String {
        let t = Int(s); let h = t / 3600, m = (t % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(max(m, 1)) min"
    }
}
