import Foundation

// Role detection for the person page (section 6.3 of the graph design). A person has a role only when an EDGE backs it: an actor is someone a film
// lists in its cast, a singer is someone a recording or album credits as a performer. Nothing here looks at a name, a provider's wording or a guess.

/// The five views a person page can show. Several roles feed one view (a music director and a composer share one).
enum MusicPersonView: String, Codable, Sendable, CaseIterable, Hashable {
    case singer, composer, lyricist, actor, director, producer, instrumentalist, conductor, label

    /// The edge roles that belong to this view.
    var roles: Set<MusicRole> {
        switch self {
        case .singer: [.singer, .performer, .featured, .remixer]
        case .composer: [.composer, .musicDirector, .arranger]
        case .lyricist: [.lyricist, .writer]
        case .actor: [.actor]
        case .director: [.director]
        case .producer: [.producer]
        case .instrumentalist: [.instrumentalist]
        case .conductor: [.conductor]
        case .label: [.label]
        }
    }

    static func view(for role: MusicRole) -> MusicPersonView? { allCases.first { $0.roles.contains(role) } }

    /// Tie-break when two views have the same number of credits: the owner's order.
    var priority: Int { switch self { case .singer: 0; case .composer: 1; case .actor: 2; case .director: 3; case .lyricist: 4; case .producer: 5; case .instrumentalist: 6; case .conductor: 7; case .label: 8 } }

    /// The value kept in page memory (`filters["role"]`).
    var memoryValue: String { rawValue }
}

/// What the chip of a view says. `artist` is a person credited only as a performer (a provider said "performed by", nobody said "sang").
enum MusicPersonRoleLabel: String, Sendable, Hashable {
    case singer, artist, composer, musicDirector, lyricist, writer, actor, director, producer, screenwriter, cinematographer, editor, label, instrumentalist, conductor
}

struct MusicPersonViewSummary: Hashable, Sendable {
    var view: MusicPersonView
    var label: MusicPersonRoleLabel
    /// Distinct works the person is credited on in this view.
    var count: Int
}

/// A role with edges but no page of its own (a screenwriter, cinematographer or editor): shown as a plain chip, not a tab.
struct MusicPersonExtraRole: Hashable, Sendable {
    var label: MusicPersonRoleLabel
    var count: Int
}

struct MusicPersonRoleSummary: Hashable, Sendable {
    var views: [MusicPersonViewSummary]
    var extras: [MusicPersonExtraRole]
    var isEmpty: Bool { views.isEmpty && extras.isEmpty }
    /// The role switcher shows only when there are several views.
    var needsSwitcher: Bool { views.count > 1 }
    func has(_ v: MusicPersonView) -> Bool { views.contains { $0.view == v } }
    func summary(_ v: MusicPersonView) -> MusicPersonViewSummary? { views.first { $0.view == v } }
    static let empty = MusicPersonRoleSummary(views: [], extras: [])
}

enum MusicPersonRoles {
    /// Edges below this confidence do not count toward a role unless a source verified them (a matcher guess does not make anyone an actor).
    static let minConfidence: Float = 0.4

    /// The credit predicates a person can be the object of, and the roles each may carry. A role the predicate cannot carry (an `actor` qualifier on a
    /// `performedBy` edge) is ignored: it is a mapper mistake, not a credit.
    static func allowedRoles(for p: MusicPredicate) -> Set<MusicRole> {
        switch p {
        case .performedBy: [.singer, .performer, .instrumentalist, .featured, .conductor, .remixer]
        case .composedBy: [.composer, .arranger, .musicDirector]
        case .musicDirectedBy: [.musicDirector, .composer]
        case .writtenBy: [.lyricist, .writer, .screenwriter]
        case .producedBy: [.producer, .arranger, .editor, .label]
        case .directedBy: [.director]
        case .hasCast: [.actor]
        default: []
        }
    }

    /// The role an edge gives its object: the qualifier when the predicate can carry it, else the predicate's default when the qualifier is empty.
    static func effectiveRole(_ e: MusicEdge) -> MusicRole? {
        let allowed = allowedRoles(for: e.predicate)
        guard !allowed.isEmpty else { return nil }
        if let r = e.role { return allowed.contains(r) ? r : nil }
        if !e.qualifier.isEmpty { return nil }
        switch e.predicate {
        case .performedBy: return .performer
        case .composedBy: return .composer
        case .musicDirectedBy: return .musicDirector
        case .writtenBy: return .writer
        case .producedBy: return .producer
        case .directedBy: return .director
        case .hasCast: return .actor
        default: return nil
        }
    }

    /// Whether an edge counts at all.
    static func counts(_ e: MusicEdge) -> Bool {
        guard !e.tombstone, effectiveRole(e) != nil else { return false }
        return e.status == .verified || e.confidence >= minConfidence
    }

    /// Roles of a person from the edges that point at them (`edges(of: id, direction: .incoming)`). Distinct subjects per role.
    static func summarize(incoming edges: [MusicEdge]) -> MusicPersonRoleSummary {
        var byRole: [MusicRole: Set<MusicEntityID>] = [:]
        for e in edges where counts(e) { if let r = effectiveRole(e) { byRole[r, default: []].insert(e.subject) } }
        var views: [MusicPersonViewSummary] = []
        for v in MusicPersonView.allCases {
            var works = Set<MusicEntityID>()
            for r in v.roles { works.formUnion(byRole[r] ?? []) }
            guard !works.isEmpty else { continue }
            views.append(MusicPersonViewSummary(view: v, label: label(for: v, byRole: byRole), count: works.count))
        }
        views.sort { $0.count != $1.count ? $0.count > $1.count : $0.view.priority < $1.view.priority }
        var extras: [MusicPersonExtraRole] = []
        for (role, label) in [(MusicRole.screenwriter, MusicPersonRoleLabel.screenwriter), (.cinematographer, .cinematographer), (.editor, .editor)] {
            if let n = byRole[role]?.count, n > 0 { extras.append(MusicPersonExtraRole(label: label, count: n)) }
        }
        return MusicPersonRoleSummary(views: views, extras: extras)
    }

    private static func label(for v: MusicPersonView, byRole: [MusicRole: Set<MusicEntityID>]) -> MusicPersonRoleLabel {
        func n(_ r: MusicRole) -> Int { byRole[r]?.count ?? 0 }
        switch v {
        case .singer: return n(.singer) > 0 ? .singer : .artist
        case .composer:
            if n(.musicDirector) == 0, n(.composer) == 0, n(.arranger) > 0 { return .composer }
            return n(.musicDirector) > n(.composer) ? .musicDirector : (n(.composer) > 0 ? .composer : .musicDirector)
        case .lyricist: return n(.lyricist) > 0 ? .lyricist : .writer
        case .actor: return .actor
        case .director: return .director
        case .producer: return .producer
        case .instrumentalist: return .instrumentalist
        case .conductor: return .conductor
        case .label: return .label
        }
    }

    /// Which view opens first: the page's remembered choice, then the route's role hint, then the view with the most credits, then nothing (a person
    /// the graph knows no credits of shows a plain page). While nothing has loaded yet the hint is honoured as is, so the page does not flip when edges arrive.
    static func initialView(summary: MusicPersonRoleSummary, remembered: String?, hint: MusicRole?, loaded: Bool = true) -> MusicPersonView? {
        if let remembered, let v = MusicPersonView(rawValue: remembered), summary.has(v) { return v }
        if let hint, let v = MusicPersonView.view(for: hint) {
            if summary.has(v) { return v }
            if !loaded && summary.isEmpty { return v }
        }
        return summary.views.first?.view
    }
}
