import Foundation

/// Streaming and file transfers for Music, through the app's HTTP client so the person's proxy, secure DNS and the redirect guard apply, and
/// with `MusicNetworkPolicy` refusing addresses on this Mac or a private network (also on every redirect). `MusicHTTP` stays the path for small
/// replies; this is for the cases it cannot serve: byte streams, large files, range reads and sessions with pause and resume data.
enum MusicTransfer {
    /// True for a public http(s) address. A private or local host is never fetched by a transfer.
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return false }
        // Only the person's own configured Piped or Invidious host is let through; every other private host stays refused.
        return !MusicNetworkPolicy.isPrivateHost(host) || MusicOwnHosts.allows(host: host)
    }

    /// The request as it will be sent: no cookies, no cache, and an error for an address a transfer must not touch.
    static func prepared(_ request: URLRequest) throws -> URLRequest {
        guard let url = request.url, isAllowed(url) else { throw MusicError.network("bad address") }
        var r = request
        r.httpShouldHandleCookies = false
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return r
    }

    static func bytes(for request: URLRequest, client: HTTPClient = .app) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let r = try prepared(request)
        do {
            let (b, resp) = try await client.bytes(r, allowRedirect: { isAllowed($0) })
            guard let h = resp as? HTTPURLResponse else { throw MusicError.network("bad response") }
            return (b, h)
        } catch { throw map(error) }
    }

    static func data(for request: URLRequest, maxBytes: Int = 8_000_000, client: HTTPClient = .app) async throws -> (Data, HTTPURLResponse) {
        let r = try prepared(request)
        do {
            let (d, resp) = try await client.fetch(r, maxBytes: maxBytes, allowRedirect: { isAllowed($0) })
            guard let h = resp as? HTTPURLResponse else { throw MusicError.network("bad response") }
            return (d, h)
        } catch { throw map(error) }
    }

    /// A configuration with no cookies and no cache, for a session that reports back through a delegate.
    static func session(configuration: URLSessionConfiguration, delegate: URLSessionDelegate?, client: HTTPClient = .app) -> URLSession {
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return client.makeTransferSession(configuration: configuration, delegate: delegate)
    }

    /// The redirect step for a delegate-based session: drops logins on another origin and refuses a private target.
    static func redirect(_ new: URLRequest, after task: URLSessionTask) -> URLRequest? {
        if let u = new.url, !isAllowed(u) { return nil }
        return RedirectPolicy.sanitized(new, after: task.originalRequest ?? new)
    }

    private static func map(_ error: Error) -> Error {
        if error is CancellationError { return MusicError.cancelled }
        if let e = error as? MusicError { return e }
        if let e = error as? URLError, e.code == .cancelled { return MusicError.cancelled }
        return MusicError.network((error as NSError).localizedDescription)
    }
}
