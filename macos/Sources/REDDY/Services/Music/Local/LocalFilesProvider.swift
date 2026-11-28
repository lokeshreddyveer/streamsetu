import Foundation

/// Plays the music files in folders the person chose. Metadata comes from the files' own tags; nothing leaves the device.
/// Tracks carry `file://` streams, so the matcher is skipped for them. Tracks from other sources can also be answered from a local file with the same title and artist.
struct LocalFilesProvider: MusicMetadataProvider, MusicAudioProvider {
    static let providerID = "local"
    let store: LocalLibraryStore

    init(store: LocalLibraryStore = .shared) { self.store = store }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: Self.providerID, name: "Local files", summary: "Music files in folders you choose on this device.",
                          privacyNote: "Reads only the folders you add. Nothing is uploaded and no network is used.")
    }
    var capabilities: MusicCapabilities { [.search, .tracks, .albums, .artists, .audio] }

    // MARK: mapping

    private func thumbs(_ file: String?) -> [MusicThumbnail] {
        guard let file else { return [] }
        return [MusicThumbnail(url: store.artworkDirectory.appendingPathComponent(file).absoluteString, width: 600, height: 600)]
    }

    func stream(_ e: LocalEntry) -> MusicStream {
        let c = LocalTagText.codec(forExtension: e.ext)
        return MusicStream(url: URL(fileURLWithPath: e.path).absoluteString, codec: c.codec, container: c.container)
    }

    func track(_ e: LocalEntry) -> MusicTrack {
        let artistRef = MusicArtistRef(id: LocalLibraryIndex.artistID(LocalLibraryIndex.primaryArtist(of: e)), name: e.artist)
        let albumRef = MusicAlbumRef(id: LocalLibraryIndex.albumKey(of: e), title: e.album, artists: [artistRef], thumbnails: thumbs(e.artworkFile))
        var t = MusicTrack(id: e.id, providerID: Self.providerID, title: e.title, durationMs: e.durationMs, trackNumber: e.trackNumber, artists: [artistRef],
                           album: albumRef, thumbnails: thumbs(e.artworkFile), directStreams: [stream(e)])
        t.creditBundle = LocalTagCreditMapper.bundle(for: e)
        return t
    }

    func album(_ g: LocalAlbumGroup) -> MusicAlbum {
        MusicAlbum(id: g.id, providerID: Self.providerID, title: g.title, artists: [MusicArtistRef(id: LocalLibraryIndex.artistID(LocalArtistName.primary(g.artist) ?? g.artist), name: g.artist)],
                   thumbnails: thumbs(g.artworkFile), totalTracks: g.entries.count)
    }

    func artist(_ g: LocalArtistGroup) -> MusicArtist {
        MusicArtist(id: g.id, providerID: Self.providerID, name: g.name, thumbnails: thumbs(g.artworkFile))
    }

    private func page<T>(_ all: [T], _ page: MusicPagination?) -> MusicPage<T> {
        var offset = 0, limit = 50
        if case .offset(let o, let l)? = page { offset = max(0, o); limit = max(1, l) }
        let slice = Array(all.dropFirst(offset).prefix(limit))
        let next: MusicPagination? = offset + limit < all.count ? .offset(offset: offset + limit, limit: limit) : nil
        return MusicPage(items: slice, totalCount: all.count, next: next)
    }

    // MARK: search

    func searchTracks(_ query: String, page p: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        let hits = await store.currentIndex().search(query, limit: 500)
        return page(hits.tracks.map(track), p)
    }
    func searchAlbums(_ query: String, page p: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        page(await store.currentIndex().search(query, limit: 200).albums.map(album), p)
    }
    func searchArtists(_ query: String, page p: MusicPagination?) async throws -> MusicPage<MusicArtist> {
        page(await store.currentIndex().search(query, limit: 200).artists.map(artist), p)
    }

    // MARK: lookups

    func track(id: String) async throws -> MusicTrack {
        guard let e = await store.currentIndex().entry(id: id) else { throw MusicError.notFound }
        return track(e)
    }
    func album(id: String) async throws -> MusicAlbum {
        guard let g = await store.currentIndex().album(id: id) else { throw MusicError.notFound }
        return album(g)
    }
    func albumTracks(id: String, page p: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        guard let g = await store.currentIndex().album(id: id) else { throw MusicError.notFound }
        return page(g.entries.map(track), p)
    }
    func artist(id: String) async throws -> MusicArtist {
        guard let g = await store.currentIndex().artist(id: id) else { throw MusicError.notFound }
        return artist(g)
    }
    func artistTopTracks(id: String) async throws -> [MusicTrack] {
        guard let g = await store.currentIndex().artist(id: id) else { throw MusicError.notFound }
        return g.entries.prefix(20).map(track)
    }
    func artistAlbums(id: String, page p: MusicPagination?) async throws -> MusicPage<MusicAlbum> {
        let idx = await store.currentIndex()
        guard let g = idx.artist(id: id) else { throw MusicError.notFound }
        return page(idx.albums(of: g).map(album), p)
    }
    /// Everything in the index, for a "Local files" shelf.
    func allTracks() async -> [MusicTrack] { await store.currentIndex().entries.sorted(by: LocalLibraryIndex.trackOrder).map(track) }

    // MARK: audio

    func sources(for t: MusicTrack) async throws -> [MusicAudioSource] {
        let idx = await store.currentIndex()
        let hit: LocalEntry?
        if t.providerID == Self.providerID { hit = idx.entry(id: t.id) } else { hit = idx.match(title: t.title, artist: t.artists.first?.name ?? "", durationMs: t.durationMs) }
        guard let e = hit else { return [] }
        let exact = t.providerID == Self.providerID
        return [MusicAudioSource(id: e.id, providerID: Self.providerID, title: e.title, artist: e.artist, album: e.album, durationMs: e.durationMs,
                                 thumbnails: thumbs(e.artworkFile), externalURL: nil, confidence: exact ? 1 : 0.9, streams: [stream(e)])]
    }

    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        if let s = source.streams, !s.isEmpty { return s }
        guard let e = await store.currentIndex().entry(id: source.id) else { throw MusicError.notFound }
        return [stream(e)]
    }
}
