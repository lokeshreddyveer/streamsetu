import Foundation

// The completeness pass for filled screens: tiles that lack a picture or works are handed to the same enrichment the pages use. This file only DECIDES
// what to ask for (pure, bounded, once per session per entity) and writes the starter roster into the graph as provisional entities; the actual
// fetching is done by whatever is installed behind `MusicCompletenessRequesting`:
//   - person works and filmography: the person-completeness writer's fetch (`MusicEntityEnriching.enrichPerson`, widened by its full filmography pass);
//   - pictures: the artwork writer's batch pass (`MusicEntityEnriching.enrichAlbum / enrichFilm / enrichPerson` set `imageRef`).
// Until those are installed the default asks the entity store's enricher, which is what a page does when it opens an entity.

protocol MusicCompletenessRequesting: Sendable {
    /// Asks for the entity to be completed (credits, works, picture). Returns the entities that changed.
    func complete(_ id: MusicEntityID) async -> Set<MusicEntityID>
}

/// The default: the app's `MusicEntityEnriching`.
struct MusicEnricherCompleteness: MusicCompletenessRequesting {
    let enricher: any MusicEntityEnriching
    func complete(_ id: MusicEntityID) async -> Set<MusicEntityID> {
        (try? await enricher.enrich(id))?.changed ?? []
    }
}

enum MusicCompletenessPlanner {
    /// How many entities one screen may ask for at a time, and in a session.
    static let perScreen = 12
    static let perSession = 160

    /// Which of `wanted` to ask for now: not asked before, people and films before albums, at most `perScreen`, never over the session budget.
    static func plan(_ wanted: [MusicEntityID], asked: Set<MusicEntityID>, sessionCount: Int, perScreen: Int = perScreen, perSession: Int = perSession) -> [MusicEntityID] {
        let room = max(0, min(perScreen, perSession - sessionCount))
        guard room > 0 else { return [] }
        func priority(_ k: MusicEntityKind) -> Int {
            switch k { case .person, .group: 0; case .film, .series: 1; case .album, .release: 2; case .recording, .track, .work: 3; default: 9 }
        }
        var seen = Set<MusicEntityID>()
        let fresh = wanted.filter { !asked.contains($0) && priority($0.kind) < 9 && seen.insert($0).inserted }
        return Array(fresh.enumerated().sorted { a, b in
            let pa = priority(a.element.kind), pb = priority(b.element.kind)
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element).prefix(room))
    }
}
