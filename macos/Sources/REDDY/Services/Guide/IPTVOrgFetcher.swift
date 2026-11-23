import Foundation

/// Where the public database files are fetched from. Injected so tests never touch the network.
protocol GuideFileFetching: Sendable {
    /// A conditional GET. `file` is nil on 304.
    func get(_ url: URL, etag: String?, lastModified: String?, maxBytes: Int64) async throws -> GuideFetched
}

struct HTTPGuideFileFetcher: GuideFileFetching {
    let http: HTTPClient
    var headers = SourceHeaders()
    func get(_ url: URL, etag: String?, lastModified: String?, maxBytes: Int64) async throws -> GuideFetched {
        var req = http.builder.get(url, etag: etag, lastModified: lastModified)
        headers.apply(to: &req)
        let r = try await http.downloadWithRetry(req, maxBytes: maxBytes)
        if r.notModified { return GuideFetched(file: nil, validators: GuideValidators(etag: etag, lastModified: lastModified), status: 304, bytes: 0) }
        guard let f = r.fileURL else { throw NetworkError.unreadable }
        return GuideFetched(file: f, validators: GuideValidators(etag: r.etag, lastModified: r.lastModified), status: r.status, bytes: r.bytes)
    }
}

/// Downloads and caches the static iptv-org files. One refresh per file per 24 hours; a token bucket and the hub's circuit breaker guard the host; ETag / Last-Modified make a refresh nearly free.
/// The block list is mandatory: without a readable one (fresh or cached within 30 days) `loadIndex` throws and nothing is enriched.
actor IPTVOrgDatabase {
    static let baseURL = URL(string: "https://iptv-org.github.io/api/")!
    static let minRefresh: TimeInterval = 24 * 3600
    static let blocklistMaxAge: TimeInterval = 30 * 24 * 3600
    static let maxBytes: Int64 = 40_000_000

    enum File: String, CaseIterable, Sendable { case blocklist, channels, feeds, logos
        var fileName: String { rawValue + ".json" }
    }
    struct Meta: Codable, Equatable { var etag: String?; var lastModified: String?; var fetchedAt: Date; var bytes: Int64 }

    private let dir: URL
    private let fetcher: any GuideFileFetching
    private let clock: @Sendable () -> Date
    private var bucket: TokenBucket
    private var breaker = CircuitBreaker()
    private let base: URL

    init(directory: URL, fetcher: any GuideFileFetching, base: URL = IPTVOrgDatabase.baseURL, clock: @escaping @Sendable () -> Date = { Date() }) {
        dir = directory; self.fetcher = fetcher; self.base = base; self.clock = clock
        bucket = TokenBucket(capacity: 4, refillPerSecond: 0.5, now: clock())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func path(_ f: File) -> URL { dir.appendingPathComponent(f.fileName) }
    private func metaPath(_ f: File) -> URL { dir.appendingPathComponent(f.rawValue + ".meta.json") }
    func meta(_ f: File) -> Meta? { (try? Data(contentsOf: metaPath(f))).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) } }

    /// Refreshes every file that is due (at most once per 24 h each, unless `force`). Returns what was fetched. Errors of one file do not stop the others, except the block list (mandatory).
    @discardableResult
    func refresh(force: Bool = false) async throws -> [File: Int] {
        var status: [File: Int] = [:]
        for f in [File.blocklist, .channels, .feeds, .logos] {
            let now = clock()
            if !force, let m = meta(f), now.timeIntervalSince(m.fetchedAt) < Self.minRefresh, FileManager.default.fileExists(atPath: path(f).path) { continue }
            guard breaker.allow(now: now) else { if f == .blocklist { throw IPTVOrgError.breakerOpen }; continue }
            let wait = bucket.take(now: now)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(min(wait, 5) * 1_000_000_000)) }
            do {
                let old = meta(f)
                let r = try await fetcher.get(base.appendingPathComponent(f.fileName), etag: old?.etag, lastModified: old?.lastModified, maxBytes: Self.maxBytes)
                breaker.success()
                if let tmp = r.file {
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    // Only keep a document that is a JSON array.
                    let head = try Data(contentsOf: tmp, options: .mappedIfSafe)
                    guard head.first(where: { $0 > 32 }) == UInt8(ascii: "[") else { throw NetworkError.unreadable }
                    try? FileManager.default.removeItem(at: path(f))
                    try FileManager.default.moveItem(at: tmp, to: path(f))
                    save(Meta(etag: r.validators.etag, lastModified: r.validators.lastModified, fetchedAt: now, bytes: r.bytes), f)
                } else if var m = old { m.fetchedAt = now; save(m, f) }
                status[f] = r.status
            } catch {
                breaker.failure(now: now)
                if f == .blocklist { throw error }
            }
        }
        return status
    }
    private func save(_ m: Meta, _ f: File) { try? JSONEncoder().encode(m).write(to: metaPath(f), options: .atomic) }

    /// Builds the index from the cache. Fails closed when the block list is missing, unreadable or older than 30 days.
    func loadIndex() throws -> IPTVOrgIndex {
        guard let bm = meta(.blocklist), clock().timeIntervalSince(bm.fetchedAt) < Self.blocklistMaxAge,
              let block = try? Data(contentsOf: path(.blocklist), options: .mappedIfSafe) else { throw IPTVOrgError.blocklistUnavailable }
        guard let chData = try? Data(contentsOf: path(.channels), options: .mappedIfSafe), let channels = try? JSONDecoder().decode([IPTVOrgChannel].self, from: chData) else { throw IPTVOrgError.databaseUnavailable }
        let logos = (try? Data(contentsOf: path(.logos), options: .mappedIfSafe)).flatMap { try? JSONDecoder().decode([IPTVOrgLogo].self, from: $0) } ?? []
        let feeds = (try? Data(contentsOf: path(.feeds), options: .mappedIfSafe)).flatMap { try? JSONDecoder().decode([IPTVOrgFeed].self, from: $0) } ?? []
        return try IPTVOrgIndex.build(channels: channels, blocklist: block, logos: logos, feeds: feeds)
    }
}
