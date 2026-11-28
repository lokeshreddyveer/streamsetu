import Foundation

/// The part of the graph one request has read: snapshots and edges of the walk's nodes, indexed by endpoint. The signals read only from here, so a
/// recommendation can never rest on something the graph does not hold.
struct MusicRecGraphView: Sendable {
    let root: MusicEntityID
    private(set) var snapshots: [MusicEntityID: MusicEntitySnapshot] = [:]
    private(set) var byEndpoint: [MusicEntityID: [MusicEdge]] = [:]
    private var seen: Set<MusicEdgeKey> = []
    /// Nodes whose own edges were read (a node can still appear as the end of a neighbour's edge).
    private(set) var loaded: Set<MusicEntityID> = []
    var depth: [MusicEntityID: Int] = [:]

    init(root: MusicEntityID) { self.root = root }

    mutating func add(snapshot s: MusicEntitySnapshot) { snapshots[s.id] = s }

    mutating func add(edges: [MusicEdge], of id: MusicEntityID) {
        loaded.insert(id)
        for e in edges where !e.tombstone && seen.insert(e.key).inserted {
            byEndpoint[e.subject, default: []].append(e)
            if e.object != e.subject { byEndpoint[e.object, default: []].append(e) }
        }
    }

    func snapshot(_ id: MusicEntityID) -> MusicEntitySnapshot? { snapshots[id] }
    func name(_ id: MusicEntityID) -> String { snapshots[id]?.name ?? "" }
    func hasLoadedEdges(_ id: MusicEntityID) -> Bool { loaded.contains(id) }

    /// Edges whose subject is `id`, optionally limited to some predicates.
    func out(_ id: MusicEntityID, _ preds: Set<MusicPredicate>? = nil) -> [MusicEdge] {
        (byEndpoint[id] ?? []).filter { $0.subject == id && (preds?.contains($0.predicate) ?? true) }
    }
    /// Edges whose object is `id`.
    func inc(_ id: MusicEntityID, _ preds: Set<MusicPredicate>? = nil) -> [MusicEdge] {
        (byEndpoint[id] ?? []).filter { $0.object == id && (preds?.contains($0.predicate) ?? true) }
    }
    /// Edges that join exactly these two entities, either way round.
    func between(_ a: MusicEntityID, _ b: MusicEntityID) -> [MusicEdge] {
        (byEndpoint[a] ?? []).filter { ($0.subject == a && $0.object == b) || ($0.subject == b && $0.object == a) }
    }
}

/// An edge strong enough to rest a statement on: verified, or inferred above the floor. Retracted and conflicted edges are never used.
func recEdgeIsUsable(_ e: MusicEdge, floor: Float) -> Bool {
    if e.tombstone { return false }
    switch e.status {
    case .verified: return true
    case .inferred: return e.confidence >= floor
    case .conflicted: return false
    }
}

enum MusicRecRoles {
    static let credit: Set<MusicPredicate> = [.performedBy, .composedBy, .musicDirectedBy, .writtenBy, .producedBy]
    static let lead: Set<MusicRole> = [.composer, .musicDirector, .arranger, .conductor]
    static let vocal: Set<MusicRole> = [.singer, .performer, .featured, .instrumentalist]
    static let words: Set<MusicRole> = [.lyricist, .writer]

    /// The role an edge carries, falling back to the predicate's usual role.
    static func role(of e: MusicEdge) -> MusicRole {
        if let r = e.role { return r }
        switch e.predicate {
        case .performedBy: return .performer
        case .composedBy: return .composer
        case .musicDirectedBy: return .musicDirector
        case .writtenBy: return .writer
        case .producedBy: return .producer
        case .directedBy: return .director
        case .hasCast: return .actor
        default: return .performer
        }
    }

    /// How much a role says about musical likeness (role-weighted Jaccard).
    static func weight(_ r: MusicRole) -> Double {
        if lead.contains(r) { return 1.0 }
        if words.contains(r) { return 0.8 }
        if r == .singer { return 0.7 }
        if vocal.contains(r) { return 0.5 }
        if r == .director { return 0.5 }
        return 0.25
    }
}

/// What the walk knows about one entity, flattened so signals compare plain sets.
struct MusicRecFacets: Sendable {
    struct Link: Sendable, Equatable { var confidence: Float; var verified: Bool }
    struct Credit: Sendable {
        var roles: Set<MusicRole>
        var confidence: Float
        /// Read from the song's album or film rather than the song itself (the "film credit" of the design, D7).
        var inherited: Bool
        var order: Int
    }

    var credits: [MusicEntityID: Credit] = [:]
    var albums: [MusicEntityID: Link] = [:]
    var films: [MusicEntityID: Link] = [:]
    var works: [MusicEntityID: Link] = [:]
    var versions: [MusicEntityID: Link] = [:]
    var cast: [MusicEntityID: Int] = [:]
    var groups: [MusicEntityID: Link] = [:]
    var members: [MusicEntityID: Link] = [:]
    var languages: Set<String> = []
    var languageNames: [String: String] = [:]
    var genres: [String: String] = [:]
    var year: Int?
    var primaryPerformer: MusicEntityID?

    var composers: [MusicEntityID] { credits.filter { !$0.value.roles.isDisjoint(with: MusicRecRoles.lead) }.map(\.key) }
    var singers: [MusicEntityID] { credits.filter { !$0.value.roles.isDisjoint(with: MusicRecRoles.vocal) }.map(\.key) }
}

enum MusicRecFacetBuilder {
    static func build(_ id: MusicEntityID, view: MusicRecGraphView, floor: Float) -> MusicRecFacets {
        var f = MusicRecFacets()
        let snap = view.snapshot(id)
        func link(_ e: MusicEdge) -> MusicRecFacets.Link { .init(confidence: e.status == .verified ? max(e.confidence, 0.9) : e.confidence, verified: e.status == .verified) }
        func addCredit(_ person: MusicEntityID, role: MusicRole, e: MusicEdge, inherited: Bool, scale: Float = 1) {
            guard person.kind.isAgent else { return }
            let c = link(e).confidence * scale
            var cur = f.credits[person] ?? .init(roles: [], confidence: 0, inherited: inherited, order: e.order ?? 999)
            cur.roles.insert(role)
            cur.confidence = max(cur.confidence, c)
            cur.inherited = cur.inherited && inherited
            cur.order = min(cur.order, e.order ?? 999)
            f.credits[person] = cur
        }
        func ownCredits(of node: MusicEntityID, inherited: Bool, preds: Set<MusicPredicate>, scale: Float = 1) {
            for e in view.out(node, preds) where recEdgeIsUsable(e, floor: floor) { addCredit(e.object, role: MusicRecRoles.role(of: e), e: e, inherited: inherited, scale: scale) }
        }
        func addFilm(_ film: MusicEntityID, via e: MusicEdge, extra: Float = 1, requireVerifiedWith other: Bool = true) {
            let l = link(e)
            let l2 = MusicRecFacets.Link(confidence: min(l.confidence, extra), verified: l.verified && other)
            if let cur = f.films[film], cur.verified || cur.confidence >= l2.confidence { return }
            f.films[film] = l2
        }
        func filmContext(_ film: MusicEntityID) {
            for e in view.out(film, [.hasCast]) where recEdgeIsUsable(e, floor: floor) { f.cast[e.object] = min(f.cast[e.object] ?? 999, e.order ?? 999) }
            ownCredits(of: film, inherited: true, preds: [.composedBy, .musicDirectedBy, .directedBy], scale: 0.85)
        }

        switch id.kind {
        case .recording, .track, .work:
            ownCredits(of: id, inherited: false, preds: MusicRecRoles.credit)
            for e in view.out(id, [.trackOn, .editionOf]) where recEdgeIsUsable(e, floor: floor) { f.albums[e.object] = link(e) }
            for e in view.out(id, [.featuredIn]) where recEdgeIsUsable(e, floor: floor) { addFilm(e.object, via: e) }
            for e in view.out(id, [.recordingOf]) where recEdgeIsUsable(e, floor: floor) { f.works[e.object] = link(e) }
            for e in view.out(id, [.alternateOf]) + view.inc(id, [.alternateOf]) where recEdgeIsUsable(e, floor: floor) {
                f.versions[e.subject == id ? e.object : e.subject] = link(e)
            }
            for (album, al) in f.albums {
                ownCredits(of: album, inherited: true, preds: [.musicDirectedBy, .composedBy, .writtenBy], scale: 0.85)
                for e in view.out(album, [.soundtrackOf]) where recEdgeIsUsable(e, floor: floor) { addFilm(e.object, via: e, extra: al.confidence, requireVerifiedWith: al.verified) }
            }
            for film in Array(f.films.keys) { filmContext(film) }
        case .album, .release:
            ownCredits(of: id, inherited: false, preds: MusicRecRoles.credit)
            for e in view.out(id, [.soundtrackOf]) where recEdgeIsUsable(e, floor: floor) { addFilm(e.object, via: e) }
            for e in view.out(id, [.editionOf]) where recEdgeIsUsable(e, floor: floor) { f.albums[e.object] = link(e) }
            for film in Array(f.films.keys) { filmContext(film) }
            // The people on its tracks, at reduced weight: an album is what its songs are.
            for t in view.inc(id, [.trackOn]) where recEdgeIsUsable(t, floor: floor) {
                for e in view.out(t.subject, [.performedBy, .composedBy, .musicDirectedBy, .writtenBy]) where recEdgeIsUsable(e, floor: floor) {
                    addCredit(e.object, role: MusicRecRoles.role(of: e), e: e, inherited: true, scale: 0.8)
                }
            }
        case .film, .series:
            f.films[id] = .init(confidence: 1, verified: true)
            for e in view.out(id, [.hasCast]) where recEdgeIsUsable(e, floor: floor) { f.cast[e.object] = min(f.cast[e.object] ?? 999, e.order ?? 999) }
            ownCredits(of: id, inherited: false, preds: [.composedBy, .musicDirectedBy, .directedBy, .producedBy])
        case .person, .group:
            var roles: Set<MusicRole> = []
            for e in view.inc(id) where recEdgeIsUsable(e, floor: floor) {
                switch e.predicate {
                case .performedBy, .composedBy, .musicDirectedBy, .writtenBy, .producedBy, .directedBy: roles.insert(MusicRecRoles.role(of: e))
                case .hasCast:
                    roles.insert(.actor)
                    addFilm(e.subject, via: e)
                case .memberOf: f.members[e.subject] = link(e)
                default: break
                }
            }
            if !roles.isEmpty { f.credits[id] = .init(roles: roles, confidence: 1, inherited: false, order: 0) }
            for e in view.out(id, [.memberOf]) where recEdgeIsUsable(e, floor: floor) { f.groups[e.object] = link(e) }
            // Films of the works the person is credited on, for "same film" comparisons.
            for e in view.inc(id) where recEdgeIsUsable(e, floor: floor) && MusicRecRoles.credit.contains(e.predicate) {
                for fe in view.out(e.subject, [.featuredIn, .soundtrackOf]) where recEdgeIsUsable(fe, floor: floor) { addFilm(fe.object, via: fe, extra: link(e).confidence) }
            }
        default: break
        }

        // Language, genre, era: the node's own fields first, then its facet edges.
        if let l = snap?.lang, !l.isEmpty { let k = MusicRecLanguage.key(l); f.languages.insert(k); f.languageNames[k] = MusicRecLanguage.display(k) }
        for e in view.out(id, [.inLanguage]) where recEdgeIsUsable(e, floor: floor) {
            f.languages.insert("id:" + e.object.rawValue)
            if let s = view.snapshot(e.object) {
                let k = MusicRecLanguage.key(s.attrs["iso639"] ?? s.lang ?? s.name)
                f.languages.insert(k); f.languageNames[k] = MusicRecLanguage.display(MusicRecLanguage.key(s.name))
            }
        }
        for e in view.out(id, [.hasGenre]) where recEdgeIsUsable(e, floor: floor) {
            f.genres["id:" + e.object.rawValue] = view.snapshot(e.object)?.name ?? ""
        }
        if let g = snap?.attrs["genres"] { for part in g.split(separator: ",") { let n = part.trimmingCharacters(in: .whitespaces); if !n.isEmpty { f.genres[n.lowercased()] = n } } }
        f.year = snap?.year ?? f.albums.keys.compactMap { view.snapshot($0)?.year }.min() ?? f.films.keys.compactMap { view.snapshot($0)?.year }.min()
        f.primaryPerformer = view.out(id, [.performedBy]).filter { recEdgeIsUsable($0, floor: floor) }
            .sorted { ($0.order ?? 999) < ($1.order ?? 999) }.first?.object
        return f
    }
}
