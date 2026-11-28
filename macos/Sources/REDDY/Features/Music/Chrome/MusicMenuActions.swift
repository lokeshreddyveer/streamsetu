import SwiftUI
#if os(macOS)
import AppKit
#endif

// What the new menu entries do: the song actions (lyrics, hide a recommendation) and the collection actions (download, export, tidy, sort, pick, edit).

@MainActor
enum MusicTrackActions {
    /// Shows the lyrics for the song in the lyrics strip. Lyrics follow the playing song, so a song that is not playing starts first (the menu says so: "Play and View Lyrics").
    static func viewLyrics(_ t: MusicTrack, hub: MusicHub) {
        if hub.player.current?.uid != t.uid { hub.play([t], at: 0, sourceName: t.title) }
        // The strip opens only for a song that is really playing: a refused Play (paused profile, a guest in a room) must not open lyrics for nothing.
        guard hub.player.current?.uid == t.uid else { return }
        MusicSongLyricsOpener.shared.bump()
    }
}

/// The shell watches this and opens the lyrics strip, because only the shell owns the panel state.
@MainActor @Observable
final class MusicSongLyricsOpener {
    static let shared = MusicSongLyricsOpener()
    private(set) var count = 0
    func bump() { count &+= 1 }
}

/// Hide Recommendation: this song, or every song by its artist; once hidden the same place offers to bring it back.
struct MusicHideRecommendationMenu: View {
    let track: MusicTrack
    private var hidden: MusicHiddenRecommendations { .shared }

    var body: some View {
        let songHidden = hidden.set.tracks.contains(track.uid)
        let artist = track.artists.first(where: { !MusicArtistFiller.isFiller($0.name) })
        Menu {
            Button(songHidden ? "Recommend This Song Again" : "Hide This Song", systemImage: songHidden ? "eye" : "eye.slash") {
                if songHidden { hidden.show(track) } else { hidden.hide(track) }
                MusicToasts.shared.show(songHidden ? Localized.string("%@ can be recommended again.", track.title) : Localized.string("%@ will not be recommended.", track.title))
            }.atlas("control.music.songMenusHideSong")
            if let a = artist {
                let artistHidden = hidden.isHidden(artist: a)
                Button(artistHidden ? Localized.string("Recommend %@ Again", a.name) : Localized.string("Hide Songs by %@", a.name), systemImage: artistHidden ? "eye" : "person.crop.circle.badge.xmark") {
                    if artistHidden { hidden.show(artist: a) } else { hidden.hide(artist: a) }
                    MusicToasts.shared.show(artistHidden ? Localized.string("%@ can be recommended again.", a.name) : Localized.string("%@ will not be recommended.", a.name))
                }.atlas("control.music.songMenusHideArtist")
            }
        } label: { Label("Hide Recommendation", systemImage: "eye.slash") }
            .atlas("control.music.songMenusHideRecommendation")
    }
}

@MainActor
enum MusicCollectionActions {
    private static func localID(_ e: MusicEntity) -> UUID? {
        if case .playlist(let p) = e, p.providerID == MusicStatsRules.localProviderID { return UUID(uuidString: p.id) }
        return nil
    }

    private static func title(_ e: MusicEntity) -> String {
        switch e { case .track(let t): t.title; case .album(let a): a.title; case .playlist(let p): p.name; case .artist(let a): a.name }
    }

    /// Queues every song the source lets the person download (the downloader refuses the rest).
    static func download(_ e: MusicEntity, hub: MusicHub) async {
        let list = await MusicEntityActions.tracks(e, hub: hub)
        guard !list.isEmpty else { MusicToasts.shared.show(Localized.string("Nothing to download here yet.")); return }
        for t in list { hub.downloads.enqueue(t) }
        MusicToasts.shared.success(Localized.plural(list.count, one: "Downloading %@ song.", other: "Downloading %@ songs."))
    }

    static func isLocalPlaylist(_ e: MusicEntity) -> Bool { localID(e) != nil }

    static func edit(_ e: MusicEntity) { MusicChromeState.shared.editPlaylist = localID(e) }

    static func select(_ e: MusicEntity, hub: MusicHub) {
        guard let id = localID(e) else { return }
        MusicChromeState.shared.selectOnOpen = id
        hub.open(.localPlaylist(id))
    }

    static func removeDuplicates(_ e: MusicEntity, hub: MusicHub) {
        guard let id = localID(e), let before = hub.library.playlist(id: id)?.tracks else { return }
        let n = MusicPlaylistDuplicates.extraCopies(before)
        guard n > 0 else { MusicToasts.shared.show(Localized.string("No repeated songs found.")); return }
        hub.library.removeRepeats(in: id)
        MusicToasts.shared.show(Localized.plural(n, one: "Removed %@ repeated song.", other: "Removed %@ repeated songs."), kind: .success, actionTitle: Localized.string("Undo")) {
            hub.library.replaceTracks(before, in: id)
        }
    }

    @ViewBuilder static func sortMenu(_ e: MusicEntity, hub: MusicHub) -> some View {
        if let id = localID(e) {
            Menu {
                ForEach(MusicTrackSortKey.allCases.filter { $0 != .default }) { key in
                    Button(Localized.string(key.label)) { sort(id, key: key, hub: hub) }.atlas("control.music.collectionMenuSortKey")
                }
                Divider()
                Button("Reverse Order", systemImage: "arrow.up.arrow.down") { reverse(id, hub: hub) }.atlas("control.music.collectionMenuSortReverse")
            } label: { Label("Sort Tracks", systemImage: "arrow.up.arrow.down.circle") }.atlas("control.music.collectionMenuSort")
        }
    }

    private static func sort(_ id: UUID, key: MusicTrackSortKey, hub: MusicHub) {
        guard let p = hub.library.playlist(id: id) else { return }
        let counts = Dictionary(hub.library.history.map { ($0.track.uid, 1) }, uniquingKeysWith: +)
        let sorted = MusicLibraryOrdering.sorted(p.tracks, by: key, playCounts: counts)
        MusicPlaylistUndo.perform(hub: hub, playlist: id, message: Localized.string("Sorted. Undo to put it back.")) { hub.library.replaceTracks(sorted, in: id) }
    }

    private static func reverse(_ id: UUID, hub: MusicHub) {
        guard let p = hub.library.playlist(id: id) else { return }
        MusicPlaylistUndo.perform(hub: hub, playlist: id, message: Localized.string("Reversed. Undo to put it back.")) { hub.library.replaceTracks(p.tracks.reversed(), in: id) }
    }

    /// Export As… for any collection: a playlist of yours as it is, an album or saved playlist as the songs the source lists.
    @ViewBuilder static func exportMenu(_ e: MusicEntity, hub: MusicHub) -> some View {
        Menu {
            ForEach(MusicPlaylistFileFormat.allCases) { f in
                Button(f.title) { Task { await export(e, format: f, hub: hub) } }.atlas("control.music.collectionMenuExportFormat")
            }
        } label: { Label("Export Playlist", systemImage: "square.and.arrow.up.on.square") }.atlas("control.music.collectionMenuExport")
    }

    private static func export(_ e: MusicEntity, format: MusicPlaylistFileFormat, hub: MusicHub) async {
        if let id = localID(e), let p = hub.library.playlist(id: id) {
            MusicPlaylistFileActions.export(p, format: format, description: MusicPlaylistExtras.shared.description(for: id)); return
        }
        let list = await MusicEntityActions.tracks(e, hub: hub)
        guard !list.isEmpty else { MusicToasts.shared.show(Localized.string("Nothing to export here yet.")); return }
        MusicPlaylistFileActions.export(LocalPlaylist(name: title(e), tracks: list), format: format, description: nil)
    }
}
