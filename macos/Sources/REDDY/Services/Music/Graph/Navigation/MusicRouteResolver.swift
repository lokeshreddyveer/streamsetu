import Foundation

/// Converts the older value routes into entity routes, lazily (section 4.1). The conversion never blocks a push: a legacy route keeps rendering
/// with its old page, and a page that wants the graph asks for the entity route here.
enum MusicRouteResolver {
    /// The entity route a legacy route stands for, with no database read: the provisional id is a pure function of the provider uid, so the same
    /// provider album always gives the same route. Nil for routes with no entity counterpart (a local playlist, a user, the Never play list, a browse genre).
    static func provisionalRoute(for route: MusicRoute) -> MusicRoute? {
        switch route {
        case .node, .collection: route
        case .album(let a): .entity(.provisional(kind: .release, providerUID: a.uid))
        case .artist(let a): .entity(.provisional(kind: .person, providerUID: a.uid))
        case .playlist(let p): .entity(.provisional(kind: .playlist, providerUID: p.uid))
        case .localPlaylist, .genre, .user, .blacklist, .actor: nil
        }
    }

    /// The same, but only when the graph already knows the item (an alias row exists): its stable id, which may differ from the provisional one
    /// after a merge. Nil when the graph does not know it yet or the route has no counterpart; the caller keeps the legacy route.
    static func knownRoute(for route: MusicRoute, index: MusicEntityIndex) async -> MusicRoute? {
        let kind: MusicEntityKind, uid: String
        switch route {
        case .node, .collection: return route
        case .album(let a): kind = .release; uid = a.uid
        case .artist(let a): kind = .person; uid = a.uid
        case .playlist(let p): kind = .playlist; uid = p.uid
        default: return nil
        }
        guard let id = try? await index.lookup(providerUID: uid, kind: kind) else { return nil }
        return .entity(id)
    }
}
