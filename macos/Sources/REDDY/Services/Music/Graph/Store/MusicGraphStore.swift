import Foundation

/// The graph database: an actor that owns one SQLite file, `<directory>/graph.sqlite` (WAL, created on first use, excluded from backup).
/// One writer (every write is one transaction and one `graph_rev` step) and a pool of read connections (reads hop off the actor).
/// A corrupt file is renamed to `graph.sqlite.bad` and a fresh one is made; a file from a newer build opens read-only.
actor MusicGraphStore: MusicGraphStoring {
    nonisolated let directory: URL
    nonisolated var databaseURL: URL { directory.appendingPathComponent("graph.sqlite") }
    private let limits: MusicGraphLimits
    private let clock: @Sendable () -> Date
    private let traversalBudget: Duration
    private var db: DatabaseManager?
    private(set) var isReadOnly = false
    /// How many times a corrupt file was set aside.
    private(set) var recoveries = 0

    init(directory: URL, limits: MusicGraphLimits = .standard, traversalBudget: Duration = MusicTraversal.budget, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.limits = limits
        self.clock = clock
        self.traversalBudget = traversalBudget
    }

    // MARK: open, recover

    private func manager() throws -> DatabaseManager {
        if let db { return db }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)
        do { return try openChecked() }
        catch let e as DatabaseError where Self.isCorruption(e) { try quarantine(); return try openChecked() }
    }

    private func openChecked() throws -> DatabaseManager {
        let m = try DatabaseManager.music(at: databaseURL)
        let verdict = try integrityVerdict()
        if verdict != "ok" { throw DatabaseError(message: "quick_check: \(verdict)", code: 11) }
        isReadOnly = try m.read { try MusicGraphMigrator.version($0) } > MusicGraphMigrator.latestVersion
        if !isReadOnly {
            let t = clock()
            let done = try m.read { try $0.queryOne("SELECT v FROM meta WHERE k = 'provider_canon_v1'") { $0.string(0) } }
            if done == nil {
                try m.write { c in
                    try MusicGraphWrites.canonicalizeProviderIDs(c, now: t)
                    try c.execute("INSERT OR REPLACE INTO meta(k, v) VALUES('provider_canon_v1', '1')")
                    try MusicGraphWrites.bumpRev(c)
                }
            }
        }
        db = m
        return m
    }

    /// `PRAGMA quick_check` on a connection of its own. A long-lived pooled reader can answer "checksum mismatch" for the full-text table after
    /// another connection wrote to it, so the check never runs there.
    private func integrityVerdict() throws -> String {
        let c = try Connection(path: databaseURL.path, readOnly: true)
        try c.exec("PRAGMA busy_timeout=5000")
        return try c.queryOne("PRAGMA quick_check(1)") { $0.string(0) } ?? "ok"
    }

    /// Sets the damaged file aside as `graph.sqlite.bad` (replacing an older one) and forgets the connection; the next open starts a new graph.
    private func quarantine() throws {
        db = nil
        let fm = FileManager.default
        let bad = directory.appendingPathComponent("graph.sqlite.bad")
        try? fm.removeItem(at: bad)
        if fm.fileExists(atPath: databaseURL.path) { try fm.moveItem(at: databaseURL, to: bad) }
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: databaseURL.path + suffix) }
        recoveries += 1
        isReadOnly = false
    }

    private static func isCorruption(_ e: DatabaseError) -> Bool { [11, 26].contains(e.code & 0xFF) }

    private static func excludeFromBackup(_ folder: URL) {
        var url = folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Checks the file now; on damage sets it aside and starts empty. True when the file was healthy.
    @discardableResult
    func verifyOrRebuild() async throws -> Bool {
        _ = try manager()
        let ok = try integrityVerdict() == "ok"
        if !ok { try quarantine(); _ = try manager() }
        return ok
    }

    // MARK: transaction helpers

    private func write<T>(_ unpinnedData: Bool = true, _ body: (Connection) throws -> T) throws -> T {
        let m = try manager()
        if isReadOnly { throw MusicGraphError.readOnly }
        do {
            if unpinnedData, try m.read({ try MusicGraphReads.usedBytes($0) }) > limits.hardStopBytes { throw MusicGraphError.full }
            return try m.write { c in
                let r = try body(c)
                try MusicGraphWrites.bumpRev(c)
                return r
            }
        } catch let e as DatabaseError where Self.isCorruption(e) {
            try? quarantine()
            throw e
        }
    }

    private func readPool() throws -> DatabaseManager { try manager() }

    private static func read<T: Sendable>(_ m: DatabaseManager, _ body: @Sendable (Connection) throws -> T) async throws -> T {
        try m.read(body)
    }

    // MARK: entities

    func upsert(_ draft: MusicEntityDraft) async throws -> MusicUpsertResult { try await upsert([draft])[0] }

    func upsert(_ drafts: [MusicEntityDraft]) async throws -> [MusicUpsertResult] {
        let now = clock()
        return try write { c in try drafts.map { try MusicGraphWrites.upsert(c, $0, now: now) } }
    }

    func resolveAlias(for externalID: ExternalID, kind: MusicEntityKind?) async throws -> MusicEntityID? {
        let hits = try await candidates(for: externalID).filter { kind == nil || $0.kind == kind }
        return hits.count == 1 ? hits[0] : nil
    }

    func candidates(for externalID: ExternalID) async throws -> [MusicEntityID] {
        let m = try readPool()
        return try await Self.read(m) { try MusicGraphReads.candidates($0, externalID) }
    }

    func resolve(_ id: MusicEntityID) async throws -> MusicEntityID? {
        let m = try readPool()
        return try await Self.read(m) { c in try MusicGraphReads.liveRID(c, id).flatMap { try MusicGraphReads.entityID(c, rid: $0) } }
    }

    func entity(_ id: MusicEntityID) async throws -> MusicEntitySnapshot? {
        let m = try readPool()
        let snap = try await Self.read(m) { try MusicGraphReads.snapshot($0, id: id) }
        // A person row whose "name" is a wiki template word or markup is not shown by any page.
        if let snap, !MusicPersonNameGuard.isShowable(kind: snap.kind, name: snap.name) { return nil }
        return snap
    }

    func externalIDs(of id: MusicEntityID) async throws -> [ExternalID] {
        let m = try readPool()
        return try await Self.read(m) { c in try MusicGraphReads.liveRID(c, id).map { try MusicGraphReads.externalIDs(c, rid: $0) } ?? [] }
    }

    func aliases(of id: MusicEntityID) async throws -> [NameAlias] {
        let m = try readPool()
        return try await Self.read(m) { c in try MusicGraphReads.liveRID(c, id).map { try MusicGraphReads.aliases(c, rid: $0) } ?? [] }
    }

    func setPinned(_ id: MusicEntityID, _ pinned: Bool) async throws {
        let now = clock()
        try write(false) { try MusicGraphWrites.setPinned($0, id, pinned, now: now) }
    }

    /// Marks entities as just used so eviction keeps them (batched by the caller).
    func touch(_ ids: [MusicEntityID]) async throws {
        let t = MusicGraphWrites.secs(clock())
        try write(false) { c in for id in ids { try c.execute("UPDATE entity SET accessed_at = ? WHERE id = ?", [t, id.rawValue]) } }
    }

    func mergeEntities(winner: MusicEntityID, loser: MusicEntityID, byUser: Bool) async throws -> MusicEntityID {
        let now = clock()
        return try write(false) { try MusicGraphWrites.merge($0, winner: winner, loser: loser, byUser: byUser, now: now) }
    }

    // MARK: edges

    func addEdge(_ edge: MusicEdge, provenance: MusicProvenance) async throws -> MusicEdge {
        try await addEdges([MusicEdgeClaim(edge, provenance)])[0]
    }

    func addEdges(_ claims: [MusicEdgeClaim]) async throws -> [MusicEdge] {
        let now = clock()
        return try write { c in try claims.map { try MusicGraphWrites.addClaim(c, edge: $0.edge, provenance: $0.provenance, now: now) } }
    }

    func edges(of id: MusicEntityID, predicate: MusicPredicate?, direction: MusicEdgeDirection, limit: Int) async throws -> [MusicEdge] {
        let m = try readPool()
        return try await Self.read(m) { c in
            guard let rid = try MusicGraphReads.liveRID(c, id) else { return [] }
            return try MusicGraphReads.edges(c, rid: rid, predicate: predicate, direction: direction, limit: limit)
        }
    }

    /// The next page of a long list of edges (one read returns at most 500). The order is fixed (display order, confidence, then the edge's own id), so pages never overlap.
    func edges(of id: MusicEntityID, predicate: MusicPredicate?, direction: MusicEdgeDirection, limit: Int, offset: Int) async throws -> [MusicEdge] {
        let m = try readPool()
        return try await Self.read(m) { c in
            guard let rid = try MusicGraphReads.liveRID(c, id) else { return [] }
            return try MusicGraphReads.edges(c, rid: rid, predicate: predicate, direction: direction, limit: limit, offset: offset)
        }
    }

    func edge(_ key: MusicEdgeKey) async throws -> MusicEdge? {
        let m = try readPool()
        return try await Self.read(m) { try MusicGraphReads.edge($0, key) }
    }

    func retractEdge(_ key: MusicEdgeKey) async throws {
        let p = MusicProvenance(source: .user, retrievedAt: clock(), license: .user, score: 1, stance: .contradicts, userOverride: true)
        try await setFact(p, for: key)
    }

    func setFact(_ fact: MusicProvenance, for key: MusicEdgeKey) async throws {
        let now = clock()
        try write { c in try MusicGraphWrites.addClaim(c, edge: MusicEdge(subject: key.subject, predicate: key.predicate, object: key.object, qualifier: key.qualifier), provenance: fact, now: now) }
    }

    func facts(for key: MusicEdgeKey) async throws -> [MusicProvenance] {
        let m = try readPool()
        return try await Self.read(m) { c in try MusicGraphReads.edgeRID(c, key).map { try MusicGraphReads.facts(c, edgeRID: $0) } ?? [] }
    }

    // MARK: cache state

    func cacheState(entity: MusicEntityID, facet: String, source: MusicSourceID) async throws -> MusicCacheState? {
        let m = try readPool()
        return try await Self.read(m) { c in try MusicGraphReads.liveRID(c, entity).flatMap { try MusicGraphReads.cacheState(c, rid: $0, facet: facet, source: source) } }
    }

    func setCacheState(entity: MusicEntityID, facet: String, source: MusicSourceID, outcome: MusicCacheState.Outcome, ttl: TimeInterval, etag: String?, matcherVersion: Int?) async throws {
        let now = clock()
        try write(false) { try MusicGraphWrites.setCacheState($0, entity: entity, facet: facet, source: source, outcome: outcome, ttl: ttl, etag: etag, matcherVersion: matcherVersion, now: now) }
    }

    // MARK: search, traversal, counts

    func search(_ query: String, kinds: Set<MusicEntityKind>, limit: Int) async throws -> [MusicSearchHit] {
        let m = try readPool()
        let hits = try await Self.read(m) { try MusicGraphReads.search($0, query: query, kinds: kinds, limit: limit) }
        return hits.filter { MusicPersonNameGuard.isShowable(kind: $0.id.kind, name: $0.name) }
    }

    func neighbours(of id: MusicEntityID, depth: Int, fanOut: Int) async throws -> MusicNeighbourhood {
        let m = try readPool(), budget = traversalBudget
        return try await Self.read(m) { try MusicGraphReads.neighbours($0, root: id, depth: depth, fanOut: fanOut, budget: budget) }
    }

    func counts() async throws -> MusicGraphCounts {
        let m = try readPool()
        return try await Self.read(m) { try MusicGraphReads.counts($0) }
    }

    func graphRev() async throws -> Int {
        let m = try readPool()
        return try await Self.read(m) { try MusicGraphReads.graphRev($0) }
    }

    // MARK: maintenance

    /// Idle-time eviction (pinned entities stay), then frees file space.
    @discardableResult
    func evict() async throws -> MusicEvictionReport {
        let now = clock(), lim = limits
        let m = try manager()
        if isReadOnly { throw MusicGraphError.readOnly }
        let rep = try m.write { try MusicGraphEviction.run($0, limits: lim, now: now) }
        if rep.total > 0 { try m.maintenance { MusicGraphEviction.compact($0) } }
        return rep
    }

    /// "Clear metadata cache": everything except user decisions, affinity and library-pinned entities.
    func clearCache() async throws {
        try write(false) { c in
            try c.exec("""
                DELETE FROM fact; DELETE FROM cache_state; DELETE FROM work_item; DELETE FROM rec_cache; DELETE FROM source_health;
                DELETE FROM edge;
                DELETE FROM entity_fts WHERE rowid IN (SELECT rid FROM entity WHERE pinned = 0);
                DELETE FROM entity WHERE pinned = 0 AND rid NOT IN (SELECT entity FROM affinity);
                DELETE FROM entity WHERE state = 1;
                """)
        }
    }

    /// Releases every connection (the file stays). The next call opens it again.
    func close() { db = nil }

    /// Deletes the database, its WAL and shm files and the folder; the next call opens a new empty graph. Safe when nothing was ever opened.
    func wipe() async throws { wipeFiles() }

    /// Same as `wipe()` but synchronous, for the app's "delete everything".
    func wipeFiles() {
        db = nil
        isReadOnly = false
        try? FileManager.default.removeItem(at: directory)
    }

    /// Test and tooling hook: raw access to the writer in one transaction (bulk fixtures). Not part of the protocol.
    func withWriter<T>(_ body: (Connection) throws -> T) throws -> T { try write(false, body) }
    func withReader<T: Sendable>(_ body: @Sendable (Connection) throws -> T) throws -> T { try manager().read(body) }
}
