import Foundation

// What the Films pill can filter by beyond the credit: the film's director and its genre, read from the edges the graph holds for each film. A film with no such
// edge is simply not offered under that filter; nothing is guessed from a title.

struct MusicFilmFacet: Hashable, Sendable, Identifiable {
    var id: MusicEntityID
    var name: String
}

struct MusicArtistFilmFacts: Equatable, Sendable {
    var directors: [MusicEntityID: [MusicFilmFacet]] = [:]
    var genres: [MusicEntityID: [MusicFilmFacet]] = [:]

    static let empty = MusicArtistFilmFacts()
    /// The most films one page reads facts for (each costs two small reads).
    static let maxFilms = 120
    static let maxChips = 30

    /// The facets the given films carry, most films first, then by name. `exclude` leaves out a facet that would be on every card (the page's own person).
    static func chips(_ map: [MusicEntityID: [MusicFilmFacet]], films: [MusicPersonEntry], exclude: MusicEntityID? = nil) -> [(facet: MusicFilmFacet, count: Int)] {
        var n: [MusicEntityID: (facet: MusicFilmFacet, count: Int)] = [:]
        for f in films {
            for x in map[f.id] ?? [] where x.id != exclude {
                var v = n[x.id] ?? (facet: x, count: 0)
                v.count += 1
                n[x.id] = v
            }
        }
        return n.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.facet.name < $1.facet.name }.prefix(maxChips).map { $0 }
    }

    /// Reads the director and genre edges of the first films (newest first, as the catalog lists them). Stops quietly when cancelled.
    static func load(films: [MusicPersonEntry], store: any MusicGraphStoring) async -> MusicArtistFilmFacts {
        var out = MusicArtistFilmFacts()
        var names: [MusicEntityID: String] = [:]
        func name(_ id: MusicEntityID) async -> String? {
            if let n = names[id] { return n }
            guard let s = try? await store.entity(id) else { return nil }
            names[id] = s.name
            return s.name
        }
        for f in films.prefix(maxFilms) {
            if Task.isCancelled { break }
            for (predicate, isDirector) in [(MusicPredicate.directedBy, true), (MusicPredicate.hasGenre, false)] {
                let edges = ((try? await store.edges(of: f.id, predicate: predicate, direction: .outgoing, limit: 6)) ?? [])
                    .filter { !$0.tombstone && ($0.status == .verified || $0.confidence >= MusicPersonRoles.minConfidence) }
                var facets: [MusicFilmFacet] = []
                for e in edges {
                    guard let n = await name(e.object), !n.isEmpty, !facets.contains(where: { $0.id == e.object }) else { continue }
                    facets.append(MusicFilmFacet(id: e.object, name: n))
                }
                if facets.isEmpty { continue }
                if isDirector { out.directors[f.id] = facets } else { out.genres[f.id] = facets }
            }
        }
        return out
    }
}
