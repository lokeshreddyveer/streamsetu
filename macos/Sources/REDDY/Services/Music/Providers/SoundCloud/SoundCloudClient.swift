import Foundation

/// The one doorway to SoundCloud's web interface (api-v2). It adds the site key, renews it once when a call is refused, counts failures
/// into the shared health (which rests the provider after repeated ones) and never sends the key anywhere but api-v2.soundcloud.com.
struct SoundCloudClient: Sendable {
    static let apiHost = "api-v2.soundcloud.com"
    static let api = URL(string: "https://api-v2.soundcloud.com")!
    static let shared = SoundCloudClient()
    static let headers = ["User-Agent": SoundCloudClientID.browserAgent, "Accept": "application/json"]

    let http: MusicHTTP
    let ids: SoundCloudClientID
    let health: SoundCloudHealth

    init(http: MusicHTTP = MusicHTTP(), health: SoundCloudHealth = SoundCloudHealth(), ids: SoundCloudClientID? = nil) {
        self.http = http
        self.health = health
        self.ids = ids ?? SoundCloudClientID(http: http, health: health)
    }

    /// True when a next-page or media address stays on SoundCloud's own api host over https.
    static func isTrusted(_ url: URL) -> Bool { url.scheme == "https" && url.host?.lowercased() == apiHost }

    func url(path: String) -> URL {
        Self.api.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }

    var isResting: Bool { get async { await health.isCooling } }

    func data(path: String, query: [String: String] = [:]) async throws -> Data {
        try await data(url: url(path: path), query: query)
    }

    /// GET with the site key. 401 or 403 renews the key once and tries again; a second refusal counts as a failure.
    func data(url: URL, query: [String: String] = [:]) async throws -> Data {
        guard Self.isTrusted(url) else { throw MusicError.notFound }
        if await health.isCooling {
            MusicDebugLog.log("soundcloud", "skipped a request: resting")
            throw MusicError.refused("soundcloud.com")
        }
        var key = try await ids.current()
        for attempt in 0..<2 {
            var q = query
            q["client_id"] = key
            do {
                let d = try await http.get(url, query: q, headers: Self.headers)
                await health.success()
                return d
            } catch let e as MusicError {
                switch e {
                case .refused, .notSignedIn:
                    if attempt == 0 {
                        MusicDebugLog.log("soundcloud", "401/403 from \(url.path), renewing the client key")
                        key = try await ids.refresh(replacing: key)
                        continue
                    }
                    await health.failure("refused after renewing the key")
                    throw MusicError.refused("soundcloud.com")
                case .notFound, .cancelled:
                    throw e
                case .rateLimited:
                    await health.failure("rate limited")
                    throw e
                default:
                    await health.failure("network")
                    throw e
                }
            }
        }
        throw MusicError.refused("soundcloud.com")
    }

}
