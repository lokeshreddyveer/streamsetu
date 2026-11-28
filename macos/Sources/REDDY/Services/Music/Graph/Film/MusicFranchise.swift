import Foundation

/// A franchise a source says films belong to, with those films in release order. The link is stored once, film to franchise, so the same list is found from
/// any of its films.
struct MusicFranchise: Equatable, Sendable {
    struct Film: Equatable, Sendable, Identifiable { var id: MusicEntityID; var name: String; var year: Int?; var current: Bool }
    var id: MusicEntityID
    var name: String
    var films: [Film]

    /// True for the series entity Wikidata writes for a franchise (`subkind "franchise"`): it groups films and is not a page of its own.
    static func isFranchise(_ subkind: String?) -> Bool { subkind == "franchise" }

    /// The franchise of `film`, if a source named one, with every film of it the graph holds. Nil when there is none or it holds only this film.
    static func load(for film: MusicEntityID, store: any MusicGraphStoring) async -> MusicFranchise? {
        guard let out = try? await store.edges(of: film, predicate: .inFranchise, direction: .outgoing, limit: 4) else { return nil }
        // Two sources can each write a franchise for the same film (one keyed by the collection, one by the Wikidata item): every link is read and the franchise that
        // holds the most films is the one shown, so a one-film entity never hides the one that lists the sequels.
        var best: MusicFranchise?
        for link in out where !link.tombstone {
            guard let fr = try? await store.entity(link.object) else { continue }
            let incoming = (try? await store.edges(of: link.object, predicate: .inFranchise, direction: .incoming, limit: 60)) ?? []
            var films: [Film] = []
            var seen = Set<MusicEntityID>()
            for e in incoming where !e.tombstone && seen.insert(e.subject).inserted {
                // A film that was removed or merged away (its state is not live) is not listed.
                if let s = try? await store.entity(e.subject), s.state == .live { films.append(Film(id: s.id, name: s.name, year: s.year, current: s.id == film)) }
            }
            guard films.count > 1 else { continue }
            films.sort { ($0.year ?? Int.max) != ($1.year ?? Int.max) ? ($0.year ?? Int.max) < ($1.year ?? Int.max) : $0.name < $1.name }
            if films.count > (best?.films.count ?? 0) { best = MusicFranchise(id: fr.id, name: fr.name, films: films) }
        }
        return best
    }
}
