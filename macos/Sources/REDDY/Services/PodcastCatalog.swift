import Foundation

/// The subjects the public podcast directory groups shows by, with the ids its charts use.
enum PodcastGenre: Int, CaseIterable, Identifiable, Codable, Sendable {
    case news = 1489, technology = 1318, comedy = 1303, business = 1321, sports = 1545, societyCulture = 1324, trueCrime = 1488
    case education = 1304, health = 1307, arts = 1301, tvFilm = 1309, history = 1487, science = 1533, music = 1310, kidsFamily = 1305
    case religion = 1314, leisure = 1502, government = 1511, fiction = 1483

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .news: "News"; case .technology: "Technology"; case .comedy: "Comedy"; case .business: "Business"; case .sports: "Sports"
        case .societyCulture: "Society & Culture"; case .trueCrime: "True Crime"; case .education: "Education"; case .health: "Health & Fitness"
        case .arts: "Arts"; case .tvFilm: "TV & Film"; case .history: "History"; case .science: "Science"; case .music: "Music"
        case .kidsFamily: "Kids & Family"; case .religion: "Religion & Spirituality"; case .leisure: "Leisure"; case .government: "Government"; case .fiction: "Fiction"
        }
    }
    var symbol: String {
        switch self {
        case .news: "newspaper"; case .technology: "cpu"; case .comedy: "face.smiling"; case .business: "briefcase"; case .sports: "sportscourt"
        case .societyCulture: "person.2"; case .trueCrime: "magnifyingglass"; case .education: "graduationcap"; case .health: "heart"
        case .arts: "paintpalette"; case .tvFilm: "film"; case .history: "clock.arrow.circlepath"; case .science: "atom"; case .music: "music.note"
        case .kidsFamily: "figure.and.child.holdinghands"; case .religion: "sparkles"; case .leisure: "gamecontroller"; case .government: "building.columns"; case .fiction: "book"
        }
    }
}

/// One answer from the catalog: the shows, whether they came from the saved copy, and whether that copy is older than six hours (the network failed).
struct PodcastCatalogResult: Equatable, Sendable {
    var shows: [PodcastSubscription]
    var fromCache: Bool
    var stale: Bool
}

enum PodcastCatalogError: Error, LocalizedError {
    case offline
    var errorDescription: String? { "The podcast directory could not be reached." }
}

/// The popular-shows charts of the public podcast directory, for the person's country (only the two-letter region is sent), saved on disk for six hours.
final class PodcastCatalogService: @unchecked Sendable {
    static let lifetime: TimeInterval = 6 * 3600
    private let fetch: @Sendable (URL) async throws -> Data
    private let directory: URL
    private let now: @Sendable () -> Date
    /// The region the charts are asked for: the one given to the initialiser (tests), else the person's choice in setup, else the system's.
    private let fixedRegion: String?
    var region: String { fixedRegion ?? PodcastCatalogService.region() }

    init(region: String? = nil, directory: URL = PodcastCatalogService.defaultDirectory, now: @escaping @Sendable () -> Date = { Date() },
         fetch: @escaping @Sendable (URL) async throws -> Data = { url in
             var r = URLRequest(url: url, timeoutInterval: 20); r.setValue("StreamSetu", forHTTPHeaderField: "User-Agent")
             return try await HTTPClient.app.exchange(r).data
         }) {
        self.fixedRegion = region; self.directory = directory; self.now = now; self.fetch = fetch
    }

    static var defaultDirectory: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("podcast-catalog", isDirectory: true) }

    /// The two-letter region of the system locale, lower case; "us" when there is none.
    static func region(_ locale: Locale = .current) -> String {
        if locale == .current, let chosen = PodcastPreferences.region() { return chosen }
        let r = locale.region?.identifier.lowercased() ?? ""
        return r.count == 2 && r.allSatisfy(\.isLetter) ? r : "us"
    }

    // MARK: endpoints

    static func chartURL(region: String, genre: PodcastGenre?, limit: Int) -> URL {
        if let genre { return URL(string: "https://itunes.apple.com/\(region)/rss/toppodcasts/limit=\(limit)/genre=\(genre.rawValue)/json")! }
        return URL(string: "https://rss.marketingtools.apple.com/api/v2/\(region)/podcasts/top/\(limit)/podcasts.json")!
    }

    static func lookupURL(ids: [String], region: String) -> URL {
        var c = URLComponents(string: "https://itunes.apple.com/lookup")!
        c.queryItems = [URLQueryItem(name: "id", value: ids.joined(separator: ",")), URLQueryItem(name: "entity", value: "podcast"), URLQueryItem(name: "country", value: region)]
        return c.url!
    }

    // MARK: parsing

    /// The ids of a chart, in chart order, from either chart format.
    static func parseChartIDs(_ data: Data) -> [String] {
        struct New: Decodable { struct R: Decodable { let id: String }; struct F: Decodable { let results: [R] }; let feed: F }
        if let n = try? JSONDecoder().decode(New.self, from: data) { return n.feed.results.map(\.id) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let feed = root["feed"] as? [String: Any] else { return [] }
        let entries = (feed["entry"] as? [[String: Any]]) ?? ((feed["entry"] as? [String: Any]).map { [$0] } ?? [])
        return entries.compactMap { (($0["id"] as? [String: Any])?["attributes"] as? [String: Any])?["im:id"] as? String }
    }

    /// Shows with their feed addresses from a lookup answer, in the order of `ids`.
    static func parseLookup(_ data: Data, order ids: [String]) -> [PodcastSubscription] {
        struct Reply: Decodable { struct R: Decodable { let collectionId: Int?; let collectionName: String?; let artistName: String?; let feedUrl: String?; let artworkUrl600: String? }; let results: [R] }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return [] }
        var byID: [String: PodcastSubscription] = [:]
        for r in reply.results {
            guard let id = r.collectionId, let f = r.feedUrl.flatMap(URL.init(string:)), let name = r.collectionName else { continue }
            byID[String(id)] = PodcastSubscription(feedURL: f, title: name, author: r.artistName ?? "", artwork: r.artworkUrl600.flatMap(URL.init(string:)))
        }
        return ids.compactMap { byID[$0] }
    }

    // MARK: cache

    private struct Saved: Codable { var saved: Date; var shows: [PodcastSubscription] }
    private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }
    private func read(_ key: String) -> Saved? { (try? Data(contentsOf: file(key))).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } }
    private func write(_ key: String, _ shows: [PodcastSubscription]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Saved(saved: now(), shows: shows)).write(to: file(key), options: .atomic)
    }

    // MARK: chart

    /// The chart for a genre (or all shows). Fresh saved copy first; otherwise the network; when the network fails a saved copy of any age is used (stale), else it throws.
    func top(genre: PodcastGenre? = nil, limit: Int = 25, refresh: Bool = false) async throws -> PodcastCatalogResult {
        let key = "top-\(region)-\(genre?.rawValue ?? 0)-\(limit)"
        let cached = read(key)
        if !refresh, let cached, now().timeIntervalSince(cached.saved) < Self.lifetime, !cached.shows.isEmpty { return PodcastCatalogResult(shows: cached.shows, fromCache: true, stale: false) }
        do {
            let shows = try await download(genre: genre, limit: limit)
            write(key, shows)
            return PodcastCatalogResult(shows: shows, fromCache: false, stale: false)
        } catch {
            if let cached, !cached.shows.isEmpty { return PodcastCatalogResult(shows: cached.shows, fromCache: true, stale: true) }
            throw PodcastCatalogError.offline
        }
    }

    private func download(genre: PodcastGenre?, limit: Int) async throws -> [PodcastSubscription] {
        var lastError: Error = PodcastCatalogError.offline
        for r in region == "us" ? ["us"] : [region, "us"] {
            do {
                let ids = Self.parseChartIDs(try await fetch(Self.chartURL(region: r, genre: genre, limit: limit)))
                guard !ids.isEmpty else { continue }
                let shows = Self.parseLookup(try await fetch(Self.lookupURL(ids: ids, region: r)), order: ids)
                if !shows.isEmpty { return shows }
            } catch { lastError = error }
        }
        throw lastError
    }
}
