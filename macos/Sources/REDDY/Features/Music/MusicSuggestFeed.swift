import Foundation

/// Gathers the names the person's own Music already holds (library, history, followed artists, saved albums, playlists, earlier searches) and the
/// starter names, and hands them to the local suggestions. Runs on the main actor only to read the library; the work after that is off it.
@MainActor
enum MusicSuggestFeed {
    private static var lastCount = -1

    static func run(library: MusicLibrary, recents: [String]) async {
        // The library is read again only when its size changed, so opening Search twice does not redo the work.
        let size = library.liked.count + library.history.count + library.followedArtists.count + library.savedAlbums.count + library.playlists.count + recents.count
        guard size != lastCount else { return }
        lastCount = size
        let liked = library.liked
        let history = library.history.prefix(1_500).map(\.track)
        let tracks = liked + history
        let groups: [(kind: MusicLocalSuggestions.Kind, names: [String], weight: Int)] = [
            (.recent, recents, 50),
            (.song, tracks.map(\.title), 6),
            (.artist, tracks.flatMap { $0.artists.map(\.name) } + library.followedArtists.map(\.name), 8),
            (.album, tracks.compactMap { $0.album?.title } + library.savedAlbums.map(\.title), 4),
            (.playlist, library.playlists.map(\.name), 3)
        ]
        await MusicLocalSuggestions.shared.feed(groups)
    }

    /// Forgets what was learned about the person (the privacy wipe); the starter names come back with the next run.
    static func forget() async { lastCount = -1; await MusicLocalSuggestions.shared.reset() }
}
