import Foundation

enum MusicGraphError: Error, Equatable, Sendable {
    case unknownEntity(String)
    case invalidEdge(String)
    case invalidMerge(String)
    /// The file was written by a newer build: reads work, writes are off.
    case readOnly
    /// The unpinned-data hard cap was reached; eviction must run first.
    case full
}

/// Bounds of the graph (section 2.4) and of one traversal (section 5.4).
struct MusicGraphLimits: Sendable {
    var targetBytes = 150 * 1024 * 1024
    var hardStopBytes = 250 * 1024 * 1024
    var maxEdges = 400_000
    var evictionBatch = 2_000
    var staleAfter: TimeInterval = 90 * 86_400
    var tombstoneAge: TimeInterval = 365 * 86_400
    static let standard = MusicGraphLimits()
}

enum MusicTraversal {
    static let maxDepth = 2
    static let maxFanOut = 40
    static let maxNodes = 400
    /// Edges read per node and direction before neighbours are folded together: a multiple of the fan-out.
    static let branchFactor = 4
    static let budget: Duration = .milliseconds(40)
}

struct MusicSearchHit: Hashable, Sendable {
    var id: MusicEntityID
    var name: String
    var subkind: String?
    var year: Int?
    var score: Float
    /// True when the match came from the romanised skeleton rather than the original spelling.
    var viaRomanised: Bool
}

struct MusicNeighbour: Hashable, Sendable {
    var id: MusicEntityID
    var depth: Int
    var parent: MusicEntityID
    var predicate: MusicPredicate
    /// From the parent's side: `.outgoing` means parent to this node.
    var direction: MusicEdgeDirection
    var confidence: Float
    var status: EdgeStatus
}

struct MusicNeighbourhood: Sendable {
    var root: MusicEntityID
    var nodes: [MusicNeighbour]
    /// A bound (depth, fan-out, node count or the time budget) cut the walk short.
    var truncated: Bool
}

struct MusicGraphCounts: Sendable, Equatable {
    var entities = 0, tombstones = 0, edges = 0, retractedEdges = 0, facts = 0, externalIDs = 0, aliases = 0, cacheStates = 0
    var bytes = 0
    var schemaVersion = 0
    var graphRev = 0
}

/// What the store knows about having fetched one facet (credits, cast, tracklist...) of an entity from one source.
struct MusicCacheState: Hashable, Sendable {
    enum Outcome: Int, Sendable { case ok = 0, empty, error }
    var outcome: Outcome
    var fetchedAt: Date?
    var expiresAt: Date?
    var attempts: Int
    var nextRetryAt: Date?
    var etag: String?
    var matcherVersion: Int?

    /// Fresh: fetched, not expired, and not an error. An empty result counts (it is a remembered negative) until its own, shorter, expiry.
    func isFresh(at now: Date) -> Bool { outcome != .error && (expiresAt.map { $0 > now } ?? false) }
    /// A fetch is due: never fresh, and past any retry back-off.
    func needsFetch(at now: Date) -> Bool { !isFresh(at: now) && (nextRetryAt.map { $0 <= now } ?? true) }

    /// Back-off after the n-th failure: 1 minute doubling to a 6 hour cap.
    static func backoff(attempts: Int) -> TimeInterval { min(21_600, 60 * pow(2, Double(max(0, attempts - 1)))) }
}

/// What other packages call. The SQLite store and the in-memory store behave the same (a test checks it).
protocol MusicGraphStoring: Sendable {
    /// Creates or enriches one entity. A strong external id found on an existing entity picks that entity; else the derived id; else a new row.
    func upsert(_ draft: MusicEntityDraft) async throws -> MusicUpsertResult
    /// Many in one transaction, in order.
    func upsert(_ drafts: [MusicEntityDraft]) async throws -> [MusicUpsertResult]
    /// The live entity that owns this id (a strong id is unique; a weak one answers only when exactly one entity has it).
    func resolveAlias(for externalID: ExternalID, kind: MusicEntityKind?) async throws -> MusicEntityID?
    /// Every live entity carrying this id (weak ids can have several).
    func candidates(for externalID: ExternalID) async throws -> [MusicEntityID]
    /// Follows tombstone redirects to the live entity; nil when the id is unknown.
    func resolve(_ id: MusicEntityID) async throws -> MusicEntityID?
    func entity(_ id: MusicEntityID) async throws -> MusicEntitySnapshot?
    func externalIDs(of id: MusicEntityID) async throws -> [ExternalID]
    func aliases(of id: MusicEntityID) async throws -> [NameAlias]
    /// Marks an entity as referenced by the library (or not). Pinned entities are never evicted.
    func setPinned(_ id: MusicEntityID, _ pinned: Bool) async throws

    /// Merges `loser` into `winner`: ids and aliases move, edges are repointed (duplicates folded, facts summed), the loser becomes a redirect.
    func mergeEntities(winner: MusicEntityID, loser: MusicEntityID, byUser: Bool) async throws -> MusicEntityID

    /// Adds a claim; creates the edge when new. Returns the edge with its aggregate confidence and status.
    func addEdge(_ edge: MusicEdge, provenance: MusicProvenance) async throws -> MusicEdge
    func addEdges(_ claims: [MusicEdgeClaim]) async throws -> [MusicEdge]
    /// `limit` is capped at 500. Retracted edges are left out. Ordered by display order, then confidence.
    func edges(of id: MusicEntityID, predicate: MusicPredicate?, direction: MusicEdgeDirection, limit: Int) async throws -> [MusicEdge]
    /// The page after the first `offset` edges of the same ordered list. A store that cannot page answers the first page only (the default) and nothing after it.
    func edges(of id: MusicEntityID, predicate: MusicPredicate?, direction: MusicEdgeDirection, limit: Int, offset: Int) async throws -> [MusicEdge]
    func edge(_ key: MusicEdgeKey) async throws -> MusicEdge?
    /// The person says this edge is wrong: a user claim that contradicts it (it stays as a tombstone so it is not inferred again).
    func retractEdge(_ key: MusicEdgeKey) async throws

    /// Adds or replaces one source's claim for an edge (same source and source reference replace each other) and re-aggregates.
    func setFact(_ fact: MusicProvenance, for key: MusicEdgeKey) async throws
    func facts(for key: MusicEdgeKey) async throws -> [MusicProvenance]

    func cacheState(entity: MusicEntityID, facet: String, source: MusicSourceID) async throws -> MusicCacheState?
    /// Records a fetch. ok and empty set `expiresAt = now + ttl` and clear failures; error counts an attempt and sets a retry back-off.
    func setCacheState(entity: MusicEntityID, facet: String, source: MusicSourceID, outcome: MusicCacheState.Outcome, ttl: TimeInterval,
                       etag: String?, matcherVersion: Int?) async throws

    /// Prefix search over original-script and romanised names.
    func search(_ query: String, kinds: Set<MusicEntityKind>, limit: Int) async throws -> [MusicSearchHit]
    /// Bounded walk in both directions: depth up to 2, 40 edges per node, 400 nodes, 40 ms.
    func neighbours(of id: MusicEntityID, depth: Int, fanOut: Int) async throws -> MusicNeighbourhood
    func counts() async throws -> MusicGraphCounts
    /// Deletes everything.
    func wipe() async throws
}

extension MusicGraphStoring {
    func edges(of id: MusicEntityID, predicate: MusicPredicate?, direction: MusicEdgeDirection, limit: Int, offset: Int) async throws -> [MusicEdge] {
        offset == 0 ? try await edges(of: id, predicate: predicate, direction: direction, limit: limit) : []
    }
    func upsertEntity(_ draft: MusicEntityDraft) async throws -> MusicEntityID { try await upsert(draft).id }
    func resolveAlias(for externalID: ExternalID) async throws -> MusicEntityID? { try await resolveAlias(for: externalID, kind: nil) }
    func edges(of id: MusicEntityID) async throws -> [MusicEdge] { try await edges(of: id, predicate: nil, direction: .outgoing, limit: 100) }
    func edges(of id: MusicEntityID, predicate: MusicPredicate) async throws -> [MusicEdge] { try await edges(of: id, predicate: predicate, direction: .outgoing, limit: 100) }
    func edges(of id: MusicEntityID, predicate: MusicPredicate, direction: MusicEdgeDirection) async throws -> [MusicEdge] {
        try await edges(of: id, predicate: predicate, direction: direction, limit: 100)
    }
    func search(_ query: String) async throws -> [MusicSearchHit] { try await search(query, kinds: [], limit: 20) }
    func search(_ query: String, kinds: Set<MusicEntityKind>) async throws -> [MusicSearchHit] { try await search(query, kinds: kinds, limit: 20) }
    func search(_ query: String, limit: Int) async throws -> [MusicSearchHit] { try await search(query, kinds: [], limit: limit) }
    func neighbours(of id: MusicEntityID) async throws -> MusicNeighbourhood { try await neighbours(of: id, depth: 2, fanOut: MusicTraversal.maxFanOut) }
    func setCacheState(entity: MusicEntityID, facet: String, source: MusicSourceID, outcome: MusicCacheState.Outcome, ttl: TimeInterval) async throws {
        try await setCacheState(entity: entity, facet: facet, source: source, outcome: outcome, ttl: ttl, etag: nil, matcherVersion: nil)
    }
}
