import SwiftUI

/// What a connected account holds, shown as its own tab on the Library page. It exists only while that account is connected.
/// Each part loads on its own, and a part that fails shows a short message and a retry, never a sign-in prompt.
struct MusicAccountLibraryTab: View {
    let hub: MusicHub
    let source: MusicLibrarySource
    @State private var playlists: MusicLoad<[MusicPlaylist]>?
    @State private var albums: MusicLoad<[MusicAlbum]>?
    @State private var artists: MusicLoad<[MusicArtist]>?
    @State private var songs: MusicLoad<[MusicTrack]>?
    private static let songLimit = 500

    private var failedCount: Int { [failed(songs), failed(playlists), failed(albums), failed(artists)].filter { $0 }.count }
    private var loadedCount: Int { [loaded(songs), loaded(playlists), loaded(albums), loaded(artists)].filter { $0 }.count }
    private func failed<V>(_ s: MusicLoad<[V]>?) -> Bool { if case .failed? = s { return true }; return false }
    private func loaded<V>(_ s: MusicLoad<[V]>?) -> Bool { if case .loaded? = s { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.lg) {
            if MusicPartialFailure.showsFullError(healthy: loadedCount, failed: failedCount) {
                MusicErrorState(title: Localized.string("Could not load this library"), message: Localized.string("Your library on this Mac is not affected. Try again in a moment."),
                                retryTitle: Localized.string("Try again")) { Task { await loadAll() } }
            } else if MusicPartialFailure.showsBanner(healthy: loadedCount, failed: failedCount) {
                MusicPartialFailureBanner(message: Localized.string("Some parts of this library could not be loaded."), onRetry: { Task { await retryFailed() } })
                    .frame(minHeight: MusicTokens.hitTarget)
            }
            part(Localized.string("Songs"), songs) { list in
                HStack(spacing: MusicSpace.sm) { MusicPlayShuffleButtons(hub: hub, tracks: list, sourceName: Localized.string("Songs")) }
                MusicTrackList(hub: hub, tracks: Array(list.prefix(Self.songLimit)), listKey: "account-songs", showsTools: false, presorted: true, prefetchOwner: "library:account-songs")
                if list.count > Self.songLimit {
                    Text(verbatim: Localized.string("Showing the first %d of %d songs.", Self.songLimit, list.count)).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                }
            }
            part(Localized.string("Playlists"), playlists) { list in
                LazyVGrid(columns: MusicLayout.gridColumns, spacing: MusicSpace.md) { ForEach(list) { p in MusicCard(playlist: p, hub: hub) } }
            }
            part(Localized.string("Albums"), albums) { list in
                LazyVGrid(columns: MusicLayout.gridColumns, spacing: MusicSpace.md) { ForEach(list) { a in MusicCard(album: a, hub: hub) } }
            }
            part(Localized.string("Artists"), artists) { list in
                LazyVGrid(columns: MusicLayout.gridColumns, spacing: MusicSpace.md) { ForEach(list) { a in MusicCard(artist: a, hub: hub) } }
            }
        }
        .task(id: "\(source)|\(ytLibrary != nil)|\(spotify != nil)") { await loadAll() }
    }

    /// A part that is loading shows placeholders of its final size; one that failed shows nothing (the banner above says so); an empty one is left out.
    @ViewBuilder private func part<V, C: View>(_ title: String, _ state: MusicLoad<[V]>?, @ViewBuilder content: ([V]) -> C) -> some View {
        switch state {
        case nil, .loading?:
            VStack(alignment: .leading, spacing: MusicSpace.xs) { MusicSectionTitle(title: title); MusicShelfSkeleton() }
        case .failed?:
            EmptyView()
        case .loaded(let list)?:
            if !list.isEmpty { VStack(alignment: .leading, spacing: MusicSpace.xs) { MusicSectionTitle(title: title); content(list) } }
        }
    }

    private func retryFailed() async {
        if failed(songs) { await loadSongs() }
        if failed(playlists) { await loadPlaylists() }
        if failed(albums) { await loadAlbums() }
        if failed(artists) { await loadArtists() }
    }

    private func loadAll() async {
        async let a: Void = loadSongs(); async let b: Void = loadPlaylists(); async let c: Void = loadAlbums(); async let d: Void = loadArtists()
        _ = await (a, b, c, d)
    }

    private func run<V: Sendable>(_ set: (MusicLoad<[V]>?) -> Void, _ op: @escaping () async throws -> [V]) async {
        set(.loading)
        do { let r = try await op(); if !Task.isCancelled { set(.loaded(r)) } }
        catch { if !Task.isCancelled { set(.failed(hub.loadError(error))) } }
    }

    private var ytLibrary: YouTubeMusicLibrary? { YouTubeMusicAccountBuiltIns.manager?.library }
    private var spotify: (any MusicMetadataProvider)? { hub.registry.metadataProvider(id: "spotify") }

    private func loadSongs() async {
        switch source {
        case .youTubeMusic: guard let l = ytLibrary else { songs = .loaded([]); return }; await run({ songs = $0 }) { try await l.songs() }
        case .spotify: guard let p = spotify else { songs = .loaded([]); return }; await run({ songs = $0 }) { try await p.savedTracks(page: nil).items }
        case .local: songs = .loaded([])
        }
    }
    private func loadPlaylists() async {
        switch source {
        case .youTubeMusic: guard let l = ytLibrary else { playlists = .loaded([]); return }; await run({ playlists = $0 }) { try await l.playlists() }
        case .spotify: guard let p = spotify else { playlists = .loaded([]); return }; await run({ playlists = $0 }) { try await p.savedPlaylists(page: nil).items }
        case .local: playlists = .loaded([])
        }
    }
    private func loadAlbums() async {
        switch source {
        case .youTubeMusic: guard let l = ytLibrary else { albums = .loaded([]); return }; await run({ albums = $0 }) { try await l.albums() }
        case .spotify: guard let p = spotify else { albums = .loaded([]); return }; await run({ albums = $0 }) { try await p.savedAlbums(page: nil).items }
        case .local: albums = .loaded([])
        }
    }
    private func loadArtists() async {
        switch source {
        case .youTubeMusic: guard let l = ytLibrary else { artists = .loaded([]); return }; await run({ artists = $0 }) { try await l.artists() }
        case .spotify: guard let p = spotify else { artists = .loaded([]); return }; await run({ artists = $0 }) { try await p.savedArtists(page: nil).items }
        case .local: artists = .loaded([])
        }
    }
}
