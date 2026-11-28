import Foundation

/// The catalogue providers the app already has (JioSaavn, iTunes / Apple Music, YouTube Music, and any metadata plugin) as a source of playable
/// albums for the completeness pass. The provider calls are the ones the artist page already makes (`searchArtists`, `artistAlbums`); nothing new is
/// asked of a provider. Hidden behind a protocol so tests answer from values.
protocol MusicPersonCatalogueFetching: Sendable {
    /// Every album the enabled providers list for this artist: through the provider ids the graph already knows (`jiosaavn: 123`), else by an exact
    /// name match on the provider's artist search. Pages are followed up to `maxPages` per provider.
    func albums(forArtist name: String, providerIDs: [String: String], maxPages: Int) async -> [MusicPersonWork]
    /// Albums whose title matches a film or album title (soundtrack editions and film passes); the caller filters by key.
    func albums(titled title: String, maxPerProvider: Int) async -> [MusicPersonWork]
}

enum MusicPersonCatalogue {
    /// One provider album as a work: the provider uid is kept so the writer can attach the provider's own release as an edition.
    static func work(from a: MusicAlbum, relation: MusicPersonRelation = .performer) -> MusicPersonWork? {
        guard !a.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var w = MusicPersonWork(kind: .album, title: a.title, year: MusicGraphAdapters.year(a.releaseDate),
                                subkind: MusicGraphAdapters.albumSubkind(type: a.albumType, title: a.title) ?? MusicAlbumSubkind.album.rawValue,
                                relations: [relation], ids: [ExternalID(.provider, a.uid)], source: MusicSourceID(a.providerID), sourceRef: a.id)
        w.artists = a.artists.map(\.name).filter { !MusicCompilationArtist.isCompilation($0) }
        w.providerUID = a.uid
        w.imageHint = a.thumbnails.best(minSide: 300)
        if let hint = MusicGraphAdapters.filmHint(inTitle: a.title) { w.filmTitle = hint }
        return w
    }

    /// An artist hit is the person only on a near-exact name; the first of several equally good hits is not taken.
    static func pickArtist(_ hits: [MusicArtist], name: String) -> MusicArtist? {
        let scored = hits.map { ($0, MusicTransliterationKey.similarity($0.name, name)) }.filter { $0.1 >= 0.92 }.sorted { $0.1 > $1.1 }
        guard let top = scored.first else { return nil }
        if scored.count > 1, scored[1].1 >= top.1, scored[1].0.name != top.0.name { return nil }
        return top.0
    }
}

/// The live fetcher over a list of providers (each call is guarded, paged, and cancellation aware).
struct MusicPersonCatalogueFetcher: MusicPersonCatalogueFetching {
    var providers: @Sendable () async -> [any MusicMetadataProvider]

    func albums(forArtist name: String, providerIDs: [String: String], maxPages: Int) async -> [MusicPersonWork] {
        var out: [MusicPersonWork] = []
        for p in await providers() {
            if Task.isCancelled { break }
            var artistID = providerIDs[p.id]
            if artistID == nil {
                guard p.capabilities.contains(.artists) || p.capabilities.contains(.search),
                      let hits = try? await p.searchArtists(name, page: nil).items, let a = MusicPersonCatalogue.pickArtist(hits, name: name) else { continue }
                artistID = a.id
            }
            guard let id = artistID else { continue }
            var page: MusicPagination? = nil
            for _ in 0..<max(1, maxPages) {
                if Task.isCancelled { break }
                guard let r = try? await p.artistAlbums(id: id, page: page) else { break }
                out += r.items.compactMap { MusicPersonCatalogue.work(from: $0) }
                guard let next = r.next, !r.items.isEmpty else { break }
                page = next
            }
        }
        return out
    }

    func albums(titled title: String, maxPerProvider: Int) async -> [MusicPersonWork] {
        var out: [MusicPersonWork] = []
        for p in await providers() {
            if Task.isCancelled { break }
            guard let r = try? await p.searchAlbums(title, page: nil) else { continue }
            out += r.items.prefix(maxPerProvider).compactMap { MusicPersonCatalogue.work(from: $0) }
        }
        return out
    }
}
