import Foundation

// Typed routes (section 4.1 of the graph design). A route is a small value: entity routes carry ONLY an id (and, for a person, the role the
// page opens on), so two routes to the same entity are equal whatever thumbnails or titles the caller had in hand, and a history entry stays tiny.
// The older routes that carry whole values stay and keep rendering with their old pages; `MusicRouteResolver` converts them lazily.

/// A route to one graph entity. The kind of page follows from `id.kind`.
struct MusicEntityRoute: Hashable, Codable, Sendable {
    var id: MusicEntityID
    /// A person page's starting role (the role switcher's first tab). Part of identity, so Back returns to the same role.
    var role: MusicRole?
    init(_ id: MusicEntityID, role: MusicRole? = nil) { self.id = id; self.role = role }

    /// Which page shows this entity.
    var page: MusicEntityPage { MusicEntityPage(kind: id.kind) }
}

/// The page families the graph routes lead to (several entity kinds share one page: a recording, work and track are all "a song").
enum MusicEntityPage: String, Sendable, CaseIterable {
    case song, album, person, film, series, station, playlist, genre, language, region, era

    init(kind: MusicEntityKind) {
        switch kind {
        case .recording, .work, .track: self = .song
        case .album, .release: self = .album
        case .person, .group: self = .person
        case .film: self = .film
        case .series: self = .series
        case .station: self = .station
        case .playlist: self = .playlist
        case .genre: self = .genre
        case .language: self = .language
        case .region: self = .region
        case .era: self = .era
        }
    }
}

/// The named discovery lists (composers, singers, soundtracks, classics, moods).
enum MusicCollectionKey: String, Codable, Sendable, CaseIterable, Hashable {
    case composers, singers, soundtracks, classics, moods
    /// The smart playlists built from the plays table.
    case onRepeat, recentlyAdded, neverPlayed, forgottenFavourites
    case mostPlayed, recentlyPlayed
}

/// A page above the section's own page. The stack is what Back unwinds.
enum MusicRoute: Hashable {
    // legacy: carry values, rendered by the original pages
    case album(MusicAlbum)
    case artist(MusicArtist)
    case playlist(MusicPlaylist)
    case localPlaylist(UUID)
    case genre(MusicBrowseGenre)
    case user(MusicUser)
    case blacklist
    case actor(MusicActorRoute)
    // graph: ids only
    case node(MusicEntityRoute)
    case collection(MusicCollectionKey)
}

// MARK: constructors (entity routes carry only ids)

extension MusicRoute {
    static func entity(_ id: MusicEntityID, role: MusicRole? = nil) -> MusicRoute { .node(MusicEntityRoute(id, role: role)) }
    static func song(_ id: MusicEntityID) -> MusicRoute { .entity(id) }
    /// An album or release (soundtracks included).
    static func albumPage(_ id: MusicEntityID) -> MusicRoute { .entity(id) }
    static func person(_ id: MusicEntityID, role: MusicRole? = nil) -> MusicRoute { .entity(id, role: role) }
    static func film(_ id: MusicEntityID) -> MusicRoute { .entity(id) }
    static func series(_ id: MusicEntityID) -> MusicRoute { .entity(id) }
    static func station(_ id: MusicEntityID) -> MusicRoute { .entity(id) }
    static func playlistNode(_ id: MusicEntityID) -> MusicRoute { .entity(id) }
    static func genreFacet(_ id: MusicEntityID) -> MusicRoute { .entity(id) }
    static func language(_ id: MusicEntityID) -> MusicRoute { .entity(id) }
    static func region(_ id: MusicEntityID) -> MusicRoute { .entity(id) }
    static func era(_ id: MusicEntityID) -> MusicRoute { .entity(id) }

    /// The entity this route is about, when it is a graph route.
    var entityRoute: MusicEntityRoute? { if case .node(let r) = self { r } else { nil } }
    var entityID: MusicEntityID? { entityRoute?.id }
    var isLegacy: Bool {
        switch self { case .node, .collection: false; default: true }
    }

    /// What loop avoidance compares. A legacy album and the graph route to the same provider album are the same destination (the provisional id of
    /// a provider uid is a pure function of it).
    var identityKey: String {
        switch self {
        case .node(let r): r.id.rawValue + (r.role.map { "#" + $0.rawValue } ?? "")
        case .collection(let c): "collection:" + c.rawValue
        case .album(let a): MusicEntityID.provisional(kind: .release, providerUID: a.uid).rawValue
        case .artist(let a): MusicEntityID.provisional(kind: .person, providerUID: a.uid).rawValue
        case .playlist(let p): MusicEntityID.provisional(kind: .playlist, providerUID: p.uid).rawValue
        case .localPlaylist(let id): "local:" + id.uuidString
        case .genre(let g): "genre:" + g.id
        case .user(let u): "user:" + u.providerID + ":" + u.id
        case .blacklist: "blacklist"
        case .actor(let r): "actor:" + r.person.id
        }
    }

    /// The key the page's scroll position and page memory are kept under. Legacy keys keep their old text so saved offsets still match.
    var scrollKey: String {
        switch self {
        case .node(let r): "entity:" + r.id.rawValue + (r.role.map { "#" + $0.rawValue } ?? "")
        case .collection(let c): "collection:" + c.rawValue
        case .album(let a): "album:" + a.uid
        case .artist(let a): "artist:" + a.uid
        case .playlist(let p): "playlist:" + p.uid
        case .localPlaylist(let id): "local:" + id.uuidString
        case .genre(let g): "genre:" + g.id
        case .user(let u): "user:" + u.providerID + ":" + u.id
        case .blacklist: "blacklist"
        case .actor(let r): "actor:" + r.person.id
        }
    }
}

// MARK: paths and persistence (graph routes only)

extension MusicRoute {
    /// `album/7K2QXM4V9ZT3B`, `person/7K2QXM4V9ZT3B?role=singer`, `collection/composers`. Nil for a legacy route (it carries a value no path can hold).
    var path: String? {
        switch self {
        case .node(let r): r.id.routePath + (r.role.map { "?role=" + $0.rawValue } ?? "")
        case .collection(let c): "collection/" + c.rawValue
        default: nil
        }
    }

    init?(path: String) {
        let pieces = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = pieces.first.map(String.init), !head.isEmpty else { return nil }
        let parts = head.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0] == "collection" {
            guard pieces.count == 1, let key = MusicCollectionKey(rawValue: parts[1]) else { return nil }
            self = .collection(key)
            return
        }
        guard let id = MusicEntityID(routePath: head) else { return nil }
        var role: MusicRole?
        if pieces.count == 2 {
            let q = String(pieces[1])
            guard q.hasPrefix("role="), let r = MusicRole(rawValue: String(q.dropFirst(5))) else { return nil }
            role = r
        }
        self = .node(MusicEntityRoute(id, role: role))
    }

    /// The stored form of a persistable route (the same text as `path`).
    var persisted: String? { path }
    init?(persisted: String) { self.init(path: persisted) }
}

// MARK: the stack

/// Where the person is inside Music, as plain values. Choosing a section clears the stack, so Back never crosses sections.
struct MusicNav: Equatable {
    var section: MusicSection = .home
    private(set) var stack: [MusicRoute] = []
    /// True when the place shown now was reached with Back or Forward: a page that draws a new pick on each visit shows the one that was left.
    private(set) var arrivedByReturn = false

    var top: MusicRoute? { stack.last }
    var canGoBack: Bool { !stack.isEmpty }
    /// Where the person is; how they got there is not part of it.
    static func == (a: MusicNav, b: MusicNav) -> Bool { a.section == b.section && a.stack == b.stack }
    mutating func select(_ s: MusicSection) { section = s; stack = []; arrivedByReturn = false }

    /// Loop and duplicate rule (section 4.5): the same destination as the top is ignored; a destination already earlier in the stack truncates the
    /// stack back to it (A, B, A ends at the first A), so cycles never grow the stack. The depth is capped (oldest dropped from the front).
    mutating func push(_ r: MusicRoute) {
        if stack.last == r { return }
        arrivedByReturn = false
        let key = r.identityKey
        if let i = stack.lastIndex(where: { $0.identityKey == key }) {
            if i == stack.count - 1 { return }
            stack.removeSubrange((i + 1)...)
            stack[i] = r
            return
        }
        stack.append(r)
        if stack.count > Self.depthCap { stack.removeFirst(stack.count - Self.depthCap) }
    }

    static let depthCap = 50
    @discardableResult mutating func back() -> MusicRoute? {
        let left = stack.popLast()
        if left != nil { arrivedByReturn = true }
        return left
    }
    /// Takes pages that no longer exist (a deleted playlist) out of the stack, wherever they are, so Back never lands on them.
    mutating func remove(where gone: (MusicRoute) -> Bool) { stack.removeAll(where: gone) }
    /// Goes to a place from the history (Back, Forward or a restored destination).
    /// `returning` is false for the last session's place brought back at launch.
    mutating func restore(_ e: MusicNavEntry, returning: Bool = true) { section = e.section; stack = e.stack; arrivedByReturn = returning }
}
