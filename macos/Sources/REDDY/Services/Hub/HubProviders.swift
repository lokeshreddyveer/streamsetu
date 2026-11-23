import Foundation

// Provider protocols (one per capability) and the three new providers. Views never name a provider; only MetadataHub calls these.

typealias HubFetch = @Sendable (URLRequest) async throws -> Data

struct HubEpisode: Sendable, Equatable {
    var season: Int; var number: Int
    var name: String?; var summary: String?
    var airdate: String?; var airstamp: String?
    var runtime: Int?; var imageURL: String?; var rating: Double?
}
struct HubSeason: Sendable, Equatable { var number: Int; var episodeCount: Int?; var premiere: String?; var end: String? }
struct HubEpisodes: Sendable, Equatable {
    var source: HubSource
    var status: String?
    var seasons: [HubSeason] = []
    var episodes: [HubEpisode] = []
    var next: HubEpisode?
    var rating: Double?
    var ids = HubIdentity()
    var updated: Int?
}
struct ScheduleEntry: Sendable, Equatable { var tvmazeID: Int; var show: String; var tvdb: Int?; var imdb: String?; var season: Int?; var number: Int?; var airstamp: String? }
struct TrendingEntry: Sendable, Equatable { var tmdbID: Int; var kind: HubTitleKind }
struct RatingCandidate: Sendable, Equatable { var source: HubSource; var average: Double; var votes: Int? }

protocol HubProvider: Sendable { var source: HubSource { get } }
protocol ArtworkProvider: HubProvider { func artwork(for id: HubIdentity, kind: HubTitleKind) async throws -> [ArtCandidate] }
protocol RatingProvider: HubProvider { func rating(for id: HubIdentity, kind: HubTitleKind) async throws -> RatingCandidate? }
protocol EpisodeProvider: HubProvider { func episodes(for id: HubIdentity) async throws -> HubEpisodes? }
protocol ScheduleProvider: HubProvider { func schedule(date: String, country: String?, web: Bool) async throws -> [ScheduleEntry] }
protocol TrendingProvider: HubProvider { func trending(kind: HubTitleKind, week: Bool) async throws -> [TrendingEntry] }

private func json(_ d: Data) -> Any? { try? JSONSerialization.jsonObject(with: d) }
private func int(_ v: Any?) -> Int? { if let i = v as? Int { return i }; if let s = v as? String { return Int(s) }; if let d = v as? Double { return Int(d) }; return nil }
private func str(_ v: Any?) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }
private func https(_ s: String) -> String { s.hasPrefix("http://") ? "https://" + s.dropFirst(7) : s }

// MARK: fanart.tv

/// fanart.tv (API v3.2). Express lane only: never queued in bulk (its terms forbid crawling). The key goes in a header, never the address.
struct FanartProvider: ArtworkProvider {
    let source = HubSource.fanart
    let keys: @Sendable () -> FanartKeys?
    let fetch: HubFetch
    static let host = "webservice.fanart.tv"

    static func request(kind: HubTitleKind, id: String, keys: FanartKeys) -> URLRequest? {
        var c = URLComponents(); c.scheme = "https"; c.host = host; c.path = "/v3.2/" + (kind == .movie ? "movies/" : "tv/") + id
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue(keys.projectKey, forHTTPHeaderField: "api-key")
        if let k = keys.clientKey { r.setValue(k, forHTTPHeaderField: "client-key") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    func artwork(for id: HubIdentity, kind: HubTitleKind) async throws -> [ArtCandidate] {
        guard let k = keys(), let qid = id.queryID(for: .fanart, kind: kind), let req = Self.request(kind: kind, id: qid, keys: k) else { return [] }
        return Self.parse(try await fetch(req), kind: kind)
    }

    /// Nominal sizes: the reply carries none, but each type has a fixed size on the site.
    private static let slots: [(key: String, kind: ArtKind, w: Int, h: Int, tv: Bool?)] = [
        ("hdmovielogo", .logo, 800, 310, false), ("movielogo", .logo, 400, 155, false), ("moviebackground", .backdrop, 1920, 1080, false),
        ("movieposter", .poster, 1000, 1426, false), ("moviebanner", .banner, 1000, 185, false), ("moviethumb", .thumb, 1000, 562, false),
        ("hdtvlogo", .logo, 800, 310, true), ("clearlogo", .logo, 400, 155, true), ("showbackground", .backdrop, 1920, 1080, true),
        ("tvposter", .poster, 1000, 1426, true), ("tvbanner", .banner, 1000, 185, true), ("tvthumb", .thumb, 1000, 562, true),
        ("seasonposter", .seasonPoster, 1000, 1426, true),
    ]
    static func parse(_ data: Data, kind: HubTitleKind) -> [ArtCandidate] {
        guard let root = json(data) as? [String: Any] else { return [] }
        var out: [ArtCandidate] = []
        for s in slots where s.tv == (kind == .series) {
            for e in (root[s.key] as? [[String: Any]]) ?? [] {
                guard let u = str(e["url"]) else { continue }
                var lang = str(e["lang"]); if lang == "00" { lang = "" }
                var c = ArtCandidate(kind: s.kind, url: https(u), source: .fanart, lang: lang, width: s.w, height: s.h, likes: int(e["likes"]) ?? 0)
                if s.kind == .seasonPoster { let sn = str(e["season"]); if sn == "all" { continue }; c.season = sn.flatMap(Int.init) }
                out.append(c)
            }
        }
        return out
    }
}

// MARK: TheTVDB

/// TheTVDB v4. The project key (or the person's subscriber key + PIN) logs in once; the 30-day token is kept in memory and the Keychain, only in an Authorization header.
actor TVDBSession {
    private let access: HubAccess
    private let fetch: HubFetch
    private var token: String?
    private var issued: Date?
    static let tokenAccount = "hub.tvdb.token"

    init(access: HubAccess, fetch: @escaping HubFetch) {
        self.access = access; self.fetch = fetch
        if let raw = access.secrets.get(Self.tokenAccount), let (t, at) = Self.decode(raw), access.now().timeIntervalSince(at) < HubAccess.tvdbTokenLife - 86400 { token = t; issued = at }
    }
    static func encode(_ t: String, _ at: Date) -> String { "\(Int(at.timeIntervalSince1970)):\(t)" }
    static func decode(_ s: String) -> (String, Date)? {
        guard let i = s.firstIndex(of: ":"), let n = TimeInterval(s[..<i]) else { return nil }
        return (String(s[s.index(after: i)...]), Date(timeIntervalSince1970: n))
    }

    static func loginRequest(apiKey: String, pin: String?) -> URLRequest? {
        guard let url = URL(string: "https://api4.thetvdb.com/v4/login") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 20); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.setValue("application/json", forHTTPHeaderField: "Accept")
        var body: [String: String] = ["apikey": apiKey]; if let pin, !pin.isEmpty { body["pin"] = pin }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }
    static func parseToken(_ d: Data) -> String? { ((json(d) as? [String: Any])?["data"] as? [String: Any]).flatMap { str($0["token"]) } }

    func currentToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let t = token, let at = issued, access.now().timeIntervalSince(at) < HubAccess.tvdbTokenLife - 86400 { return t }
        let own = access.ownKey
        guard let key = own ?? (access.builtInUsable ? access.builtIn() : nil), let req = Self.loginRequest(apiKey: key, pin: own == nil ? nil : access.pin) else { throw NetworkError.http(status: 401, retryAfter: nil) }
        do {
            let t = try await { () async throws -> String in
                guard let t = Self.parseToken(try await fetch(req)) else { throw NetworkError.unreadable }
                return t
            }()
            token = t; issued = access.now(); access.secrets.set(Self.encode(t, access.now()), for: Self.tokenAccount)
            return t
        } catch NetworkError.http(let s, let a) where BuiltInKeyPause.isRefusal(s) {
            access.markBuiltInRejected()
            token = nil; access.secrets.set(nil, for: Self.tokenAccount)
            throw NetworkError.http(status: s, retryAfter: a)
        }
    }
    func forget() { token = nil; issued = nil; access.secrets.set(nil, for: Self.tokenAccount) }

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        func req(_ t: String) -> URLRequest? {
            var c = URLComponents(); c.scheme = "https"; c.host = "api4.thetvdb.com"; c.path = "/v4" + path; c.queryItems = query.isEmpty ? nil : query
            guard let u = c.url else { return nil }
            var r = URLRequest(url: u, timeoutInterval: 20); r.setValue("Bearer " + t, forHTTPHeaderField: "Authorization"); r.setValue("application/json", forHTTPHeaderField: "Accept"); return r
        }
        guard let r1 = req(try await currentToken()) else { throw NetworkError.invalidURL }
        do { return try await fetch(r1) }
        catch NetworkError.http(let s, _) where s == 401 {              // an expired token: log in once more
            guard let r2 = req(try await currentToken(forceRefresh: true)) else { throw NetworkError.invalidURL }
            return try await fetch(r2)
        }
    }
}

struct TVDBProvider: ArtworkProvider, EpisodeProvider {
    let source = HubSource.tvdb
    let session: TVDBSession

    static func lang(_ three: String?) -> String? {
        guard let t = three?.lowercased(), !t.isEmpty else { return "" }
        let map = ["eng": "en", "hin": "hi", "tel": "te", "tam": "ta", "mal": "ml", "kan": "kn", "ben": "bn", "mar": "mr", "pan": "pa", "guj": "gu", "urd": "ur", "spa": "es", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "jpn": "ja", "kor": "ko", "zho": "zh", "ita": "it", "por": "pt", "rus": "ru", "tur": "tr", "ara": "ar"]
        return map[t] ?? String(t.prefix(2))
    }
    /// TheTVDB artwork type ids: series 1 banner, 2 poster, 3 background, 7 season poster, 23 clearlogo; movies 14 poster, 15 background, 16 banner, 25 clearlogo.
    static func parseArtworks(_ data: Data, kind: HubTitleKind) -> [ArtCandidate] {
        let d = ((json(data) as? [String: Any])?["data"] as? [String: Any])
        let list = (d?["artworks"] as? [[String: Any]]) ?? []
        let map: [Int: ArtKind] = kind == .series ? [1: .banner, 2: .poster, 3: .backdrop, 7: .seasonPoster, 23: .logo] : [14: .poster, 15: .backdrop, 16: .banner, 25: .logo]
        return list.compactMap { a in
            guard let t = int(a["type"]), let k = map[t], let u = str(a["image"]) else { return nil }
            var c = ArtCandidate(kind: k, url: https(u), source: .tvdb, lang: lang(str(a["language"])), width: int(a["width"]) ?? 0, height: int(a["height"]) ?? 0, likes: int(a["score"]) ?? 0)
            if k == .seasonPoster { c.season = nil }
            return c
        }
    }
    static func parseEpisodes(_ data: Data) -> HubEpisodes {
        let d = ((json(data) as? [String: Any])?["data"] as? [String: Any])
        let eps: [HubEpisode] = ((d?["episodes"] as? [[String: Any]]) ?? []).compactMap { e in
            guard let s = int(e["seasonNumber"]), let n = int(e["number"]) else { return nil }
            return HubEpisode(season: s, number: n, name: str(e["name"]), summary: str(e["overview"]), airdate: str(e["aired"]), airstamp: nil, runtime: int(e["runtime"]), imageURL: str(e["image"]).map(https), rating: nil)
        }
        return HubEpisodes(source: .tvdb, episodes: eps)
    }
    func artwork(for id: HubIdentity, kind: HubTitleKind) async throws -> [ArtCandidate] {
        guard let q = id.queryID(for: .tvdb, kind: kind) else { return [] }
        return Self.parseArtworks(try await session.get(kind == .series ? "/series/\(q)/artworks" : "/movies/\(q)/extended"), kind: kind)
    }
    func episodes(for id: HubIdentity) async throws -> HubEpisodes? {
        guard let q = id.queryID(for: .tvdb, kind: .series) else { return nil }
        return Self.parseEpisodes(try await session.get("/series/\(q)/episodes/default", query: [URLQueryItem(name: "page", value: "0")]))
    }
}

// MARK: TVmaze

/// TVmaze: keyless, CC BY-SA. Episodes, seasons, next episode with time zone, schedules. Never asked for more than 10 calls per 10 seconds (see HubPolicy.tvmaze).
struct TVmazeProvider: EpisodeProvider, ScheduleProvider {
    let source = HubSource.tvmaze
    let fetch: HubFetch
    static let base = "https://api.tvmaze.com"

    static func showRequest(id: HubIdentity) -> URLRequest? {
        var c = URLComponents(string: base)!
        if let m = id.tvmaze { c.path = "/shows/\(m)"; c.queryItems = ["nextepisode", "seasons", "episodes"].map { URLQueryItem(name: "embed[]", value: $0) } }
        else if let t = id.tvdb { c.path = "/lookup/shows"; c.queryItems = [URLQueryItem(name: "thetvdb", value: String(t))] }
        else if let i = id.imdb { c.path = "/lookup/shows"; c.queryItems = [URLQueryItem(name: "imdb", value: i)] }
        else { return nil }
        return c.url.map { URLRequest(url: $0, timeoutInterval: 20) }
    }
    static func parseShow(_ data: Data) -> HubEpisodes? {
        guard let s = json(data) as? [String: Any], let sid = int(s["id"]) else { return nil }
        let emb = s["_embedded"] as? [String: Any]
        func ep(_ e: [String: Any]) -> HubEpisode? {
            guard let sn = int(e["season"]), let n = int(e["number"]) else { return nil }          // specials without a number are skipped
            let img = (e["image"] as? [String: Any]).flatMap { str($0["original"]) ?? str($0["medium"]) }
            return HubEpisode(season: sn, number: n, name: str(e["name"]), summary: str(e["summary"]).map(EpisodeTextArbiter.stripHTML), airdate: str(e["airdate"]), airstamp: str(e["airstamp"]),
                              runtime: int(e["runtime"]), imageURL: img.map(https), rating: ((e["rating"] as? [String: Any])?["average"] as? Double))
        }
        let eps = ((emb?["episodes"] as? [[String: Any]]) ?? []).compactMap(ep)
        let seasons = ((emb?["seasons"] as? [[String: Any]]) ?? []).compactMap { x -> HubSeason? in
            guard let n = int(x["number"]) else { return nil }
            return HubSeason(number: n, episodeCount: int(x["episodeOrder"]), premiere: str(x["premiereDate"]), end: str(x["endDate"]))
        }
        let nextList = (emb?["nextepisode"] as? [String: Any]).flatMap(ep) ?? (emb?["nextepisode"] as? [[String: Any]])?.first.flatMap(ep)
        let ext = s["externals"] as? [String: Any]
        let ids = HubIdentity(tvdb: int(ext?["thetvdb"]), imdb: HubIdentity.imdbID(str(ext?["imdb"])), tvmaze: sid, kind: .series)
        return HubEpisodes(source: .tvmaze, status: str(s["status"]), seasons: seasons, episodes: eps, next: nextList, rating: (s["rating"] as? [String: Any])?["average"] as? Double, ids: ids, updated: int(s["updated"]))
    }
    static func parseSchedule(_ data: Data) -> [ScheduleEntry] {
        ((json(data) as? [[String: Any]]) ?? []).compactMap { e in
            guard let show = (e["show"] as? [String: Any]) ?? ((e["_embedded"] as? [String: Any])?["show"] as? [String: Any]), let sid = int(show["id"]), let name = str(show["name"]) else { return nil }
            let ext = show["externals"] as? [String: Any]
            return ScheduleEntry(tvmazeID: sid, show: name, tvdb: int(ext?["thetvdb"]), imdb: HubIdentity.imdbID(str(ext?["imdb"])), season: int(e["season"]), number: int(e["number"]), airstamp: str(e["airstamp"]))
        }
    }
    func episodes(for id: HubIdentity) async throws -> HubEpisodes? {
        guard var req = Self.showRequest(id: id) else { return nil }
        let wasLookup = id.tvmaze == nil
        var data = try await fetch(req)
        if wasLookup, var r = Self.parseShow(data) {              // the lookup redirects to /shows/{id}: one more call for the embedded data
            req = Self.showRequest(id: HubIdentity(tvmaze: r.ids.tvmaze))!
            data = try await fetch(req); r = Self.parseShow(data) ?? r; return r
        }
        return Self.parseShow(data)
    }
    func schedule(date: String, country: String?, web: Bool) async throws -> [ScheduleEntry] {
        var c = URLComponents(string: Self.base)!
        c.path = web ? "/schedule/web" : "/schedule"
        var q = [URLQueryItem(name: "date", value: date)]; if !web, let country { q.append(URLQueryItem(name: "country", value: country)) }
        c.queryItems = q
        guard let u = c.url else { return [] }
        return Self.parseSchedule(try await fetch(URLRequest(url: u, timeoutInterval: 20)))
    }
}

// MARK: TMDB adapter

/// Wraps what the app already does with TMDB (MetadataMatchService, ArtworkAutoMatcher) through closures, without editing them: the app wires the hooks.
struct TMDBProvider: ArtworkProvider, RatingProvider, TrendingProvider {
    let source = HubSource.tmdb
    var artworkHook: @Sendable (HubIdentity, HubTitleKind) async throws -> [ArtCandidate] = { _, _ in [] }
    var ratingHook: @Sendable (HubIdentity, HubTitleKind) async throws -> RatingCandidate? = { _, _ in nil }
    var trendingHook: @Sendable (HubTitleKind, Bool) async throws -> [TrendingEntry] = { _, _ in [] }
    func artwork(for id: HubIdentity, kind: HubTitleKind) async throws -> [ArtCandidate] { try await artworkHook(id, kind) }
    func rating(for id: HubIdentity, kind: HubTitleKind) async throws -> RatingCandidate? { try await ratingHook(id, kind) }
    func trending(kind: HubTitleKind, week: Bool) async throws -> [TrendingEntry] { try await trendingHook(kind, week) }

    /// A TMDB /images reply (posters, backdrops, logos) as candidates; `base` is the image base address of the app.
    static func parseImages(_ data: Data, base: String = "https://image.tmdb.org/t/p/original") -> [ArtCandidate] {
        guard let r = json(data) as? [String: Any] else { return [] }
        var out: [ArtCandidate] = []
        for (key, kind) in [("posters", ArtKind.poster), ("backdrops", .backdrop), ("logos", .logo)] {
            for e in (r[key] as? [[String: Any]]) ?? [] {
                guard let p = str(e["file_path"]) else { continue }
                out.append(ArtCandidate(kind: kind, url: base + p, source: .tmdb, lang: e["iso_639_1"] as? String, width: int(e["width"]) ?? 0, height: int(e["height"]) ?? 0, likes: int(e["vote_count"]) ?? 0))
            }
        }
        return out
    }
}

// MARK: TMDB details extras

/// What the details reply carries beyond the page's own fields: the other services' ids (external_ids) and the Hindi/Telugu title and overview (translations).
enum TMDBExtras {
    struct Parsed: Equatable { var ids: HubIdentity; var translations: [String: String] }
    /// `data` is a /3/movie/{id} or /3/tv/{id} reply asked with append_to_response=external_ids,translations.
    static func parse(_ data: Data, isSeries: Bool) -> Parsed? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = int(j["id"]) else { return nil }
        let ext = j["external_ids"] as? [String: Any]
        let imdb = HubIdentity.imdbID(str(ext?["imdb_id"]) ?? str(j["imdb_id"]))
        let ids = HubIdentity(tmdb: id, tvdb: isSeries ? int(ext?["tvdb_id"]) : nil, imdb: imdb, tvmaze: nil, kind: isSeries ? .series : .movie)
        var tr: [String: String] = [:]
        for t in ((j["translations"] as? [String: Any])?["translations"] as? [[String: Any]]) ?? [] {
            guard let lang = str(t["iso_639_1"]), lang == "hi" || lang == "te", let d = t["data"] as? [String: Any] else { continue }
            if let n = str(d["title"]) ?? str(d["name"]) { tr["title:" + lang] = n }
            if let o = str(d["overview"]) { tr["overview:" + lang] = o }
        }
        return Parsed(ids: ids, translations: tr)
    }
}
