import Foundation

// TMDB lists behind the all-time and genre views of the ranked shelves.
// Privacy: a request carries only a public list name (top_rated, or a genre id with a sort order). Nothing about the person is sent; the lists are matched locally.
// Same credential rules, activation and 180-day cap as the weekly list (SMTrendingPolicy); an inactive policy makes no request and stores nothing.

/// Cache keys: "top" (all-time best, movies and series), "week:<genre>" (popularity now), "top:<genre>" (best rated with enough votes).
enum SMListKey {
    static let top = "top"
    static func week(_ genre: String) -> String { "week:" + genre }
    static func allTime(_ genre: String) -> String { "top:" + genre }
    /// The list a shelf follows in a mode. A genre shelf falls back to the whole-library list of the same mode when its own is missing.
    static func forShelf(_ shelf: String, mode: SMShelfMode) -> (own: String?, general: String?) {
        if SMShelf.isGenre(shelf) {
            let g = String(shelf.dropFirst(SMGenres.shelfPrefix.count))
            return (mode == .weekly ? week(g) : allTime(g), mode == .weekly ? "week" : top)
        }
        if shelf == SMShelf.trendingLibrary { return (nil, mode == .weekly ? "week" : top) }
        return (nil, nil)
    }
    /// Time before a cached list is fetched again.
    static func refetchHours(_ key: String) -> Int { key.hasPrefix("week") ? 24 : 24 * 7 }
}

protocol SMListFetching: Sendable { func fetch(_ key: String) async throws -> [SMTrendingEntry] }

protocol SMListsCacheStore: Sendable {
    func load() -> [String: SMTrendingCache]
    func save(_ lists: [String: SMTrendingCache])
    func clear()
}

final class DefaultsListsCache: SMListsCacheStore, @unchecked Sendable {
    static let key = "smartmix.lists.cache"
    private let defaults: UserDefaults
    init(_ d: UserDefaults) { defaults = d }
    func load() -> [String: SMTrendingCache] { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: SMTrendingCache].self, from: $0) } ?? [:] }
    func save(_ lists: [String: SMTrendingCache]) { if let d = try? JSONEncoder().encode(lists) { defaults.set(d, forKey: Self.key) } }
    func clear() { defaults.removeObject(forKey: Self.key) }
}

#if DEBUG
final class InMemoryListsCache: SMListsCacheStore, @unchecked Sendable {
    private var value: [String: SMTrendingCache]
    private let lock = NSLock()
    init(_ v: [String: SMTrendingCache] = [:]) { value = v }
    func load() -> [String: SMTrendingCache] { lock.withLock { value } }
    func save(_ lists: [String: SMTrendingCache]) { lock.withLock { value = lists } }
    func clear() { lock.withLock { value = [:] } }
}
#endif

actor SMListsService {
    private let fetcher: SMListFetching
    private let cache: SMListsCacheStore
    private var policy: SMTrendingPolicy

    init(fetcher: SMListFetching, cache: SMListsCacheStore, policy: SMTrendingPolicy) { self.fetcher = fetcher; self.cache = cache; self.policy = policy }

    func setPolicy(_ p: SMTrendingPolicy) { policy = p; if !p.isActive { cache.clear() } }

    /// Fetches the named lists that are missing or due (one at a time, a failure keeps the old copy), drops lists past the 6-month cap.
    func refresh(_ keys: [String], now: Date) async {
        guard policy.isActive else { return }
        var all = cache.load()
        for (k, v) in all where policy.status(cache: v, now: now) == .purged { all[k] = nil }
        for key in keys {
            let c = all[key]
            let due = c.map { Int(now.timeIntervalSince($0.fetchedAt)) >= SMListKey.refetchHours(key) * 3600 } ?? true
            if due, let entries = try? await fetcher.fetch(key), !entries.isEmpty { all[key] = SMTrendingCache(fetchedAt: now, entries: entries) }
        }
        cache.save(all)
    }

    /// Entries usable for ranking now, per key (only lists that are fresh enough: the same rule as the weekly list).
    func current(now: Date) -> [String: [SMTrendingEntry]] {
        guard policy.isActive else { return [:] }
        var out: [String: [SMTrendingEntry]] = [:]
        for (k, v) in cache.load() where policy.status(cache: v, now: now) == .active { out[k] = v.entries }
        return out
    }
}

struct SMTMDBListClient: SMListFetching {
    enum Failure: Error { case disabled, http(Int), badResponse, unknownList }
    let keys: SMTMDBKeyProvider
    var session: URLSession = .shared

    func fetch(_ key: String) async throws -> [SMTrendingEntry] {
        guard let cred = keys.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !cred.isEmpty else { throw Failure.disabled }
        var parts: [[SMTrendingEntry]] = []
        if key == SMListKey.top {
            for type in ["movie", "tv"] { parts.append(try await get("/\(type)/top_rated", [("page", "1")], type, cred) + get("/\(type)/top_rated", [("page", "2")], type, cred)) }
        } else {
            let bits = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard bits.count == 2, let def = SMGenres.byKey[bits[1]] else { throw Failure.unknownList }
            let weekly = bits[0] == "week"
            for (type, ids) in [("movie", def.tmdbMovie), ("tv", def.tmdbTV)] where !ids.isEmpty {
                var q: [(String, String)] = [("with_genres", ids.map(String.init).joined(separator: "|")), ("include_adult", "false"), ("page", "1")]
                if let l = def.tmdbLang { q.append(("with_original_language", l)) }
                if weekly { q.append(("sort_by", "popularity.desc")) }
                else { q += [("sort_by", "vote_average.desc"), ("vote_count.gte", type == "movie" ? "300" : "150")] }
                parts.append(try await get("/discover/\(type)", q, type, cred))
            }
            if parts.isEmpty { throw Failure.unknownList }
        }
        // One rank for both kinds: movie 1, series 1, movie 2, ...
        var out: [SMTrendingEntry] = []
        for i in 0..<(parts.map(\.count).max() ?? 0) { for p in parts where i < p.count { out.append(p[i]) } }
        for i in out.indices { out[i].rank = i + 1 }
        return out
    }

    private func get(_ path: String, _ query: [(String, String)], _ type: String, _ cred: String) async throws -> [SMTrendingEntry] {
        guard var comps = URLComponents(string: "https://api.themoviedb.org/3" + path) else { throw Failure.badResponse }
        var items = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        var bearer = false
        if MetadataMatchService.isBearerToken(cred) { bearer = true } else { items.append(URLQueryItem(name: "api_key", value: cred)) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        if bearer { req.setValue("Bearer " + cred, forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 15
        req.allowsConstrainedNetworkAccess = true; req.allowsExpensiveNetworkAccess = true
        req.httpShouldHandleCookies = false
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Failure.badResponse }
        if BuiltInKeyPause.isRefusal(http.statusCode) { keys.reportRejected() }
        guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let results = obj["results"] as? [[String: Any]] else { throw Failure.badResponse }
        return results.map { r in
            let title = (r["title"] as? String) ?? (r["name"] as? String) ?? ""
            let orig = (r["original_title"] as? String) ?? (r["original_name"] as? String)
            let date = (r["release_date"] as? String) ?? (r["first_air_date"] as? String) ?? ""
            return SMTrendingEntry(rank: 0, type: type, title: title, original: orig, year: Int(date.prefix(4)))
        }.filter { !$0.title.isEmpty }
    }
}
