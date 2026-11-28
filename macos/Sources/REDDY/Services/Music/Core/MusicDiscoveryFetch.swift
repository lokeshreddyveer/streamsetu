import Foundation

/// The shelves a discovery source offers for a country (charts, new releases), asked through `MusicFetch`: Home and Explore ask for the SAME shelves
/// from the same sources, so they now share one saved copy and one request instead of two, and the shelves of a country seen before appear at once.
enum MusicDiscoveryFetch {
    static func regional(_ source: any MusicRegionalDiscovery, providerID: String, region: String) async throws -> [MusicBrowseSection] {
        try await regionalAnswer(source, providerID: providerID, region: region).sections
    }

    /// The same, with the time the saved copy was made (now, for an answer that was just fetched), for a chart's "Updated" line.
    static func regionalAnswer(_ source: any MusicRegionalDiscovery, providerID: String, region: String) async throws -> (sections: [MusicBrowseSection], fetchedAt: Date) {
        let a = try await MusicFetch.shared.value(MusicFetch.key(providerID, "featured", region, Localized.activeCode), policy: MusicFetch.Kind.browse, keep: { !$0.isEmpty }) {
            try await source.featured(region: region).map(MusicCachedSection.init)
        }
        return (a.value.map(\.section), a.savedAt ?? Date())
    }

    static func languages(_ source: any MusicLanguageDiscovery, providerID: String, region: String, languages: [MusicLanguage]) async throws -> [MusicBrowseSection] {
        let codes = languages.map(\.rawValue).sorted().joined(separator: ",")
        let a = try await MusicFetch.shared.value(MusicFetch.key(providerID, "featuredLanguages", region, codes, Localized.activeCode), policy: MusicFetch.Kind.browse, keep: { !$0.isEmpty }) {
            try await source.featured(region: region, languages: languages).map(MusicCachedSection.init)
        }
        return a.value.map(\.section)
    }

    /// A source's own featured shelves (not about a country).
    static func featured(_ source: any MusicMetadataProvider) async throws -> [MusicBrowseSection] {
        let a = try await MusicFetch.shared.value(MusicFetch.key(source.id, "featured", Localized.activeCode), policy: MusicFetch.Kind.browse, keep: { !$0.isEmpty }) {
            try await source.featured().map(MusicCachedSection.init)
        }
        return a.value.map(\.section)
    }

    struct GenrePage: Codable, Sendable { var sections: [MusicCachedSection]; var total: Int?; var next: MusicPagination? }

    /// The first page of a mood or genre page; later pages are asked live.
    static func genreFirstPage(_ source: any MusicMetadataProvider, genreID: String) async throws -> MusicPage<MusicBrowseSection> {
        let a = try await MusicFetch.shared.value(MusicFetch.key(source.id, "genre", genreID, Localized.activeCode), policy: MusicFetch.Kind.browse, keep: { !$0.sections.isEmpty }) {
            let p = genreID.hasPrefix("search:") ? try await searchSections(source, words: String(genreID.dropFirst("search:".count))) : try await source.browse(genreID: genreID, page: nil)
            return GenrePage(sections: p.items.map(MusicCachedSection.init), total: p.totalCount, next: p.next)
        }
        return MusicPage(items: a.value.sections.map(\.section), totalCount: a.value.total, next: a.value.next)
    }

    /// A page for words that are not a source's own genre (a language, a mood the source does not list): the source's songs, albums and playlists for those words. A kind the source
    /// cannot answer is left out.
    static func searchSections(_ source: any MusicMetadataProvider, words: String) async throws -> MusicPage<MusicBrowseSection> {
        async let songResult: Result<MusicPage<MusicTrack>, Error> = Self.attempt { try await source.searchTracks(words, page: nil) }
        async let albumResult: Result<MusicPage<MusicAlbum>, Error> = Self.attempt { try await source.searchAlbums(words, page: nil) }
        async let playlistResult: Result<MusicPage<MusicPlaylist>, Error> = Self.attempt { try await source.searchPlaylists(words, page: nil) }
        let (songResults, albumResults, playlistResults) = await (songResult, albumResult, playlistResult)
        // Offline or refused on all three is a failure the page can say (with Try again), not "this source has no picks".
        if case .failure(let first) = songResults, case .failure = albumResults, case .failure = playlistResults { throw first }
        let songs = try? songResults.get(), albums = try? albumResults.get(), playlists = try? playlistResults.get()
        var out: [MusicBrowseSection] = []
        if let s = songs, !s.items.isEmpty { out.append(MusicBrowseSection(id: "search-songs", title: Localized.string("Songs"), items: s.items.prefix(25).map { .track($0) })) }
        if let a = albums, !a.items.isEmpty { out.append(MusicBrowseSection(id: "search-albums", title: Localized.string("Albums"), items: a.items.prefix(25).map { .album($0) })) }
        if let p = playlists, !p.items.isEmpty { out.append(MusicBrowseSection(id: "search-playlists", title: Localized.string("Playlists"), items: p.items.prefix(25).map { .playlist($0) })) }
        return MusicPage(items: out)   // nothing found is an empty page ("Nothing to show"), not an error with Retry; the cache keeps only non-empty first pages
    }

    /// One call's answer as a value, so three calls can be asked at once and judged together.
    private static func attempt<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    struct CachedCategory: Codable, Sendable {
        var name: String
        var kind: MusicCategoryKind
        var genreID: String?
        var genreName: String?
        var search: String?
        var thumbnails: [MusicThumbnail]
        init(_ c: MusicCategory) {
            name = c.name; kind = c.kind; thumbnails = c.thumbnails
            switch c.target {
            case .genre(let g): genreID = g.id; genreName = g.name; search = nil
            case .search(let q): search = q; genreID = nil; genreName = nil
            }
        }
        var category: MusicCategory {
            let target: MusicCategory.Target = genreID.map { .genre(MusicBrowseGenre(id: $0, name: genreName ?? name)) } ?? .search(search ?? name)
            return MusicCategory(name: name, kind: kind, target: target, thumbnails: thumbnails)
        }
    }

    /// The mood and genre tiles of a source: saved, so the grid is there at once on the next launch and refreshed behind it.
    static func categories(sourceID: String, build: @escaping @Sendable () async -> [MusicCategory]) async -> [MusicCategory] {
        // A slow source does not keep the tiles on a skeleton for the whole network timeout: after 12 seconds the page shows what it has (nothing) and can ask again.
        let a = try? await MusicStreamResolver.withDeadline(12) {
            try await MusicFetch.shared.value(MusicFetch.key(sourceID, "categories", "derived"), policy: MusicFetch.Kind.browse, keep: { !$0.isEmpty }) {
                await build().map(CachedCategory.init)
            }
        }
        return a?.value.map(\.category) ?? []
    }

    /// The source's genre list (Search's "Browse all" tiles): saved, so the empty Search page is full at once.
    static func genres(_ source: any MusicMetadataProvider) async throws -> [MusicBrowseGenre] {
        try await MusicFetch.shared.value(MusicFetch.key(source.id, "genres"), policy: MusicFetch.Kind.browse, keep: { !$0.isEmpty }) { try await source.genres() }.value
    }
}
