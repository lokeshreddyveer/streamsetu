import Foundation

// Request building and transport policy for YouTube Music's private JSON API.
// Retries: connect/timeout errors and 5xx answers up to 3 attempts (500 ms, then 1000 ms); 429 answers honour Retry-After with a capped
// back-off. Anything else (404, 401/403, undecodable body) is the answer and is not retried.

struct YTMResponse: @unchecked Sendable {
    let root: Any
    var dict: [String: Any] { root as? [String: Any] ?? [:] }
}

/// Runs `op` and gives up after `seconds`.
func ytmWithTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MusicError.network("timed out")
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw MusicError.network("timed out") }
        return first
    }
}

/// Passes cookie values YouTube rotated on a response to the session, but only for requests that carried a cookie.
struct YTMCookieRotatingTransport: MusicHTTPTransport {
    let inner: MusicHTTPTransport
    let session: YouTubeMusicSession
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (d, r) = try await inner.data(for: request)
        if request.value(forHTTPHeaderField: "cookie") != nil, let url = request.url {
            let fields = r.allHeaderFields.reduce(into: [String: String]()) { if let k = $1.key as? String, let v = $1.value as? String { $0[k] = v } }
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
                .filter { !$0.name.isEmpty && !$0.value.isEmpty }.map { (name: $0.name, value: $0.value) }
            if !cookies.isEmpty { await session.merge(rotatedCookies: cookies) }
        }
        return (d, r)
    }
}

/// Fetches YouTube's anonymous visitor id once and remembers it; a failed attempt is not repeated for a minute.
actor YTMVisitorBootstrap {
    private var cached: String?
    private var failedAt: Date?
    func value(http: MusicHTTP, now: Date) async -> String? {
        if let cached { return cached }
        if let f = failedAt, now.timeIntervalSince(f) < 60 { return nil }
        guard let url = URL(string: "https://music.youtube.com/sw.js_data"),
              let data = try? await http.get(url, headers: ["Accept-Language": "en-US,en;q=0.9"]),
              let v = YouTubeMusicClient.parseVisitorData(data) else { failedAt = now; return nil }
        cached = v
        return v
    }
}

struct YouTubeMusicClient: Sendable {
    static let base = "https://music.youtube.com/youtubei/v1/"

    let http: MusicHTTP
    let session: YouTubeMusicSession
    let locale: YTMLocale
    let clients: [YTMClientKey: YTMClientIdentity]
    let sleep: @Sendable (TimeInterval) async -> Void
    let now: @Sendable () -> Date
    private let visitor = YTMVisitorBootstrap()

    init(http: MusicHTTP = MusicHTTP(), session: YouTubeMusicSession = GuestYouTubeMusicSession(), locale: YTMLocale = YTMLocale(),
         clients: [YTMClientKey: YTMClientIdentity] = YTMClientTable.builtIn,
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        var h = http
        h.transport = YTMCookieRotatingTransport(inner: http.transport, session: session)
        self.http = h; self.session = session; self.locale = locale; self.clients = clients; self.sleep = sleep; self.now = now
    }

    func identity(_ key: YTMClientKey) -> YTMClientIdentity { clients[key] ?? YTMClientTable.builtIn[key] ?? YTMClientTable.builtIn[.webRemix]! }

    var isSignedIn: Bool { get async { await session.snapshot().isSignedIn } }

    // MARK: visitor data

    /// `sw.js_data` starts with a few junk characters; the id is the first `Cgt`/`Cgs` string in element [0][2].
    static func parseVisitorData(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), let open = text.firstIndex(of: "["),
              let obj = try? JSONSerialization.jsonObject(with: Data(text[open...].utf8)),
              let outer = obj as? [Any], let first = outer.first as? [Any], first.count > 2, let arr = first[2] as? [Any] else { return nil }
        return arr.compactMap { $0 as? String }.first { $0.hasPrefix("Cgt") || $0.hasPrefix("Cgs") }
    }

    private func snapshot() async -> YouTubeMusicSessionSnapshot {
        var s = await session.snapshot()
        if s.visitorData?.isEmpty ?? true, let v = await visitor.value(http: http, now: now()) {
            s.visitorData = v
            await session.updateVisitorData(v)
        }
        return s
    }

    // MARK: core POST

    static func url(for path: String) -> URL? {
        URL(string: base + path + (path.contains("?") ? "&" : "?") + "prettyPrint=false")
    }

    func post(_ path: String, body: [String: Any] = [:], client key: YTMClientKey = .webRemix, mode: YTMRequestMode = .normal,
              embedVideoID: String? = nil, identityOverride: String? = nil) async throws -> YTMResponse {
        guard let url = Self.url(for: path) else { throw MusicError.network("bad address") }
        let identity = identity(key)
        let snap = await snapshot()
        var lastError: Error = MusicError.network("no answer")
        for attempt in 0..<3 {
            var payload = body
            payload["context"] = YTMContext.build(client: identity, locale: locale, session: snap, mode: mode, embedVideoID: embedVideoID, identityOverride: identityOverride)
            let headers = YTMContext.headers(client: identity, locale: locale, session: snap, mode: mode, now: now())
            do {
                let raw = try await http.postJSON(url, body: try JSONSerialization.data(withJSONObject: payload), headers: headers)
                guard let obj = try? JSONSerialization.jsonObject(with: raw) else { throw MusicError.network("unexpected reply") }
                return YTMResponse(root: obj)
            } catch {
                lastError = error
                guard attempt < 2, let delay = Self.retryDelay(for: error, attempt: attempt) else { throw error }
                await sleep(delay)
            }
        }
        throw lastError
    }

    /// Seconds to wait before another attempt, or nil when the error is final.
    static func retryDelay(for error: Error, attempt: Int) -> TimeInterval? {
        if let m = error as? MusicError {
            switch m {
            case .rateLimited(let after):
                // A server that asks for a very long wait is not worth waiting for inside one request.
                if let after, after > 30 { return nil }
                return min(max(after ?? [1.5, 3.0][min(attempt, 1)], 0.5), 30)
            case .network(let text):
                if text.hasPrefix("HTTP 5") { return [0.5, 1.0][min(attempt, 1)] }
                if text.hasPrefix("HTTP ") || text == "bad address" || text == "unexpected reply" || text == "bad response" { return nil }
                return [0.5, 1.0][min(attempt, 1)]
            default: return nil
            }
        }
        if error is CancellationError { return nil }
        if let u = error as? URLError {
            switch u.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet: return [0.5, 1.0][min(attempt, 1)]
            default: return nil
            }
        }
        return nil
    }

    // MARK: endpoints

    func browse(_ browseID: String, params: String? = nil, mode: YTMRequestMode = .normal, client: YTMClientKey = .webRemix, selectedValues: [String]? = nil) async throws -> YTMResponse {
        var body: [String: Any] = ["browseId": browseID]
        if let params { body["params"] = params }
        // The charts page takes its country this way (an upper-case ISO code); the locale's `gl` alone does not change it.
        if let selectedValues, !selectedValues.isEmpty { body["formData"] = ["selectedValues": selectedValues] }
        return try await post("browse", body: body, client: client, mode: mode)
    }

    private static func tokenQuery(_ token: String) -> String {
        let e = YouTubeSignature.encode(token)
        return "ctoken=\(e)&continuation=\(e)&type=next"
    }

    func browseContinuation(_ token: String, mode: YTMRequestMode = .normal) async throws -> YTMResponse {
        try await post("browse?" + Self.tokenQuery(token), mode: mode)
    }

    func search(_ query: String, params: String? = nil, mode: YTMRequestMode = .normal, client: YTMClientKey = .webRemix) async throws -> YTMResponse {
        var body: [String: Any] = ["query": query]
        if let params { body["params"] = params }
        return try await post("search", body: body, client: client, mode: mode)
    }

    func searchContinuation(_ token: String) async throws -> YTMResponse {
        try await post("search?" + Self.tokenQuery(token), mode: .anonymous)
    }

    /// Typeahead is always anonymous: it must not be tied to an account's search history or ranking.
    func suggestions(_ input: String) async throws -> YTMResponse {
        try await post("music/get_search_suggestions", body: ["input": input], mode: .anonymous)
    }

    func next(videoID: String?, playlistID: String? = nil, params: String? = nil) async throws -> YTMResponse {
        var body: [String: Any] = ["isAudioOnly": true]
        if let videoID { body["videoId"] = videoID }
        if let playlistID { body["playlistId"] = playlistID }
        if let params { body["params"] = params }
        return try await post("next", body: body)
    }

    func player(videoID: String, client key: YTMClientKey, signatureTimestamp: Int?, poToken: String?, playlistID: String? = nil) async throws -> YTMResponse {
        let id = identity(key)
        var body: [String: Any] = ["videoId": videoID, "contentCheckOk": true, "racyCheckOk": true]
        if let playlistID { body["playlistId"] = playlistID }
        if id.useSignatureTimestamp, let sts = signatureTimestamp { body["playbackContext"] = ["contentPlaybackContext": ["signatureTimestamp": sts]] }
        if id.useWebPoTokens, let poToken { body["serviceIntegrityDimensions"] = ["poToken": poToken] }
        return try await post("player", body: body, client: key, embedVideoID: id.isEmbedded ? videoID : nil)
    }

    /// The video a watch link really points to (region twins). Anonymous.
    func watchRedirect(videoID: String) async -> String? {
        guard let r = try? await post("navigation/resolve_url", body: ["url": "https://music.youtube.com/watch?v=\(videoID)"], mode: .anonymous),
              let target = YTMJSON.firstString("videoId", in: r.dict["endpoint"] as Any), target != videoID else { return nil }
        return target
    }
}
