import Foundation

/// The app's TMDB client, handed to Music by the app container. Music has no TMDB key of its own: it asks through the app's one client, which
/// applies the person's TMDB switch, the built-in or own key, pacing and the refusal pause. Nothing is set (so nothing is asked) in tests.
final class MusicFilmTMDBGate: @unchecked Sendable {
    typealias Fetch = @Sendable (String, [URLQueryItem]) async throws -> Data
    static let shared = MusicFilmTMDBGate()
    private let lock = NSLock()
    private var _fetch: Fetch?
    func install(_ f: @escaping Fetch) { lock.lock(); _fetch = f; lock.unlock() }
    var fetch: Fetch? { lock.lock(); defer { lock.unlock() }; return _fetch }
}

/// One place that can say who made a film. TMDB, Wikidata and the music source's own names each implement it, so a later metadata layer can
/// host them (or add MusicBrainz, Discogs) without touching the resolver, the cache or the views.
protocol MusicFilmSource: Sendable {
    var source: MusicFilmInfo.Source { get }
    func film(for identity: MusicFilmIdentity) async throws -> MusicFilmInfo?
}

struct MusicTMDBFilmSource: MusicFilmSource {
    var tmdb: MusicFilmTMDBGate.Fetch?
    var source: MusicFilmInfo.Source { .tmdb }

    func film(for identity: MusicFilmIdentity) async throws -> MusicFilmInfo? {
        guard let tmdb else { return nil }
        var query = [URLQueryItem(name: "query", value: identity.title), URLQueryItem(name: "include_adult", value: "false"), URLQueryItem(name: "language", value: MusicLanguagePolicy.tmdbText())]
        var hits = MusicFilmTMDBParser.credits(from: try await tmdb("/3/search/movie", query))
        if hits.isEmpty, let y = identity.year {
            query.append(URLQueryItem(name: "year", value: String(y)))
            hits = MusicFilmTMDBParser.credits(from: try await tmdb("/3/search/movie", query))
        }
        let ranked = hits.compactMap { h -> (MusicFilmCredit, Double)? in
            MusicFilmMatch.score(identity: identity, titles: [h.title, h.originalTitle], year: h.year, language: h.language, popularity: h.popularity).map { (h, $0) }
        }.sorted { $0.1 > $1.1 }
        for (hit, score) in ranked.prefix(3) {
            let data = try await tmdb("/3/movie/\(hit.tmdbID)", [URLQueryItem(name: "append_to_response", value: "credits"), URLQueryItem(name: "language", value: MusicLanguagePolicy.tmdbText())])
            if var info = MusicFilmTMDBParser.film(from: data), MusicFilmMatch.accepts(info, identity: identity) {
                info.singers = identity.singers
                info.provenance = MusicFilmProvenance(source: .tmdb, retrievedAt: Date(), confidence: min(1, max(0, score)))
                return info
            }
        }
        return nil
    }
}

struct MusicWikidataFilmSource: MusicFilmSource {
    var http: MusicHTTP = MusicHTTP()
    var source: MusicFilmInfo.Source { .wikidata }
    static let api = URL(string: "https://www.wikidata.org/w/api.php")!

    func film(for identity: MusicFilmIdentity) async throws -> MusicFilmInfo? {
        let search = try await http.get(Self.api, query: ["action": "wbsearchentities", "search": identity.title, "language": "en", "type": "item", "limit": "10", "format": "json"])
        let ranked = MusicFilmWikidataParser.searchHits(from: search).compactMap { h -> (MusicFilmWikidataParser.Hit, Double)? in
            MusicFilmMatch.score(identity: identity, titles: [h.label], year: h.year, language: nil).map { (h, $0) }
        }.sorted { $0.1 > $1.1 }
        for (hit, score) in ranked.prefix(2) {
            let d = try await http.get(Self.api, query: ["action": "wbgetentities", "ids": hit.id, "props": "claims", "format": "json"])
            guard let film = MusicFilmWikidataParser.film(from: d, id: hit.id), !film.cast.isEmpty || !film.directors.isEmpty else { continue }
            let ids = Array(film.cast.prefix(8) + film.directors.prefix(2) + film.composers.prefix(2))
            let peopleData = try await http.get(Self.api, query: ["action": "wbgetentities", "ids": ids.joined(separator: "|"), "props": "labels|claims", "languages": "en", "format": "json"])
            let people = MusicFilmWikidataParser.people(from: peopleData)
            func list(_ ids: [String], limit: Int) -> [MusicFilmPerson] { ids.prefix(limit).compactMap { people[$0] } }
            var info = MusicFilmInfo(title: hit.label, year: film.year ?? hit.year, language: identity.language, tmdbID: nil, wikidataID: hit.id,
                                     cast: list(film.cast, limit: 8), directors: list(film.directors, limit: 2), composers: list(film.composers, limit: 2),
                                     singers: identity.singers, source: .wikidata)
            info.provenance = MusicFilmProvenance(source: .wikidata, retrievedAt: Date(), confidence: min(1, max(0, score)))
            if MusicFilmMatch.accepts(info, identity: identity), info.isUseful { return info }
        }
        return nil
    }
}

/// Names only, from what the music source itself credited (JioSaavn "starring"). The last resort.
struct MusicProviderNamesFilmSource: MusicFilmSource {
    var source: MusicFilmInfo.Source { .provider }
    func film(for identity: MusicFilmIdentity) async throws -> MusicFilmInfo? {
        guard !identity.starring.isEmpty else { return nil }
        func people(_ names: [String]) -> [MusicFilmPerson] { names.map { MusicFilmPerson(name: $0) } }
        var info = MusicFilmInfo(title: identity.title, year: identity.year, language: identity.language, cast: people(Array(identity.starring.prefix(8))),
                                 composers: people(identity.musicBy), singers: identity.singers, source: .provider)
        info.provenance = MusicFilmProvenance(source: .provider, retrievedAt: Date(), confidence: 0.6)
        return info
    }
}

/// Finds a film's cast and crew through its sources in order (TMDB, Wikidata, the music source's names) and caches the answer on disk for 30
/// days. The cache stores `MusicFilmInfo` values only, never view state.
struct MusicFilmService: Sendable {
    var sources: [any MusicFilmSource]
    var cache: MusicFilmCache = .shared
    /// Whether TMDB was given to this service (a key and the switch on). Decided from the client the service was built with, not from the global gate.
    private var tmdbOn: Bool

    init(sources: [any MusicFilmSource]? = nil, tmdb: MusicFilmTMDBGate.Fetch? = MusicFilmTMDBGate.shared.fetch, http: MusicHTTP = MusicHTTP(), cache: MusicFilmCache = .shared) {
        let base = sources ?? [MusicTMDBFilmSource(tmdb: tmdb), MusicWikidataFilmSource(http: http), MusicProviderNamesFilmSource()]
        // With the metadata layer installed, whatever the default sources find also lands in the graph (in the background; the answer is unchanged).
        if sources == nil, let r = MusicFilmGraphLink.shared.resolver { self.sources = MusicGraphWritingFilmSource.wrap(base, resolver: r) } else { self.sources = base }
        self.cache = cache
        self.tmdbOn = tmdb != nil
    }

    /// The film info for an identity: from the cache, else looked up. Nil when no source has the film with enough confidence.
    func info(for identity: MusicFilmIdentity) async -> MusicFilmInfo? {
        let key = identity.cacheKey
        if let hit = cache.read(MusicFilmInfo.self, key: key) { return hit }
        var found: MusicFilmInfo?
        var networkFailed = !tmdbOn   // TMDB switched off or without a key: what a weaker source says is shown, not remembered
        for s in sources {
            do { if let f = try await s.film(for: identity) { found = f; break } }
            catch is CancellationError { return nil }
            catch MusicError.cancelled { return nil }
            catch let e as URLError where e.code == .cancelled { return nil }
            catch { networkFailed = true }
            if Task.isCancelled { return nil }
        }
        // A failed network is not a miss: only a real answer is remembered.
        // A weaker answer found after a source failed (names only after TMDB threw) is shown but not remembered, so the next visit asks the better source again.
        if let f = found { if !networkFailed { cache.write(f, key: key) } } else if !networkFailed { cache.write(Optional<MusicFilmInfo>.none, key: key) }
        return found
    }
}
