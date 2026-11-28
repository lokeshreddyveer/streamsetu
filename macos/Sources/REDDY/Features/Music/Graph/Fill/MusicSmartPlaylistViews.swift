import SwiftUI

// Smart playlists in Your library: On Repeat, Recently added, Never played and Forgotten favourites, built on open from the plays table (nothing is
// stored). A list is offered from five songs; each can be dismissed for good. The page plays, shuffles and saves the list as a playlist.

@MainActor
enum MusicSmartSource {
    static let dismissedKey = "music.smart.dismissed"

    static func songs(hub: MusicHub) -> (songs: [MusicSmartSong], tracks: [String: MusicTrack]) {
        var tracks: [String: MusicTrack] = [:], plays: [String: [Date]] = [:]
        for r in hub.library.history where !hub.library.isBlacklisted(r.track) { tracks[r.track.uid] = tracks[r.track.uid] ?? r.track; plays[r.track.uid, default: []].append(r.at) }
        var out: [MusicSmartSong] = []
        var seen = Set<String>()
        for (i, t) in hub.library.liked.enumerated() where seen.insert(t.uid).inserted {
            tracks[t.uid] = t
            out.append(MusicSmartSong(uid: t.uid, plays: plays[t.uid] ?? [], liked: true, isLocal: t.providerID == MusicStatsRules.localProviderID, order: i))
        }
        for p in hub.library.playlists { for t in p.tracks where seen.insert(t.uid).inserted {
            tracks[t.uid] = t
            out.append(MusicSmartSong(uid: t.uid, plays: plays[t.uid] ?? [], liked: false, isLocal: t.providerID == MusicStatsRules.localProviderID))
        } }
        // Songs that were only played (neither liked nor in a playlist) still count for Most played and Recently played.
        for (uid, t) in tracks where seen.insert(uid).inserted {
            out.append(MusicSmartSong(uid: uid, plays: plays[uid] ?? [], liked: false, isLocal: t.providerID == MusicStatsRules.localProviderID))
        }
        let songCount = out.count, playedCount = plays.count
        MusicDebugLog.log("library", "smart source: \(songCount) songs, \(playedCount) played")
        return (out, tracks)
    }

    static func dismissed() -> Set<MusicSmartKind> { Set((UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []).compactMap(MusicSmartKind.init(rawValue:))) }
    static func dismiss(_ k: MusicSmartKind) { UserDefaults.standard.set(Array(dismissed().union([k]).map(\.rawValue)), forKey: dismissedKey) }
}

extension MusicSmartKind {
    var collectionKey: MusicCollectionKey {
        switch self { case .onRepeat: .onRepeat; case .recentlyAdded: .recentlyAdded; case .neverPlayed: .neverPlayed; case .forgottenFavourites: .forgottenFavourites; case .mostPlayed: .mostPlayed; case .recentlyPlayed: .recentlyPlayed }
    }
    var localizedTitle: String { Localized.string(title) }
    var localizedReason: String { Localized.string(reason) }
    var symbol: String {
        switch self { case .onRepeat: "repeat"; case .recentlyAdded: "clock.badge.checkmark"; case .neverPlayed: "sparkles"; case .forgottenFavourites: "heart.text.square"; case .mostPlayed: "chart.bar"; case .recentlyPlayed: "clock.arrow.circlepath" }
    }
}

/// The shelf of offered smart playlists, for the top of the Playlists tab.
struct MusicSmartPlaylistsShelf: View {
    let hub: MusicHub
    @State private var dismissedRevision = 0

    var body: some View {
        let _ = dismissedRevision
        let (songs, _) = MusicSmartSource.songs(hub: hub)
        let lists = MusicSmartPlaylists.lists(songs, dismissed: MusicSmartSource.dismissed())
        if !lists.isEmpty {
            MusicShelf(title: Localized.string("Made for you, from your plays"), subtitle: Localized.string("Built on this Mac from what you play. Nothing is stored.")) {
                ForEach(lists) { l in
                    VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                        MusicCard(title: l.kind.localizedTitle, subtitle: Localized.plural(l.songs.count, one: "%@ song", other: "%@ songs"), thumbs: [], width: MusicCardGeometry.defaultWidth) {
                            hub.open(collection: l.kind.collectionKey)
                        }
                        MusicGraphReasonLabel(l.kind.localizedReason, lines: 2).frame(width: MusicCardGeometry.defaultWidth, alignment: .leading)
                        Button(Localized.string("Hide")) { MusicSmartSource.dismiss(l.kind); dismissedRevision += 1 }
                            .musicButton(.tertiary, size: .compact).accessibilityLabel(Localized.string("Hide %@", l.kind.localizedTitle)).atlas("control.music.smartPlaylistHide")
                    }
                }
            }
        }
    }
}

struct MusicSmartPlaylistPage: View {
    let hub: MusicHub
    let kind: MusicSmartKind

    var body: some View {
        let (songs, tracks) = MusicSmartSource.songs(hub: hub)
        let ids = MusicSmartPlaylists.lists(songs).first { $0.kind == kind }?.songs ?? []
        let list = ids.compactMap { tracks[$0] }
        MusicPageScaffold(hub: hub, thumbs: list.first?.thumbnails ?? []) {
            MusicPageHeader(title: kind.localizedTitle, kind: Localized.string("Made for you"), subtitle: kind.localizedReason, thumbs: list.first?.thumbnails ?? []) {
                MusicPlayShuffleButtons(hub: hub, tracks: list, sourceName: kind.localizedTitle)
                Button { savePlaylist(list) } label: { Label(Localized.string("Save as playlist"), systemImage: "square.and.arrow.down") }
                    .musicButton(.secondary, size: .compact).disabled(list.isEmpty).accessibilityLabel(Localized.string("Save %@ as a playlist", kind.localizedTitle)).atlas("control.music.smartPlaylistSave")
            }
            if list.isEmpty {
                MusicEmptyState(symbol: "music.note.list", title: Localized.string("Nothing here yet"), message: Localized.string("This list fills in as you play and save music."),
                                actionTitle: Localized.string("Browse Explore")) { hub.nav.select(.explore) }
            } else {
                MusicTrackList(hub: hub, tracks: list, listKey: "smart:" + kind.rawValue)
            }
        }
        .atlasScreen("screen.music.smartPlaylist")
    }

    private func savePlaylist(_ list: [MusicTrack]) {
        let p = hub.library.createPlaylist(name: kind.localizedTitle, tracks: list)
        MusicToasts.shared.success(Localized.string("Saved as the playlist %@.", p.name))
    }
}

/// Undo for destructive playlist edits and reorders: the edit is done at once and the toast offers Undo for eight seconds.
@MainActor
enum MusicPlaylistUndo {
    static func perform(hub: MusicHub, playlist id: UUID, message: String, edit: () -> Void) {
        guard let before = hub.library.playlist(id: id)?.tracks else { return }
        edit()
        MusicToasts.shared.show(message, kind: .success, actionTitle: Localized.string("Undo")) {
            hub.library.replaceTracks(before, in: id)
            MusicAnnouncer.shared.announce(Localized.string("Undone"))
        }
    }
}

/// The album page's extra shelves: other editions, more by the artist, and Appears on.
struct MusicAlbumConnectionShelves: View {
    let hub: MusicHub
    let album: MusicEntityID
    let tracks: [MusicTrack]
    @State private var model = MusicFillModel()
    @State private var rt = MusicFillRuntime.shared

    var body: some View {
        let _ = rt.revision
        VStack(alignment: .leading, spacing: MusicSpace.xl) {
            ForEach(model.shelves) { MusicFillShelfView(shelf: $0, hub: hub, phase: model.phase) }
        }
        // The first albums of these shelves are the likeliest next taps: their first page of songs is saved now (cheap; see MusicEntityWarmer).
        .task(id: model.shelves.reduce(0) { $0 + $1.tiles.count }) {
            MusicEntityWarmer.shared.warm(model.shelves.flatMap { $0.tiles.prefix(2).map(\.entity) }, hub: hub)
        }
        .task(id: album.rawValue + "|\(rt.revision)") {
            let ids = Dictionary(tracks.map { ($0.uid, MusicFillRuntime.songID($0)) }, uniquingKeysWith: { a, _ in a })
            let locals = hub.library.playlists.map { MusicAlbumConnections.LocalPlaylist(id: $0.id.uuidString, name: $0.name, songUIDs: Set($0.tracks.map(\.uid))) }
            let w = rt.wording, a = album
            model.load(key: a.rawValue, force: rt.revision > 0) { store in await MusicAlbumConnections.build(album: a, store: store, songUIDs: ids, localPlaylists: locals, wording: w) }
        }
    }
}
