import Foundation

/// The graph kept in memory, with the same rules as `MusicGraphStore` (a test runs both against one script). For tests, previews and a store that
/// could not be opened. Nothing is written anywhere.
actor MusicInMemoryGraph: MusicGraphStoring {
    private struct Row {
        var seq: Int
        var snap: MusicEntitySnapshot
        var ids: [ExternalID] = []
        var aliases: [NameAlias] = []
        var mergedAt: Int = 0
    }
    private struct EdgeRec {
        var seq: Int
        var attributes: EdgeAttributes
        var order: Int?
        var level: CreditLevel
        var facts: [FactKey: MusicProvenance] = [:]
        var factOrder: [FactKey] = []
        var confidence: Float = 0
        var status: EdgeStatus = .inferred
        var tomb = false
    }
    private struct FactKey: Hashable { var source: MusicSourceID; var ref: String }
    private struct CacheKey: Hashable { var entity: MusicEntityID; var facet: String; var source: MusicSourceID }

    private var rows: [MusicEntityID: Row] = [:]
    private var edgeRecs: [MusicEdgeKey: EdgeRec] = [:]
    private var cache: [CacheKey: MusicCacheState] = [:]
    private var rev = 0
    private var seq = 0
    private let clock: @Sendable () -> Date
    private let traversalBudget: Duration

    init(traversalBudget: Duration = MusicTraversal.budget, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock; self.traversalBudget = traversalBudget
    }

    private func nextSeq() -> Int { seq += 1; return seq }

    private func live(_ id: MusicEntityID) -> MusicEntityID? {
        var cur = id
        for _ in 0..<8 {
            guard let r = rows[cur] else { return nil }
            if r.snap.state != .merged { return cur }
            guard let n = r.snap.mergedInto else { return nil }
            cur = n
        }
        return nil
    }

    private func strongOwner(_ x: ExternalID) -> MusicEntityID? {
        for (id, r) in rows where r.snap.state == .live && r.ids.contains(x) { return id }
        return nil
    }

    // MARK: entities

    func upsert(_ draft: MusicEntityDraft) async throws -> MusicUpsertResult { try await upsert([draft])[0] }

    func upsert(_ drafts: [MusicEntityDraft]) async throws -> [MusicUpsertResult] {
        let now = clock()
        rev += 1
        return drafts.map { upsertOne($0, now: now) }
    }

    private func upsertOne(_ d: MusicEntityDraft, now: Date) -> MusicUpsertResult {
        let name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var owners: [(ExternalID, MusicEntityID)] = []
        var targets: [MusicEntityID] = []
        for x in d.externalIDs where x.isStrong {
            guard let o = strongOwner(x), let l = live(o) else { continue }
            owners.append((x, l))
            if l.kind == d.kind, !targets.contains(l) { targets.append(l) }
        }
        var target = targets.first
        let conflicts = owners.filter { $0.1 != target }.map(\.0)
        var created = false
        if target == nil, rows[d.derivedID] != nil {
            if let l = live(d.derivedID) { target = l }
            else { rows[d.derivedID]!.snap.state = .live; rows[d.derivedID]!.snap.mergedInto = nil; target = d.derivedID }
        }
        if target == nil {
            let id = d.derivedID
            let snap = MusicEntitySnapshot(id: id, subkind: d.subkind, name: name, nameLatin: MusicGraphText.latin(name), lang: d.lang, year: d.year, yearEnd: d.yearEnd,
                                           country: d.country, durationMs: d.durationMs, imageRef: d.imageRef, attrs: d.attrs, provisional: d.provisional, state: .live,
                                           pinned: d.pinned, mergedInto: nil, createdAt: Date(timeIntervalSince1970: Double(Int(now.timeIntervalSince1970))),
                                           updatedAt: Date(timeIntervalSince1970: Double(Int(now.timeIntervalSince1970))))
            rows[id] = Row(seq: nextSeq(), snap: snap)
            target = id; created = true
        }
        let id = target!
        var r = rows[id]!
        if !created {
            let cur = r.snap
            let upgrade = cur.provisional && !d.provisional
            func pick<T>(_ old: T?, _ new: T?) -> T? { upgrade ? (new ?? old) : (old ?? new) }
            let newName = (upgrade || cur.name.isEmpty) && !name.isEmpty ? name : cur.name
            var attrs = cur.attrs
            for (k, v) in d.attrs where upgrade || attrs[k] == nil { attrs[k] = v }
            r.snap.subkind = pick(cur.subkind, d.subkind); r.snap.name = newName; r.snap.nameLatin = MusicGraphText.latin(newName)
            r.snap.lang = pick(cur.lang, d.lang); r.snap.year = pick(cur.year, d.year); r.snap.yearEnd = pick(cur.yearEnd, d.yearEnd)
            r.snap.country = pick(cur.country, d.country); r.snap.durationMs = pick(cur.durationMs, d.durationMs); r.snap.imageRef = pick(cur.imageRef, d.imageRef)
            r.snap.attrs = attrs; r.snap.provisional = cur.provisional && d.provisional; r.snap.pinned = cur.pinned || d.pinned
            r.snap.updatedAt = Date(timeIntervalSince1970: Double(Int(now.timeIntervalSince1970)))
        }
        let blocked = Set(conflicts)
        for x in d.externalIDs where !blocked.contains(x) && !r.ids.contains(x) { r.ids.append(x) }
        let current = r.snap.name
        for a in [NameAlias(current, lang: d.lang, isPrimary: true)] + d.aliases where !a.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if !r.aliases.contains(where: { $0.text == a.text }) { r.aliases.append(a) }
        }
        for i in r.aliases.indices { r.aliases[i].isPrimary = r.aliases[i].text == current }
        rows[id] = r
        return MusicUpsertResult(id: id, created: created, conflicts: conflicts)
    }

    func candidates(for externalID: ExternalID) async throws -> [MusicEntityID] {
        rows.filter { $0.value.snap.state == .live && $0.value.ids.contains(externalID) }.sorted { $0.value.seq < $1.value.seq }.map(\.key)
    }

    func resolveAlias(for externalID: ExternalID, kind: MusicEntityKind?) async throws -> MusicEntityID? {
        let hits = try await candidates(for: externalID).filter { kind == nil || $0.kind == kind }
        return hits.count == 1 ? hits[0] : nil
    }

    func resolve(_ id: MusicEntityID) async throws -> MusicEntityID? { live(id) }
    func entity(_ id: MusicEntityID) async throws -> MusicEntitySnapshot? { rows[id]?.snap }
    func externalIDs(of id: MusicEntityID) async throws -> [ExternalID] {
        guard let l = live(id) else { return [] }
        return rows[l]!.ids.sorted { ($0.scheme.rawValue, $0.value) < ($1.scheme.rawValue, $1.value) }
    }
    func aliases(of id: MusicEntityID) async throws -> [NameAlias] {
        guard let l = live(id) else { return [] }
        return rows[l]!.aliases.sorted { ($0.isPrimary ? 0 : 1, $0.text) < ($1.isPrimary ? 0 : 1, $1.text) }
    }
    func setPinned(_ id: MusicEntityID, _ pinned: Bool) async throws {
        guard let l = live(id) else { throw MusicGraphError.unknownEntity(id.rawValue) }
        rows[l]!.snap.pinned = pinned; rev += 1
    }

    func mergeEntities(winner: MusicEntityID, loser: MusicEntityID, byUser: Bool) async throws -> MusicEntityID {
        guard let w = live(winner) else { throw MusicGraphError.unknownEntity(winner.rawValue) }
        guard let l = live(loser) else { throw MusicGraphError.unknownEntity(loser.rawValue) }
        guard w != l else { return w }
        guard w.kind == l.kind else { throw MusicGraphError.invalidMerge("kinds differ") }
        rev += 1
        let now = clock()
        var wr = rows[w]!; let lr = rows[l]!
        for x in lr.ids where !wr.ids.contains(x) { wr.ids.append(x) }
        for i in wr.aliases.indices { wr.aliases[i].isPrimary = wr.aliases[i].text == wr.snap.name }
        for a in lr.aliases + [NameAlias(lr.snap.name, lang: lr.snap.lang)] where !wr.aliases.contains(where: { $0.text == a.text }) {
            var b = a; b.isPrimary = false; wr.aliases.append(b)
        }
        let ls = lr.snap
        wr.snap.subkind = wr.snap.subkind ?? ls.subkind; wr.snap.lang = wr.snap.lang ?? ls.lang; wr.snap.year = wr.snap.year ?? ls.year
        wr.snap.yearEnd = wr.snap.yearEnd ?? ls.yearEnd; wr.snap.country = wr.snap.country ?? ls.country
        wr.snap.durationMs = wr.snap.durationMs ?? ls.durationMs; wr.snap.imageRef = wr.snap.imageRef ?? ls.imageRef
        wr.snap.pinned = wr.snap.pinned || ls.pinned
        wr.snap.updatedAt = Date(timeIntervalSince1970: Double(Int(now.timeIntervalSince1970)))
        rows[w] = wr
        rows[l]!.snap.state = .merged; rows[l]!.snap.mergedInto = w; rows[l]!.snap.pinned = false; rows[l]!.ids = []; rows[l]!.aliases = []
        for (k, v) in rows where v.snap.state == .merged && v.snap.mergedInto == l { rows[k]!.snap.mergedInto = w }
        for (c, st) in cache where c.entity == l {
            cache[c] = nil
            let nc = CacheKey(entity: w, facet: c.facet, source: c.source)
            if cache[nc] == nil { cache[nc] = st }
        }
        // Edges: oldest first, as the store walks them.
        let moving = edgeRecs.filter { $0.key.subject == l || $0.key.object == l }.sorted { $0.value.seq < $1.value.seq }
        for (key, rec) in moving {
            edgeRecs[key] = nil
            var nk = key
            if nk.subject == l { nk.subject = w }
            if nk.object == l { nk.object = w }
            if nk.subject == nk.object { continue }
            if var d = edgeRecs[nk] {
                var attrs = rec.attributes; for (k, v) in d.attributes.values { attrs[k] = v }
                d.attributes = attrs; d.order = d.order ?? rec.order
                d.level = CreditLevel(rawValue: min(d.level.rawValue, rec.level.rawValue)) ?? d.level
                for fk in rec.factOrder { if d.facts[fk] == nil { d.factOrder.append(fk) }; d.facts[fk] = rec.facts[fk] }
                reaggregate(&d, nk.predicate, now)
                edgeRecs[nk] = d
            } else { edgeRecs[nk] = rec }
        }
        return w
    }

    // MARK: edges

    func addEdge(_ edge: MusicEdge, provenance: MusicProvenance) async throws -> MusicEdge { try await addEdges([MusicEdgeClaim(edge, provenance)])[0] }

    func addEdges(_ claims: [MusicEdgeClaim]) async throws -> [MusicEdge] {
        let now = clock()
        rev += 1
        return try claims.map { try addClaim($0.edge, $0.provenance, now) }
    }

    private func reaggregate(_ rec: inout EdgeRec, _ p: MusicPredicate, _ now: Date) {
        let agg = MusicEdgeAggregator.aggregate(predicate: p, facts: rec.factOrder.compactMap { rec.facts[$0] }, now: now)
        rec.confidence = agg.confidence; rec.status = agg.status; rec.tomb = agg.tombstone
    }

    private func addClaim(_ e: MusicEdge, _ p: MusicProvenance, _ now: Date) throws -> MusicEdge {
        guard let s = live(e.subject) else { throw MusicGraphError.unknownEntity(e.subject.rawValue) }
        guard let o = live(e.object) else { throw MusicGraphError.unknownEntity(e.object.rawValue) }
        guard s != o else { throw MusicGraphError.invalidEdge("self edge") }
        guard e.predicate.accepts(subject: e.subject.kind, object: e.object.kind) else { throw MusicGraphError.invalidEdge("kinds") }
        let key = MusicEdgeKey(subject: s, predicate: e.predicate, object: o, qualifier: e.qualifier)
        var rec = edgeRecs[key] ?? EdgeRec(seq: nextSeq(), attributes: e.attributes, order: e.order, level: e.creditLevel)
        if edgeRecs[key] != nil {
            for (k, v) in e.attributes.values { rec.attributes[k] = v }
            rec.order = e.order ?? rec.order
            rec.level = CreditLevel(rawValue: min(rec.level.rawValue, e.creditLevel.rawValue)) ?? rec.level
        }
        let fk = FactKey(source: p.source, ref: p.sourceRef ?? "")
        if rec.facts[fk] == nil { rec.factOrder.append(fk) }
        rec.facts[fk] = p
        reaggregate(&rec, e.predicate, now)
        edgeRecs[key] = rec
        return render(key, rec)
    }

    private func render(_ key: MusicEdgeKey, _ r: EdgeRec) -> MusicEdge {
        MusicEdge(subject: key.subject, predicate: key.predicate, object: key.object, qualifier: key.qualifier, attributes: r.attributes,
                  confidence: r.confidence, status: r.status, creditLevel: r.level, tombstone: r.tomb, order: r.order)
    }

    func edges(of id: MusicEntityID, predicate: MusicPredicate?, direction: MusicEdgeDirection, limit: Int) async throws -> [MusicEdge] {
        try await edges(of: id, predicate: predicate, direction: direction, limit: limit, offset: 0)
    }

    func edges(of id: MusicEntityID, predicate: MusicPredicate?, direction: MusicEdgeDirection, limit: Int, offset: Int) async throws -> [MusicEdge] {
        guard let l = live(id) else { return [] }
        let n = max(0, min(limit, 500))
        func sorted(_ list: [(MusicEdgeKey, EdgeRec)]) -> [(MusicEdgeKey, EdgeRec)] {
            list.sorted { a, b in
                if (a.1.order == nil) != (b.1.order == nil) { return b.1.order == nil }
                if a.1.order != b.1.order { return (a.1.order ?? 0) < (b.1.order ?? 0) }
                if a.1.confidence != b.1.confidence { return a.1.confidence > b.1.confidence }
                return a.1.seq < b.1.seq
            }
        }
        let wantOut = direction != .incoming, wantIn = direction != .outgoing
        let list = Array(sorted(edgeRecs.filter { (k, v) in
            ((wantOut && k.subject == l) || (wantIn && k.object == l)) && !v.tomb && (predicate == nil || k.predicate == predicate)
        }.map { ($0.key, $0.value) }).dropFirst(max(0, offset)).prefix(n))
        return list.map { render($0.0, $0.1) }
    }

    func edge(_ key: MusicEdgeKey) async throws -> MusicEdge? {
        guard let s = live(key.subject), let o = live(key.object) else { return nil }
        let k = MusicEdgeKey(subject: s, predicate: key.predicate, object: o, qualifier: key.qualifier)
        return edgeRecs[k].map { render(k, $0) }
    }

    func retractEdge(_ key: MusicEdgeKey) async throws {
        try await setFact(MusicProvenance(source: .user, retrievedAt: clock(), license: .user, score: 1, stance: .contradicts, userOverride: true), for: key)
    }

    func setFact(_ fact: MusicProvenance, for key: MusicEdgeKey) async throws {
        rev += 1
        _ = try addClaim(MusicEdge(subject: key.subject, predicate: key.predicate, object: key.object, qualifier: key.qualifier), fact, clock())
    }

    func facts(for key: MusicEdgeKey) async throws -> [MusicProvenance] {
        guard let s = live(key.subject), let o = live(key.object),
              let r = edgeRecs[MusicEdgeKey(subject: s, predicate: key.predicate, object: o, qualifier: key.qualifier)] else { return [] }
        return r.factOrder.compactMap { r.facts[$0] }
    }

    // MARK: cache state

    func cacheState(entity: MusicEntityID, facet: String, source: MusicSourceID) async throws -> MusicCacheState? {
        guard let l = live(entity) else { return nil }
        return cache[CacheKey(entity: l, facet: facet, source: source)]
    }

    func setCacheState(entity: MusicEntityID, facet: String, source: MusicSourceID, outcome: MusicCacheState.Outcome, ttl: TimeInterval, etag: String?, matcherVersion: Int?) async throws {
        guard let l = live(entity) else { throw MusicGraphError.unknownEntity(entity.rawValue) }
        let now = clock(), k = CacheKey(entity: l, facet: facet, source: source)
        rev += 1
        if outcome == .error {
            let attempts = (cache[k]?.attempts ?? 0) + 1
            var s = cache[k] ?? MusicCacheState(outcome: .error, fetchedAt: nil, expiresAt: nil, attempts: 0, nextRetryAt: nil, etag: nil, matcherVersion: nil)
            s.outcome = .error; s.attempts = attempts; s.nextRetryAt = now.addingTimeInterval(MusicCacheState.backoff(attempts: attempts))
            cache[k] = s
        } else {
            cache[k] = MusicCacheState(outcome: outcome, fetchedAt: now, expiresAt: now.addingTimeInterval(ttl), attempts: 0, nextRetryAt: nil, etag: etag, matcherVersion: matcherVersion)
        }
    }

    // MARK: search, traversal, counts

    func search(_ query: String, kinds: Set<MusicEntityKind>, limit: Int) async throws -> [MusicSearchHit] {
        let raw = MusicGraphText.tokens(query), lat = MusicGraphText.tokens(MusicGraphText.latin(query))
        guard limit > 0, !(raw.isEmpty && lat.isEmpty) else { return [] }
        func matches(_ tokens: [String], in text: String) -> Bool {
            let words = MusicGraphText.tokens(text)
            return !tokens.isEmpty && tokens.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
        }
        var hits: [MusicSearchHit] = []
        for (id, r) in rows where r.snap.state == .live && (kinds.isEmpty || kinds.contains(id.kind)) {
            let named = ([r.snap.name] + r.aliases.map(\.text)).joined(separator: " ")
            let latin = ([r.snap.nameLatin] + r.aliases.map(\.latin)).joined(separator: " ")
            guard matches(raw, in: named) || matches(lat, in: latin) else { continue }
            let m = MusicSearchRanking.score(query: query, name: r.snap.name, latin: r.snap.nameLatin, pinned: r.snap.pinned)
            hits.append(MusicSearchHit(id: id, name: r.snap.name, subkind: r.snap.subkind, year: r.snap.year, score: m.score, viaRomanised: m.viaRomanised))
        }
        return MusicSearchRanking.top(hits, limit: limit)
    }

    func neighbours(of id: MusicEntityID, depth: Int, fanOut: Int) async throws -> MusicNeighbourhood {
        let start = ContinuousClock.now
        let maxDepth = max(0, min(depth, MusicTraversal.maxDepth)), fan = max(1, min(fanOut, MusicTraversal.maxFanOut))
        guard let root = live(id) else { return MusicNeighbourhood(root: id, nodes: [], truncated: false) }
        var visited: Set<MusicEntityID> = [root]
        var frontier = [root]
        var nodes: [MusicNeighbour] = []
        var truncated = false
        search: for d in 1...max(1, maxDepth) where maxDepth > 0 {
            var next: [MusicEntityID] = []
            for parent in frontier {
                if ContinuousClock.now - start > traversalBudget { truncated = true; break search }
                let cap = fan * MusicTraversal.branchFactor
                typealias Row = (id: MusicEntityID, pred: MusicPredicate, incoming: Bool, conf: Float, status: EdgeStatus)
                func branch(_ incoming: Bool) -> [Row] {
                    var list: [Row] = []
                    for (k, v) in edgeRecs.sorted(by: { $0.value.seq < $1.value.seq }) where !v.tomb {
                        let other = incoming ? k.subject : k.object
                        guard (incoming ? k.object : k.subject) == parent, let o = rows[other], o.snap.state == .live else { continue }
                        list.append((other, k.predicate, incoming, v.confidence, v.status))
                    }
                    return Array(list.enumerated().sorted { a, b in a.element.conf != b.element.conf ? a.element.conf > b.element.conf : a.offset < b.offset }.map(\.element).prefix(cap))
                }
                var best: [MusicEntityID: Row] = [:]
                for r in branch(false) + branch(true) where best[r.id].map({ r.conf > $0.conf }) ?? true { best[r.id] = r }
                let ordered = best.values.sorted { a, b in
                    a.conf != b.conf ? a.conf > b.conf : rows[a.id]!.seq < rows[b.id]!.seq
                }
                if ordered.count > fan { truncated = true }
                for r in ordered.prefix(fan) where !visited.contains(r.id) {
                    if nodes.count >= MusicTraversal.maxNodes { truncated = true; break search }
                    visited.insert(r.id)
                    nodes.append(MusicNeighbour(id: r.id, depth: d, parent: parent, predicate: r.pred, direction: r.incoming ? .incoming : .outgoing, confidence: r.conf, status: r.status))
                    next.append(r.id)
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        if maxDepth < depth { truncated = true }
        return MusicNeighbourhood(root: root, nodes: nodes, truncated: truncated)
    }

    func counts() async throws -> MusicGraphCounts {
        var k = MusicGraphCounts()
        k.entities = rows.values.filter { $0.snap.state == .live }.count
        k.tombstones = rows.values.filter { $0.snap.state == .merged }.count
        k.edges = edgeRecs.values.filter { !$0.tomb }.count
        k.retractedEdges = edgeRecs.values.filter(\.tomb).count
        k.facts = edgeRecs.values.reduce(0) { $0 + $1.facts.count }
        k.externalIDs = rows.values.reduce(0) { $0 + $1.ids.count }
        k.aliases = rows.values.reduce(0) { $0 + $1.aliases.count }
        k.cacheStates = cache.count
        k.schemaVersion = MusicGraphMigrator.latestVersion
        k.graphRev = rev
        return k
    }

    func wipe() async throws { rows = [:]; edgeRecs = [:]; cache = [:]; rev = 0; seq = 0 }
}
