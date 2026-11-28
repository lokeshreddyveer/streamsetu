import Foundation

/// soundcloud.com addresses as Music's link targets. A link only opens a page. The page's address is kept inside the target's id as a token
/// (`r~artist~track`, `s~shortcode`) because the numeric id is only known after SoundCloud's resolve call; the provider turns the token into the real item.
enum SoundCloudLink {
    enum Kind: Equatable, Sendable { case track, set, user, short }
    struct Parsed: Equatable, Sendable {
        var kind: Kind
        /// `artist`, `artist/track`, `artist/sets/name` (with a trailing `/s-secret` for a private share), or the short code.
        var path: String
    }

    static let hosts: Set<String> = ["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com"]
    static let shortHost = "on.soundcloud.com"
    /// First path words that are SoundCloud's own pages, not an artist's.
    private static let reserved: Set<String> = [
        "discover", "stream", "upload", "you", "search", "charts", "pages", "terms-of-use", "jobs", "imprint", "popular", "feed", "settings",
        "notifications", "messages", "people", "tags", "mobile", "creators", "company", "blog", "download", "go", "lp", "legal", "help", "login", "signin"
    ]
    /// Second path words that are an artist's own sub pages.
    private static let userPages: Set<String> = ["tracks", "albums", "reposts", "likes", "following", "followers", "popular-tracks", "comments", "spotlight", "playlists"]

    private static func isSlug(_ s: String) -> Bool {
        guard (1...100).contains(s.utf8.count) else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-") }
    }

    static func parse(_ url: URL) -> Parsed? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map { String($0.removingPercentEncoding ?? String($0)) }
        if host == shortHost {
            guard parts.count == 1, isSlug(parts[0]) else { return nil }
            return Parsed(kind: .short, path: parts[0])
        }
        guard hosts.contains(host), let first = parts.first, !reserved.contains(first.lowercased()), isSlug(first) else { return nil }
        if parts.count == 1 { return Parsed(kind: .user, path: first) }
        let second = parts[1]
        if userPages.contains(second.lowercased()) { return Parsed(kind: .user, path: first) }
        if second.lowercased() == "sets" {
            guard parts.count >= 3, isSlug(parts[2]) else { return Parsed(kind: .user, path: first) }
            var path = [first, "sets", parts[2]]
            if parts.count >= 4, parts[3].hasPrefix("s-"), isSlug(parts[3]) { path.append(parts[3]) }
            return Parsed(kind: .set, path: path.joined(separator: "/"))
        }
        guard isSlug(second) else { return nil }
        var path = [first, second]
        if parts.count >= 3, parts[2].hasPrefix("s-"), isSlug(parts[2]) { path.append(parts[2]) }
        return Parsed(kind: .track, path: path.joined(separator: "/"))
    }

    static func parse(text: String) -> Parsed? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = t.contains("://") ? t : "https://" + t
        guard t.count <= 400, let u = URL(string: withScheme) else { return nil }
        return parse(u)
    }

    // MARK: tokens

    static func token(for p: Parsed) -> String {
        (p.kind == .short ? "s~" : "r~") + p.path.replacingOccurrences(of: "/", with: "~")
    }

    /// The Music link target for a soundcloud.com address, nil when it is not one this provider can open.
    static func target(for url: URL) -> MusicLinkTarget? {
        guard let p = parse(url) else { return nil }
        let kind: MusicLinkKind
        switch p.kind {
        case .track, .short: kind = .track
        case .set: kind = .playlist
        case .user: kind = .artist
        }
        let id = token(for: p)
        guard MusicDeepLinks.isValidItemID(id) else { return nil }
        return MusicLinkTarget(kind: kind, providerID: SoundCloudProvider.providerID, id: id)
    }

    static func isToken(_ id: String) -> Bool { id.hasPrefix("r~") || id.hasPrefix("s~") }

    /// The public address a token stands for.
    static func url(forToken id: String) -> URL? {
        guard isToken(id) else { return nil }
        let body = id.dropFirst(2).split(separator: "~").map(String.init)
        guard !body.isEmpty, body.allSatisfy(isSlug) else { return nil }
        if id.hasPrefix("s~") { return body.count == 1 ? URL(string: "https://on.soundcloud.com/" + body[0]) : nil }
        return URL(string: "https://soundcloud.com/" + body.joined(separator: "/"))
    }

    /// The address a short link's page names as its own (`og:url` or the canonical link), as a soundcloud.com address.
    static func canonical(inHTML html: String) -> URL? {
        let patterns = ["<link[^>]+rel=[\"']canonical[\"'][^>]*href=[\"']([^\"']+)[\"']", "<meta[^>]+property=[\"']og:url[\"'][^>]*content=[\"']([^\"']+)[\"']",
                        "<link[^>]+href=[\"']([^\"']+)[\"'][^>]*rel=[\"']canonical[\"']"]
        let ns = html as NSString
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
                  let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1,
                  let u = URL(string: ns.substring(with: m.range(at: 1))), let parsed = parse(u), parsed.kind != .short else { continue }
            return u
        }
        return nil
    }
}

extension SoundCloudLink {
    /// A short link becomes the target of the page it points to. Anything else, or a short link that cannot be read, comes back unchanged.
    static func expanded(_ target: MusicLinkTarget, client: SoundCloudClient = .shared) async -> MusicLinkTarget {
        guard target.providerID == SoundCloudProvider.providerID, target.id.hasPrefix("s~"), let short = url(forToken: target.id) else { return target }
        do {
            let page = try await client.http.get(short, headers: ["User-Agent": SoundCloudClientID.browserAgent, "Accept": "text/html"])
            if let html = String(data: page, encoding: .utf8), let real = canonical(inHTML: html), let t = Self.target(for: real) {
                MusicDebugLog.log("soundcloud", "short link opened as \(t.kind.rawValue)")
                return t
            }
            MusicDebugLog.log("soundcloud", "short link page named no address")
        } catch {
            MusicDebugLog.log("soundcloud", "short link could not be read")
        }
        return target
    }
}
