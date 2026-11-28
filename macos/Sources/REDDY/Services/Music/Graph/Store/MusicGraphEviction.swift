import Foundation

struct MusicEvictionReport: Sendable, Equatable {
    var expiredFacts = 0, orphanEdges = 0, entities = 0, tombstones = 0, recCache = 0
    var total: Int { expiredFacts + orphanEdges + entities + tombstones + recCache }
}

/// Eviction at idle (section 2.4). Pinned entities, and any entity joined to a pinned one by an edge (a credit of a liked song), are never removed.
enum MusicGraphEviction {
    /// Entities that may be deleted: unpinned, live, not joined by any edge to a pinned entity.
    private static let evictable = """
        e.pinned = 0 AND e.state = 0
        AND NOT EXISTS (SELECT 1 FROM edge x JOIN entity p ON p.rid = x.object WHERE x.subject = e.rid AND p.pinned = 1)
        AND NOT EXISTS (SELECT 1 FROM edge x JOIN entity p ON p.rid = x.subject WHERE x.object = e.rid AND p.pinned = 1)
        AND e.kind NOT IN (\(MusicEntityKind.allCases.filter(\.isFacet).map { String($0.rawValue) }.joined(separator: ",")))
        """

    static func run(_ c: Connection, limits: MusicGraphLimits, now: Date) throws -> MusicEvictionReport {
        var rep = MusicEvictionReport()
        let t = MusicGraphWrites.secs(now)

        // 1. Facts past their expiry (terms-restricted data has a hard retention), then edges left with no claim at all.
        try c.execute("DELETE FROM fact WHERE expires_at IS NOT NULL AND expires_at <= ?", [now])
        rep.expiredFacts = c.changes
        try c.execute("DELETE FROM edge WHERE NOT EXISTS (SELECT 1 FROM fact f WHERE f.edge = edge.rid) AND tomb = 0")
        rep.orphanEdges = c.changes

        // 2. Old redirects.
        try c.execute("DELETE FROM entity WHERE state = 1 AND updated_at < ?", [t - Int(limits.tombstoneAge)])
        rep.tombstones = c.changes

        // 3. Stale entities, least recently used first, in batches, until under the target. A second pass ignores age if still over.
        func overLimit() throws -> Bool {
            try MusicGraphReads.usedBytes(c) > limits.targetBytes || c.scalarInt("SELECT count(*) FROM edge") > limits.maxEdges
        }
        func evict(olderThan cutoff: Int) throws -> Int {
            var removed = 0
            while try overLimit() {
                let ids = try c.query("SELECT e.rid FROM entity e WHERE \(evictable) AND e.accessed_at < ? ORDER BY e.accessed_at LIMIT \(limits.evictionBatch)", [cutoff]) { $0.int(0) }
                if ids.isEmpty { break }
                try delete(c, rids: ids)
                removed += ids.count
            }
            return removed
        }
        rep.entities += try evict(olderThan: t - Int(limits.staleAfter))
        rep.entities += try evict(olderThan: Int.max / 2)

        try c.execute("DELETE FROM rec_cache WHERE entity NOT IN (SELECT rid FROM entity)")
        try c.execute("DELETE FROM work_item WHERE entity NOT IN (SELECT rid FROM entity)")

        // 4. Computed shelves go when still over.
        if try overLimit() { try c.execute("DELETE FROM rec_cache"); rep.recCache = c.changes }
        return rep
    }

    private static func delete(_ c: Connection, rids: [Int]) throws {
        let list = rids.map(String.init).joined(separator: ",")
        try c.exec("DELETE FROM entity_fts WHERE rowid IN (\(list)); DELETE FROM entity WHERE rid IN (\(list));")
    }

    /// Frees file space after a big delete (needs the writer outside a transaction).
    static func compact(_ c: Connection) {
        try? c.exec("PRAGMA incremental_vacuum(2000); PRAGMA wal_checkpoint(TRUNCATE)")
    }
}
