import Foundation

/// The resolver as the navigation layer's `MusicEntityEnriching` hook: one call per opened entity, in the background, never on the playback path.
/// A page that opens while every source is off, offline or fresh gets an empty `changed` set and shows what the store holds.
struct MusicGraphEnricher: MusicEntityEnriching {
    let resolver: MusicEntityResolver
    /// A provider's own credits for the recording (YouTube Music's song-credits panel), asked in the same background run. Nil leaves enrichment as it was.
    var credits: MusicRecordingCreditsFetcher? = nil

    private func result(_ o: MusicMetadataOutcome) -> MusicEnrichmentResult {
        var changed = Set<MusicEntityID>()
        if o.edgesWritten > 0 || !o.fetched.isEmpty { if let e = o.entity { changed.insert(e) }; if let f = o.linkedFilm { changed.insert(f) } }
        return MusicEnrichmentResult(changed: changed)
    }

    func enrichTrack(_ id: MusicEntityID) async throws -> MusicEnrichmentResult {
        try Task.checkCancellation()
        // Runs beside the metadata sources, never in front of them: it asks only for a YouTube Music recording that has a video id.
        async let providerCredits = credits?.run(id)
        var out = result(await resolver.enrichRecording(id))
        if let extra = await providerCredits { out.changed.formUnion(extra.changed) }
        return out
    }
    func enrichAlbum(_ id: MusicEntityID) async throws -> MusicEnrichmentResult { try Task.checkCancellation(); return result(await resolver.enrichAlbum(id)) }
    func enrichFilm(_ id: MusicEntityID) async throws -> MusicEnrichmentResult { try Task.checkCancellation(); return result(await resolver.enrichFilm(id)) }
    func enrichPerson(_ id: MusicEntityID) async throws -> MusicEnrichmentResult { try Task.checkCancellation(); return result(await resolver.enrichPerson(id)) }
}

/// The sources of the metadata layer, built over one governor. TMDB is optional (it takes the app's gate); OMDb and Last.fm only work when the person
/// supplied a key; Discogs is built and off by default.
enum MusicMetadataSources {
    static func make(transport: any MusicMetadataTransport, tmdb: MusicFilmTMDBGate.Fetch?, omdbKey: @escaping @Sendable () -> String? = { nil },
                     lastFMKey: @escaping @Sendable () -> String? = { LastFMKeys.current()?.apiKey }, discogsToken: @escaping @Sendable () -> String? = { nil }) -> [any MusicMetadataSource] {
        [MusicBrainzSource(transport: transport), WikidataSource(transport: transport), WikipediaSource(transport: transport), IMDbSource(transport: transport),
         ListenBrainzGraphSource(transport: transport), TMDBGraphSource(gate: tmdb), OMDbSource(transport: transport, key: omdbKey),
         DiscogsSource(transport: transport, token: discogsToken), LastFMGraphSource(transport: transport, key: lastFMKey)]
    }
}
