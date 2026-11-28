import SwiftUI

/// Every song on the film's soundtrack albums that can play, grouped by album, with the singers on each row; then the film's singers. Songs with no
/// playable copy yet are matched in the background (bounded, cancelled when the page closes); the ones that find no copy are not drawn as songs, and
/// the page says how many there are.
struct MusicFilmSongsSection: View {
    let model: MusicFilmGraphModel
    let hub: MusicHub
    /// The language switcher's choice: everything (the default), the film's own songs, or one dubbed edition.
    var filter: MusicFilmLanguageFilter = .all
    @Environment(\.musicLayoutClass) private var cls

    private struct AlbumGroup: Identifiable { var id: String; var title: String; var tracks: [MusicTrack] }

    private func groups() -> [AlbumGroup] {
        var order: [MusicEntityID] = []
        let scores = Set(model.scoreAlbums.map(\.album))   // background-score cues are not songs: they stay on the Score tab
        var by: [MusicEntityID: [MusicFilmSongItem]] = [:]
        let shown = model.songs.filter { filter.matches(dubLanguage: $0.dubLanguage) && !scores.contains($0.album) }
        // A recording on two albums (the original and its deluxe edition) is one song: it keeps its first place and is not queued twice.
        for s in MusicFilmSongRules.uniqueRecordings(shown) { if by[s.album] == nil { order.append(s.album) }; by[s.album, default: []].append(s) }
        var playing = Set<String>()
        return order.compactMap { album in
            let items = by[album] ?? []
            let tracks = model.playable(in: items).filter { playing.insert($0.uid).inserted }
            guard !tracks.isEmpty, let first = items.first else { return nil }
            let title = first.dubLanguage.map { Localized.string("%1$@ (dubbed in %2$@)", first.albumName, MusicFilmLanguageNames.name(for: $0)) } ?? first.albumName
            return AlbumGroup(id: album.rawValue, title: title, tracks: tracks)
        }
    }

    var body: some View {
        let songs = model.section(MusicFilmSectionKey.songs)
        let list = groups()
        let everySong = list.flatMap(\.tracks)
        let singers = model.singers(for: filter)
        let width = MusicGraphCardWidth.width(for: cls)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.md) {
                Text(verbatim: Localized.string("Songs from the film")).font(Typography.title).accessibilityAddTraits(.isHeader)
                ForEach(list) { g in
                    VStack(alignment: .leading, spacing: MusicSpace.xs) {
                        if list.count > 1 { Text(verbatim: g.title).musicText(.card).foregroundStyle(ColorTokens.textSecondary).accessibilityAddTraits(.isHeader) }
                        MusicTrackList(hub: hub, tracks: g.tracks, showsTools: false, numbered: false, canSort: false, showsAlbumByDefault: false, presorted: true, queueContext: everySong)
                    }
                }
                footnote
            }
        } else if songs.phase == .loading || songs.phase == .partial || model.resolvingSongs {
            MusicShelfSkeletonRows()
        } else if model.unplayableCount(for: filter) > 0 {
            footnote
        } else if (songs.phase == .loaded || songs.phase == .empty) && model.musicVideos.isEmpty {
            // Nothing to draw and nothing still loading (only background-score cues, no song in the chosen language, or no playable copy): say so, so the tab is never blank.
            Text(verbatim: Localized.string("No songs from this film to show here yet.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
        }
        let videos = model.musicVideos
        if !videos.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                Text(verbatim: Localized.string("Music videos")).font(Typography.title).accessibilityAddTraits(.isHeader)
                MusicTrackList(hub: hub, tracks: videos, showsTools: false, numbered: false, canSort: false, showsAlbumByDefault: false, presorted: true)
            }
        }
        MusicGraphShelf(title: Localized.string("Singers"), phase: songs.phase, itemCount: singers.count, itemWidth: width) {
            ForEach(singers) { s in
                MusicGraphPersonCard(name: s.name, caption: Localized.string("Singer · songs: %1$@", String(s.songCount)), imageRef: s.imageRef, width: width, entity: s.person) {
                    hub.open(s.person, role: .singer)
                }
            }
        }
    }

    @ViewBuilder private var footnote: some View {
        if model.resolvingSongs {
            Text(verbatim: Localized.string("Finding playable copies of more songs...")).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
        } else if model.unplayableCount(for: filter) > 0 {
            Text(verbatim: Localized.string("Songs from this soundtrack not available on your music sources yet: %1$@", String(model.unplayableCount(for: filter))))
                .musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
        }
    }
}

/// A few song-row skeletons, the height of the real rows, while the songs load.
private struct MusicShelfSkeletonRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            ForEach(0..<4, id: \.self) { _ in MusicSkeletonRow() }
        }
        .accessibilityHidden(true)
    }
}
