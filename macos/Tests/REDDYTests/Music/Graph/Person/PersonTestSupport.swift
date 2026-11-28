import Foundation
@testable import REDDY

/// A store that fails some reads, to model a half-working database or a metadata outage that left only part of the data cached.
struct FlakyGraph: MusicGraphStoring {
    let base: MusicInMemoryGraph
    var failIncoming: Set<MusicPredicate> = []
    var failEntities: Set<MusicEntityID> = []
    struct Boom: Error {}

    func upsert(_ draft: MusicEntityDraft) async throws -> MusicUpsertResult { try await base.upsert(draft) }
    func upsert(_ drafts: [MusicEntityDraft]) async throws -> [MusicUpsertResult] { try await base.upsert(drafts) }
    func resolveAlias(for externalID: ExternalID, kind: MusicEntityKind?) async throws -> MusicEntityID? { try await base.resolveAlias(for: externalID, kind: kind) }
    func candidates(for externalID: ExternalID) async throws -> [MusicEntityID] { try await base.candidates(for: externalID) }
    func resolve(_ id: MusicEntityID) async throws -> MusicEntityID? { try await base.resolve(id) }
    func entity(_ id: MusicEntityID) async throws -> MusicEntitySnapshot? {
        if failEntities.contains(id) { throw Boom() }
        return try await base.entity(id)
    }
    func externalIDs(of id: MusicEntityID) async throws -> [ExternalID] { try await base.externalIDs(of: id) }
    func aliases(of id: MusicEntityID) async throws -> [NameAlias] { try await base.aliases(of: id) }
    func setPinned(_ id: MusicEntityID, _ pinned: Bool) async throws { try await base.setPinned(id, pinned) }
    func mergeEntities(winner: MusicEntityID, loser: MusicEntityID, byUser: Bool) async throws -> MusicEntityID { try await base.mergeEntities(winner: winner, loser: loser, byUser: byUser) }
    func addEdge(_ edge: MusicEdge, provenance: MusicProvenance) async throws -> MusicEdge { try await base.addEdge(edge, provenance: provenance) }
    func addEdges(_ claims: [MusicEdgeClaim]) async throws -> [MusicEdge] { try await base.addEdges(claims) }
    func edges(of id: MusicEntityID, predicate: MusicPredicate?, direction: MusicEdgeDirection, limit: Int) async throws -> [MusicEdge] {
        if let p = predicate, direction == .incoming, failIncoming.contains(p) { throw Boom() }
        return try await base.edges(of: id, predicate: predicate, direction: direction, limit: limit)
    }
    func edge(_ key: MusicEdgeKey) async throws -> MusicEdge? { try await base.edge(key) }
    func retractEdge(_ key: MusicEdgeKey) async throws { try await base.retractEdge(key) }
    func setFact(_ fact: MusicProvenance, for key: MusicEdgeKey) async throws { try await base.setFact(fact, for: key) }
    func facts(for key: MusicEdgeKey) async throws -> [MusicProvenance] { try await base.facts(for: key) }
    func cacheState(entity: MusicEntityID, facet: String, source: MusicSourceID) async throws -> MusicCacheState? { try await base.cacheState(entity: entity, facet: facet, source: source) }
    func setCacheState(entity: MusicEntityID, facet: String, source: MusicSourceID, outcome: MusicCacheState.Outcome, ttl: TimeInterval, etag: String?, matcherVersion: Int?) async throws {
        try await base.setCacheState(entity: entity, facet: facet, source: source, outcome: outcome, ttl: ttl, etag: etag, matcherVersion: matcherVersion)
    }
    func search(_ query: String, kinds: Set<MusicEntityKind>, limit: Int) async throws -> [MusicSearchHit] { try await base.search(query, kinds: kinds, limit: limit) }
    func neighbours(of id: MusicEntityID, depth: Int, fanOut: Int) async throws -> MusicNeighbourhood { try await base.neighbours(of: id, depth: depth, fanOut: fanOut) }
    func counts() async throws -> MusicGraphCounts { try await base.counts() }
    func wipe() async throws { try await base.wipe() }
}
