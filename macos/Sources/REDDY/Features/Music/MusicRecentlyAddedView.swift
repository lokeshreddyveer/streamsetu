import SwiftUI

/// Everything the person added to their library, newest first, with chips to narrow it to Songs, Albums, Artists, Playlists or Local files. Each row says how long ago
/// it was added; something added before dates were kept says "Earlier" (no date is made up).
struct MusicRecentlyAddedView: View {
    let hub: MusicHub
    @State private var items: [MusicRecentItem] = []
    @State private var kind: MusicAdditionKind?
    @State private var loaded = false
    @Environment(\.reddyAccent) private var accent

    private var shown: [MusicRecentItem] { Array(MusicRecentlyAdded.filter(items, kind: kind).prefix(300)) }

    private func title(_ k: MusicAdditionKind) -> String {
        switch k {
        case .song: Localized.string("Songs")
        case .album: Localized.string("Albums")
        case .artist: Localized.string("Artists")
        case .playlist: Localized.string("Playlists")
        case .local: Localized.string("Local files")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            MusicChipFlow(spacing: MusicSpace.xs) {
                MusicChip(title: Localized.string("All"), selected: kind == nil) { kind = nil }
                ForEach(MusicAdditionKind.allCases, id: \.self) { k in MusicChip(title: title(k), selected: kind == k) { kind = k } }
            }
            if !loaded { MusicLoadingIcon(size: MusicIconSize.small).frame(maxWidth: .infinity, minHeight: 120) }
            else if shown.isEmpty, !items.isEmpty, let k = kind {
                Text(Localized.string("Nothing under %@ has been added yet.", title(k))).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).padding(.vertical, MusicSpace.lg)
            } else if shown.isEmpty {
                Text(Localized.string("Nothing has been added yet. Like a song, follow an artist, save an album or add a music folder, and it shows up here.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).padding(.vertical, MusicSpace.lg)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { item in row(item) }
                }
            }
        }
        .task(id: signature) { await load() }
    }

    private var signature: String { "\(hub.library.likedRevision)|\(hub.library.albumsRevision)|\(hub.library.followedRevision)|\(hub.library.playlistsRevision)|\(hub.library.additionsRevision)" }

    @ViewBuilder private func row(_ item: MusicRecentItem) -> some View {
        Button { open(item) } label: {
            HStack(spacing: MusicSpace.sm) {
                MusicArtwork(item.thumbnails, size: 44, corner: item.kind == .artist ? 22 : MusicCorner.control)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.title).font(Typography.bodyMedium).lineLimit(1)
                    if !item.subtitle.isEmpty { Text(verbatim: item.subtitle).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                }
                Spacer(minLength: MusicSpace.sm)
                Text(verbatim: kindLabel(item.kind)).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                Text(verbatim: ageText(item.addedAt)).font(Typography.caption).foregroundStyle(accent).frame(minWidth: 80, alignment: .trailing)
            }
            .padding(.vertical, 6).frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight().atlas("control.music.recentlyAddedRow")
    }

    private func kindLabel(_ k: MusicAdditionKind) -> String {
        switch k {
        case .song: Localized.string("Song")
        case .album: Localized.string("Album")
        case .artist: Localized.string("Artist")
        case .playlist: Localized.string("Playlist")
        case .local: Localized.string("Local file")
        }
    }

    private func ageText(_ date: Date?) -> String {
        switch MusicRecentlyAdded.age(of: date) {
        case .today: Localized.string("Today")
        case .yesterday: Localized.string("Yesterday")
        case .days(let n): Localized.plural(n, one: "%@ day ago", other: "%@ days ago")
        case .weeks(let n): Localized.plural(n, one: "%@ week ago", other: "%@ weeks ago")
        case .months(let n): Localized.plural(n, one: "%@ month ago", other: "%@ months ago")
        case .longAgo: Localized.string("Over a year ago")
        case .earlier: Localized.string("Earlier")
        }
    }

    // MARK: data

    private func load() async {
        let lib = hub.library
        var out: [MusicRecentItem] = []
        for (i, t) in lib.liked.enumerated() where t.isPodcast != true {
            out.append(MusicRecentItem(kind: .song, key: t.uid, title: t.title, subtitle: t.artistLine, thumbnails: t.thumbnails, addedAt: lib.addedAt(.song, t.uid), order: i))
        }
        for (i, a) in lib.savedAlbums.enumerated() {
            out.append(MusicRecentItem(kind: .album, key: a.uid, title: a.title, subtitle: MusicHeroText.cardCredit(a.artists), thumbnails: a.thumbnails, addedAt: lib.addedAt(.album, a.uid), order: i))
        }
        for (i, a) in lib.followedArtists.enumerated() {
            out.append(MusicRecentItem(kind: .artist, key: a.uid, title: a.name, subtitle: "", thumbnails: a.thumbnails, addedAt: lib.addedAt(.artist, a.uid), order: i))
        }
        for (i, p) in lib.playlists.reversed().enumerated() {
            out.append(MusicRecentItem(kind: .playlist, key: p.id.uuidString, title: p.name, subtitle: Localized.plural(p.tracks.count, one: "%@ song", other: "%@ songs"),
                                       thumbnails: p.tracks.first?.thumbnails ?? [], addedAt: p.created, order: i))
        }
        // Local files carry the file's own date (when it was last written): newest 200 only, so thousands of files never slow this page.
        let entries = await LocalLibraryStore.shared.currentIndex().entries.sorted { $0.modified > $1.modified }.prefix(200)
        if let p = hub.registry.provider(id: MusicStatsRules.localProviderID) as? LocalFilesProvider {
            for (i, e) in entries.enumerated() {
                let t = p.track(e)
                out.append(MusicRecentItem(kind: .local, key: t.uid, title: e.title, subtitle: e.artist, thumbnails: t.thumbnails, addedAt: e.modified, order: i))
            }
        }
        if Task.isCancelled { return }   // a newer load has started: it must not be overwritten by this older snapshot
        items = MusicRecentlyAdded.sorted(out)
        loaded = true
    }

    /// The liked songs behind the listed rows, in the rows' order. One pass over the library (a dictionary), not one scan per row.
    static func likedSongs(for rows: [MusicRecentItem], liked: [MusicTrack]) -> [MusicTrack] {
        let byUID = Dictionary(liked.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.compactMap { byUID[$0.key] }
    }

    /// The local index's id inside a row key (`uid` is "provider:id").
    nonisolated static func localEntryID(_ key: String) -> String { String(key.drop { $0 != ":" }.dropFirst()) }

    private func open(_ item: MusicRecentItem) {
        let lib = hub.library
        switch item.kind {
        case .song:
            // The songs shown in the list, in the order shown, so playback continues with the next recent song.
            let shown = Self.likedSongs(for: items.filter { $0.kind == .song }, liked: lib.liked)
            if let i = shown.firstIndex(where: { $0.uid == item.key }) { hub.play(shown, at: i) }
        case .album: if let a = lib.savedAlbums.first(where: { $0.uid == item.key }) { hub.open(album: a) }
        case .artist: if let a = lib.followedArtists.first(where: { $0.uid == item.key }) { hub.open(artist: a) }
        case .playlist: if let p = lib.playlists.first(where: { $0.id.uuidString == item.key }) { hub.open(.localPlaylist(p.id)) }
        case .local:
            // The files shown in the list, in the order shown, so playback continues with the next recent file (as it does for songs).
            let order = items.filter { $0.kind == .local }.map(\.key)
            Task {
                guard let p = hub.registry.provider(id: MusicStatsRules.localProviderID) as? LocalFilesProvider else { return }
                let index = await LocalLibraryStore.shared.currentIndex()
                let queue = order.compactMap { key in index.entry(id: Self.localEntryID(key)).map { p.track($0) } }
                if let i = queue.firstIndex(where: { $0.uid == item.key }) { hub.play(queue, at: i) }
            }
        }
    }
}
