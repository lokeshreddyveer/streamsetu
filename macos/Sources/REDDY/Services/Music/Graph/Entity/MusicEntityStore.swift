import Foundation
import Observation

/// What an open-by-id found.
enum MusicEntityLoad: Sendable, Equatable {
    /// The live entity (`id` can differ from the one asked for after a merge).
    case found(MusicEntitySnapshot)
    /// The graph has no such entity and nothing could fetch it: the page shows a not-found state with Back.
    case missing
}

/// The graph changed for these entities (enrichment landed, a merge happened). `merged` maps a retired id to the survivor.
struct MusicEntityChange: Sendable, Equatable {
    var ids: Set<MusicEntityID>
    var merged: [MusicEntityID: MusicEntityID] = [:]
}

/// The UI-facing facade over the graph store (section 4.3): a bounded memory cache, open-by-id with provisional ids resolving to the live entity after a
/// merge, single-flight enrichment, and a change stream so open pages refresh when new data lands. Everything here is read-mostly and never touches
/// the player.
@MainActor @Observable
final class MusicEntityStore {
    let graph: any MusicGraphStoring
    /// G2/G3/G5-G8 install the real enrichers here; the default does nothing.
    @ObservationIgnored var enricher: any MusicEntityEnriching
    /// Fetches an entity the graph does not hold yet (a provisional id from a provider uid), if the app wired one. Nil: the entity is `missing`.
    @ObservationIgnored var fetchMissing: (@Sendable (MusicEntityID) async -> MusicEntitySnapshot?)?
    /// Counts graph changes announced; observing it re-evaluates views that depend on the store.
    private(set) var revision = 0

    @ObservationIgnored let capacity: Int
    @ObservationIgnored private var cache: [MusicEntityID: MusicEntitySnapshot] = [:]
    @ObservationIgnored private var order: [MusicEntityID] = []
    @ObservationIgnored private var redirects: [MusicEntityID: MusicEntityID] = [:]
    @ObservationIgnored private var loading: [MusicEntityID: Task<MusicEntityLoad, Never>] = [:]
    @ObservationIgnored private var enriching: [MusicEntityID: Task<Void, Never>] = [:]
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<MusicEntityChange>.Continuation] = [:]
    /// How many graph reads open-by-id made (tests check that a hot entity costs none).
    @ObservationIgnored private(set) var graphReads = 0
    @ObservationIgnored private(set) var enrichmentRuns = 0

    init(graph: any MusicGraphStoring, enricher: any MusicEntityEnriching = MusicNoopEntityEnricher(), capacity: Int = 512) {
        self.graph = graph; self.enricher = enricher; self.capacity = max(8, capacity)
    }

    // MARK: memory

    /// The id the graph knows this entity by now (follows merges seen so far; memory only).
    func canonical(_ id: MusicEntityID) -> MusicEntityID {
        var cur = id, hops = 0
        while let next = redirects[cur], next != cur, hops < 8 { cur = next; hops += 1 }
        return cur
    }

    /// The entity if it is in memory. Never reads the database.
    func snapshot(_ id: MusicEntityID) -> MusicEntitySnapshot? { cache[canonical(id)] }

    private func remember(_ s: MusicEntitySnapshot) {
        order.removeAll { $0 == s.id }
        order.append(s.id)
        cache[s.id] = s
        while order.count > capacity { cache[order.removeFirst()] = nil }
    }

    private func forget(_ id: MusicEntityID) { cache[id] = nil; order.removeAll { $0 == id } }

    var cachedCount: Int { cache.count }

    // MARK: open by id

    /// Memory, then the graph (following tombstone redirects), then the fetch hook for a provisional id. Calls for one id share one read.
    func load(_ id: MusicEntityID) async -> MusicEntityLoad {
        let wanted = canonical(id)
        if let hit = cache[wanted], !hit.provisional || fetchMissing == nil { return .found(hit) }
        if let running = loading[wanted] { return await running.value }
        let graph = self.graph, fetch = fetchMissing
        graphReads += 1
        let task = Task<MusicEntityLoad, Never> { [wanted] in
            var live = wanted
            if let resolved = try? await graph.resolve(wanted) { live = resolved }
            if let s = try? await graph.entity(live) { return .found(s) }
            if let fetch, let s = await fetch(wanted) { return .found(s) }
            return .missing
        }
        loading[wanted] = task
        let result = await task.value
        loading[wanted] = nil
        if case .found(let s) = result {
            if s.id != wanted { redirects[wanted] = s.id }
            if s.id != id { redirects[id] = s.id }
            remember(s)
        }
        return result
    }

    // MARK: enrichment

    /// Runs the enrichers for an entity once at a time; the result is announced as a change. Errors are swallowed (the page keeps what it has).
    @discardableResult
    func enrich(_ id: MusicEntityID) -> Task<Void, Never> {
        let wanted = canonical(id)
        if let running = enriching[wanted] { return running }
        enrichmentRuns += 1
        let enricher = self.enricher
        let task = Task { [weak self] in
            let result = try? await enricher.enrich(wanted)
            guard !Task.isCancelled else { await self?.finishEnrichment(wanted, nil); return }
            await self?.finishEnrichment(wanted, result)
        }
        enriching[wanted] = task
        return task
    }

    private func finishEnrichment(_ id: MusicEntityID, _ r: MusicEnrichmentResult?) {
        enriching[id] = nil
        if let r, !r.changed.isEmpty { notifyChanged(r.changed) }
    }

    // MARK: changes

    /// Writers (G2 resolver, G3 ingest, enrichers) call this after their batch commits: one call per batch. Cached rows are dropped so the next
    /// read sees the new data; `merged` records a survivor for each retired id so a saved provisional route finds the live entity.
    func notifyChanged(_ ids: Set<MusicEntityID>, merged: [MusicEntityID: MusicEntityID] = [:]) {
        for (loser, winner) in merged where loser != winner { redirects[loser] = winner; forget(loser) }
        for id in ids { forget(id) }
        revision += 1
        let change = MusicEntityChange(ids: ids.union(merged.keys).union(merged.values), merged: merged)
        for c in subscribers.values { c.yield(change) }
    }

    /// A stream of changes; ends when the consumer stops iterating.
    func changes() -> AsyncStream<MusicEntityChange> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<MusicEntityChange>.makeStream(bufferingPolicy: .bufferingNewest(64))
        subscribers[key] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers[key] = nil } }
        return stream
    }


    /// The privacy wipe: forget everything held in memory.
    func reset() {
        cache = [:]; order = []; redirects = [:]
        for t in enriching.values { t.cancel() }
        enriching = [:]
    }
}
