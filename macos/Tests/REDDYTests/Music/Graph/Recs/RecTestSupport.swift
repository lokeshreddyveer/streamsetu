import Foundation
import Testing
@testable import REDDY

/// A small hand-built graph over the in-memory store, for the recommender and credits tests.
final class RecWorld: @unchecked Sendable {
    let g: MusicInMemoryGraph
    private var n = 0
    init() { g = MusicInMemoryGraph() }

    func ent(_ kind: MusicEntityKind, _ name: String, lang: String? = nil, year: Int? = nil, uid: String? = nil, img: String? = nil,
             attrs: [String: String] = [:], country: String? = nil) async -> MusicEntityID {
        n += 1
        var d = MusicEntityDraft(kind: kind, name: name, lang: lang, year: year, country: country, imageRef: img, attrs: attrs,
                                 externalIDs: [ExternalID(.provider, uid ?? "fx:\(n):\(name)")])
        d.provisional = false
        return try! await g.upsert(d).id
    }

    static let verifiedClaim = MusicProvenance(source: .musicbrainz, score: 0.95, evidence: [MusicProvenance.statedToken])
    static let inferredClaim = MusicProvenance(source: MusicSourceID("jiosaavn"), score: 0.6)

    @discardableResult
    func link(_ s: MusicEntityID, _ p: MusicPredicate, _ o: MusicEntityID, role: MusicRole? = nil, order: Int? = nil, verified: Bool = true,
              level: CreditLevel = .song, attrs: EdgeAttributes = [:]) async -> MusicEdge {
        let e = MusicEdge(subject: s, predicate: p, object: o, qualifier: role?.rawValue ?? "", attributes: attrs, creditLevel: level, order: order)
        return try! await g.addEdge(e, provenance: verified ? Self.verifiedClaim : Self.inferredClaim)
    }

    /// A song with its people, album and film.
    @discardableResult
    func song(_ title: String, year: Int, lang: String, album: MusicEntityID? = nil, order: Int = 0, film: MusicEntityID? = nil,
              md: MusicEntityID? = nil, lyricist: MusicEntityID? = nil, singers: [MusicEntityID] = [], composer: MusicEntityID? = nil,
              img: String? = nil, attrs: [String: String] = [:]) async -> MusicEntityID {
        let r = await ent(.recording, title, lang: lang, year: year, img: img, attrs: attrs)
        if let album { await link(r, .trackOn, album, order: order) }
        if let film { await link(r, .featuredIn, film) }
        if let md { await link(r, .musicDirectedBy, md, role: .musicDirector) }
        if let composer { await link(r, .composedBy, composer, role: .composer) }
        if let lyricist { await link(r, .writtenBy, lyricist, role: .lyricist) }
        for (i, s) in singers.enumerated() { await link(r, .performedBy, s, role: .singer, order: i) }
        return r
    }
}

/// Wraps a store, counts the calls the recommender makes, and can be switched "down" to throw (a graph outage).
final class CountingStore: MusicGraphStoring, @unchecked Sendable {
    let base: any MusicGraphStoring
    private let lock = NSLock()
    private var _edges = 0, _entity = 0, _neighbours = 0, _down = false
    private var _lastDepth = 0, _lastFan = 0
    init(_ base: any MusicGraphStoring) { self.base = base }
    var edgeCalls: Int { lock.withLock { _edges } }
    var entityCalls: Int { lock.withLock { _entity } }
    var neighbourCalls: Int { lock.withLock { _neighbours } }
    var lastDepth: Int { lock.withLock { _lastDepth } }
    var lastFan: Int { lock.withLock { _lastFan } }
    var down: Bool { get { lock.withLock { _down } } set { lock.withLock { _down = newValue } } }
    func resetCounts() { lock.withLock { _edges = 0; _entity = 0; _neighbours = 0 } }
    private func gate() throws { if down { throw MusicGraphError.readOnly } }

    func upsert(_ draft: MusicEntityDraft) async throws -> MusicUpsertResult { try await base.upsert(draft) }
    func upsert(_ drafts: [MusicEntityDraft]) async throws -> [MusicUpsertResult] { try await base.upsert(drafts) }
    func resolveAlias(for externalID: ExternalID, kind: MusicEntityKind?) async throws -> MusicEntityID? { try await base.resolveAlias(for: externalID, kind: kind) }
    func candidates(for externalID: ExternalID) async throws -> [MusicEntityID] { try await base.candidates(for: externalID) }
    func resolve(_ id: MusicEntityID) async throws -> MusicEntityID? { try gate(); return try await base.resolve(id) }
    func entity(_ id: MusicEntityID) async throws -> MusicEntitySnapshot? { try gate(); lock.withLock { _entity += 1 }; return try await base.entity(id) }
    func externalIDs(of id: MusicEntityID) async throws -> [ExternalID] { try await base.externalIDs(of: id) }
    func aliases(of id: MusicEntityID) async throws -> [NameAlias] { try await base.aliases(of: id) }
    func setPinned(_ id: MusicEntityID, _ pinned: Bool) async throws { try await base.setPinned(id, pinned) }
    func mergeEntities(winner: MusicEntityID, loser: MusicEntityID, byUser: Bool) async throws -> MusicEntityID { try await base.mergeEntities(winner: winner, loser: loser, byUser: byUser) }
    func addEdge(_ edge: MusicEdge, provenance: MusicProvenance) async throws -> MusicEdge { try await base.addEdge(edge, provenance: provenance) }
    func addEdges(_ claims: [MusicEdgeClaim]) async throws -> [MusicEdge] { try await base.addEdges(claims) }
    func edges(of id: MusicEntityID, predicate: MusicPredicate?, direction: MusicEdgeDirection, limit: Int) async throws -> [MusicEdge] {
        try gate(); lock.withLock { _edges += 1 }
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
    func neighbours(of id: MusicEntityID, depth: Int, fanOut: Int) async throws -> MusicNeighbourhood {
        try gate(); lock.withLock { _neighbours += 1; _lastDepth = depth; _lastFan = fanOut }
        return try await base.neighbours(of: id, depth: depth, fanOut: fanOut)
    }
    func counts() async throws -> MusicGraphCounts { try await base.counts() }
    func wipe() async throws { try await base.wipe() }
}

/// Collects the partial reports of a section loader.
final class PartialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _results: [MusicSectionResult] = []
    var results: [MusicSectionResult] { lock.withLock { _results } }
    var reporter: MusicSectionReporter { MusicSectionReporter { [self] r in lock.withLock { _results.append(r) } } }
}
