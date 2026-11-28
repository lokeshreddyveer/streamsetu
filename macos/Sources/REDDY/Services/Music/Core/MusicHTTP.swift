import Foundation

/// The one HTTP helper every music provider uses: fixed timeouts, a descriptive User-Agent, JSON decoding, and typed errors.
/// Providers never build their own URLSession. Tests inject a `MusicHTTPTransport`.
protocol MusicHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Music's own requests go through the app's HTTP client, so the person's proxy, secure DNS and the redirect guard that drops logins on a
/// cross-site redirect apply to Music exactly as they do everywhere else. Cookies are only ever the ones a provider sets by hand.
struct URLSessionTransport: MusicHTTPTransport {
    static let maxBytes = 12_000_000
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = request
        req.httpShouldHandleCookies = false
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if req.timeoutInterval > 20 { req.timeoutInterval = 20 }
        do {
            let (d, r) = try await HTTPClient.app.exchangeWithResponse(req, maxBytes: Self.maxBytes)
            guard let h = r else { throw MusicError.network("bad response") }
            return (d, h)
        } catch is CancellationError { throw MusicError.cancelled
        } catch let e as MusicError { throw e
        } catch let e as URLError where e.code == .cancelled { throw MusicError.cancelled
        } catch { throw MusicError.network((error as NSError).localizedDescription) }
    }
}

struct MusicHTTP: Sendable {
    var transport: MusicHTTPTransport = URLSessionTransport()
    var userAgent = "StreamSetu-Music/1.0 (+https://github.com/lokeshreddyveerabhadra/streamsetu)"

    func get(_ url: URL, query: [String: String] = [:], headers: [String: String] = [:]) async throws -> Data {
        try await send(url: url, method: "GET", query: query, headers: headers, body: nil)
    }
    func getJSON<T: Decodable>(_ type: T.Type, _ url: URL, query: [String: String] = [:], headers: [String: String] = [:]) async throws -> T {
        let d = try await get(url, query: query, headers: headers)
        do { return try JSONDecoder().decode(T.self, from: d) } catch { throw MusicError.network("unexpected reply") }
    }
    func getObject(_ url: URL, query: [String: String] = [:], headers: [String: String] = [:]) async throws -> Any {
        let d = try await get(url, query: query, headers: headers)
        guard let o = try? JSONSerialization.jsonObject(with: d) else { throw MusicError.network("unexpected reply") }
        return o
    }
    func postJSON(_ url: URL, body: Data, headers: [String: String] = [:]) async throws -> Data {
        var h = headers; h["Content-Type"] = h["Content-Type"] ?? "application/json"
        return try await send(url: url, method: "POST", query: [:], headers: h, body: body)
    }
    func postForm(_ url: URL, fields: [String: String], headers: [String: String] = [:]) async throws -> Data {
        var h = headers; h["Content-Type"] = "application/x-www-form-urlencoded"
        var c = URLComponents(); c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        let encoded = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return try await send(url: url, method: "POST", query: [:], headers: h, body: Data(encoded.utf8))
    }

    func send(url: URL, method: String, query: [String: String], headers: [String: String], body: Data?) async throws -> Data {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            let existing = comps?.queryItems ?? []
            let added = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            comps?.queryItems = existing + added
        }
        // A plus sign in a value would be read as a space by the server.
        if let q = comps?.percentEncodedQuery, q.contains("+") { comps?.percentEncodedQuery = q.replacingOccurrences(of: "+", with: "%2B") }
        guard let final = comps?.url, final.scheme == "https" || final.scheme == "http" else { throw MusicError.network("bad address") }
        var r = URLRequest(url: final); r.httpMethod = method; r.httpBody = body
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        var attempt = 0
        var result: (Data, HTTPURLResponse)
        while true {
            do {
                result = try await transport.data(for: r)
                if MusicRetryPolicy.shouldRetry(method: method, status: result.1.statusCode, urlErrorCode: nil, attempt: attempt + 1) {
                    attempt += 1
                    try await Task.sleep(for: .seconds(MusicRetryPolicy.delay(attempt: attempt)))
                    continue
                }
                break
            } catch let e as MusicError {
                // The shared transport words a dropped connection as a network error; only that kind is worth a second try.
                guard case .network(let why) = e, MusicRetryPolicy.shouldRetry(method: method, status: nil, urlErrorCode: Self.transientCode(why), attempt: attempt + 1) else { throw e }
                attempt += 1
                try await Task.sleep(for: .seconds(MusicRetryPolicy.delay(attempt: attempt)))
            }
        }
        let (d, resp) = result
        switch resp.statusCode {
        case 200..<300: return d
        case 404: throw MusicError.notFound
        case 401, 403:
            // Only a call that actually sent an account's credentials can mean "sign in". A guest request that a host refuses is just a refusal.
            let host = final.host ?? "service"
            throw Self.carriesCredentials(r) ? MusicError.notSignedIn(host) : MusicError.refused(host)
        case 429: throw MusicError.rateLimited(retryAfter: (resp.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init))
        default: throw MusicError.network("HTTP \(resp.statusCode)")
        }
    }
}

extension MusicHTTP {
    /// Maps the transport's wording of a dropped or timed-out connection back to its code.
    static func transientCode(_ text: String) -> URLError.Code? {
        let t = text.lowercased()
        if t.contains("timed out") { return .timedOut }
        if t.contains("connection was lost") || t.contains("connection lost") { return .networkConnectionLost }
        if t.contains("could not connect") { return .cannotConnectToHost }
        return nil
    }

    /// True when the request sent something that belongs to a person's account: a bearer or token header, a login cookie, or a session key in a form body.
    static func carriesCredentials(_ r: URLRequest) -> Bool {
        let names: Set<String> = ["authorization", "cookie", "x-goog-authuser", "x-goog-pageid"]
        for (k, _) in r.allHTTPHeaderFields ?? [:] where names.contains(k.lowercased()) { return true }
        if r.httpMethod == "POST", let b = r.httpBody, let text = String(data: b.prefix(4096), encoding: .utf8) {
            return text.hasPrefix("sk=") || text.contains("&sk=")
        }
        return false
    }
}

/// Small JSON helpers for providers that read untyped replies.
extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { (self[k] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (self[k] as? NSNumber).map { "\($0)" } }
    func int(_ k: String) -> Int? { (self[k] as? Int) ?? (self[k] as? String).flatMap(Int.init) ?? (self[k] as? Double).map(Int.init) }
    func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func array(_ k: String) -> [[String: Any]] { (self[k] as? [[String: Any]]) ?? [] }
}
