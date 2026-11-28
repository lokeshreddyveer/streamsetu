import Foundation

/// Genre charts and trending shelves from SoundCloud for Home and Explore. SoundCloud does not promise that these lists answer without an
/// account, so everything here is defensive: a list that does not answer or comes back empty is simply not shown, and the reason is logged.
struct SoundCloudDiscoveryProvider: MusicMetadataProvider {
    static let id = "discover-soundcloud"
    /// The overall chart's name on SoundCloud. Other chart names are made from the genres the overall chart's own songs carry.
    static let overallGenre = "soundcloud:genres:all-music"
    static let maxGenreShelves = 3

    let provider: SoundCloudProvider
    private var client: SoundCloudClient { provider.client }
    init(provider: SoundCloudProvider = SoundCloudProvider()) { self.provider = provider }

    var info: MusicProviderInfo {
        .discovery(id: Self.id, name: "SoundCloud trending", summary: "What is climbing on SoundCloud right now, by genre.", host: "soundcloud.com")
    }
    var capabilities: MusicCapabilities { [.browse] }

    // MARK: pure helpers

    /// SoundCloud writes a genre into a chart's name in lower case without spaces or marks ("Drum & Bass" becomes "drumandbass").
    static func genreSlug(_ genre: String) -> String {
        MusicText.normalize(genre).replacingOccurrences(of: " ", with: "")
    }

    /// The genres most used by a list of songs, most common first; the plain "none" kinds are skipped.
    static func topGenres(_ tracks: [SCTrack], limit: Int) -> [String] {
        var counts: [String: (name: String, n: Int)] = [:]
        for t in tracks {
            guard let g = t.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty, g.count <= 40 else { continue }
            let key = genreSlug(g)
            guard !key.isEmpty else { continue }
            counts[key] = (counts[key]?.name ?? g, (counts[key]?.n ?? 0) + 1)
        }
        return counts.values.sorted { $0.n != $1.n ? $0.n > $1.n : $0.name < $1.name }.prefix(limit).map(\.name)
    }

    /// Chart rows are `{"track": {...}, "score": ...}`; plain track rows are accepted too.
    static func chartTracks(_ any: Any?) -> [SCTrack] {
        SoundCloudJSON.rows(any).compactMap { SoundCloudJSON.track($0.dict("track") ?? $0) }
    }

    // MARK: fetching

    private func chart(genre: String, kind: String = "trending", limit: Int = 30) async -> [SCTrack] {
        do {
            let data = try await client.data(path: "charts", query: ["kind": kind, "genre": genre, "limit": String(limit)])
            let tracks = Self.chartTracks(SoundCloudJSON.any(data))
            if tracks.isEmpty { MusicDebugLog.log("soundcloud", "chart \(genre) answered empty") }
            return tracks
        } catch {
            MusicDebugLog.log("soundcloud", "chart \(genre) failed: \((error as? MusicError)?.errorDescription ?? "error")")
            return []
        }
    }

    private func section(id: String, title: String, tracks: [SCTrack]) async -> MusicBrowseSection? {
        let mapped = await provider.mapped(tracks, dropUnplayable: true)
        guard mapped.count >= 3 else { return nil }
        return MusicBrowseSection(id: id, title: title, items: mapped.prefix(25).map { .track($0) }, scope: .global)
    }

    func featured() async throws -> [MusicBrowseSection] {
        if await client.isResting { throw MusicError.refused("soundcloud.com") }
        let overall = await chart(genre: Self.overallGenre)
        var out: [MusicBrowseSection] = []
        if let s = await section(id: "soundcloud-trending", title: Localized.string("Trending now"), tracks: overall) { out.append(s) }
        for g in Self.topGenres(overall, limit: Self.maxGenreShelves) {
            let slug = "soundcloud:genres:" + Self.genreSlug(g)
            if let s = await section(id: "soundcloud-" + Self.genreSlug(g), title: g, tracks: await chart(genre: slug)) { out.append(s) }
        }
        out += await selections()
        if out.isEmpty { throw MusicError.notFound }
        return out
    }

    /// SoundCloud's curated home rows, when they answer without an account.
    private func selections() async -> [MusicBrowseSection] {
        guard let data = try? await client.data(path: "mixed-selections", query: ["limit": "10"]) else {
            MusicDebugLog.log("soundcloud", "mixed-selections did not answer")
            return []
        }
        var out: [MusicBrowseSection] = []
        for row in SoundCloudJSON.rows(SoundCloudJSON.any(data)).prefix(6) {
            guard let title = row.str("title"), let items = row.dict("items") else { continue }
            let playlists = SoundCloudJSON.rows(items).compactMap { SoundCloudJSON.playlist($0) }
            guard playlists.count >= 3 else { continue }
            out.append(MusicBrowseSection(id: "soundcloud-sel-" + (row.str("urn") ?? title), title: title,
                                          items: playlists.prefix(20).map { .playlist(SoundCloudMapping.playlist($0)) }, scope: .global))
        }
        let shelves = out
        MusicDebugLog.log("soundcloud", "mixed-selections gave \(shelves.count) shelves")
        return shelves
    }

    // MARK: genres

    func genres() async throws -> [MusicBrowseGenre] {
        let overall = await chart(genre: Self.overallGenre)
        let names = Self.topGenres(overall, limit: 12)
        if names.isEmpty { throw MusicError.notFound }
        return names.map { MusicBrowseGenre(id: $0, name: $0) }
    }

    func browse(genreID: String, page: MusicPagination?) async throws -> MusicPage<MusicBrowseSection> {
        let tracks = await chart(genre: "soundcloud:genres:" + Self.genreSlug(genreID), limit: 50)
        guard let s = await section(id: "soundcloud-genre-" + Self.genreSlug(genreID), title: genreID, tracks: tracks) else { throw MusicError.notFound }
        return MusicPage(items: [s])
    }
}
