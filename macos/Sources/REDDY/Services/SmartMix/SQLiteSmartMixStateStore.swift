import Foundation

/// `smartmix_state` and `smartmix_shown` (SchemaV19), keyed by profile and bounded: at most 48 remembered rows per profile and shelf. Ids and keys only.
/// The same behaviour as `InMemorySmartMixStateStore` (the contract the tests run against both).
final class SQLiteSmartMixStateStore: SmartMixStateStore, @unchecked Sendable {
    let db: DatabaseManager
    static let keepRows = InMemorySmartMixStateStore.keepRows
    init(db: DatabaseManager) { self.db = db }

    func refreshCounter(profile: String, shelf: String) -> Int {
        (try? db.read { try $0.queryOne("SELECT refresh_counter FROM smartmix_state WHERE profile_id=? AND shelf_id=?", [profile, shelf]) { $0.int(0) } }) ?? 0
    }

    func bumpRefresh(profile: String, shelves: [String]) {
        _ = try? db.write { c in
            for s in shelves {
                try c.execute("""
                    INSERT INTO smartmix_state(profile_id, shelf_id, refresh_counter) VALUES(?,?,1)
                    ON CONFLICT(profile_id, shelf_id) DO UPDATE SET refresh_counter = refresh_counter + 1
                    """, [profile, s])
            }
        }
    }

    func loadsAgo(profile: String, shelf: String, loadKey: String) -> [String: Int] {
        (try? db.read { c -> [String: Int] in
            guard let st = try c.queryOne("SELECT load_key, load_seq FROM smartmix_state WHERE profile_id=? AND shelf_id=?", [profile, shelf], { ($0.string(0), $0.int(1)) }) else { return [:] }
            let eff = st.0 == loadKey ? st.1 : st.1 + 1
            var out: [String: Int] = [:]
            for r in try c.query("SELECT identity_key, load_seq FROM smartmix_shown WHERE profile_id=? AND shelf_id=?", [profile, shelf], { ($0.string(0), $0.int(1)) }) {
                let ago = eff - r.1
                if ago >= 1 { out[r.0] = min(out[r.0] ?? ago, ago) }
            }
            return out
        }) ?? [:]
    }

    func recordShown(profile: String, shelf: String, loadKey: String, rows: [SMShownRow]) {
        _ = try? db.write { c in
            let st = try c.queryOne("SELECT load_key, load_seq FROM smartmix_state WHERE profile_id=? AND shelf_id=?", [profile, shelf], { ($0.string(0), $0.int(1)) })
            if let st, st.0 == loadKey { return }
            let seq = (st?.1 ?? 0) + 1
            try c.execute("""
                INSERT INTO smartmix_state(profile_id, shelf_id, refresh_counter, load_key, load_seq) VALUES(?,?,0,?,?)
                ON CONFLICT(profile_id, shelf_id) DO UPDATE SET load_key = excluded.load_key, load_seq = excluded.load_seq
                """, [profile, shelf, loadKey, seq])
            let now = Date()
            for r in rows {
                try c.execute("INSERT OR REPLACE INTO smartmix_shown(profile_id, shelf_id, identity_key, year, item_id, load_seq, shown_at) VALUES(?,?,?,?,?,?,?)",
                              [profile, shelf, r.key, r.year, r.itemId, seq, now])
            }
            try c.execute("""
                DELETE FROM smartmix_shown WHERE profile_id=? AND shelf_id=? AND rowid NOT IN
                  (SELECT rowid FROM smartmix_shown WHERE profile_id=? AND shelf_id=? ORDER BY load_seq DESC, rowid ASC LIMIT ?)
                """, [profile, shelf, profile, shelf, Self.keepRows])
        }
    }

    func forget(profile: String, keys: Set<String>) {
        guard !keys.isEmpty else { return }
        _ = try? db.write { c in for k in keys { try c.execute("DELETE FROM smartmix_shown WHERE profile_id=? AND identity_key=?", [profile, k]) } }
    }

    func clear(profile: String) {
        _ = try? db.write { c in
            try c.execute("DELETE FROM smartmix_shown WHERE profile_id=?", [profile])
            try c.execute("DELETE FROM smartmix_state WHERE profile_id=?", [profile])
        }
    }
}
