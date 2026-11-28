import Foundation

/// How the loopback proxy talks to a stream host: the byte window per request and the headers, both read from the stream address itself.
/// YouTube's media addresses carry the client that minted them in the `c` parameter, and each client only honours certain requests.
enum MusicProxyPolicy {
    static let narrowWindow: Int64 = 512 * 1024
    static let mediumWindow: Int64 = 1_048_576

    static func isGoogleVideo(_ url: URL) -> Bool {
        let h = (url.host ?? "").lowercased()
        return h.hasSuffix("googlevideo.com") || h.hasSuffix(".c.youtube.com") || url.path.contains("/videoplayback")
    }

    /// The value of the `c` query item (the minting client), upper-cased.
    static func client(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "c" }?.value?.uppercased()
    }

    /// 512 KiB for the clients that only serve the first mebibyte, 1 MiB for other YouTube media, the normal chunk elsewhere.
    static func window(for url: URL) -> Int64 {
        guard isGoogleVideo(url) else { return MusicProxyChunker.chunkBytes }
        switch client(of: url) {
        case "ANDROID_VR", "TVHTML5_SIMPLY": return narrowWindow
        default: return mediumWindow
        }
    }

    static func isWebClient(_ c: String) -> Bool { ["WEB", "WEB_REMIX", "WEB_CREATOR", "WEB_EMBEDDED_PLAYER", "MWEB", "TVHTML5", "TVHTML5_SIMPLY"].contains(c) }

    /// The stream's own headers plus Origin and Referer for web-client addresses. Headers the stream already sets are kept.
    static func headers(for url: URL, base: [String: String]) -> [String: String] {
        var h = base
        guard isGoogleVideo(url), let c = client(of: url), isWebClient(c) else { return h }
        let origin = c == "WEB_REMIX" ? "https://music.youtube.com" : "https://www.youtube.com"
        let lower = Set(h.keys.map { $0.lowercased() })
        if !lower.contains("origin") { h["Origin"] = origin }
        if !lower.contains("referer") { h["Referer"] = origin + "/" }
        return h
    }

    /// A small ranged read through the proxy's own loopback address. True when it comes back with bytes.
    static func selfTest(_ local: URL, timeout: TimeInterval = 8) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 2
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: local)
        req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return false }
        return (http.statusCode == 200 || http.statusCode == 206) && !data.isEmpty
    }
}
