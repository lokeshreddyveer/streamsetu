import Foundation

/// Write side of the graph: pure functions over the writer connection, always called inside one transaction by the store.
enum MusicGraphWrites {
    static func secs(_ d: Date) -> Int { Int(d.timeIntervalSince1970) }

    // MARK: entities

    static func upsert(_ c: Connection, _ d: MusicEntityDraft, now: Date) throws -> MusicUpsertResult {
        let t = secs(now)
        let name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Strong ids already on a live entity of this kind pick the entity; ones owned by something else are conflicts.
        var owners: [(id: ExternalID, rid: Int)] = []
        var conflicts: [ExternalID] = []
        var targets: [Int] = []
        for x in d.externalIDs where x.isStrong {
            guard let owner = try c.queryOne("SELECT entity FROM external_id WHERE scheme = ? AND value = ? AND strong = 1 AND conflict = 0", [x.scheme.rawValue, x.value], { $0.int(0) }),
                  let live = try MusicGraphReads.liveRID(c, rid: owner) else { continue }
            owners.append((x, live))
            let kind = try c.queryOne("SELECT kind FROM entity WHERE rid = ?", [live]) { $0.int(0) }
            if kind == Int(d.kind.rawValue), !targets.contains(live) { targets.append(live) }
        }
        var target: Int? = targets.first
        for o in owners where o.rid != target { conflicts.append(o.id) }

        // 2. Else the derived id (a redirect leads to the survivor), else a new row.
        var created = false
        if target == nil, let existing = try MusicGraphReads.rid(c, d.derivedID) {
            if let live = try MusicGraphReads.liveRID(c, rid: existing) { target = live }
            else { try c.execute("UPDATE entity SET state = 0, merged_into = NULL WHERE rid = ?", [existing]); target = existing }
        }
        if target == nil {
            try c.execute("""
                INSERT INTO entity(id, kind, subkind, name, name_latin, lang, year, year_end, country, duration_ms, image_ref, attrs, provisional, state, pinned, created_at, updated_at, accessed_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
                """, [d.derivedID.rawValue, Int(d.kind.rawValue), d.subkind, name, MusicGraphText.latin(name), d.lang, d.year, d.yearEnd, d.country, d.durationMs,
                      d.imageRef, MusicGraphReads.encodeAttrs(d.attrs), d.provisional, d.pinned, t, t, t])
            target = Int(c.lastInsertRowID)
            created = true
        }
        let rid = target!

        // 3. Enrich: fill what is missing; a provisional row takes a real draft's values over its own.
        var nameChanged = created
        if !created, let cur = try MusicGraphReads.snapshot(c, rid: rid) {
            let upgrade = cur.provisional && !d.provisional
            func pick<T>(_ old: T?, _ new: T?) -> T? { upgrade ? (new ?? old) : (old ?? new) }
            let newName = (upgrade || cur.name.isEmpty) && !name.isEmpty ? name : cur.name
            nameChanged = newName != cur.name
            var attrs = cur.attrs
            for (k, v) in d.attrs where upgrade || attrs[k] == nil { attrs[k] = v }
            try c.execute("""
                UPDATE entity SET subkind = ?, name = ?, name_latin = ?, lang = ?, year = ?, year_end = ?, country = ?, duration_ms = ?, image_ref = ?, attrs = ?,
                  provisional = ?, pinned = ?, updated_at = ? WHERE rid = ?
                """, [pick(cur.subkind, d.subkind), newName, MusicGraphText.latin(newName), pick(cur.lang, d.lang), pick(cur.year, d.year), pick(cur.yearEnd, d.yearEnd),
                      pick(cur.country, d.country), pick(cur.durationMs, d.durationMs), pick(cur.imageRef, d.imageRef), MusicGraphReads.encodeAttrs(attrs),
                      cur.provisional && d.provisional, cur.pinned || d.pinned, t, rid])
        }

        // 4. Ids (weak ones may be shared) and names.
        let blocked = Set(conflicts)
        for x in d.externalIDs where !blocked.contains(x) {
            try c.execute("INSERT OR IGNORE INTO external_id(entity, scheme, value, strong, source, retrieved_at, conflict) VALUES(?, ?, ?, ?, NULL, ?, 0)",
                          [rid, x.scheme.rawValue, x.value, x.isStrong, t])
        }
        var aliasesChanged = false
        let current = try MusicGraphReads.snapshot(c, rid: rid)?.name ?? name
        for a in [NameAlias(current, lang: d.lang, isPrimary: true)] + d.aliases where !a.text.trimmingCharacters(in: .whitespaces).isEmpty {
            try c.execute("INSERT OR IGNORE INTO name_alias(entity, text, latin, lang, script, primary_name, source) VALUES(?, ?, ?, ?, ?, ?, ?)",
                          [rid, a.text, a.latin, a.lang, a.script, a.isPrimary, a.source])
            if c.changes > 0 { aliasesChanged = true }
        }
        if nameChanged {
            try c.execute("UPDATE name_alias SET primary_name = (text = ?) WHERE entity = ?", [current, rid])
        }
        if created || nameChanged || aliasesChanged { try reindex(c, rid: rid) }
        let id = try MusicGraphReads.entityID(c, rid: rid)!
        return MusicUpsertResult(id: id, created: created, conflicts: conflicts)
    }

    /// Rewrites the full-text row of one entity: its name, the folded skeletons of every spelling, and all alias texts.
    static func reindex(_ c: Connection, rid: Int) throws {
        try c.execute("DELETE FROM entity_fts WHERE rowid = ?", [rid])
        guard let row = try c.queryOne("SELECT name, name_latin, state FROM entity WHERE rid = ?", [rid], { (name: $0.string(0), latin: $0.string(1), state: $0.int(2)) }),
              row.state == 0 else { return }
        let al = try c.query("SELECT text, latin FROM name_alias WHERE entity = ?", [rid]) { (text: $0.string(0), latin: $0.string(1)) }
        let latin = ([row.latin] + al.map(\.latin)).joined(separator: " ")
        try c.execute("INSERT INTO entity_fts(rowid, name, latin, aliases) VALUES(?, ?, ?, ?)", [rid, row.name, latin, al.map(\.text).joined(separator: " ")])
    }

    static func setPinned(_ c: Connection, _ id: MusicEntityID, _ pinned: Bool, now: Date) throws {
        guard let rid = try MusicGraphReads.liveRID(c, id) else { throw MusicGraphError.unknownEntity(id.rawValue) }
        try c.execute("UPDATE entity SET pinned = ?, updated_at = ? WHERE rid = ?", [pinned, secs(now), rid])
    }

    // MARK: edges and facts

    @discardableResult
    static func addClaim(_ c: Connection, edge e: MusicEdge, provenance p: MusicProvenance, now: Date) throws -> MusicEdge {
        guard let s = try MusicGraphReads.liveRID(c, e.subject) else { throw MusicGraphError.unknownEntity(e.subject.rawValue) }
        guard let o = try MusicGraphReads.liveRID(c, e.object) else { throw MusicGraphError.unknownEntity(e.object.rawValue) }
        guard s != o else { throw MusicGraphError.invalidEdge("self edge") }
        guard e.predicate.accepts(subject: e.subject.kind, object: e.object.kind) else {
            throw MusicGraphError.invalidEdge("\(e.predicate.label) does not take \(e.subject.kind.slug) to \(e.object.kind.slug)")
        }
        let t = secs(now)
        let existing = try c.queryOne("SELECT rid, attrs, ord, credit_level FROM edge WHERE subject = ? AND predicate = ? AND object = ? AND qual = ?",
                                      [s, e.predicate.rawValue, o, e.qualifier]) { (rid: $0.int(0), attrs: $0.optString(1), ord: $0.optInt(2), level: $0.int(3)) }
        let edgeRID: Int
        if let ex = existing {
            var attrs = MusicGraphReads.decodeAttrs(ex.attrs)
            for (k, v) in e.attributes.values { attrs[k] = v }
            try c.execute("UPDATE edge SET attrs = ?, ord = ?, credit_level = ?, updated_at = ? WHERE rid = ?",
                          [MusicGraphReads.encodeAttrs(attrs), e.order ?? ex.ord, min(ex.level, Int(e.creditLevel.rawValue)), t, ex.rid])
            edgeRID = ex.rid
        } else {
            try c.execute("INSERT INTO edge(subject, predicate, object, qual, attrs, ord, confidence, status, credit_level, tomb, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, 0, ?, ?, 0, ?, ?)",
                          [s, e.predicate.rawValue, o, e.qualifier, MusicGraphReads.encodeAttrs(e.attributes.values), e.order, Int(EdgeStatus.inferred.rawValue), Int(e.creditLevel.rawValue), t, t])
            edgeRID = Int(c.lastInsertRowID)
        }
        try writeFact(c, edge: edgeRID, p)
        try reaggregate(c, edge: edgeRID, predicate: e.predicate, now: now)
        return try c.queryOne("\(MusicGraphReads.edgeSelect) WHERE ed.rid = ?", [edgeRID], MusicGraphReads.edge)!!
    }

    static func writeFact(_ c: Connection, edge: Int, _ p: MusicProvenance) throws {
        try c.execute("""
            INSERT INTO fact(edge, source, source_ref, retrieved_at, expires_at, license, score, matcher_version, evidence, stance, override)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(edge, source, source_ref) DO UPDATE SET retrieved_at = excluded.retrieved_at, expires_at = excluded.expires_at, license = excluded.license,
              score = excluded.score, matcher_version = excluded.matcher_version, evidence = excluded.evidence, stance = excluded.stance, override = excluded.override
            """, [edge, p.source.rawValue, p.sourceRef ?? "", p.retrievedAt, p.expiresAt, p.license.rawValue, p.score.map { Double($0) }, p.matcherVersion,
                  p.evidence.isEmpty ? nil : p.evidence.joined(separator: ","), p.stance.rawValue, p.userOverride])
    }

    static func reaggregate(_ c: Connection, edge: Int, predicate: MusicPredicate, now: Date) throws {
        let agg = MusicEdgeAggregator.aggregate(predicate: predicate, facts: try MusicGraphReads.facts(c, edgeRID: edge), now: now)
        try c.execute("UPDATE edge SET confidence = ?, status = ?, tomb = ?, updated_at = ? WHERE rid = ?",
                      [Double(agg.confidence), Int(agg.status.rawValue), agg.tombstone, secs(now), edge])
    }

    // MARK: cache state

    static func setCacheState(_ c: Connection, entity id: MusicEntityID, facet: String, source: MusicSourceID, outcome: MusicCacheState.Outcome, ttl: TimeInterval,
                              etag: String?, matcherVersion: Int?, now: Date) throws {
        guard let rid = try MusicGraphReads.liveRID(c, id) else { throw MusicGraphError.unknownEntity(id.rawValue) }
        let prior = try MusicGraphReads.cacheState(c, rid: rid, facet: facet, source: source)
        if outcome == .error {
            let attempts = (prior?.attempts ?? 0) + 1
            try c.execute("""
                INSERT INTO cache_state(entity, facet, source, fetched_at, expires_at, outcome, attempts, next_retry_at, etag, matcher_version) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(entity, facet, source) DO UPDATE SET outcome = excluded.outcome, attempts = excluded.attempts, next_retry_at = excluded.next_retry_at
                """, [rid, facet, source.rawValue, prior?.fetchedAt, prior?.expiresAt, outcome.rawValue, attempts,
                      now.addingTimeInterval(MusicCacheState.backoff(attempts: attempts)), prior?.etag, prior?.matcherVersion])
        } else {
            try c.execute("""
                INSERT INTO cache_state(entity, facet, source, fetched_at, expires_at, outcome, attempts, next_retry_at, etag, matcher_version) VALUES(?, ?, ?, ?, ?, ?, 0, NULL, ?, ?)
                ON CONFLICT(entity, facet, source) DO UPDATE SET fetched_at = excluded.fetched_at, expires_at = excluded.expires_at, outcome = excluded.outcome,
                  attempts = 0, next_retry_at = NULL, etag = excluded.etag, matcher_version = excluded.matcher_version
                """, [rid, facet, source.rawValue, now, now.addingTimeInterval(ttl), outcome.rawValue, etag, matcherVersion])
        }
    }

    // MARK: provider id spelling

    /// One-time repair for graphs written before provider ids had one spelling: every provider id of the YouTube family (`youtube-music:`, `youtube:`, `piped:`, `invidious:`) becomes `ytmusic:`, and entities of one kind that
    /// end up holding the same id are merged into the one with the most edges (the others keep a redirect). Safe to run again; a run that finds nothing writes nothing.
    @discardableResult
    static func canonicalizeProviderIDs(_ c: Connection, now: Date) throws -> Int {
        let like = ExternalID.youTubeFamily.map { "value LIKE '\($0):%'" }.joined(separator: " OR ")
        let rows = try c.query("SELECT entity, value FROM external_id WHERE scheme = 'provider' AND (\(like))") { (rid: $0.int(0), value: $0.string(1)) }
        var changed = 0
        for row in rows {
            let canon = ExternalID.canonical(.provider, row.value)
            let other = try c.queryOne("SELECT entity FROM external_id WHERE scheme = 'provider' AND value = ?", [canon]) { $0.int(0) }
            if let o = other, o != row.rid {
                guard let a = try MusicGraphReads.liveRID(c, rid: row.rid), let b = try MusicGraphReads.liveRID(c, rid: o), a != b,
                      let ak = try MusicGraphReads.snapshot(c, rid: a)?.kind, let bk = try MusicGraphReads.snapshot(c, rid: b)?.kind, ak == bk else { continue }
                let ae = try c.queryOne("SELECT COUNT(*) FROM edge WHERE tomb = 0 AND (subject = ? OR object = ?)", [a, a]) { $0.int(0) } ?? 0
                let be = try c.queryOne("SELECT COUNT(*) FROM edge WHERE tomb = 0 AND (subject = ? OR object = ?)", [b, b]) { $0.int(0) } ?? 0
                let (w, l) = ae > be ? (a, b) : (b, a)
                if let wid = try MusicGraphReads.entityID(c, rid: w), let lid = try MusicGraphReads.entityID(c, rid: l) { _ = try merge(c, winner: wid, loser: lid, byUser: false, now: now) }
                try c.execute("DELETE FROM external_id WHERE entity = ? AND scheme = 'provider' AND value = ?", [row.rid, row.value])
            } else {
                try c.execute("UPDATE OR IGNORE external_id SET value = ? WHERE entity = ? AND scheme = 'provider' AND value = ?", [canon, row.rid, row.value])
            }
            changed += 1
        }
        return changed
    }

    // MARK: merge

    /// One transaction: ids, names, edges (duplicates folded, their facts summed), cache rows and pin move to the winner; the loser keeps only a redirect.
    static func merge(_ c: Connection, winner wid: MusicEntityID, loser lid: MusicEntityID, byUser: Bool, now: Date) throws -> MusicEntityID {
        guard let w = try MusicGraphReads.liveRID(c, wid) else { throw MusicGraphError.unknownEntity(wid.rawValue) }
        guard let l = try MusicGraphReads.liveRID(c, lid) else { throw MusicGraphError.unknownEntity(lid.rawValue) }
        guard w != l else { return try MusicGraphReads.entityID(c, rid: w)! }
        guard let ws = try MusicGraphReads.snapshot(c, rid: w), let ls = try MusicGraphReads.snapshot(c, rid: l) else { throw MusicGraphError.unknownEntity(lid.rawValue) }
        guard ws.kind == ls.kind else { throw MusicGraphError.invalidMerge("\(ws.kind.slug) and \(ls.kind.slug) cannot merge") }
        let t = secs(now)

        try c.execute("UPDATE OR IGNORE external_id SET entity = ? WHERE entity = ?", [w, l])
        try c.execute("DELETE FROM external_id WHERE entity = ?", [l])
        try c.execute("UPDATE OR IGNORE name_alias SET entity = ?, primary_name = 0 WHERE entity = ?", [w, l])
        try c.execute("DELETE FROM name_alias WHERE entity = ?", [l])
        try c.execute("INSERT OR IGNORE INTO name_alias(entity, text, latin, lang, script, primary_name, source) VALUES(?, ?, ?, ?, NULL, 0, NULL)", [w, ls.name, ls.nameLatin, ls.lang])
        try c.execute("UPDATE OR IGNORE cache_state SET entity = ? WHERE entity = ?", [w, l])
        try c.execute("DELETE FROM cache_state WHERE entity = ?", [l])
        try c.execute("DELETE FROM affinity WHERE entity = ?", [l])

        // Edges of the loser, in both directions.
        let moving = try c.query("SELECT rid, subject, predicate, object, qual, attrs, ord, credit_level FROM edge WHERE subject = ? OR object = ?", [l, l]) {
            (rid: $0.int(0), s: $0.int(1), p: $0.int(2), o: $0.int(3), q: $0.string(4), attrs: $0.optString(5), ord: $0.optInt(6), level: $0.int(7))
        }
        for e in moving {
            let ns = e.s == l ? w : e.s, no = e.o == l ? w : e.o
            if ns == no { try c.execute("DELETE FROM edge WHERE rid = ?", [e.rid]); continue }
            let dup = try c.queryOne("SELECT rid, attrs, ord, credit_level FROM edge WHERE subject = ? AND predicate = ? AND object = ? AND qual = ?", [ns, e.p, no, e.q]) {
                (rid: $0.int(0), attrs: $0.optString(1), ord: $0.optInt(2), level: $0.int(3))
            }
            guard let d = dup else {
                try c.execute("UPDATE edge SET subject = ?, object = ?, updated_at = ? WHERE rid = ?", [ns, no, t, e.rid])
                continue
            }
            var attrs = MusicGraphReads.decodeAttrs(e.attrs)
            for (k, v) in MusicGraphReads.decodeAttrs(d.attrs) { attrs[k] = v }
            try c.execute("UPDATE OR REPLACE fact SET edge = ? WHERE edge = ?", [d.rid, e.rid])
            try c.execute("UPDATE edge SET attrs = ?, ord = ?, credit_level = ? WHERE rid = ?", [MusicGraphReads.encodeAttrs(attrs), d.ord ?? e.ord, min(d.level, e.level), d.rid])
            try c.execute("DELETE FROM edge WHERE rid = ?", [e.rid])
            if let p = MusicPredicate(rawValue: e.p) { try reaggregate(c, edge: d.rid, predicate: p, now: now) }
        }

        // Fields the winner lacks come from the loser; a pin is never lost.
        try c.execute("""
            UPDATE entity SET subkind = COALESCE(subkind, ?), lang = COALESCE(lang, ?), year = COALESCE(year, ?), year_end = COALESCE(year_end, ?), country = COALESCE(country, ?),
              duration_ms = COALESCE(duration_ms, ?), image_ref = COALESCE(image_ref, ?), pinned = MAX(pinned, ?), updated_at = ? WHERE rid = ?
            """, [ls.subkind, ls.lang, ls.year, ls.yearEnd, ls.country, ls.durationMs, ls.imageRef, ls.pinned, t, w])
        try c.execute("DELETE FROM entity_fts WHERE rowid = ?", [l])
        try c.execute("UPDATE entity SET state = 1, merged_into = ?, pinned = 0, updated_at = ? WHERE rid = ?", [w, t, l])
        try c.execute("UPDATE entity SET merged_into = ? WHERE merged_into = ? AND state = 1", [w, l])
        try c.execute("INSERT INTO decision(kind, a, b, verdict, score, by_user, matcher_version, created_at) VALUES('merge', ?, ?, 1, NULL, ?, NULL, ?)", [w, l, byUser, t])
        try reindex(c, rid: w)
        return wid
    }

    static func bumpRev(_ c: Connection) throws {
        try c.exec("UPDATE meta SET v = CAST(CAST(v AS INTEGER) + 1 AS TEXT) WHERE k = 'graph_rev'")
    }
}
