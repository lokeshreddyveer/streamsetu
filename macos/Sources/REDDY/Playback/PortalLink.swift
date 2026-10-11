import Foundation

/// A stand-in address for streams that a portal (Stalker, Ministra) only reveals when you press play: its links expire within minutes,
/// so they are never stored. The player swaps this for the real address just before it starts, and again on every retry.
enum PortalLink {
    static let scheme = "portal-link"

    static func make(kind: ContentKind, ref: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme; c.host = "stream"
        c.queryItems = [URLQueryItem(name: "kind", value: kind.rawValue), URLQueryItem(name: "ref", value: ref)]
        return c.url
    }

    static func parse(_ url: URL) -> (kind: ContentKind, ref: String)? {
        guard url.scheme == scheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let k = items.first(where: { $0.name == "kind" })?.value.flatMap(ContentKind.init(rawValue:)),
              let r = items.first(where: { $0.name == "ref" })?.value else { return nil }
        return (k, r)
    }
}
