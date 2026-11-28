import SwiftUI

// A mood, genre or language page: a banner with the category's cover and Play / Shuffle, then what the source offers laid out by kind. Songs are a
// list, playlists, albums and artists are grids sized from the layout class. Nothing scrolls sideways, and the page uses the same frame as Home.

// MARK: - Layout decisions (pure)

enum MusicCategoryLayout {
    static let songPreview = 8

    enum Block: Equatable { case songs, playlists, albums, artists }

    struct Split: Equatable {
        var songs: [MusicTrack] = []
        var playlists: [MusicPlaylist] = []
        var albums: [MusicAlbum] = []
        var artists: [MusicArtist] = []
        var blocks: [Block] {
            var b: [Block] = []
            if !songs.isEmpty { b.append(.songs) }
            if !playlists.isEmpty { b.append(.playlists) }
            if !albums.isEmpty { b.append(.albums) }
            if !artists.isEmpty { b.append(.artists) }
            return b
        }
    }

    /// A section's items sorted into the four kinds, in their own order.
    static func split(_ items: [MusicBrowseItem]) -> Split {
        var s = Split()
        for i in items {
            switch i {
            case .track(let t): s.songs.append(t)
            case .playlist(let p): s.playlists.append(p)
            case .album(let a): s.albums.append(a)
            case .artist(let a): s.artists.append(a)
            }
        }
        return s
    }

    /// Songs to play from the whole page: every song once, in order.
    static func allSongs(_ sections: [MusicBrowseSection]) -> [MusicTrack] {
        var seen = Set<String>()
        return sections.flatMap { split($0.items).songs }.filter { seen.insert($0.uid).inserted }
    }

    static func firstPlaylist(_ sections: [MusicBrowseSection]) -> MusicPlaylist? { sections.lazy.flatMap { split($0.items).playlists }.first }

    static func shownSongs(_ songs: [MusicTrack], expanded: Bool) -> [MusicTrack] { expanded ? songs : Array(songs.prefix(songPreview)) }
    static func showsMoreSongs(total: Int, expanded: Bool) -> Bool { !expanded && total > songPreview }

    /// Columns for a card grid: the same count the Search page uses.
    static func columns(width: CGFloat, cls: MusicLayoutClass) -> Int { MusicSearchLayout.rowCapacity(width: width, cls: cls) }

    /// Titles repeated by the source are shown once; sections with nothing in them are dropped.
    static func clean(_ sections: [MusicBrowseSection]) -> [MusicBrowseSection] {
        var seen = Set<String>()
        return sections.filter { !$0.items.isEmpty && seen.insert($0.title.lowercased() + "|" + $0.id).inserted }
    }
}

// MARK: - Page

struct MusicCategoryPage: View {
    let hub: MusicHub
    let genre: MusicBrowseGenre
    @State private var sections: MusicPagedList<MusicBrowseSection>
    @State private var expanded: Set<String> = []
    @State private var gridWidth: CGFloat = 0
    @Environment(\.musicLayoutClass) private var cls
    @Environment(\.reddyAccent) private var accent

    init(hub: MusicHub, genre: MusicBrowseGenre) {
        self.hub = hub; self.genre = genre
        _sections = State(initialValue: MusicPagedList(describe: { hub.loadError($0) }) { page in
            guard let p = hub.registry.activeMetadata else { throw MusicError.unsupported("no music source is switched on") }
            // The first page is saved, so a mood or genre seen before opens at once and is refreshed behind; later pages are asked live.
            if page == nil { return try await MusicDiscoveryFetch.genreFirstPage(p, genreID: genre.id) }
            return try await p.browse(genreID: genre.id, page: page)
        })
    }

    /// The name as the tile showed it: a source's category names arrive in English, and the tile, the title and the Play label all read the app's language.
    private var shownName: String { Localized.string(genre.name) }
    private var category: MusicCategory { MusicCategory(name: genre.name, kind: .genre, target: .genre(genre), thumbnails: genre.thumbnails, stableName: genre.stableName) }
    private var cleaned: [MusicBrowseSection] { MusicCategoryLayout.clean(sections.items) }

    var body: some View {
        MusicScreen(title: shownName, scrollKey: genre.id, trailing: { backButton }, content: {
            hero
            content
        })
        .task { MusicGenreArtwork.shared.useSource(hub.registry.activeMetadata); await sections.loadIfNeeded() }
    }

    private var backButton: some View {
        // The toolbar above already has Back; Escape still goes back through this hidden zero-size button.
        Button { hub.nav.back() } label: { EmptyView() }
            .buttonStyle(.plain).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true).keyboardShortcut(.cancelAction)
            .atlas("control.music.albumArtistAndPlaylistPagesBack")
    }

    // MARK: hero

    private var hero: some View {
        let shape = RoundedRectangle(cornerRadius: MusicCorner.panel, style: .continuous)
        let songs = MusicCategoryLayout.allSongs(cleaned)
        let playlist = MusicCategoryLayout.firstPlaylist(cleaned)
        let canPlay = !songs.isEmpty || playlist != nil
        return Color.clear
            .frame(height: MusicExploreHero.height(for: cls))
            .overlay { MusicCategoryArt(category: category) }
            .overlay { LinearGradient(colors: [MusicInk.scrim(.heavy), MusicInk.scrim(.light)], startPoint: .leading, endPoint: .trailing) }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    Text(genre.id.hasPrefix("search:") ? Localized.string("Explore") : Localized.string("Mood & genre")).musicText(.caption).foregroundStyle(MusicInk.onArtworkSecondary)
                    Text(verbatim: shownName).musicText(.page).foregroundStyle(MusicInk.onArtwork).lineLimit(2).accessibilityAddTraits(.isHeader)
                    HStack(spacing: MusicSpace.xs) {
                        Button {
                            if !songs.isEmpty { hub.play(songs, at: 0, sourceName: shownName) } else if let playlist { Task { await MusicEntityActions.play(.playlist(playlist), hub: hub) } }
                        } label: { Label(Localized.string("Play"), systemImage: "play.fill") }
                        .musicButton(.hero, size: .large)
                        .disabled(!canPlay).accessibilityLabel(Localized.string("Play %@", shownName)).atlas("control.music.categoryPlay")
                        Button {
                            if !songs.isEmpty { hub.playShuffled(songs, sourceName: shownName) }
                            else if let playlist { Task { await MusicEntityActions.play(.playlist(playlist), shuffle: true, hub: hub) } }
                        } label: { Label(Localized.string("Shuffle"), systemImage: "shuffle") }
                        .musicButton(.secondary, size: .large)
                        .disabled(!canPlay).accessibilityLabel(Localized.string("Shuffle %@", shownName)).atlas("control.music.categoryShuffle")
                    }
                }
                .padding(MusicSpace.xl)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(ColorTokens.line, lineWidth: 0.75))
            .accessibilityElement(children: .contain)
    }

    // MARK: sections

    @ViewBuilder private var content: some View {
        switch sections.state {
        case .idle, .loading:
            skeletons
        case .failed(let m):
            MusicErrorState(message: m, retry: { Task { await sections.reload() } })
        case .loaded:
            if cleaned.isEmpty {
                MusicEmptyState(glyph: .emptySearch, title: Localized.string("Nothing to show"), message: Localized.string("This source has no picks for this genre."), compact: true)
            } else {
                VStack(alignment: .leading, spacing: MusicSpace.xl) {
                    ForEach(cleaned) { s in sectionView(s) }
                    MusicLoadMoreButton(list: sections)
                    Color.clear.frame(height: 1).onAppear { if sections.hasMore { Task { await sections.loadMore() } } }
                }
                .musicReadWidth($gridWidth)
            }
        }
    }

    private var skeletons: some View {
        let cols = MusicCategoryLayout.columns(width: gridWidth, cls: cls)
        return VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSkeletonBlock(width: MusicCardGeometry.defaultWidth, height: MusicTypeRole.section.pointSize + MusicSpace.xxs, corner: MusicSpace.xxs)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: MusicSpace.md), count: cols), spacing: MusicSpace.lg) {
                ForEach(0..<cols * 2, id: \.self) { _ in MusicSkeletonCard(width: MusicCardGeometry.defaultWidth) }
            }
        }
        .musicReadWidth($gridWidth).accessibilityHidden(true)
    }

    @ViewBuilder private func sectionView(_ s: MusicBrowseSection) -> some View {
        let split = MusicCategoryLayout.split(s.items)
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSectionTitle(title: s.title)
            ForEach(split.blocks, id: \.self) { block in
                switch block {
                case .songs: songs(split.songs, key: s.id)
                case .playlists: grid(split.playlists, id: \.uid) { MusicCard(playlist: $0, hub: hub, width: nil) }
                case .albums: grid(split.albums, id: \.uid) { MusicCard(album: $0, hub: hub, width: nil) }
                case .artists: grid(split.artists, id: \.uid) { MusicCard(artist: $0, hub: hub, width: nil) }
                }
            }
        }
    }

    @ViewBuilder private func songs(_ list: [MusicTrack], key: String) -> some View {
        let open = expanded.contains(key)
        MusicChartSongs(hub: hub, tracks: MusicCategoryLayout.shownSongs(list, expanded: open), chartID: "category:" + genre.id + ":" + key)
        if MusicCategoryLayout.showsMoreSongs(total: list.count, expanded: open) {
            Button(Localized.string("Show all %@ songs", "\(list.count)")) { expanded.insert(key) }
                .buttonStyle(.plain).musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                .frame(minHeight: MusicTokens.hitTarget).hoverHighlight()
                .accessibilityLabel(Localized.string("Show all %@ songs", "\(list.count)")).atlas("control.music.categoryShowSongs")
        }
    }

    private func grid<T, V: View>(_ items: [T], id: KeyPath<T, String>, @ViewBuilder card: @escaping (T) -> V) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: MusicSpace.md, alignment: .top), count: MusicCategoryLayout.columns(width: gridWidth, cls: cls)),
                  alignment: .leading, spacing: MusicSpace.lg) {
            ForEach(items, id: id) { card($0) }
        }
    }
}
