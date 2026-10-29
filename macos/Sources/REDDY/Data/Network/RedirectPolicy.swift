import Foundation

/// What a redirect may carry along. A provider or media server can answer a request with "go to this other address". URLSession then repeats the request there with the headers we set, which
/// would hand a media server's access token, or a cookie, to whatever host the answer names. When a redirect leaves the host, the port or the scheme the request went to (or drops from HTTPS to
/// plain HTTP), the secrets we sent are removed from the repeated request: login headers, secret-looking headers, and any login in the address that was copied from ours. Whatever the server
/// itself put in the new address, such as a signed token for its own CDN, is kept, so ordinary provider redirects still work.
enum RedirectPolicy {
    /// Same scheme, host and port (host names compare without regard to case). A move from https to http is never the same origin.
    static func sameOrigin(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b, let ah = a.host?.lowercased(), let bh = b.host?.lowercased() else { return false }
        func port(_ u: URL) -> Int { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && ah == bh && port(a) == port(b)
    }

    /// Headers that may carry a login or key, whatever they are called.
    static func isSecretHeader(_ name: String) -> Bool {
        SourceHeaders.blocked.contains(name.lowercased()) && !["host", "content-length", "connection", "transfer-encoding"].contains(name.lowercased()) || SourceHeaders.looksSecret(name)
    }

    /// Address parameters that name a login or key.
    static func isSecretParameter(_ name: String) -> Bool {
        let n = name.lowercased()
        return SourceHeaders.looksSecret(n) || ["username", "user", "login", "pass", "pwd", "password", "passwd"].contains(n)
    }

    /// The request to make after a redirect: [new] unchanged when it stays on the same origin, otherwise [new] without the secrets [original] carried.
    static func sanitized(_ new: URLRequest, after original: URLRequest) -> URLRequest {
        guard !sameOrigin(original.url, new.url) else { return new }
        var out = new
        // 1. Headers we set that carry a secret: removed when they are the same value we sent (a header the server's redirect added itself is left alone).
        for (name, value) in original.allHTTPHeaderFields ?? [:] where isSecretHeader(name) {
            if let sent = out.value(forHTTPHeaderField: name), sent == value { out.setValue(nil, forHTTPHeaderField: name) }
        }
        // 2. A login copied into the new address from ours.
        if let url = out.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = parts.queryItems, !items.isEmpty {
            let ours = Set((URLComponents(url: original.url ?? url, resolvingAgainstBaseURL: false)?.queryItems ?? []).filter { isSecretParameter($0.name) }.map { "\($0.name.lowercased())=\($0.value ?? "")" })
            let kept = items.filter { !(isSecretParameter($0.name) && ours.contains("\($0.name.lowercased())=\($0.value ?? "")")) }
            if kept.count != items.count { parts.queryItems = kept.isEmpty ? nil : kept; out.url = parts.url ?? url }
        }
        return out
    }
}
