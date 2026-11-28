import SwiftUI

/// A playlist in Your library: a large cover (the chosen picture, else a mosaic of distinct album covers), a title renamed in place, a description,
/// a stat line, Play and Shuffle, and the full song list with filter, sort, drag to reorder and picking. Songs dropped from any card are added. Under
/// the list, "More like this" recommends songs to add.
struct MusicLocalPlaylistPage: View {
    let hub: MusicHub
    let id: UUID
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var showMerge = false
    @State private var showRepeats = false
    @State private var showStats = false
    @State private var picking = false
    @State private var mode = MusicPlaylistViewMode.load()
    @Environment(\.musicLayoutClass) private var layoutClass
    private let extras = MusicPlaylistExtras.shared

    private var playlist: LocalPlaylist? { hub.library.playlists.first { $0.id == id } }
    private var coverSize: CGFloat { MusicPlaylistPageMetrics.coverSize(layoutClass) }

    var body: some View {
        if let p = playlist {
            MusicPageScaffold(hub: hub) {
                header(p)
                if p.tracks.isEmpty {
                    MusicEmptyState(symbol: "music.note.list", title: Localized.string("This playlist is empty"),
                                    message: Localized.string("Add songs from search, or from the menu of any song."),
                                    actionTitle: Localized.string("Add songs")) {
                        MusicDebugLog.log("playlist", "add songs from empty playlist: opening search")
                        hub.nav.select(.search)
                    }
                    .frame(minHeight: 240)
                } else {
                    MusicTrackList(hub: hub, tracks: p.tracks, listKey: "local:" + p.id.uuidString, fromPlaylist: p.id, showsAlbumByDefault: true,
                                   onRemove: { removed in remove(removed, from: p) },
                                   onMove: { src, dst in MusicPlaylistUndo.perform(hub: hub, playlist: p.id, message: Localized.string("Moved. Undo to put it back.")) { hub.library.move(from: src, to: dst, in: p.id) } },
                                   onDropTracks: { add($0, to: p) },
                                   rowStyle: mode.rowStyle, selecting: $picking)
                    MusicPlaylistMoreLikeThis(hub: hub, tracks: p.tracks) { add([$0], to: p) }
                }
            }
            .musicDropTracks(hub: hub) { add($0, to: p) }
            .onAppear { if MusicChromeState.shared.selectOnOpen == id { MusicChromeState.shared.selectOnOpen = nil; picking = true } }
            .sheet(isPresented: $editing) { MusicEditPlaylistSheet(hub: hub, playlist: p) { editing = false } }
            .sheet(isPresented: $showMerge) { MusicPlaylistMergeSheet(hub: hub, source: p.id) { showMerge = false } }
            .sheet(isPresented: $showRepeats) { MusicPlaylistRepeatsSheet(hub: hub, id: p.id) { showRepeats = false } }
            .sheet(isPresented: $showStats) { MusicPlaylistStatsSheet(hub: hub, id: p.id) { showStats = false } }
            .confirmationDialog("Delete \(p.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete playlist", role: .destructive) { delete(p) }.atlas("control.music.playlistDelete")
                Button("Cancel", role: .cancel) {}.atlas("control.music.albumArtistAndPlaylistPagesCancel")
            } message: { Text("The songs stay in Your library. Only the playlist is removed.") }
        } else {
            MusicEmptyState(symbol: "music.note.list", title: Localized.string("Playlist not found"), message: Localized.string("It may have been deleted."))
        }
    }

    // MARK: header

    private func header(_ p: LocalPlaylist) -> some View {
        let stats = MusicPlaylistStats.Input(songCount: p.tracks.count, totalMs: MusicPlaylistStats.totalMs(p.tracks), updated: p.created, dateIsCreation: true)
        return MusicPlaylistHeader(title: p.name, kind: Localized.string("Playlist"), description: extras.description(for: p.id),
                                   onAddDescription: { editing = true }, stats: MusicPlaylistStats.line(stats),
                                   backdrop: MusicPlaylistCover.backdropThumbs(own: [], members: p.tracks.prefix(MusicPlaylistCoverPlan.scanLimit).map(\.thumbnails), seed: p.id.uuidString),
                                   onRename: { hub.library.rename(p, to: $0); MusicDebugLog.log("playlist", "renamed in place") },
                                   cover: {
            MusicLocalCover(id: p.id, fallback: p.tracks.first?.thumbnails ?? [], members: MusicPlaylistCoverPicker.representatives(p.tracks), name: p.name, size: coverSize, corner: 16)
        }, actions: {
            MusicPlayShuffleButtons(hub: hub, tracks: p.tracks, sourceName: p.name, sourceID: p.sourceID)
            MusicPlaylistIconRow(enabled: !p.tracks.isEmpty, onQueue: { hub.player.enqueue(p.tracks, from: p.name) }, onNext: { hub.player.playNext(p.tracks, from: p.name) },
                                 onDownload: MusicPlaylistActionRules.canDownloadAll(count: p.tracks.count) ? { download(p.tracks) } : nil,
                                 onShare: { share(p) }, mode: $mode)
            moreMenu(p)
        })
    }

    private func moreMenu(_ p: LocalPlaylist) -> some View {
        Menu {
            Button("Rename…", systemImage: "character.cursor.ibeam") { editing = true }.atlas("control.music.playlistRename")
            Button("Edit Description…", systemImage: "text.alignleft") { editing = true }.atlas("control.music.playlistEditDescription")
            Button("Change Cover…", systemImage: "photo") { editing = true }.atlas("control.music.playlistChangeCover")
            Divider()
            Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { if let t = p.tracks.first { Task { await MusicQueueActions.startRadio(t, hub: hub) } } }
                .disabled(p.tracks.isEmpty).atlas("control.music.albumArtistAndPlaylistPagesStartRadio")
            Button("Add All to Another Playlist…", systemImage: "music.note.list") { MusicChromeState.shared.addToPlaylist = p.tracks }
                .disabled(p.tracks.isEmpty).atlas("control.music.playlistAddAllToPlaylist")
            Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(p) }.atlas("control.music.playlistDuplicate")
            Button(Localized.string("Merge with Other Playlists…"), systemImage: "arrow.triangle.merge") { showMerge = true }.atlas("control.music.playlistMergeOpen")
            Button(Localized.string("Find Repeated Songs…"), systemImage: "square.on.square.dashed") { showRepeats = true }.atlas("control.music.playlistRepeatsOpen")
            Button(Localized.string("Statistics…"), systemImage: "chart.bar") { showStats = true }.atlas("control.music.playlistStatsOpen")
            Menu(Localized.string("Export As"), systemImage: "square.and.arrow.up.on.square") {
                ForEach(MusicPlaylistFileFormat.allCases) { f in
                    Button(f.title) { MusicPlaylistFileActions.export(p, format: f, description: extras.description(for: p.id)) }.atlas("control.music.playlistExport")
                }
            }.atlas("control.music.playlistExportMenu")
            Divider()
            Button("Delete Playlist", systemImage: "trash", role: .destructive) { confirmDelete = true }.atlas("control.music.playlistDelete")
        } label: { Image(systemName: "ellipsis").font(MusicTokens.iconLarge) }
            .menuStyle(.button).menuIndicator(.hidden).musicButton(.glassIcon, size: .large).fixedSize()
            .accessibilityLabel("More").help("More").atlas("control.music.playlistMoreMenu")
    }

    // MARK: actions

    private func download(_ tracks: [MusicTrack]) {
        MusicDebugLog.log("playlist", "download \(tracks.count) songs of a local playlist")
        for t in tracks { hub.downloads.enqueue(t) }
        MusicToasts.shared.show(Localized.plural(tracks.count, one: "Downloading %@ song.", other: "Downloading %@ songs."))
    }

    private func share(_ p: LocalPlaylist) {
        let asService = MusicPlaylist(id: p.id.uuidString, providerID: MusicStatsRules.localProviderID, name: p.name, trackCount: p.tracks.count)
        MusicEntityActions.share(.playlist(asService), hub: hub)
    }

    private func duplicate(_ p: LocalPlaylist) {
        let made = hub.library.createPlaylist(name: MusicPlaylistActionRules.copyName(p.name), tracks: p.tracks)
        let text = extras.description(for: p.id)
        if !text.isEmpty { extras.setDescription(text, for: made.id) }
        MusicDebugLog.log("playlist", "duplicated a playlist of \(p.tracks.count) songs")
        MusicToasts.shared.success(Localized.string("Saved %@ to Your library.", made.name))
        hub.open(.localPlaylist(made.id))
    }

    private func delete(_ p: LocalPlaylist) {
        hub.deletePlaylist(p)
    }

    private func remove(_ removed: [MusicTrack], from p: LocalPlaylist) {
        let uids = Set(removed.map(\.uid))
        let indexes = IndexSet(p.tracks.indices.filter { uids.contains(p.tracks[$0].uid) })
        guard !indexes.isEmpty else { return }
        MusicPlaylistUndo.perform(hub: hub, playlist: p.id, message: Localized.plural(indexes.count, one: "Removed %@ song from the playlist.", other: "Removed %@ songs from the playlist.")) {
            hub.library.remove(at: indexes, from: p.id)
        }
    }

    private func add(_ tracks: [MusicTrack], to p: LocalPlaylist) {
        let added = hub.library.add(tracks, to: p.id)
        MusicToasts.shared.show(MusicMenuLogic.addToast(added: added, duplicates: tracks.count - added, playlists: [p.name], songCount: tracks.count), kind: added == 0 ? .info : .success)
    }
}

/// Sizes of the playlist header by layout class: a large cover, but never half the page (the long-standing complaint of the big header).
enum MusicPlaylistPageMetrics {
    static func coverSize(_ c: MusicLayoutClass) -> CGFloat {
        switch c { case .compact: 168; case .medium: 184; case .expanded: 208; case .wide: 232 }
    }
}
