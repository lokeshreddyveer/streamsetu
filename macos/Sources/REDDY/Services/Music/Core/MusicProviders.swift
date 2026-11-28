import Foundation

// Provider contracts. A provider is ONE source (Spotify, Audius, a JS plugin...). It declares which capabilities it has; the registry
// routes calls to the active provider for each capability. Unsupported calls throw `MusicError.unsupported` (default implementations below),
// so a provider only writes what it offers.

struct MusicCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let search = Self(rawValue: 1 << 0), browse = Self(rawValue: 1 << 1), tracks = Self(rawValue: 1 << 2), albums = Self(rawValue: 1 << 3)
    static let artists = Self(rawValue: 1 << 4), playlists = Self(rawValue: 1 << 5), users = Self(rawValue: 1 << 6), audio = Self(rawValue: 1 << 7)
    static let lyrics = Self(rawValue: 1 << 8), scrobble = Self(rawValue: 1 << 9), library = Self(rawValue: 1 << 10)
    /// A source that only DESCRIBES songs (no audio of its own). Its songs are shown only after a playable twin is verified; it still serves browse pages.
    static let catalogue = Self(rawValue: 1 << 11)
    static let metadata: Self = [.search, .browse, .tracks, .albums, .artists, .playlists, .users]
}

enum MusicProviderKind: String, Codable, Sendable { case builtIn, plugin }

struct MusicProviderInfo: Codable, Hashable, Sendable, Identifiable {
    var id: String; var name: String; var summary: String; var version: String = "1.0.0"; var kind: MusicProviderKind = .builtIn
    var requiresSignIn: Bool = false
    /// Shown in Settings so the person knows what leaves the device when it is on.
    var privacyNote: String = ""
    var homepage: String? = nil
}

protocol MusicProvider: Sendable {
    var info: MusicProviderInfo { get }
    var capabilities: MusicCapabilities { get }
    var isSignedIn: Bool { get async }
    func signIn() async throws
    func signOut() async
}
extension MusicProvider {
    var id: String { info.id }
    var isSignedIn: Bool { get async { !info.requiresSignIn } }
    func signIn() async throws { throw MusicError.unsupported("sign in") }
    func signOut() async {}
}

protocol MusicMetadataProvider: MusicProvider {
    func search(_ query: String, types: Set<MusicSearchType>) async throws -> [MusicSearchResult]
    func searchTracks(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack>
    func searchArtists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicArtist>
    func searchAlbums(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum>
    func searchPlaylists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicPlaylist>

    func featured() async throws -> [MusicBrowseSection]
    func genres() async throws -> [MusicBrowseGenre]
    func browse(genreID: String, page: MusicPagination?) async throws -> MusicPage<MusicBrowseSection>

    func track(id: String) async throws -> MusicTrack
    func recommendations(seedTrackIDs: [String], limit: Int) async throws -> [MusicTrack]

    func album(id: String) async throws -> MusicAlbum
    func albumTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack>

    func artist(id: String) async throws -> MusicArtist
    func artistOverview(id: String) async throws -> MusicArtistOverview
    func artistTopTracks(id: String) async throws -> [MusicTrack]
    func artistAlbums(id: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum>
    func relatedArtists(id: String) async throws -> [MusicArtist]

    func playlist(id: String) async throws -> MusicPlaylist
    func playlistTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack>

    func user(id: String) async throws -> MusicUser?

    // The signed in person's own library on that service.
    func savedTracks(page: MusicPagination?) async throws -> MusicPage<MusicTrack>
    func savedAlbums(page: MusicPagination?) async throws -> MusicPage<MusicAlbum>
    func savedArtists(page: MusicPagination?) async throws -> MusicPage<MusicArtist>
    func savedPlaylists(page: MusicPagination?) async throws -> MusicPage<MusicPlaylist>
    func setSaved(_ saved: Bool, trackIDs: [String]) async throws
    func isSaved(trackIDs: [String]) async throws -> [Bool]
}

extension MusicMetadataProvider {
    func search(_ query: String, types: Set<MusicSearchType>) async throws -> [MusicSearchResult] {
        var out: [MusicSearchResult] = []
        if types.contains(.track) { out += try await searchTracks(query, page: nil).items.map { .track($0) } }
        if types.contains(.artist) { out += ((try? await searchArtists(query, page: nil))?.items ?? []).map { .artist($0) } }
        if types.contains(.album) { out += ((try? await searchAlbums(query, page: nil))?.items ?? []).map { .album($0) } }
        if types.contains(.playlist) { out += ((try? await searchPlaylists(query, page: nil))?.items ?? []).map { .playlist($0) } }
        return out
    }
    func searchTracks(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> { throw MusicError.unsupported("track search") }
    func searchArtists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicArtist> { throw MusicError.unsupported("artist search") }
    func searchAlbums(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> { throw MusicError.unsupported("album search") }
    func searchPlaylists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicPlaylist> { throw MusicError.unsupported("playlist search") }
    func featured() async throws -> [MusicBrowseSection] { throw MusicError.unsupported("browse") }
    func genres() async throws -> [MusicBrowseGenre] { throw MusicError.unsupported("genres") }
    func browse(genreID: String, page: MusicPagination?) async throws -> MusicPage<MusicBrowseSection> { throw MusicError.unsupported("browse") }
    func track(id: String) async throws -> MusicTrack { throw MusicError.unsupported("track") }
    func recommendations(seedTrackIDs: [String], limit: Int) async throws -> [MusicTrack] { throw MusicError.unsupported("recommendations") }
    func album(id: String) async throws -> MusicAlbum { throw MusicError.unsupported("album") }
    func albumTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> { throw MusicError.unsupported("album tracks") }
    func artist(id: String) async throws -> MusicArtist { throw MusicError.unsupported("artist") }
    func artistOverview(id: String) async throws -> MusicArtistOverview {
        async let a = artist(id: id)
        async let t = artistTopTracks(id: id)
        async let al = artistAlbums(id: id, page: nil)
        let rel = (try? await relatedArtists(id: id)) ?? []
        return MusicArtistOverview(artist: try await a, topTracks: (try? await t) ?? [], albums: (try? await al)?.items ?? [], related: rel)
    }
    func artistTopTracks(id: String) async throws -> [MusicTrack] { throw MusicError.unsupported("top tracks") }
    func artistAlbums(id: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> { throw MusicError.unsupported("artist albums") }
    func relatedArtists(id: String) async throws -> [MusicArtist] { [] }
    func playlist(id: String) async throws -> MusicPlaylist { throw MusicError.unsupported("playlist") }
    func playlistTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> { throw MusicError.unsupported("playlist tracks") }
    func user(id: String) async throws -> MusicUser? { nil }
    func savedTracks(page: MusicPagination?) async throws -> MusicPage<MusicTrack> { throw MusicError.unsupported("saved tracks") }
    func savedAlbums(page: MusicPagination?) async throws -> MusicPage<MusicAlbum> { throw MusicError.unsupported("saved albums") }
    func savedArtists(page: MusicPagination?) async throws -> MusicPage<MusicArtist> { throw MusicError.unsupported("saved artists") }
    func savedPlaylists(page: MusicPagination?) async throws -> MusicPage<MusicPlaylist> { throw MusicError.unsupported("saved playlists") }
    func setSaved(_ saved: Bool, trackIDs: [String]) async throws { throw MusicError.unsupported("saving tracks") }
    func isSaved(trackIDs: [String]) async throws -> [Bool] { Array(repeating: false, count: trackIDs.count) }
}

/// Finds and resolves playable audio for a track (YouTube through Piped / Invidious, JioSaavn, Audius...).
protocol MusicAudioProvider: MusicProvider {
    /// Candidate recordings for the track, best first. May already carry streams.
    func sources(for track: MusicTrack) async throws -> [MusicAudioSource]
    /// Playable streams for a candidate that has none yet.
    func streams(for source: MusicAudioSource) async throws -> [MusicStream]
}

protocol MusicLyricsProvider: MusicProvider {
    func lyrics(for track: MusicTrack) async throws -> MusicLyrics?
}

protocol MusicScrobbleProvider: MusicProvider {
    func scrobble(_ s: MusicScrobble) async throws
    /// Optional "now playing" ping. Default does nothing.
    func nowPlaying(_ track: MusicTrack) async
}
extension MusicScrobbleProvider { func nowPlaying(_ track: MusicTrack) async {} }
