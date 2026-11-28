import Foundation

/// What a `streamsetu://music/<kind>/<token>` or `streamsetu://music/<kind>/ext/<scheme>:<value>` address names (section 4.6). Pure parsing and
/// building; `MusicDeepLinks` wraps it in the app's link types and the hub opens the result. A link only ever opens a page.
enum MusicEntityLink: Equatable, Sendable {
    /// A stored (or provisional) id, optionally with a person's starting role.
    case entity(MusicEntityID, role: MusicRole?)
    /// An id other systems know (`film/ext/tmdbMovie:39039`, `person/ext/wikidata:Q2367593`).
    case external(MusicEntityKind, ExternalID)

    /// The schemes another app can know an entity by (never the app's own provider uid, catalogue key or local uuid).
    static let publicSchemes: Set<ExternalID.Scheme> = Set(ExternalID.Scheme.allCases).subtracting([.provider, .canon, .localUUID])

    /// Words accepted for a kind in a link, besides the kind's own name.
    static func kind(word: String) -> MusicEntityKind? {
        let w = word.lowercased()
        if let k = MusicEntityKind(slug: w) { return k }
        switch w {
        case "song", "track-recording": return .recording
        case "artist", "singer", "composer", "actor": return .person
        case "movie": return .film
        case "soundtrack": return .album
        default: return nil
        }
    }

    /// `parts` are the path components after `music`: `[kind, token]` or `[kind, "ext", "scheme:value"]`. `role` is the `role` query value.
    static func parse(parts: [String], role: String? = nil) -> MusicEntityLink? {
        guard let first = parts.first, let kind = kind(word: first) else { return nil }
        let r: MusicRole?
        if let role { guard let m = MusicRole(rawValue: role) else { return nil }; r = m } else { r = nil }
        if parts.count == 2 {
            guard let id = MusicEntityID(rawValue: kind.slug + ":" + parts[1]) else { return nil }
            return .entity(id, role: r)
        }
        if parts.count == 3, parts[1] == "ext" {
            guard role == nil, let x = externalID(parts[2]) else { return nil }
            return .external(kind, x)
        }
        return nil
    }

    /// `scheme:value`, with a bounded, plain value.
    static func externalID(_ text: String) -> ExternalID? {
        guard let colon = text.firstIndex(of: ":"), let scheme = ExternalID.Scheme(rawValue: String(text[..<colon])), publicSchemes.contains(scheme) else { return nil }
        let value = String(text[text.index(after: colon)...])
        guard (1...64).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-") }) else { return nil }
        return ExternalID(scheme, value)
    }

    var pathComponents: [String] {
        switch self {
        case .entity(let id, _): [id.kind.slug, id.token]
        case .external(let k, let x): [k.slug, "ext", x.scheme.rawValue + ":" + x.value]
        }
    }
    var role: MusicRole? { if case .entity(_, let r) = self { r } else { nil } }

    /// The route for a stored id. An external link needs the graph to resolve (see `MusicDeepLinks.resolve`).
    var route: MusicRoute? { if case .entity(let id, let r) = self { .entity(id, role: r) } else { nil } }

    /// The id a link to an external id opens before the graph knows it: a route can be pushed at once and the entity model fetches it.
    var provisionalID: MusicEntityID? {
        if case .external(let k, let x) = self { .provisional(kind: k, externalID: x) } else { nil }
    }

    // MARK: text form carried by the app's link target

    /// `kind:token` (with `~role`) or `kind:scheme:value`: letters, digits and `. _ - : ~` only, so it fits the link target's id field.
    var targetID: String {
        switch self {
        case .entity(let id, let r): id.rawValue + (r.map { "~" + $0.rawValue } ?? "")
        case .external(let k, let x): k.slug + ":" + x.scheme.rawValue + ":" + x.value
        }
    }

    init?(entityTarget text: String) {
        let pieces = text.split(separator: "~", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let head = pieces.first, let id = MusicEntityID(rawValue: head) else { return nil }
        var r: MusicRole?
        if pieces.count == 2 { guard let m = MusicRole(rawValue: pieces[1]) else { return nil }; r = m }
        self = .entity(id, role: r)
    }

    init?(externalTarget kindSlug: String, id text: String) {
        guard let kind = MusicEntityKind(slug: kindSlug), let x = Self.externalID(text) else { return nil }
        self = .external(kind, x)
    }
}
