import Foundation

/// What a source said about an album or a playlist, saved so the next page that needs it (the same album from another artist's page, from search, from
/// Home, from a link) has it at once while a quiet refresh runs behind it. The saving, the one-request-per-key rule, the retry and the fall back to an
/// older copy when the source is down are all `MusicFetch`; this only says what a page of songs is worth. Only the FIRST page of a list is saved; later
/// pages are fetched live.
actor MusicPageCache {
    static let shared = MusicPageCache()

    /// An album's songs depend on the store the person is in (the same album id can list no songs in one country and all of them in another), so the country is
    /// part of the saved key: a list saved under one country is never served after the country changes.
    static var storefront: String { MusicCatalogRuntime.shared.country ?? "" }

    struct Tracks: Codable, Sendable { var tracks: [MusicTrack]; var total: Int?; var next: MusicPagination? }

    /// The first page of an album's songs.
    func albumTracksFirstPage(provider: any MusicMetadataProvider, id: String) async throws -> (page: MusicPage<MusicTrack>, cached: Bool) {
        try await firstPage(MusicFetch.key(provider.id, "albumTracks", id, Self.storefront), MusicFetch.Kind.albumPage) { try await provider.albumTracks(id: id, page: nil) }
    }

    /// The first page of a playlist's songs, AFTER whatever the caller does to it (`fetch` returns the finished page: the playable-only filter of a
    /// catalogue source, for one).
    func playlistFirstPage(providerID: String, id: String, fetch: @escaping @Sendable () async throws -> MusicPage<MusicTrack>) async throws -> (page: MusicPage<MusicTrack>, cached: Bool) {
        try await firstPage(MusicFetch.key(providerID, "playlistTracks", id), MusicFetch.Kind.playlist, fetch)
    }

    /// The album's own facts (year, type, artists).
    func album(provider: any MusicMetadataProvider, id: String) async -> MusicAlbum? {
        try? await MusicFetch.shared.value(MusicFetch.key(provider.id, "album", id, Self.storefront), policy: MusicFetch.Kind.albumPage) { try await provider.album(id: id) }.value
    }

    /// Drops the saved songs and facts of one album, so the next read asks the source (Refresh metadata; a folder of local files, whose songs change under the app).
    func forgetAlbum(providerID: String, id: String) async {
        await MusicFetch.shared.forget(prefix: MusicFetch.key(providerID, "albumTracks", id, Self.storefront))
        await MusicFetch.shared.forget(prefix: MusicFetch.key(providerID, "album", id, Self.storefront))
    }

    /// The privacy wipe.
    func wipe() async { await MusicFetch.shared.wipe() }

    private func firstPage(_ key: String, _ policy: MusicFetch.Policy, _ fetch: @escaping @Sendable () async throws -> MusicPage<MusicTrack>) async throws -> (page: MusicPage<MusicTrack>, cached: Bool) {
        let a = try await MusicFetch.shared.value(key, policy: policy, keep: { !$0.tracks.isEmpty }) {
            let p = try await fetch()
            return Tracks(tracks: p.items, total: p.totalCount, next: p.next)
        }
        return (MusicPage(items: a.value.tracks, totalCount: a.value.total, next: a.value.next), a.source != .network)
    }
}
