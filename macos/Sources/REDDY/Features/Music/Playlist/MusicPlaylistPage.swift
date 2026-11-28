import SwiftUI

/// A service's playlist (also an editorial list or a chart): the same header as the person's own playlists (cover, title, owner, description, stat line,
/// Play and Shuffle, icon buttons), a skeleton shaped like the final page while it loads, an error with Retry (or the offline note), an empty state, the
/// songs, and "More like this". Play, Shuffle, Save and Download load every page first, so they cover the whole list.
struct MusicPlaylistPage: View {
    let hub: MusicHub
    let playlist: MusicPlaylist
    @State private var tracks: MusicPagedList<MusicTrack>
    /// Set for a chart or other ranked list: its rows are resolved to verified playable copies (see `MusicChartResolver`).
    @State private var chart: MusicChartSession?
    @State private var mode = MusicPlaylistViewMode.load()
    @State private var working = false
    @Environment(\.musicLayoutClass) private var layoutClass

    init(hub: MusicHub, playlist: MusicPlaylist) {
        self.hub = hub; self.playlist = playlist
        let isChart = MusicChartRules.isChart(title: playlist.name, providerID: playlist.providerID)
        _chart = State(initialValue: isChart ? MusicChartBinding.session(hub: hub, chartID: "playlist:" + playlist.uid) : nil)
        _tracks = State(initialValue: MusicPagedList(describe: { hub.loadError($0) }) { page in
            let source = try MusicDetailSource.metadata(hub, providerID: playlist.providerID)
            // A chart is resolved row by row on the page; any other catalogue-only list shows just the songs with a verified playable copy.
            let finish: @Sendable (MusicPage<MusicTrack>) async -> MusicPage<MusicTrack> = { p in
                guard !isChart, MusicSearchEnrichment.isCatalogueOnly(source.capabilities), MusicCatalogRuntime.shared.isEnabled else { return p }
                let shown = await MusicSearchEnrichment.playableOnly(p.items)
                return MusicPage(items: shown.isEmpty ? p.items : shown, totalCount: p.totalCount, next: p.next)
            }
            // The first page is saved AFTER that filtering, so the next visit shows the finished list at once (and refreshes it behind); later pages are live.
            if page == nil, !isChart {
                return try await MusicPageCache.shared.playlistFirstPage(providerID: playlist.providerID, id: playlist.id) { await finish(try await source.playlistTracks(id: playlist.id, page: nil)) }.page
            }
            return await finish(try await source.playlistTracks(id: playlist.id, page: page))
        })
    }

    private var entity: MusicEntity { .playlist(playlist) }
    private var coverSize: CGFloat { MusicPlaylistPageMetrics.coverSize(layoutClass) }
    private var loaded: Bool { tracks.state == .loaded }
    /// What Save, Queue and the like copy: a chart's verified playable songs, any other list as loaded.
    private var current: [MusicTrack] { chart.map(\.playableTracks) ?? tracks.items }

    var body: some View {
        MusicPageScaffold(hub: hub) {
            header
            content
        }
        .task(id: playlist.uid) { MusicDebugLog.log("playlist", "opened \(playlist.uid) chart=\(chart != nil)") }
    }

    @ViewBuilder private var content: some View {
        Group { stateBody }.task { await tracks.loadIfNeeded() }
    }

    @ViewBuilder private var stateBody: some View {
        switch tracks.state {
        case .idle, .loading:
            MusicPlaylistRowsSkeleton()
        case .failed(let message):
            MusicErrorView(message: message) { Task { await tracks.reload() } }.frame(minHeight: 220)
        case .loaded:
            if tracks.items.isEmpty && !tracks.hasMore {
                MusicEmptyState(symbol: "music.note.list", title: Localized.string("No songs available"),
                                message: Localized.string("This playlist has no songs we can show right now."),
                                actionTitle: Localized.string("Try again")) { Task { await tracks.reload() } }.frame(minHeight: 240)
            } else if let chart {
                MusicChartTracks(hub: hub, list: tracks, session: chart)
            } else {
                MusicTrackList(hub: hub, tracks: tracks.items, listKey: "playlist:" + playlist.uid, showsAlbumByDefault: true,
                               hasMore: tracks.hasMore, loadingMore: tracks.loadingMore, loadFailed: tracks.loadMoreFailed,
                               loadMore: { Task { await tracks.loadMore() } }, retry: { Task { await tracks.loadMore() } },
                               emptyMessage: Localized.string("There are no songs here."), rowStyle: mode.rowStyle)
                MusicPlaylistMoreLikeThis(hub: hub, tracks: tracks.items) { MusicChromeState.shared.addToPlaylist = [$0] }
            }
        }
    }

    // MARK: header

    private var header: some View {
        let items = tracks.items
        let known = max(playlist.trackCount ?? 0, items.count)
        let stats = MusicPlaylistStats.Input(songCount: known, totalMs: MusicPlaylistStats.totalMs(items), lengthIsComplete: loaded && !tracks.hasMore)
        return MusicPlaylistHeader(title: playlist.name, kind: Localized.string("Playlist"), owner: MusicSourceText.clean(playlist.owner), description: MusicSourceText.clean(playlist.summary) ?? "",
                                   stats: loaded || known > 0 ? MusicPlaylistStats.line(stats) : "",
                                   backdrop: MusicPlaylistCover.backdropThumbs(own: playlist.thumbnails, members: items.prefix(MusicPlaylistCoverPlan.scanLimit).map(\.thumbnails), seed: playlist.uid),
                                   cover: { cover(items) }, actions: { actions })
    }

    @ViewBuilder private func cover(_ items: [MusicTrack]) -> some View {
        if playlist.thumbnails.isEmpty, !items.isEmpty {
            MusicPlaylistCoverArt(members: MusicPlaylistCoverPicker.representatives(items), name: playlist.name, size: coverSize, corner: 16)
        } else {
            MusicArtwork(playlist.thumbnails, size: coverSize, corner: 16, subject: .derive(playlist))
        }
    }

    /// Download is offered only for a list of a size the rules allow.
    private var downloadAction: (() -> Void)? {
        let allowed = MusicPlaylistActionRules.canDownloadAll(count: max(playlist.trackCount ?? 0, tracks.items.count))
        if allowed { return { downloadAll() } }
        return nil
    }

    @ViewBuilder private var actions: some View {
        if let chart { MusicChartPlayButtons(hub: hub, session: chart) } else { playButtons }
        Button { saveCopy() } label: { Label("Save to Your library", systemImage: "plus") }
            .musicButton(.secondary, size: .large).disabled(!loaded || working || current.isEmpty)
            .accessibilityLabel("Save a copy to Your library as a playlist").atlas("control.music.albumArtistAndPlaylistPagesSaveACopyToYourLibrary")
        MusicPlaylistIconRow(enabled: loaded && !current.isEmpty,
                             onQueue: { run { all in hub.player.enqueue(all, from: playlist.name) } }, onNext: { run { all in hub.player.playNext(all, from: playlist.name) } },
                             onDownload: downloadAction,
                             onShare: { MusicEntityActions.share(entity, hub: hub) }, mode: $mode)
        Menu {
            Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { Task { await MusicEntityActions.startRadio(entity, hub: hub) } }.atlas("control.music.albumArtistAndPlaylistPagesStartRadio")
            Button("Add to Playlist…", systemImage: "music.note.list") { Task { await MusicEntityActions.addToPlaylist(entity, hub: hub) } }.atlas("control.music.albumArtistAndPlaylistPagesAddToPlaylist")
        } label: { Image(systemName: "ellipsis").font(MusicTokens.iconLarge) }
            .menuStyle(.button).menuIndicator(.hidden).musicButton(.glassIcon, size: .large).fixedSize()
            .accessibilityLabel("More").help("More").atlas("control.music.playlistMoreMenu")
    }

    @ViewBuilder private var playButtons: some View {
        Button { run { all in hub.play(all, at: 0, sourceName: playlist.name, sourceID: playlist.uid) } } label: { Label("Play", systemImage: "play.fill") }
            .musicButton(.hero, size: .large).disabled(!loaded || current.isEmpty).accessibilityLabel("Play all").atlas("control.music.albumArtistAndPlaylistPagesPlayAll")
        Button { run { all in hub.playShuffled(all, sourceName: playlist.name, sourceID: playlist.uid) } } label: { Label("Shuffle", systemImage: "shuffle") }
            .musicButton(.secondary, size: .large).disabled(!loaded || current.isEmpty).accessibilityLabel("Shuffle all").atlas("control.music.albumArtistAndPlaylistPagesShuffleAll")
    }

    // MARK: actions

    /// Runs an action on the WHOLE list: the remaining pages are loaded first, and songs known not to play are left out.
    private func run(_ action: @escaping @MainActor ([MusicTrack]) -> Void) {
        guard !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            let all: [MusicTrack]
            if let chart { all = chart.playableTracks }
            else { let loaded = await MusicPlaylistLoadAll.run(tracks); all = MusicPlaylistListLogic.playable(loaded, failed: hub.player.failedUIDs) }
            guard !all.isEmpty else { MusicDebugLog.log("playlist", "action skipped: nothing playable in \(playlist.uid)"); return }
            action(all)
        }
    }

    private func downloadAll() {
        run { all in
            MusicDebugLog.log("playlist", "download \(all.count) songs of \(playlist.uid)")
            for t in all { hub.downloads.enqueue(t) }
            MusicToasts.shared.show(Localized.plural(all.count, one: "Downloading %@ song.", other: "Downloading %@ songs."))
        }
    }

    private func saveCopy() {
        run { all in
            let made = hub.library.createPlaylist(name: playlist.name, tracks: all)
            if let text = playlist.summary, !text.isEmpty { MusicPlaylistExtras.shared.setDescription(text, for: made.id) }
            MusicToasts.shared.success(Localized.string("Saved %@ to Your library.", made.name))
        }
    }
}
