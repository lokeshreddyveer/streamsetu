import Foundation

/// Read side of the graph: pure functions over one connection, run on the reader pool (or inside a write transaction). No actor, no state.
enum MusicGraphReads {
    // MARK: ids and rows

    static func rid(_ c: Connection, _ id: MusicEntityID) throws -> Int? {
        try c.queryOne("SELECT rid FROM entity WHERE id = ?", [id.rawValue]) { $0.int(0) }
    }

    /// The live row an id leads to, following redirects (at most 8 hops). Nil for an unknown id or a redirect whose target was evicted.
    static func liveRID(_ c: Connection, _ id: MusicEntityID) throws -> Int? {
        guard let r = try rid(c, id) else { return nil }
        return try liveRID(c, rid: r)
    }

    static func liveRID(_ c: Connection, rid start: Int) throws -> Int? {
        var cur = start
        for _ in 0..<8 {
            guard let row = try c.queryOne("SELECT state, merged_into FROM entity WHERE rid = ?", [cur], { (state: $0.int(0), into: $0.optInt(1)) }) else { return nil }
            if row.state != MusicEntityState.merged.rawValue { return cur }
            guard let next = row.into else { return nil }
            cur = next
        }
        return nil
    }

    static func entityID(_ c: Connection, rid: Int) throws -> MusicEntityID? {
        try c.queryOne("SELECT id FROM entity WHERE rid = ?", [rid]) { MusicEntityID(rawValue: $0.string(0)) } ?? nil
    }

    static let snapshotColumns = "e.id, e.subkind, e.name, e.name_latin, e.lang, e.year, e.year_end, e.country, e.duration_ms, e.image_ref, e.attrs, e.provisional, e.state, e.pinned, e.created_at, e.updated_at, m.id"
    static let snapshotFrom = "FROM entity e LEFT JOIN entity m ON m.rid = e.merged_into"

    static func snapshot(_ r: Row) -> MusicEntitySnapshot? {
        guard let id = MusicEntityID(rawValue: r.string(0)) else { return nil }
        return MusicEntitySnapshot(
            id: id, subkind: r.optString(1), name: r.string(2), nameLatin: r.string(3), lang: r.optString(4), year: r.optInt(5), yearEnd: r.optInt(6),
            country: r.optString(7), durationMs: r.optInt(8), imageRef: r.optString(9), attrs: decodeAttrs(r.optString(10)),
            provisional: r.bool(11), state: MusicEntityState(rawValue: r.int(12)) ?? .live, pinned: r.bool(13),
            mergedInto: r.optString(16).flatMap(MusicEntityID.init(rawValue:)),
            createdAt: Date(timeIntervalSince1970: Double(r.int(14))), updatedAt: Date(timeIntervalSince1970: Double(r.int(15))))
    }

    static func snapshot(_ c: Connection, rid: Int) throws -> MusicEntitySnapshot? {
        try c.queryOne("SELECT \(snapshotColumns) \(snapshotFrom) WHERE e.rid = ?", [rid], snapshot) ?? nil
    }

    static func snapshot(_ c: Connection, id: MusicEntityID) throws -> MusicEntitySnapshot? {
        try c.queryOne("SELECT \(snapshotColumns) \(snapshotFrom) WHERE e.id = ?", [id.rawValue], snapshot) ?? nil
    }

    static func decodeAttrs(_ s: String?) -> [String: String] {
        guard let s, !s.isEmpty, let d = try? JSONDecoder().decode([String: String].self, from: Data(s.utf8)) else { return [:] }
        return d
    }
    static func encodeAttrs(_ a: [String: String]) -> String? {
        guard !a.isEmpty, let d = try? JSONEncoder().encode(a) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    static func externalIDs(_ c: Connection, rid: Int) throws -> [ExternalID] {
        try c.query("SELECT scheme, value FROM external_id WHERE entity = ? ORDER BY scheme, value", [rid]) { r in
            ExternalID.Scheme(rawValue: r.string(0)).map { ExternalID(scheme: $0, value: r.string(1)) }
        }.compactMap { $0 }
    }

    static func aliases(_ c: Connection, rid: Int) throws -> [NameAlias] {
        try c.query("SELECT text, lang, script, primary_name, source FROM name_alias WHERE entity = ? ORDER BY primary_name DESC, text", [rid]) {
            NameAlias($0.string(0), lang: $0.optString(1), script: $0.optString(2), isPrimary: $0.bool(3), source: $0.optString(4))
        }
    }

    static func candidates(_ c: Connection, _ x: ExternalID) throws -> [MusicEntityID] {
        let rows = try c.query("SELECT e.id, e.rid FROM external_id x JOIN entity e ON e.rid = x.entity WHERE x.scheme = ? AND x.value = ? AND e.state = 0 ORDER BY e.rid",
                               [x.scheme.rawValue, x.value]) { (id: $0.string(0), rid: $0.int(1)) }
        return rows.compactMap { MusicEntityID(rawValue: $0.id) }
    }

    // MARK: edges and facts

    static let edgeSelect = """
        SELECT ed.rid, s.id, ed.predicate, o.id, ed.qual, ed.attrs, ed.ord, ed.confidence, ed.status, ed.credit_level, ed.tomb
        FROM edge ed JOIN entity s ON s.rid = ed.subject JOIN entity o ON o.rid = ed.object
        """

    static func edge(_ r: Row) -> MusicEdge? {
        guard let s = MusicEntityID(rawValue: r.string(1)), let o = MusicEntityID(rawValue: r.string(3)), let p = MusicPredicate(rawValue: r.int(2)) else { return nil }
        return MusicEdge(subject: s, predicate: p, object: o, qualifier: r.string(4), attributes: EdgeAttributes(decodeAttrs(r.optString(5))),
                         confidence: Float(r.double(7)), status: EdgeStatus(rawValue: UInt8(r.int(8))) ?? .inferred,
                         creditLevel: CreditLevel(rawValue: UInt8(r.int(9))) ?? .unknown, tombstone: r.bool(10), order: r.optInt(6))
    }

    static let edgeOrder = "ORDER BY (ed.ord IS NULL), ed.ord, ed.confidence DESC, ed.rid"

    static func edges(_ c: Connection, rid: Int, predicate: MusicPredicate?, direction: MusicEdgeDirection, limit: Int, offset: Int = 0, includeRetracted: Bool = false) throws -> [MusicEdge] {
        let n = max(0, min(limit, 500))
        guard n > 0 else { return [] }
        let tomb = includeRetracted ? "" : " AND ed.tomb = 0"
        let pred = predicate.map { " AND ed.predicate = \($0.rawValue)" } ?? ""
        let side: String
        var args: [(any SQLConvertible)?] = [rid]
        switch direction {
        case .outgoing: side = "ed.subject = ?"
        case .incoming: side = "ed.object = ?"
        case .both: side = "(ed.subject = ? OR ed.object = ?)"; args.append(rid)
        }
        return try c.query("\(edgeSelect) WHERE \(side)\(tomb)\(pred) \(edgeOrder) LIMIT \(n) OFFSET \(max(0, offset))", args, edge).compactMap { $0 }
    }

    static func edgeRID(_ c: Connection, _ key: MusicEdgeKey) throws -> Int? {
        guard let s = try liveRID(c, key.subject), let o = try liveRID(c, key.object) else { return nil }
        return try c.queryOne("SELECT rid FROM edge WHERE subject = ? AND predicate = ? AND object = ? AND qual = ?", [s, key.predicate.rawValue, o, key.qualifier]) { $0.int(0) }
    }

    static func edge(_ c: Connection, _ key: MusicEdgeKey) throws -> MusicEdge? {
        guard let r = try edgeRID(c, key) else { return nil }
        return try c.queryOne("\(edgeSelect) WHERE ed.rid = ?", [r], edge) ?? nil
    }

    static func facts(_ c: Connection, edgeRID: Int) throws -> [MusicProvenance] {
        try c.query("SELECT source, source_ref, retrieved_at, expires_at, license, score, matcher_version, evidence, stance, override FROM fact WHERE edge = ? ORDER BY rid", [edgeRID]) { r in
            MusicProvenance(source: MusicSourceID(r.string(0)), sourceRef: r.string(1).isEmpty ? nil : r.string(1), retrievedAt: r.date(2), expiresAt: r.optDate(3),
                            license: SourceLicense(rawValue: r.int(4)) ?? .providerCache, score: r.optDouble(5).map { Float($0) }, matcherVersion: r.optInt(6),
                            evidence: r.optString(7).map { $0.split(separator: ",").map(String.init) } ?? [],
                            stance: Stance(rawValue: r.int(8)) ?? .asserts, userOverride: r.bool(9))
        }
    }

    // MARK: cache state

    static func cacheState(_ c: Connection, rid: Int, facet: String, source: MusicSourceID) throws -> MusicCacheState? {
        try c.queryOne("SELECT outcome, fetched_at, expires_at, attempts, next_retry_at, etag, matcher_version FROM cache_state WHERE entity = ? AND facet = ? AND source = ?",
                       [rid, facet, source.rawValue]) {
            MusicCacheState(outcome: .init(rawValue: $0.int(0)) ?? .error, fetchedAt: $0.optDate(1), expiresAt: $0.optDate(2), attempts: $0.int(3),
                            nextRetryAt: $0.optDate(4), etag: $0.optString(5), matcherVersion: $0.optInt(6))
        }
    }

    // MARK: search

    static func search(_ c: Connection, query: String, kinds: Set<MusicEntityKind>, limit: Int) throws -> [MusicSearchHit] {
        guard let expr = MusicGraphText.ftsExpression(query), limit > 0 else { return [] }
        let kindClause = kinds.isEmpty ? "" : " AND e.kind IN (\(kinds.map { String($0.rawValue) }.sorted().joined(separator: ",")))"
        let pool = max(50, limit * 5)
        let rows = try c.query("""
            SELECT e.id, e.name, e.name_latin, e.subkind, e.year, e.pinned
            FROM entity_fts f JOIN entity e ON e.rid = f.rowid
            WHERE entity_fts MATCH ? AND e.state = 0\(kindClause)
            ORDER BY bm25(entity_fts) LIMIT \(pool)
            """, [expr]) { (id: $0.string(0), name: $0.string(1), latin: $0.string(2), sub: $0.optString(3), year: $0.optInt(4), pinned: $0.bool(5)) }
        let hits: [MusicSearchHit] = rows.compactMap { r in
            guard let id = MusicEntityID(rawValue: r.id) else { return nil }
            let m = MusicSearchRanking.score(query: query, name: r.name, latin: r.latin, pinned: r.pinned)
            return MusicSearchHit(id: id, name: r.name, subkind: r.sub, year: r.year, score: m.score, viaRomanised: m.viaRomanised)
        }
        return MusicSearchRanking.top(hits, limit: limit)
    }

    // MARK: neighbours

    static func neighbours(_ c: Connection, root: MusicEntityID, depth: Int, fanOut: Int, budget: Duration) throws -> MusicNeighbourhood {
        let start = ContinuousClock.now
        let maxDepth = max(0, min(depth, MusicTraversal.maxDepth)), fan = max(1, min(fanOut, MusicTraversal.maxFanOut))
        guard let rootRID = try liveRID(c, root), let rootID = try entityID(c, rid: rootRID) else { return MusicNeighbourhood(root: root, nodes: [], truncated: false) }
        var visited: Set<Int> = [rootRID]
        var frontier: [(rid: Int, id: MusicEntityID)] = [(rootRID, rootID)]
        var nodes: [MusicNeighbour] = []
        var truncated = false
        search: for d in 1...max(1, maxDepth) where maxDepth > 0 {
            var next: [(rid: Int, id: MusicEntityID)] = []
            for (rid, id) in frontier {
                if ContinuousClock.now - start > budget { truncated = true; break search }
                let cap = fan * MusicTraversal.branchFactor
                // The best edge per neighbour (a person who sang and composed one song is one neighbour), strongest first.
                let rows = try c.query("""
                    SELECT incoming, rid, id, pred, MAX(conf), status FROM (
                      SELECT * FROM (SELECT 0 AS incoming, o.rid AS rid, o.id AS id, ed.predicate AS pred, ed.confidence AS conf, ed.status AS status
                        FROM edge ed JOIN entity o ON o.rid = ed.object WHERE ed.subject = ? AND ed.tomb = 0 AND o.state = 0 ORDER BY ed.confidence DESC LIMIT \(cap))
                      UNION ALL
                      SELECT * FROM (SELECT 1, s.rid, s.id, ed.predicate, ed.confidence, ed.status
                        FROM edge ed JOIN entity s ON s.rid = ed.subject WHERE ed.object = ? AND ed.tomb = 0 AND s.state = 0 ORDER BY ed.confidence DESC LIMIT \(cap))
                    ) GROUP BY rid ORDER BY 5 DESC, rid LIMIT \(fan + 1)
                    """, [rid, rid]) { (incoming: $0.int(0) == 1, rid: $0.int(1), id: $0.string(2), pred: $0.int(3), conf: $0.double(4), status: $0.int(5)) }
                if rows.count > fan { truncated = true }
                for r in rows.prefix(fan) where !visited.contains(r.rid) {
                    guard let nid = MusicEntityID(rawValue: r.id), let p = MusicPredicate(rawValue: r.pred) else { continue }
                    if nodes.count >= MusicTraversal.maxNodes { truncated = true; break search }
                    visited.insert(r.rid)
                    nodes.append(MusicNeighbour(id: nid, depth: d, parent: id, predicate: p, direction: r.incoming ? .incoming : .outgoing,
                                                confidence: Float(r.conf), status: EdgeStatus(rawValue: UInt8(r.status)) ?? .inferred))
                    next.append((r.rid, nid))
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        if maxDepth < depth { truncated = true }
        return MusicNeighbourhood(root: rootID, nodes: nodes, truncated: truncated)
    }

    // MARK: counts

    static func counts(_ c: Connection) throws -> MusicGraphCounts {
        var k = MusicGraphCounts()
        k.entities = try c.scalarInt("SELECT count(*) FROM entity WHERE state = 0")
        k.tombstones = try c.scalarInt("SELECT count(*) FROM entity WHERE state = 1")
        k.edges = try c.scalarInt("SELECT count(*) FROM edge WHERE tomb = 0")
        k.retractedEdges = try c.scalarInt("SELECT count(*) FROM edge WHERE tomb = 1")
        k.facts = try c.scalarInt("SELECT count(*) FROM fact")
        k.externalIDs = try c.scalarInt("SELECT count(*) FROM external_id")
        k.aliases = try c.scalarInt("SELECT count(*) FROM name_alias")
        k.cacheStates = try c.scalarInt("SELECT count(*) FROM cache_state")
        k.bytes = try usedBytes(c)
        k.schemaVersion = try MusicGraphMigrator.version(c)
        k.graphRev = try graphRev(c)
        return k
    }

    static func usedBytes(_ c: Connection) throws -> Int {
        let pageSize = try c.scalarInt("PRAGMA page_size")
        return (try c.scalarInt("PRAGMA page_count") - c.scalarInt("PRAGMA freelist_count")) * pageSize
    }

    static func graphRev(_ c: Connection) throws -> Int {
        try c.queryOne("SELECT v FROM meta WHERE k='graph_rev'") { Int($0.string(0)) ?? 0 } ?? 0
    }
}

/// Ranking shared by the SQLite and in-memory stores so both order results the same way.
enum MusicSearchRanking {
    struct Match { var score: Float; var viaRomanised: Bool }

    static func score(query: String, name: String, latin: String, pinned: Bool) -> Match {
        let q = MusicGraphText.fold(query), ql = MusicGraphText.latin(query)
        let n = MusicGraphText.fold(name)
        var s: Float = 0.2; var roman = false
        if n == q { s = 3 }
        else if n.hasPrefix(q) { s = 2 }
        else if n.contains(q) { s = 1.5 }
        else if !ql.isEmpty, latin == ql || latin.hasPrefix(ql) { s = latin == ql ? 2.5 : 1.8; roman = true }
        else if !ql.isEmpty, latin.contains(ql) { s = 1.2; roman = true }
        if pinned { s += 0.1 }
        return Match(score: s, viaRomanised: roman)
    }

    /// Best score first; ties by shorter name, then id (stable).
    static func top(_ hits: [MusicSearchHit], limit: Int) -> [MusicSearchHit] {
        Array(hits.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.id < b.id
        }.prefix(limit))
    }
}
