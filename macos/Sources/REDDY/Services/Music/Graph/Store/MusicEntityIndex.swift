import Foundation

/// The lazy side index (section 2.6): provider uids (`providerID:id`) of the saved JSON libraries to stable entity ids, on demand. The library files
/// are not rewritten and keep their format; the index only adds rows to the graph. Minting is local, no network, one small transaction.
actor MusicEntityIndex {
    private let store: any MusicGraphStoring
    private let capacity: Int
    private var memory: [String: MusicEntityID] = [:]

    init(store: any MusicGraphStoring, capacity: Int = 4_096) { self.store = store; self.capacity = max(16, capacity) }

    /// The id a provider item gets, with no database read: for routes and history entries built on the main actor.
    nonisolated static func provisionalID(kind: MusicEntityKind, providerUID: String) -> MusicEntityID { .provisional(kind: kind, providerUID: providerUID) }

    private func key(_ kind: MusicEntityKind, _ x: ExternalID) -> String { kind.slug + "|" + x.description }

    private func remember(_ k: String, _ id: MusicEntityID) {
        if memory.count >= capacity { memory.removeAll(keepingCapacity: true) }
        memory[k] = id
    }

    /// The entity for a provider uid if the graph has one (memory, then the alias table). Never mints.
    func lookup(providerUID: String, kind: MusicEntityKind) async throws -> MusicEntityID? {
        let x = ExternalID(.provider, providerUID), k = key(kind, x)
        if let hit = memory[k] { return hit }
        guard let id = try await store.resolveAlias(for: x, kind: kind) else { return nil }
        remember(k, id)
        return id
    }

    /// The id of a draft's entity: memory, else the alias table, else mint it. A draft with no external id is looked up by its name-derived id.
    func entityID(for draft: MusicEntityDraft) async throws -> MusicEntityID {
        let first = draft.externalIDs.first(where: \.isStrong)
        if let first {
            let k = key(draft.kind, first)
            if let hit = memory[k] { return hit }
            if let id = try await store.resolveAlias(for: first, kind: draft.kind) { remember(k, id); return id }
        }
        let id = try await store.upsert(draft).id
        if let first { remember(key(draft.kind, first), id) }
        return id
    }

    /// Mints an entity with its provider-confidence links (credits, album placement) in two transactions. Returns the primary id.
    @discardableResult
    func mint(_ plan: MusicMintPlan) async throws -> MusicEntityID {
        let results = try await store.upsert([plan.primary] + plan.links.map(\.draft))
        let primary = results[0].id
        if let first = plan.primary.externalIDs.first(where: \.isStrong) { remember(key(plan.primary.kind, first), primary) }
        var claims: [MusicEdgeClaim] = []
        for (i, link) in plan.links.enumerated() {
            let other = results[i + 1].id
            guard other != primary else { continue }
            let (s, o) = link.direction == .incoming ? (other, primary) : (primary, other)
            guard link.predicate.accepts(subject: s.kind, object: o.kind) else { continue }
            let edge = MusicEdge(subject: s, predicate: link.predicate, object: o, qualifier: link.role?.rawValue ?? "", attributes: link.attributes,
                                 creditLevel: link.creditLevel, order: link.order)
            claims.append(MusicEdgeClaim(edge, MusicProvenance(source: plan.source, retrievedAt: plan.retrievedAt, expiresAt: plan.expiresAt, license: plan.license,
                                                               score: link.score ?? plan.defaultScore, evidence: link.evidence)))
        }
        if !claims.isEmpty { _ = try await store.addEdges(claims) }
        return primary
    }

    /// Idle backfill of saved items in chunks (liked first, then followed artists, saved albums, playlists, newest history). Every entity is pinned so
    /// eviction keeps it. Runs on the store's executors, never the main thread; yields between chunks. Returns how many drafts were processed.
    @discardableResult
    func backfill(_ drafts: [MusicEntityDraft], chunkSize: Int = 300, progress: (@Sendable (Int) -> Void)? = nil) async throws -> Int {
        var done = 0
        let step = max(1, chunkSize)
        var i = 0
        while i < drafts.count {
            try Task.checkCancellation()
            var chunk = Array(drafts[i..<min(drafts.count, i + step)])
            for j in chunk.indices { chunk[j].pinned = true }
            let results = try await store.upsert(chunk)
            for (d, r) in zip(chunk, results) { if let f = d.externalIDs.first(where: \.isStrong) { remember(key(d.kind, f), r.id) } }
            done += chunk.count; i += step
            progress?(done)
            await Task.yield()
        }
        return done
    }

    func forgetAll() { memory.removeAll() }
}
