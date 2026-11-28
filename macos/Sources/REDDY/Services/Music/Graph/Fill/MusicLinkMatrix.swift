import Foundation

// The link matrix: for any entity (a song, an album or soundtrack, a person, a film, a playlist) every kind of thing it connects to, in both
// directions, read from the graph's typed edges (one hop, plus a bounded second hop through the entity's songs). Pure: Foundation and the graph
// store only, no UI. Pages, rows, chips and context menus all ask this one place, so a name that is a link on one screen is a link on all of them.
//
// Rules the tests hold:
//  - a link is a graph id (never a copy of a name), so Back and Forward keep their page memory;
//  - "Various Artists" and the other compilation credits are never a link, a destination or a radio seed;
//  - `destination(_:in:)` never returns nothing: with no link of that kind it names a search for it, so a menu item is never dead.

/// The kinds of place a link can lead to. A person is one `artist` link, and also one link per role they hold on the source.
enum MusicConnectionKind: String, CaseIterable, Sendable, Hashable {
    case song, album, soundtrack, artist, film, musicDirector, singer, lyricist, actor, playlist, radio

    /// The kinds a page of `source` must be able to reach (all of them but itself). A radio is reachable from everything.
    static func reachable(from source: MusicConnectionKind) -> [MusicConnectionKind] {
        allCases.filter { $0 != source && !(source == .soundtrack && $0 == .album) && !(source == .album && $0 == .soundtrack) }
    }

    /// The kinds a graph entity is a source of.
    static func source(of kind: MusicEntityKind, isSoundtrack: Bool = false) -> MusicConnectionKind? {
        switch kind {
        case .recording, .work, .track: .song
        case .album, .release: isSoundtrack ? .soundtrack : .album
        case .person, .group: .artist
        case .film, .series: .film
        case .playlist: .playlist
        case .station: .radio
        default: nil
        }
    }

    /// The person kinds a role belongs to (a person credited as composer or music director is one "music director" link).
    static func person(role: MusicRole?) -> MusicConnectionKind {
        switch role {
        case .singer?: .singer
        case .composer?, .musicDirector?: .musicDirector
        case .lyricist?, .writer?: .lyricist
        case .actor?: .actor
        default: .artist
        }
    }

    var isPerson: Bool { switch self { case .artist, .musicDirector, .singer, .lyricist, .actor: true; default: false } }
}

/// One thing the source connects to.
struct MusicConnection: Hashable, Sendable, Identifiable {
    var kind: MusicConnectionKind
    /// The entity to open. For `.radio` it is the seed (the source itself).
    var target: MusicEntityID
    var name: String
    /// The role the person holds on the source (opens the person page on that view).
    var role: MusicRole?
    var imageRef: String?
    var year: Int?
    /// How many of the source's songs connect to it (1 for a direct edge).
    var count: Int
    /// Read through the source's songs or soundtrack, not stated on the source itself.
    var derived: Bool
    var id: String { kind.rawValue + "|" + target.rawValue + "|" + (role?.rawValue ?? "") }
}

/// Where a link or a menu item goes. Never absent.
enum MusicLinkDestination: Hashable, Sendable {
    /// The typed page of an entity (a person opens on `role`).
    case page(MusicEntityID, role: MusicRole?)
    /// Start a radio seeded by this entity.
    case radio(seed: MusicEntityID)
    /// The graph has no such link yet: a typed search for it ("<title> film"), so the person is never at a dead end. The completeness pass fills it later.
    case search(query: String, kind: MusicConnectionKind)
}

struct MusicLinkSet: Sendable {
    var source: MusicEntityID
    var sourceKind: MusicConnectionKind
    var sourceName: String
    var links: [MusicConnection]
    /// The source is a compilation credit ("Various Artists"): it has no links and no radio.
    var isCompilation = false

    func links(_ kind: MusicConnectionKind) -> [MusicConnection] { links.filter { $0.kind == kind } }
    func has(_ kind: MusicConnectionKind) -> Bool { links.contains { $0.kind == kind } }
    /// The kinds with at least one real link.
    var present: Set<MusicConnectionKind> { Set(links.map(\.kind)) }

    /// The one place `kind` leads: the strongest link (most songs, then billing order), a radio seeded here, or a search. Never nil.
    func destination(_ kind: MusicConnectionKind) -> MusicLinkDestination {
        if kind == .radio { return isCompilation ? .search(query: sourceName, kind: .radio) : .radio(seed: source) }
        if let l = links(kind).first { return .page(l.target, role: l.role) }
        return .search(query: MusicLinkMatrix.fallbackQuery(kind, sourceName: sourceName), kind: kind)
    }

    /// Every destination of the matrix row for this source.
    func matrixRow() -> [(kind: MusicConnectionKind, destination: MusicLinkDestination)] {
        MusicConnectionKind.reachable(from: sourceKind).map { ($0, destination($0)) }
    }
}

enum MusicLinkMatrix {
    /// Credits from the source's own edges are read up to this many; second-hop reads cover at most `songBudget` songs.
    static let edgeLimit = 200
    static let songBudget = 30

    /// Credit names that are labels for a compilation, never a person (the app also asks `MusicCompilationArtist`, see `MusicLinkMatrixHook`).
    static func isVariousArtists(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }
        if hook.isCompilation?(name) == true { return true }
        let heads = ["various artists", "various artist", "various", "v.a.", "va", "multiple artists", "assorted artists", "unknown artist", "soundtrack",
                     "original soundtrack", "original motion picture soundtrack", "ost", "original cast", "विभिन्न कलाकार", "వివిధ కళాకారులు", "பல்வேறு கலைஞர்கள்"]
        if heads.contains(t) { return true }
        for sep in [" - ", " – ", " — ", " | ", ": ", " (", " ["] {
            if let r = t.range(of: sep), r.lowerBound > t.startIndex, heads.contains(String(t[..<r.lowerBound])) { return true }
        }
        return false
    }

    /// The app sets the stricter `MusicCompilationArtist.isCompilation` here at launch; tests leave it unset.
    final class Hook: @unchecked Sendable {
        private let lock = NSLock()
        private var fn: (@Sendable (String) -> Bool)?
        var isCompilation: (@Sendable (String) -> Bool)? { get { lock.withLock { fn } } set { lock.withLock { fn = newValue } } }
    }
    static let hook = Hook()

    static func fallbackQuery(_ kind: MusicConnectionKind, sourceName: String) -> String {
        switch kind {
        case .film: "\(sourceName) film"
        case .soundtrack: "\(sourceName) soundtrack"
        case .musicDirector: "\(sourceName) music director"
        case .lyricist: "\(sourceName) lyricist"
        case .singer: "\(sourceName) singer"
        case .actor: "\(sourceName) cast"
        case .album: "\(sourceName) album"
        case .playlist: "\(sourceName) playlist"
        case .artist: "\(sourceName) artist"
        case .song, .radio: sourceName
        }
    }

    // MARK: reading

    private struct Acc {
        var link: MusicConnection
        var order: Int
    }

    /// Every link of `id`, both directions, grouped by kind when asked. Reads at most `edgeLimit` edges of the source and the edges of `songBudget` songs.
    static func read(_ id: MusicEntityID, store: any MusicGraphStoring) async -> MusicLinkSet {
        let canonical = (try? await store.resolve(id)) ?? id
        guard let snap = try? await store.entity(canonical) else {
            return MusicLinkSet(source: canonical, sourceKind: MusicConnectionKind.source(of: canonical.kind) ?? .song, sourceName: "", links: [])
        }
        let edges = (try? await store.edges(of: canonical, predicate: nil, direction: .both, limit: edgeLimit)) ?? []
        var isSoundtrack = snap.subkind == "soundtrack"
        if !isSoundtrack, edges.contains(where: { $0.subject == canonical && $0.predicate == .soundtrackOf }) { isSoundtrack = true }
        var kind = MusicConnectionKind.source(of: canonical.kind, isSoundtrack: isSoundtrack) ?? .song
        if canonical.kind.isAgent {
            // A person's page is the page of their main role (the one most credits point at), so "music director" is not a link from itself.
            var counts: [MusicConnectionKind: Int] = [:]
            for e in edges where e.object == canonical && !e.tombstone {
                let r: MusicRole? = e.role ?? { switch e.predicate { case .composedBy, .musicDirectedBy: .musicDirector; case .writtenBy: .lyricist; case .performedBy: .singer; case .hasCast: .actor; default: nil } }()
                let k = MusicConnectionKind.person(role: r)
                if k != .artist { counts[k, default: 0] += 1 }
            }
            let prio: [MusicConnectionKind] = [.musicDirector, .singer, .lyricist, .actor]
            if let top = prio.filter({ (counts[$0] ?? 0) > 0 }).max(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) }) { kind = top }
        }
        if isVariousArtists(snap.name) { return MusicLinkSet(source: canonical, sourceKind: kind, sourceName: snap.name, links: [], isCompilation: true) }
        var out: [String: Acc] = [:]
        var seq = 0
        var names: [MusicEntityID: MusicEntitySnapshot] = [canonical: snap]

        func name(_ e: MusicEntityID) async -> MusicEntitySnapshot? {
            if let s = names[e] { return s }
            let live = (try? await store.resolve(e)) ?? e
            guard let s = try? await store.entity(live), s.state == .live else { return nil }
            names[e] = s; names[live] = s
            return s
        }
        func add(_ k: MusicConnectionKind, _ other: MusicEntityID, role: MusicRole? = nil, derived: Bool, count: Int = 1) async {
            guard let s = await name(other), !isVariousArtists(s.name), s.id != canonical else { return }
            if k.isPerson, !s.kind.isAgent { return }
            if k == .film, MusicFranchise.isFranchise(s.subkind) { return }   // a franchise is not a film: its page would be empty
            let key = k.rawValue + "|" + s.id.rawValue + "|" + (role?.rawValue ?? "")
            if var a = out[key] {
                a.link.count += count
                if !derived { a.link.derived = false }
                out[key] = a
            } else {
                seq += 1
                out[key] = Acc(link: MusicConnection(kind: k, target: s.id, name: s.name, role: role, imageRef: s.imageRef, year: s.year, count: count, derived: derived), order: seq)
            }
        }
        /// A person credited on a work: one `artist` link, and one role link.
        func addPerson(_ p: MusicEntityID, role: MusicRole?, derived: Bool, count: Int = 1) async {
            await add(.artist, p, role: nil, derived: derived, count: count)
            let k = MusicConnectionKind.person(role: role)
            if k != .artist { await add(k, p, role: role, derived: derived, count: count) }
        }
        func isSoundtrackAlbum(_ a: MusicEntityID) async -> Bool {
            if let s = await name(a), s.subkind == "soundtrack" { return true }
            let e = (try? await store.edges(of: a, predicate: .soundtrackOf, direction: .outgoing, limit: 1)) ?? []
            return !e.isEmpty
        }
        func addAlbum(_ a: MusicEntityID, derived: Bool, count: Int = 1) async {
            await add(.album, a, derived: derived, count: count)
            if await isSoundtrackAlbum(a) { await add(.soundtrack, a, derived: derived, count: count) }
        }
        func creditRole(_ e: MusicEdge) -> MusicRole? {
            if let r = e.role { return r }
            switch e.predicate {
            case .composedBy, .musicDirectedBy: return .musicDirector
            case .writtenBy: return .lyricist
            case .performedBy: return e.subject.kind == .recording || e.subject.kind == .track ? .singer : .performer
            case .directedBy: return .director
            case .hasCast: return .actor
            case .producedBy: return .producer
            default: return nil
            }
        }
        let credit: Set<MusicPredicate> = [.performedBy, .composedBy, .musicDirectedBy, .writtenBy, .producedBy, .directedBy, .hasCast]

        // Direct edges, both directions.
        var songs: [MusicEntityID] = []
        for e in edges where !e.tombstone {
            let outgoing = e.subject == canonical
            let other = outgoing ? e.object : e.subject
            switch e.predicate {
            case _ where credit.contains(e.predicate):
                if outgoing { await addPerson(other, role: creditRole(e), derived: false) }
                else {
                    // Someone is credited on `other`: an artist's page lists the work.
                    switch other.kind {
                    case .recording, .track, .work: await add(.song, other, derived: false); songs.append(other)
                    case .album, .release: await addAlbum(other, derived: false)
                    case .film, .series: await add(.film, other, derived: false)
                    default: break
                    }
                }
            case .trackOn:
                if outgoing { await addAlbum(other, derived: false) } else { await add(.song, other, derived: false); songs.append(other) }
            case .editionOf:
                if outgoing { await addAlbum(other, derived: false) } else { await addAlbum(other, derived: false) }
            case .featuredIn:
                if outgoing { await add(.film, other, derived: false) } else { await add(.song, other, derived: false); songs.append(other) }
            case .soundtrackOf:
                if outgoing { await add(.film, other, derived: false) } else { await addAlbum(other, derived: false) }
            case .playlistContains:
                if outgoing { await add(.song, other, derived: false); songs.append(other) } else { await add(.playlist, other, derived: false) }
            case .relatedAlbum:
                await addAlbum(other, derived: false)
            default: break
            }
        }

        func targets(_ k: MusicConnectionKind) -> [MusicEntityID] { out.values.filter { $0.link.kind == k }.sorted { $0.order < $1.order }.map(\.link.target) }

        // A song's film through its albums' soundtrack edge.
        if kind == .song {
            for a in targets(.album).prefix(4) {
                let films = (try? await store.edges(of: a, predicate: .soundtrackOf, direction: .outgoing, limit: 4)) ?? []
                for f in films { await add(.film, f.object, derived: true) }
            }
        }
        // A person's work in films: the songs and soundtracks of the films they are credited on (an actor has no songs of their own).
        if canonical.kind.isAgent {
            for f in targets(.film).prefix(3) {
                let fs = (try? await store.edges(of: f, predicate: .featuredIn, direction: .incoming, limit: 20)) ?? []
                for e in fs { await add(.song, e.subject, derived: true); songs.append(e.subject) }
                let ost = (try? await store.edges(of: f, predicate: .soundtrackOf, direction: .incoming, limit: 6)) ?? []
                for e in ost { await addAlbum(e.subject, derived: true) }
            }
        }
        // A film's songs also come through its soundtrack albums.
        if kind == .film {
            for a in targets(.soundtrack).prefix(4) {
                let tr = (try? await store.edges(of: a, predicate: .trackOn, direction: .incoming, limit: 80)) ?? []
                for t in tr { await add(.song, t.subject, derived: true); songs.append(t.subject) }
            }
        }
        // Second hop through the songs: an album, a film, a playlist and a person have the credits, albums, films and playlists of their songs.
        if kind != .song {
            for s in Array(Set(songs)).sorted().prefix(songBudget) {
                let se = (try? await store.edges(of: s, predicate: nil, direction: .both, limit: 100)) ?? []
                for e in se where !e.tombstone {
                    let outgoing = e.subject == s
                    switch e.predicate {
                    case _ where credit.contains(e.predicate):
                        if outgoing { await addPerson(e.object, role: creditRole(e), derived: true) }
                    case .trackOn:
                        if outgoing, kind != .album, kind != .soundtrack { await addAlbum(e.object, derived: true) }
                    case .featuredIn:
                        if outgoing, kind != .film { await add(.film, e.object, derived: true) }
                    case .playlistContains:
                        if !outgoing, kind != .playlist { await add(.playlist, e.subject, derived: true) }
                    default: break
                    }
                }
            }
        }

        // The people of the films: cast and music directors of every film the source connects to (a song's, an album's, a person's, a playlist's).
        if kind != .film {
            for f in targets(.film).prefix(3) {
                let fe = (try? await store.edges(of: f, predicate: nil, direction: .outgoing, limit: 40)) ?? []
                var cast = 0
                for e in fe.sorted(by: { ($0.order ?? 99) < ($1.order ?? 99) }) where !e.tombstone {
                    if e.predicate == .hasCast, cast < 6 { cast += 1; await addPerson(e.object, role: .actor, derived: true) }
                    else if e.predicate == .musicDirectedBy || e.predicate == .composedBy { await addPerson(e.object, role: .musicDirector, derived: true) }
                }
            }
        }
        var links = out.values.filter { $0.link.kind != .radio }.sorted { a, b in
            if a.link.kind != b.link.kind { return a.link.kind.rawValue < b.link.kind.rawValue }
            if a.link.derived != b.link.derived { return !a.link.derived }
            if a.link.count != b.link.count { return a.link.count > b.link.count }
            return a.order < b.order
        }.map(\.link)
        links.append(MusicConnection(kind: .radio, target: canonical, name: snap.name, role: nil, imageRef: snap.imageRef, year: snap.year, count: 1, derived: false))
        return MusicLinkSet(source: canonical, sourceKind: kind, sourceName: snap.name, links: links)
    }
}
