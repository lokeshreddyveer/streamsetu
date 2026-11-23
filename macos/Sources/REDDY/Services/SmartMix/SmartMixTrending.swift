import Foundation

// TMDB weekly trending for "Top This Week" / "Trending in Your Library".
// Privacy: the only network request is the public weekly trending list. Nothing about the person (library, history, folders, profile, device) is sent.
// The list is matched locally. ON by default; ACTIVE with the person's own TMDB key or the built-in token when this build has one (TMDBAccess).

struct SMTrendingEntry: Codable, Sendable, Equatable {
    var rank: Int
    var type: String            // "movie" | "tv"
    var title: String
    var original: String?
    var year: Int?
}

struct SMTrendingCache: Codable, Sendable, Equatable {
    var fetchedAt: Date
    var entries: [SMTrendingEntry]
}

enum SMTrendingStatus: String, Sendable { case off, noCache, active, expired, purged }

/// Cache and activation policy. All thresholds in one place.
struct SMTrendingPolicy: Sendable {
    /// "Use TMDB weekly trending" switch. Default ON; has no effect without a credential (own key or built-in token).
    var enabled = true
    var hasOwnKey = false
    static let displayFreshDays = Retention.trendingFreshDays      // older: shown local-only until refreshed
    static let maxCacheDays = Retention.maxKeepDays         // owner cap: nothing is kept longer than 6 months
    static let refetchAfterHours = 24     // a weekly list: at most one refresh a day
    static let minMatchesForTopWeek = 6

    var isActive: Bool { enabled && hasOwnKey }

    /// Status of `cache` at `now`. Integer seconds only.
    func status(cache: SMTrendingCache?, now: Date) -> SMTrendingStatus {
        guard isActive else { return .off }
        guard let cache else { return .noCache }
        let days = max(0, Int(now.timeIntervalSince(cache.fetchedAt)) / 86_400)
        if days > Self.maxCacheDays { return .purged }
        if days > Self.displayFreshDays { return .expired }
        return .active
    }

    func needsRefetch(cache: SMTrendingCache?, now: Date) -> Bool {
        guard isActive else { return false }
        guard let cache else { return true }
        return Int(now.timeIntervalSince(cache.fetchedAt)) >= Self.refetchAfterHours * 3600
    }
}

protocol SMTrendingFetching: Sendable { func fetchWeekly() async throws -> [SMTrendingEntry] }
protocol SMTrendingCacheStore: Sendable {
    func load() -> SMTrendingCache?
    func save(_ cache: SMTrendingCache)
    func clear()
}
protocol SMTMDBKeyProvider: Sendable { var apiKey: String? { get }; func reportRejected() }
extension SMTMDBKeyProvider { func reportRejected() {} }

enum SMTrendingMatcher {
    /// Normalises a title for matching. Must equal the identity layer's key function once that is wired (the matcher takes `normalize`).
    static func fold(_ title: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for s in title.decomposedStringWithCompatibilityMapping.unicodeScalars {
            if s.properties.canonicalCombiningClass != .notReordered { continue }
            for l in String(s).lowercased().unicodeScalars {
                let v = l.value
                if (v >= 48 && v <= 57) || (v >= 97 && v <= 122) || v >= 0x80 {
                    if pendingSpace && !out.isEmpty { out.append(" ") }
                    pendingSpace = false
                    out.append(l)
                } else { pendingSpace = true }
            }
        }
        var words = String(out).split(separator: " ").map(String.init)
        if words.count > 1, ["the", "a", "an"].contains(words[0]) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// candidate id -> lowest TMDB rank. Kind movie<->movie, tv<->series; year within 1 when both known; title or original title.
    static func match(entries: [SMTrendingEntry], candidates: [SMCandidate], normalize: (String) -> String = fold) -> [String: Int] {
        struct K: Hashable { let kind: SMKind; let key: String }
        var index: [K: [Int]] = [:]
        for (i, c) in candidates.enumerated() { index[K(kind: c.kind, key: c.key), default: []].append(i) }
        var res: [String: Int] = [:]
        for e in entries.sorted(by: { $0.rank < $1.rank }) {
            let kind: SMKind = e.type == "movie" ? .movie : .series
            var names: Set<String> = [normalize(e.title)]
            if let o = e.original, !o.isEmpty { names.insert(normalize(o)) }
            for nm in names {
                for i in index[K(kind: kind, key: nm)] ?? [] {
                    let c = candidates[i]
                    if let ey = e.year, let cy = c.year, abs(ey - cy) > 1 { continue }
                    if res[c.id] == nil { res[c.id] = e.rank }
                }
            }
        }
        return res
    }
}

/// Fetch + cache coordinator. Does nothing (no request, nothing stored) unless the policy is active.
actor SMTrendingService {
    private let fetcher: SMTrendingFetching
    private let cache: SMTrendingCacheStore
    private var policy: SMTrendingPolicy

    init(fetcher: SMTrendingFetching, cache: SMTrendingCacheStore, policy: SMTrendingPolicy) {
        self.fetcher = fetcher; self.cache = cache; self.policy = policy
    }

    func setPolicy(_ p: SMTrendingPolicy) {
        policy = p
        if !p.isActive { cache.clear() }           // off or key removed: forget the list
    }

    /// Refreshes when due. Failure keeps the old cache (until the 6-month cap). Returns the status afterwards.
    @discardableResult
    func refreshIfNeeded(now: Date) async -> SMTrendingStatus {
        guard policy.isActive else { return .off }
        var c = cache.load()
        if policy.status(cache: c, now: now) == .purged { cache.clear(); c = nil }
        if policy.needsRefetch(cache: c, now: now) {
            if let entries = try? await fetcher.fetchWeekly(), !entries.isEmpty { let n = SMTrendingCache(fetchedAt: now, entries: entries); cache.save(n); c = n }
        }
        return policy.status(cache: c, now: now)
    }

    /// Entries usable for ranking right now (nil unless status is active).
    func current(now: Date) -> (entries: [SMTrendingEntry]?, status: SMTrendingStatus) {
        var c = cache.load()
        let st = policy.status(cache: c, now: now)
        if st == .purged { cache.clear(); c = nil }
        return (st == .active ? c?.entries : nil, st)
    }
}

// MARK: in-memory fakes (tests only)
#if DEBUG
final class InMemoryTrendingCacheStore: SMTrendingCacheStore, @unchecked Sendable {
    private var value: SMTrendingCache?
    private let lock = NSLock()
    init(_ v: SMTrendingCache? = nil) { value = v }
    func load() -> SMTrendingCache? { lock.withLock { value } }
    func save(_ cache: SMTrendingCache) { lock.withLock { value = cache } }
    func clear() { lock.withLock { value = nil } }
}

final class FakeTrendingFetcher: SMTrendingFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var result: Result<[SMTrendingEntry], Error>
    var calls: Int { lock.withLock { _calls } }
    init(_ r: Result<[SMTrendingEntry], Error>) { result = r }
    func fetchWeekly() async throws -> [SMTrendingEntry] { lock.withLock { _calls += 1 }; return try result.get() }
}
#endif

// MARK: thin network client (OFF unless the person entered their own key)
struct SMTMDBTrendingClient: SMTrendingFetching {
    enum Failure: Error { case disabled, http(Int), badResponse }
    let keys: SMTMDBKeyProvider
    var session: URLSession = .shared

    func fetchWeekly() async throws -> [SMTrendingEntry] {
        guard let key = keys.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { throw Failure.disabled }
        async let movies = list("movie", key), tv = list("tv", key)
        let (m, t) = try await (movies, tv)
        // Interleave by position (movie 1, tv 1, movie 2, ...) and renumber, so one rank orders both kinds.
        var out: [SMTrendingEntry] = []
        for i in 0..<max(m.count, t.count) {
            if i < m.count { out.append(m[i]) }
            if i < t.count { out.append(t[i]) }
        }
        for i in out.indices { out[i].rank = i + 1 }
        return out
    }

    private func list(_ type: String, _ key: String) async throws -> [SMTrendingEntry] {
        guard var comps = URLComponents(string: "https://api.themoviedb.org/3/trending/\(type)/week") else { throw Failure.badResponse }
        var req: URLRequest
        if MetadataMatchService.isBearerToken(key) { req = URLRequest(url: comps.url!); req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        else { comps.queryItems = [URLQueryItem(name: "api_key", value: key)]; req = URLRequest(url: comps.url!) }
        req.timeoutInterval = 15
        req.allowsConstrainedNetworkAccess = true; req.allowsExpensiveNetworkAccess = true
        req.httpShouldHandleCookies = false
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Failure.badResponse }
        if BuiltInKeyPause.isRefusal(http.statusCode) { keys.reportRejected() }          // a refused built-in token is set aside for a while
        guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let results = obj["results"] as? [[String: Any]] else { throw Failure.badResponse }
        return results.enumerated().map { i, r in
            let title = (r["title"] as? String) ?? (r["name"] as? String) ?? ""
            let orig = (r["original_title"] as? String) ?? (r["original_name"] as? String)
            let date = (r["release_date"] as? String) ?? (r["first_air_date"] as? String) ?? ""
            return SMTrendingEntry(rank: i + 1, type: type, title: title, original: orig, year: Int(date.prefix(4)))
        }.filter { !$0.title.isEmpty }
    }
}
