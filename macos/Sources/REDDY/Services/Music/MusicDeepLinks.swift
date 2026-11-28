import Foundation

// Links into Music: streamsetu://music/<track|album|artist|playlist>/<providerID>/<id>, plus ordinary open.spotify.com links.
// A link only ever opens a page. It never starts playback, never switches a source on, and anything that does not fit the strict shapes below is refused.

enum MusicLinkKind: String, CaseIterable, Sendable {
    case track, album, artist, playlist
    /// A place in Music rather than an item: `streamsetu://music/open/<section>` (the target's id is the section's link word).
    case section
    /// A graph entity by its stable id: `streamsetu://music/<kind>/<token>` (the target's id is `kind:token`, plus `~role` for a person).
    case entity
    /// A graph entity by an id other systems know: `streamsetu://music/<kind>/ext/<scheme>:<value>` (the target's provider field holds the kind).
    case external
}

struct MusicLinkTarget: Hashable, Sendable {
    var kind: MusicLinkKind
    var providerID: String
    var id: String
}

enum MusicLinkResolution: Sendable {
    case route(MusicRoute)
    /// A track has no page of its own: the hub shows `track` (for example selected in its album) and may use `route` (its album or artist page) as the page to open.
    case track(MusicTrack, route: MusicRoute?)
    /// A section of Music to show (Listen Now, Explore, Search, Library, Radio, Downloads, Devices, Listen Together, Settings).
    case section(MusicSection)
}

enum MusicDeepLinks {
    static let host = "music"
    /// Stands in for the provider id of a section link (a section belongs to no source).
    static let sectionProviderID = "shell"

    /// Provider ids: lowercase letters, digits, dot, dash, underscore.
    static func isValidProviderID(_ s: String) -> Bool {
        guard (1...64).contains(s.utf8.count) else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains(Character($0)) || ("0"..."9").contains(Character($0)) || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// Item ids: letters, digits and . _ - : ~ only (every provider's real ids fit), up to 128 characters.
    static func isValidItemID(_ s: String) -> Bool {
        guard (1...128).contains(s.utf8.count) else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-" || $0 == ":" || $0 == "~") }
    }

    // MARK: parse

    static func parse(_ url: URL) -> MusicLinkTarget? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == DeepLink.scheme { return parseOwn(url) }
        if scheme == "https" || scheme == "http" { return parseSpotifyWeb(url) ?? parseYouTube(url) ?? SoundCloudLink.target(for: url) }
        if scheme == "spotify" { return parseSpotifyURI(url.absoluteString) }
        return nil
    }

    /// Pasted text: a link, or a `spotify:track:<id>` address.
    static func parse(text: String) -> MusicLinkTarget? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 300, let u = URL(string: t), u.scheme != nil, let target = parse(u) { return target }
        return firstURL(in: t).flatMap(parse)
    }

    /// The first http(s) address in shared text ("Listen to this https://youtu.be/...").
    static func firstURL(in text: String) -> URL? {
        guard text.count <= 2_000, let r = text.range(of: "https?://[^\\s<>\"']+", options: .regularExpression) else { return nil }
        return URL(string: String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)")))
    }

    /// The search text of a YouTube search link. A search link opens the search page; it never plays anything.
    static func youTubeSearchQuery(_ url: URL) -> String? {
        guard isYouTubeHost(url), url.path.lowercased().hasPrefix("/search"),
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value else { return nil }
        let t = q.replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(200))
    }

    private static let youTubeHosts: Set<String> = ["youtube.com", "www.youtube.com", "music.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be"]
    static func isYouTubeHost(_ url: URL) -> Bool { youTubeHosts.contains((url.host ?? "").lowercased()) }

    /// YouTube and YouTube Music links: videos (watch, youtu.be, shorts, embed, v), playlists, channels (artists) and browse ids (albums, artists, playlists).
    /// A link only ever opens a page. YouTube Music's provider has to be switched on for it to resolve.
    static func parseYouTube(_ url: URL) -> MusicLinkTarget? {
        guard isYouTubeHost(url) else { return nil }
        let provider = YouTubeMusicFullProvider.providerID
        let host = (url.host ?? "").lowercased()
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map { String($0.removingPercentEncoding ?? String($0)) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { items.first { $0.name == name }?.value }
        func target(_ kind: MusicLinkKind, _ id: String?) -> MusicLinkTarget? {
            guard let id, isValidItemID(id) else { return nil }
            return MusicLinkTarget(kind: kind, providerID: provider, id: id)
        }
        if host.hasSuffix("youtu.be") { return target(.track, parts.first) }
        guard let first = parts.first?.lowercased() else { return q("v").flatMap { target(.track, $0) } ?? target(.playlist, q("list")) }
        switch first {
        case "watch": return q("v").flatMap { target(.track, $0) } ?? target(.playlist, q("list"))
        case "playlist": return target(.playlist, q("list"))
        case "shorts", "embed", "v": return parts.count > 1 ? target(.track, parts[1]) : nil
        case "channel": return parts.count > 1 ? target(.artist, parts[1]) : nil
        case "browse":
            guard parts.count > 1 else { return nil }
            let id = parts[1]
            if id.hasPrefix("MPRE") { return target(.album, id) }
            if id.hasPrefix("UC") { return target(.artist, id) }
            if id.hasPrefix("VL") || id.hasPrefix("PL") || id.hasPrefix("OLAK") { return target(.playlist, id) }
            return nil
        case "search": return nil
        default: return target(.playlist, q("list"))
        }
    }

    private static func parseOwn(_ url: URL) -> MusicLinkTarget? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var parts = comps.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let h = comps.host, !h.isEmpty { parts.insert(h, at: 0) }
        if parts.count == 3, parts[0].lowercased() == host, parts[1].lowercased() == "open" {
            guard let name = parts[2].removingPercentEncoding, isValidItemID(name), MusicSection.from(linkName: name) != nil else { return nil }
            return MusicLinkTarget(kind: .section, providerID: sectionProviderID, id: name.lowercased())
        }
        if parts.count >= 3, parts[0].lowercased() == host, parts[1].lowercased() != "open", parts.count == 3 || (parts.count == 4 && parts[2].lowercased() == "ext") {
            let rest = parts.dropFirst().map { $0.removingPercentEncoding ?? $0 }
            let role = comps.queryItems?.first { $0.name == "role" }?.value
            guard let link = MusicEntityLink.parse(parts: Array(rest), role: role) else { return nil }
            return target(for: link)
        }
        guard parts.count == 4, parts[0].lowercased() == host else { return nil }
        guard let kind = MusicLinkKind(rawValue: parts[1].lowercased()), kind != .entity, kind != .external else { return nil }
        let provider = parts[2].removingPercentEncoding ?? ""
        let id = parts[3].removingPercentEncoding ?? ""
        guard isValidProviderID(provider), isValidItemID(id) else { return nil }
        return MusicLinkTarget(kind: kind, providerID: provider, id: id)
    }

    /// The app's link target for a graph link.
    static func target(for link: MusicEntityLink) -> MusicLinkTarget {
        switch link {
        case .entity: MusicLinkTarget(kind: .entity, providerID: "entity", id: link.targetID)
        case .external(let k, let x): MusicLinkTarget(kind: .external, providerID: k.slug, id: x.scheme.rawValue + ":" + x.value)
        }
    }

    private static func parseSpotifyWeb(_ url: URL) -> MusicLinkTarget? {
        guard url.host?.lowercased() == "open.spotify.com" else { return nil }
        var parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let f = parts.first, f.hasPrefix("intl-") { parts.removeFirst() }
        guard parts.count >= 2, let kind = MusicLinkKind(rawValue: parts[0].lowercased()), isSpotifyID(parts[1]) else { return nil }
        return MusicLinkTarget(kind: kind, providerID: "spotify", id: parts[1])
    }

    private static func parseSpotifyURI(_ s: String) -> MusicLinkTarget? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0].lowercased() == "spotify", let kind = MusicLinkKind(rawValue: parts[1].lowercased()), isSpotifyID(parts[2]) else { return nil }
        return MusicLinkTarget(kind: kind, providerID: "spotify", id: parts[2])
    }

    private static func isSpotifyID(_ s: String) -> Bool {
        (10...32).contains(s.utf8.count) && s.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    // MARK: build

    /// `streamsetu://music/open/<section>`: opens a place in Music. It only navigates.
    static func link(section: MusicSection) -> URL? {
        var c = URLComponents()
        c.scheme = DeepLink.scheme; c.host = host
        c.percentEncodedPath = "/open/\(section.linkName)"
        return c.url
    }

    /// A path segment may hold a colon (`tmdbMovie:39039`); it is not escaped.
    private static let pathSegmentAllowed: CharacterSet = { var s = CharacterSet.urlPathAllowed; s.insert(":"); s.remove("/"); return s }()

    /// `streamsetu://music/<kind>/<token>` (with `?role=` for a person) or `.../<kind>/ext/<scheme>:<value>`.
    static func link(entity l: MusicEntityLink) -> URL? {
        var c = URLComponents()
        c.scheme = DeepLink.scheme; c.host = host
        c.percentEncodedPath = "/" + l.pathComponents.map { $0.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? $0 }.joined(separator: "/")
        if let r = l.role { c.queryItems = [URLQueryItem(name: "role", value: r.rawValue)] }
        return c.url
    }
    /// The link for a graph route (nil for a legacy route, which carries a value no link can hold).
    static func link(route: MusicRoute) -> URL? {
        guard case .node(let r) = route else { return nil }
        return link(entity: .entity(r.id, role: r.role))
    }

    static func link(_ target: MusicLinkTarget) -> URL? {
        if target.kind == .section {
            return MusicSection.from(linkName: target.id).flatMap { link(section: $0) }
        }
        if target.kind == .entity { return MusicEntityLink(entityTarget: target.id).flatMap { link(entity: $0) } }
        if target.kind == .external { return MusicEntityLink(externalTarget: target.providerID, id: target.id).flatMap { link(entity: $0) } }
        guard isValidProviderID(target.providerID), isValidItemID(target.id) else { return nil }
        var c = URLComponents()
        c.scheme = DeepLink.scheme; c.host = host
        c.percentEncodedPath = "/\(target.kind.rawValue)/\(target.providerID)/\(target.id)"
        return c.url
    }
    static func link(track t: MusicTrack) -> URL? { link(MusicLinkTarget(kind: .track, providerID: t.providerID, id: t.id)) }
    static func link(album a: MusicAlbum) -> URL? { link(MusicLinkTarget(kind: .album, providerID: a.providerID, id: a.id)) }
    static func link(artist a: MusicArtist) -> URL? { link(MusicLinkTarget(kind: .artist, providerID: a.providerID, id: a.id)) }
    static func link(playlist p: MusicPlaylist) -> URL? { link(MusicLinkTarget(kind: .playlist, providerID: p.providerID, id: p.id)) }

    // MARK: resolve

    /// Fetches the item from its source so the hub can open its page. Only a source the person already switched on is contacted: a link cannot turn one on.
    @MainActor
    static func resolve(_ target: MusicLinkTarget, registry: MusicRegistry) async throws -> MusicLinkResolution {
        // A SoundCloud short link first becomes the page it points to.
        let target = await SoundCloudLink.expanded(target)
        if target.kind == .section {
            guard let s = MusicSection.from(linkName: target.id) else { throw MusicError.notFound }
            return .section(s)
        }
        if target.kind == .entity {
            guard let route = MusicEntityLink(entityTarget: target.id)?.route else { throw MusicError.notFound }
            return .route(route)
        }
        if target.kind == .external {
            guard let l = MusicEntityLink(externalTarget: target.providerID, id: target.id), case .external(let kind, let x) = l else { throw MusicError.notFound }
            // The graph's own id if it knows this external id; otherwise a provisional id, so the page opens at once and fetches the rest.
            let known = try? await MusicGraphRuntime.shared.store.resolveAlias(for: x, kind: kind)
            return .route(.entity(known ?? .provisional(kind: kind, externalID: x)))
        }
        guard let provider = registry.provider(id: target.providerID) as? any MusicMetadataProvider else { throw MusicError.notFound }
        guard registry.isEnabled(target.providerID) else {
            throw MusicError.unsupported("Switch on \(provider.info.name) in Music settings to open this link.")
        }
        switch target.kind {
        case .album: return .route(.album(try await provider.album(id: target.id)))
        case .artist: return .route(.artist(try await provider.artist(id: target.id)))
        case .playlist: return .route(.playlist(try await provider.playlist(id: target.id)))
        case .section, .entity, .external: throw MusicError.notFound
        case .track:
            let t = try await provider.track(id: target.id)
            let route: MusicRoute?
            if let a = t.album, let full = try? await provider.album(id: a.id) { route = .album(full) }
            else if let ar = t.artists.first, let full = try? await provider.artist(id: ar.id) { route = .artist(full) }
            else { route = nil }
            return .track(t, route: route)
        }
    }
}
