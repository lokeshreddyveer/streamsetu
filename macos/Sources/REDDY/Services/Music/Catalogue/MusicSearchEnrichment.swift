import Foundation

/// Search integration: the ONE hook the search runner calls for every source's answer.
enum MusicSearchEnrichment {
    typealias Plain = @Sendable (any MusicMetadataProvider, String, MusicSearchKind, MusicPagination?) async throws -> MusicSearchChunk

    /// A source that can only describe songs: it has a catalogue role and no audio.
    static func isCatalogueOnly(_ caps: MusicCapabilities) -> Bool { caps.contains(.catalogue) && !caps.contains(.audio) }

    /// Wraps one source's search. Catalogue-only sources show songs only once a playable copy is verified; playable sources also get the
    /// catalogue's spelling of the query asked in the background and merged in. Any failure of the catalogue leaves the plain answer.
    static func run(provider: any MusicMetadataProvider, query: String, kind: MusicSearchKind, page: MusicPagination?, plain: Plain) async throws -> MusicSearchChunk {
        let runtime = MusicCatalogRuntime.shared
        guard runtime.isEnabled, let matcher = runtime.matcher, kind == .all || kind == .songs else { return try await plain(provider, query, kind, page) }
        await runtime.refreshCountry()
        if isCatalogueOnly(provider.capabilities) {
            var chunk = try await plain(provider, query, kind, page)
            chunk.results = await onlyPlayable(chunk.results, matcher: matcher)
            return chunk
        }
        guard provider.capabilities.contains(.audio) || provider.capabilities.contains(.search) else { return try await plain(provider, query, kind, page) }
        async let expansion = matcher.expand(query)
        var chunk = try await plain(provider, query, kind, page)
        let exp = await expansion
        guard page == nil || kind == .all, exp.canonical != nil else { return chunk }
        var seen = Set(chunk.results.compactMap { r -> String? in if case .track(let t) = r { t.uid } else { nil } })
        for q in exp.queries.prefix(2) {
            guard let more = try? await MusicStreamResolver.withDeadline(4, { try await provider.searchTracks(q, page: nil).items }) else { continue }
            for t in more where seen.insert(t.uid).inserted { chunk.results.append(.track(t)) }
        }
        return chunk
    }

    /// A catalogue source's answer for search: its own albums, artists and playlists never show; each song shows only as its verified playable twin
    /// (the twin is a track of a playable source), in the catalogue's order, without repeats.
    static func onlyPlayable(_ results: [MusicSearchResult], matcher: MusicCatalogMatcher) async -> [MusicSearchResult] {
        let tracks = results.compactMap { r -> MusicTrack? in if case .track(let t) = r { t } else { nil } }
        guard !tracks.isEmpty else { return [] }
        let twins = await matcher.playable(tracks)
        var out: [MusicSearchResult] = []
        var seen = Set<String>()
        for w in twins { if let w, seen.insert(w.uid).inserted { out.append(.track(w)) } }
        return out
    }

    /// Playlist and chart tracks from a catalogue list: only the verified-playable ones, no placeholder rows and no count of what was left out.
    static func playableOnly(_ tracks: [MusicTrack]) async -> [MusicTrack] {
        let rt = MusicCatalogRuntime.shared
        guard rt.isEnabled, let m = rt.matcher else { return tracks }
        return await m.playable(tracks, budget: 10).compactMap { $0 }
    }
}
