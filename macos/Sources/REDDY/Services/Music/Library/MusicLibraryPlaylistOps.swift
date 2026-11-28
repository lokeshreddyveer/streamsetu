import Foundation

// The playlist tools applied to the person's own playlists: merging, taking out repeats, making a playlist from an imported file, and the numbers of a
// smart list. They only use the library's ordinary playlist calls, so every change is saved the usual way.

extension MusicLibrary {
    /// A new playlist with the songs of the given playlists one after the other. Repeats are left out unless asked for. With `deleteSources` the playlists it
    /// was made from are removed afterwards. Returns nil when fewer than two playlists exist among the ids.
    @discardableResult
    func mergePlaylists(_ ids: [UUID], name: String? = nil, dropRepeats: Bool = true, deleteSources: Bool = false) -> LocalPlaylist? {
        let sources = ids.compactMap { id in playlists.first { $0.id == id } }
        guard sources.count >= 2 else { return nil }
        let merged = MusicPlaylistMerge.merge(sources.map(\.tracks), dropRepeats: dropRepeats)
        let title = (name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? MusicPlaylistMerge.name(for: sources.map(\.name))
        let made = createPlaylist(name: title, tracks: merged)
        if deleteSources { for s in sources { delete(s.id) } }
        MusicDebugLog.log("playlist", "merged \(sources.count) playlists into \(made.tracks.count) songs (repeats \(dropRepeats ? "left out" : "kept"), sources \(deleteSources ? "deleted" : "kept"))")
        return made
    }

    /// Takes the repeated recordings out of one playlist (the first copy stays). Returns the songs it removed.
    @discardableResult
    func removeRepeats(in id: UUID) -> [MusicTrack] {
        guard let p = playlist(id: id) else { return [] }
        let r = MusicPlaylistDuplicates.removing(p.tracks)
        guard !r.removed.isEmpty else { return [] }
        replaceTracks(r.kept, in: id)
        MusicDebugLog.log("playlist", "removed \(r.removed.count) repeats from a playlist of \(p.tracks.count)")
        return r.removed
    }

    /// A playlist made from songs found for an imported file. The file's own name is used when no better one is given.
    @discardableResult
    func makePlaylist(fromImport name: String, tracks: [MusicTrack]) -> LocalPlaylist {
        let made = createPlaylist(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? Localized.string("Imported playlist") : name, tracks: tracks)
        MusicDebugLog.log("playlist", "imported playlist with \(made.tracks.count) songs")
        return made
    }

    /// The songs a smart playlist holds right now: the library's liked songs, played songs and playlist songs that match its rules.
    func smartTracks(for list: MusicSmartPlaylist, seed: UInt64 = 1) -> [MusicTrack] {
        let fromPlaylists = playlists.flatMap(\.tracks)
        let pool = liked + history.map(\.track) + fromPlaylists
        let signals = MusicSmartSignals.build(history: history, liked: liked)
        return MusicSmartEvaluator.tracks(for: list, in: pool, signals: signals, seed: seed)
    }
}
