import Foundation

/// The recommendation engine (section 5): bounded traversals around a seed, candidates graded into the owner's nine priority bands, scored inside a
/// band, folded of near-duplicates, and each given one short sentence made from the real edges that put it there. Pure logic over `MusicGraphStoring`:
/// it never touches the player, the network, or the database file directly, so it works offline from whatever edges are cached.
///
/// Ordering guarantee: the sort key is (band, score). A candidate's score is `band.base` plus an in-band part below 100, and listening affinity only
/// moves the in-band part, so affinity can never lift a lower band over a higher one.
final class MusicRecommender: Sendable {
    let store: any MusicGraphStoring
    let cache: MusicRecommendationCache
    let affinityStore: MusicAffinityStore?

    init(store: any MusicGraphStoring, affinity: MusicAffinityStore? = nil, cache: MusicRecommendationCache = MusicRecommendationCache()) {
        self.store = store; self.affinityStore = affinity; self.cache = cache
    }

    /// Kinds returned when a caller names none: things a person can open.
    static let defaultKinds: Set<MusicEntityKind> = [.recording, .track, .work, .album, .release, .film, .series, .person, .group]

    // MARK: API

    /// The best `limit` related entities of the asked kinds, strongest band first. Never throws: a graph that cannot be read answers from the cache (marked
    /// `stale`) or with nothing.
    func recommend(for seed: MusicEntityID, kinds: Set<MusicEntityKind> = [], limit: Int = 20, context: MusicRecContext = MusicRecContext()) async -> MusicRecResult {
        let affinity = await resolvedAffinity(context)
        let cold = affinity.isEmpty
        let wanted = kinds.isEmpty ? Self.defaultKinds : kinds
        let n = max(1, limit)
        let key = MusicRecommendationCache.Key(seed: seed, signature: context.configSignature(affinityRevision: affinity.revision, kinds: wanted, limit: n))
        if context.useCache, var hit = await cache.fresh(key, now: context.now) { hit.fromCache = true; return hit }
        do {
            let all = try await compute(seed: seed, kinds: wanted, context: context, affinity: affinity)
            var result = MusicRecResult(seed: seed, items: Array(all.items.prefix(n)), truncated: all.truncated, visitedNodes: all.visited, coldStart: cold, fromCache: false, stale: false)
            await Self.hydrate(&result.items, store: store)
            if context.useCache { await cache.store(result, for: key, now: context.now) }
            return result
        } catch {
            if var old = await cache.stale(key) { old.fromCache = true; old.stale = true; return old }
            return .empty(seed, coldStart: cold)
        }
    }

    /// Every reason `candidate` relates to `seed`, the main one first; empty when the graph holds no real link (nothing is invented).
    func explain(_ candidate: MusicEntityID, for seed: MusicEntityID, context: MusicRecContext = MusicRecContext()) async -> [MusicRecExplanation] {
        var ctx = context
        ctx.useCache = false; ctx.includeSeedVersions = true
        let affinity = await resolvedAffinity(ctx)
        guard let all = try? await compute(seed: seed, kinds: [candidate.kind], context: ctx, affinity: affinity),
              var hit = all.items.first(where: { $0.id == candidate }) else { return [] }
        var items = [hit]
        await Self.hydrate(&items, store: store)
        hit = items[0]
        return [hit.explanation] + hit.otherReasons
    }

    func invalidate(_ id: MusicEntityID) async { await cache.invalidate(id) }

    private func resolvedAffinity(_ c: MusicRecContext) async -> MusicAffinityVector {
        if let a = c.affinity { return a }
        return await affinityStore?.vector() ?? .empty
    }

    // MARK: computation

    struct Computation { var items: [MusicRecCandidate]; var truncated: Bool; var visited: Int }

    func compute(seed requested: MusicEntityID, kinds: Set<MusicEntityKind>, context ctx: MusicRecContext, affinity: MusicAffinityVector) async throws -> Computation {
        let floor = ctx.minInferredConfidence
        let seedID = try await store.resolve(requested) ?? requested
        let nb = try await store.neighbours(of: seedID, depth: ctx.depth, fanOut: ctx.fanOut)
        var truncated = nb.truncated
        var view = MusicRecGraphView(root: seedID)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: ctx.profileBudget)

        // The seed first, then depth 1, then depth 2 (strongest links first): whatever the budget allows is read in that order.
        if let s = try await store.entity(seedID) { view.add(snapshot: s) }
        view.add(edges: try await store.edges(of: seedID, predicate: nil, direction: .both, limit: 100), of: seedID)
        let ordered = nb.nodes.sorted { $0.depth != $1.depth ? $0.depth < $1.depth : $0.confidence > $1.confidence }
        var profiled: [MusicEntityID] = []
        for n in ordered {
            if clock.now > deadline { truncated = true; break }
            if let s = try await store.entity(n.id) { view.add(snapshot: s) } else { continue }
            if !n.id.kind.isFacet {
                view.add(edges: try await store.edges(of: n.id, predicate: nil, direction: .both, limit: 60), of: n.id)
            }
            view.depth[n.id] = n.depth
            profiled.append(n.id)
        }
        // One more ring, within the same budget: the albums and films the walk's songs and albums belong to (their cast, credits and names).
        var queued: Set<MusicEntityID> = [], ring: [MusicEntityID] = []
        for id in profiled where !id.kind.isFacet {
            for e in view.out(id, [.trackOn, .soundtrackOf, .featuredIn, .editionOf]) where !view.hasLoadedEdges(e.object) && ring.count < ctx.maxRing && queued.insert(e.object).inserted { ring.append(e.object) }
        }
        for id in ring {
            if clock.now > deadline { truncated = true; break }
            if let s = try await store.entity(id) { view.add(snapshot: s) } else { continue }
            view.add(edges: try await store.edges(of: id, predicate: nil, direction: .both, limit: 60), of: id)
        }
        guard view.snapshot(seedID) != nil else { return Computation(items: [], truncated: truncated, visited: nb.nodes.count) }

        let params = MusicRecParams(floor: floor, now: ctx.now, affinity: affinity, includeBroad: ctx.includeBroad,
                                    preferredLanguages: Set(ctx.preferredLanguages.map(MusicRecLanguage.key)))
        let seedInfo = MusicRecSeed(id: seedID, view: view, floor: floor)
        let seedKeys = MusicRecDedup.clusterKeys(id: seedID, snapshot: view.snapshot(seedID), facets: seedInfo.facets, view: view)
        var entries: [MusicRecDedup.Entry] = []
        for id in profiled where id != seedID && kinds.contains(id.kind) && !ctx.exclude.contains(id) {
            guard let snap = view.snapshot(id), snap.state == .live else { continue }
            let facets = MusicRecFacetBuilder.build(id, view: view, floor: floor)
            let signals = MusicRecSignals.evaluate(seed: seedInfo, candidate: id, facets: facets, view: view, params: params)
            guard let best = signals.first else { continue }
            let boost = MusicRecSignals.affinityBoost(facets, id: id, params: params)
            let stale = ctx.now.timeIntervalSince(snap.updatedAt) > 2 * ctx.freshnessTTL
            var inBand = 60 * best.strength * Double(max(best.confidence, 0.05)) * (stale ? 0.8 : 1) + 40 * boost
            if ctx.recentlyShown.contains(id) { inBand -= 25 }
            inBand = min(MusicRecBand.inBandCeiling, max(0, inBand))
            var seen: Set<MusicRecReason> = [best.explanation.reason]
            var others: [MusicRecExplanation] = []
            for s in signals.dropFirst() where seen.insert(s.explanation.reason).inserted && others.count < 2 { others.append(s.explanation) }
            var flags: Set<MusicRecFlag> = []
            if best.explanation.tentative { flags.insert(.inferredLink) }
            let c = MusicRecCandidate(id: id, snapshot: snap, band: best.band, score: best.band.base + inBand, explanation: best.explanation, otherReasons: others,
                                      confidence: best.confidence, affinityBoost: boost, versionCount: 1, flags: flags, artist: facets.primaryPerformer)
            entries.append(.init(candidate: c, keys: MusicRecDedup.clusterKeys(id: id, snapshot: snap, facets: facets, view: view),
                                 languages: Set(facets.languages.filter { !$0.hasPrefix("id:") })))
        }
        var items = MusicRecDedup.dedupe(entries, seedKeys: seedKeys, preferred: params.preferredLanguages, keepSeedVersions: ctx.includeSeedVersions)
        items = MusicRecDedup.flagRemakes(items, seed: view.snapshot(seedID))
        items.sort { a, b in
            if a.band != b.band { return a.band < b.band }
            if a.score != b.score { return a.score > b.score }
            if a.snapshot.name != b.snapshot.name { return a.snapshot.name < b.snapshot.name }
            return a.id < b.id
        }
        return Computation(items: items, truncated: truncated, visited: profiled.count)
    }

    /// Fills the names of explanation subjects the walk did not read; a subject whose name cannot be found is dropped (the plain wording is used).
    static func hydrate(_ items: inout [MusicRecCandidate], store: any MusicGraphStoring) async {
        var names: [MusicEntityID: String] = [:]
        func fix(_ e: MusicRecExplanation) async -> MusicRecExplanation {
            var out = e
            var subs: [MusicRecSubject] = []
            for s in e.subjects {
                if !s.name.isEmpty { subs.append(s); continue }
                guard let id = s.id else { continue }
                if names[id] == nil { names[id] = (try? await store.entity(id))?.name ?? "" }
                if let n = names[id], !n.isEmpty { subs.append(MusicRecSubject(id: id, name: n)) }
            }
            out.subjects = subs
            return out
        }
        for i in items.indices {
            items[i].explanation = await fix(items[i].explanation)
            var rest: [MusicRecExplanation] = []
            for r in items[i].otherReasons { rest.append(await fix(r)) }
            items[i].otherReasons = rest
        }
    }
}
