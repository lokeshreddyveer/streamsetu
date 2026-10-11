import Foundation

/// Movie and series details are fetched on demand, cached in the database, and de-duplicated while in flight.
actor DetailService {
    private let catalog: CatalogRepository
    private let indexer: CatalogIndexer
    private let sources: SourceManager
    private var movieTasks: [String: Task<Movie, Error>] = [:]
    private var seriesTasks: [String: Task<SeriesDetail, Error>] = [:]
    /// Trailer, cast and similar facts the provider sent, kept for the session (they are not stored with the catalog).
    private var extrasCache: [String: ProviderExtras] = [:]
    private let movieTTL: TimeInterval = 7 * 86400
    private let seriesTTL: TimeInterval = 12 * 3600

    init(catalog: CatalogRepository, indexer: CatalogIndexer, sources: SourceManager) {
        self.catalog = catalog; self.indexer = indexer; self.sources = sources
    }

    func movie(id: String, force: Bool = false) async throws -> Movie {
        guard let m = try catalog.movie(id: id) else { throw SourceError.invalidResponse("Movie not found") }
        if !force, let t = m.detailFetchedAt, Date().timeIntervalSince(t) < movieTTL { return m }
        if let t = movieTasks[id] { return try await t.value }
        let task = Task<Movie, Error> { [catalog, indexer, sources] in
            let source = try catalog.source(id: m.sourceID)
            do {
                guard let source else { throw SourceError.invalidResponse("Source missing") }
                let detail = try await sources.makeProvider(for: source).movieDetail(m)
                try indexer.saveMovieDetail(id: id, detail: detail)
                if let e = detail.extras { self.remember(id, e) }
            } catch is CancellationError { throw CancellationError() }
            catch { /* provider has no details: show what the list already knows */ Log.sync.info("movie detail unavailable") }
            return try catalog.movie(id: id) ?? m
        }
        movieTasks[id] = task
        defer { movieTasks[id] = nil }
        return try await task.value
    }

    func series(id: String, force: Bool = false) async throws -> SeriesDetail {
        guard let s = try catalog.seriesItem(id: id) else { throw SourceError.invalidResponse("Series not found") }
        let cached = (try? catalog.episodes(seriesID: id)) ?? []
        if !force, !cached.isEmpty, let t = s.lastMetadataRefresh, Date().timeIntervalSince(t) < seriesTTL {
            return SeriesDetail(series: s, seasons: try catalog.seasons(seriesID: id), episodes: cached)
        }
        if let t = seriesTasks[id] { return try await t.value }
        let task = Task<SeriesDetail, Error> { [catalog, indexer, sources] in
            guard let source = try catalog.source(id: s.sourceID) else { throw SourceError.invalidResponse("Source missing") }
            do {
                let detail = try await sources.makeProvider(for: source).seriesDetail(s)
                try indexer.saveSeriesDetail(detail)
                if let e = detail.extras { self.remember(s.id, e) }
            } catch is CancellationError { throw CancellationError() }
            catch { if cached.isEmpty { throw error } }      // keep showing cached episodes if a refresh fails
            let fresh = try catalog.seriesItem(id: id) ?? s
            return SeriesDetail(series: fresh, seasons: try catalog.seasons(seriesID: id), episodes: try catalog.episodes(seriesID: id))
        }
        seriesTasks[id] = task
        defer { seriesTasks[id] = nil }
        return try await task.value
    }

    private func remember(_ id: String, _ e: ProviderExtras) { extrasCache[id] = e }

    /// What the provider says about a movie beyond the basics. Asks the provider again when the details were served from the cache.
    func extras(movie id: String) async -> ProviderExtras? {
        if let e = extrasCache[id] { return e }
        guard let m = try? catalog.movie(id: id), let source = try? catalog.source(id: m.sourceID),
              let e = try? await sources.makeProvider(for: source).movieDetail(m).extras else { return nil }
        extrasCache[id] = e
        return e
    }

    func extras(series id: String) async -> ProviderExtras? {
        if let e = extrasCache[id] { return e }
        guard let s = try? catalog.seriesItem(id: id), let source = try? catalog.source(id: s.sourceID),
              let e = try? await sources.makeProvider(for: source).seriesDetail(s).extras else { return nil }
        extrasCache[id] = e
        return e
    }
}
