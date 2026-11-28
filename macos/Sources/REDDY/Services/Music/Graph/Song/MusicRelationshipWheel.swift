import Foundation

// The song at the centre and the people and things around it: singer, composer, lyricist, producer, musicians, the film. Only credits the graph holds appear;
// a role nobody is credited for gets no node. Pure values, so the layout is tested without a screen.

struct MusicWheelNode: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable, CaseIterable { case singer, composer, lyricist, producer, musicians, film }
    var kind: Kind
    var people: [MusicSongCreditPerson]
    var film: MusicSongLink?
    var id: String { kind.rawValue }
    /// How many more people stand behind the names shown on the node.
    var extra: Int { max(0, people.count - 2) }
}

enum MusicRelationshipWheel {
    /// Clockwise from the top, the order of the owner's diagram.
    static let order: [MusicWheelNode.Kind] = [.composer, .lyricist, .producer, .musicians, .film, .singer]

    static func kind(for g: MusicSongCreditGroupKind) -> MusicWheelNode.Kind? {
        switch g {
        case .singers: .singer
        case .composers, .musicDirectors, .arrangers: .composer
        case .lyricists, .writers: .lyricist
        case .producers: .producer
        case .performers, .instruments: .musicians
        case .others: nil
        }
    }

    static func nodes(groups: [MusicSongCreditGroup], film: MusicSongFilmLink?) -> [MusicWheelNode] {
        var by: [MusicWheelNode.Kind: [MusicSongCreditPerson]] = [:]
        for g in groups {
            guard let k = kind(for: g.kind) else { continue }
            for p in g.people where !(by[k] ?? []).contains(where: { $0.id == p.id }) { by[k, default: []].append(p) }
        }
        var out: [MusicWheelNode] = order.compactMap { k in
            if k == .film { return film.flatMap { $0.isPlainText ? nil : MusicWheelNode(kind: .film, people: [], film: $0.film) } }
            return by[k].map { MusicWheelNode(kind: k, people: $0, film: nil) }
        }
        out.sort { (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0) }
        return out
    }

    /// The wheel is worth drawing when at least two things surround the song.
    static func isWorthShowing(_ nodes: [MusicWheelNode]) -> Bool { nodes.count >= 2 }

    /// Position of node `i` of `n` on a circle of radius 1 around (0, 0), starting at the top and going clockwise.
    static func point(index i: Int, of n: Int) -> (x: Double, y: Double) {
        guard n > 0 else { return (0, 0) }
        let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
        return (cos(a), sin(a))
    }
}
