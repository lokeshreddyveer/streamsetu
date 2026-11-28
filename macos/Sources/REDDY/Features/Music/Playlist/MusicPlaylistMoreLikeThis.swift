import SwiftUI

/// "More like this" under a playlist: songs the playlist's own service recommends from a few songs spread over the list (the same call a song's radio
/// uses), minus what is already in the playlist. Each has a plus button. It is only shown when the service answered with something; when it cannot
/// (offline, a service with no recommendations) the section is simply absent, since it is an extra and not the page.
struct MusicPlaylistMoreLikeThis: View {
    let hub: MusicHub
    let tracks: [MusicTrack]
    /// What the plus button does with a song (add it to this playlist, or ask which playlist for a service's list).
    let onAdd: (MusicTrack) -> Void
    @State private var items: [MusicTrack] = []
    @State private var refresh = 0
    @State private var loading = false
    @Environment(\.reddyAccent) private var accent

    private var seeds: [MusicTrack] { MusicPlaylistSuggestions.seeds(from: tracks) }
    private var taskKey: String { seeds.map(\.uid).joined(separator: ",") + "#\(refresh)" }

    var body: some View {
        // A task on an empty view never runs, so a zero-height line always exists to hold it until there is something to show.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if !items.isEmpty || loading { section }
        }
        .task(id: taskKey) { await load() }
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            HStack {
                Text("More like this").font(Typography.heading).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise").font(MusicTokens.iconMedium) }
                    .musicButton(.icon).disabled(loading).accessibilityLabel("Show other songs").help("Show other songs").atlas("control.music.playlistSuggestionsRefresh")
            }
            if loading && items.isEmpty {
                MusicLoadingView(rows: 4)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(items, id: \.uid) { t in suggestion(t) }
                }
            }
        }
        .padding(.top, MusicSpace.md)
    }

    private func suggestion(_ t: MusicTrack) -> some View {
        HStack(spacing: MusicSpace.sm) {
            Button {
                MusicDebugLog.log("playlist", "play suggestion \(t.uid)")
                hub.play([t], at: 0)
            } label: {
                HStack(spacing: MusicSpace.sm) {
                    MusicArtwork(track: t, size: 44, corner: MusicCorner.control)
                    Text(verbatim: t.title).font(Typography.bodyMedium).lineLimit(1).foregroundStyle(ColorTokens.textPrimary)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Play \(t.title)").atlas("control.music.playlistSuggestionPlay")
            MusicArtistLinks(artists: t.artists, providerID: t.providerID, hub: hub)
                .frame(maxWidth: 220, alignment: .trailing)
            Button {
                onAdd(t)
                items.removeAll { $0.uid == t.uid }
            } label: { Image(systemName: "plus").font(MusicTokens.iconMedium) }
                .musicButton(.glassIcon).accessibilityLabel("Add \(t.title)").help("Add to playlist").atlas("control.music.playlistSuggestionAdd")
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        let seeds = self.seeds
        guard let first = seeds.first, let provider = hub.registry.provider(id: first.providerID) as? any MusicMetadataProvider else { items = []; return }
        loading = true
        defer { loading = false }
        do {
            let found = try await provider.recommendations(seedTrackIDs: seeds.map(\.id), limit: 30)
            guard !Task.isCancelled else { return }
            let lib = hub.library
            items = MusicPlaylistSuggestions.select(found, existing: tracks, blocked: { lib.isBlacklisted($0) })
            MusicDebugLog.log("playlist", "more like this: \(items.count) of \(found.count) kept from \(seeds.count) seeds")
        } catch {
            guard !(error is CancellationError) else { return }
            items = []
            MusicDebugLog.log("playlist", "more like this unavailable: \(error.localizedDescription)")
        }
    }
}

/// The page's loading shape: the final layout's rows at their real height, so nothing shifts when the songs arrive.
struct MusicPlaylistRowsSkeleton: View {
    var rows = 12
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            ForEach(0..<max(1, rows), id: \.self) { _ in MusicSkeletonRow(cover: 44) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .musicSkeletonShimmer()
        .accessibilityElement(children: .ignore).accessibilityLabel(Localized.string("Loading content"))
    }
}
