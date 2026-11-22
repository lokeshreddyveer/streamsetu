import Foundation

/// What the recommendation code remembers, kept apart from everything the person did: "do not recommend this again" markers (`rec_dismissed`) and what a shelf showed recently
/// (`smartmix_shown`). Both are keyed by profile, never read across profiles, and neither is ever written for a title the person may not be shown (a locked or hidden folder, or
/// a copy of a title with a copy there). Continue Watching, its progress and its order are not touched by anything in this file.
struct RecommendationMemory: Sendable {
    let db: DatabaseManager
    let catalog: SQLiteCatalogRepository

    private struct Ident { let kind: ContentKind; let key: String; let year: Int? }

    private func identity(of itemID: String, in c: Connection) throws -> Ident? {
        if let r = try c.queryOne("SELECT kind, identity_key, year FROM content_identity WHERE item_id=?", [itemID], { ($0.string(0), $0.string(1), $0.optInt(2)) }),
           let kind = ContentKind(rawValue: r.0) { return Ident(kind: kind, key: r.1, year: r.2) }
        return nil
    }

    /// Whether the person may be shown this title on a recommendation surface (the always-restricted view finds it).
    func isRecommendable(_ itemID: String) -> Bool { ((try? catalog.recommendableIDs([itemID])) ?? []).contains(itemID) }

    // MARK: dismissed ("remove from Continue Watching" also stops recommending it)

    /// Marks a title so it is not recommended again. Returns false, and writes nothing, when the title is restricted or unknown.
    @discardableResult
    func dismiss(profileID: String, itemID: String, now: Date = Date()) throws -> Bool {
        guard isRecommendable(itemID) else { return false }
        return try db.write { c in
            guard let i = try identity(of: itemID, in: c) else { return false }
            try c.execute("INSERT OR REPLACE INTO rec_dismissed(profile_id, item_id, kind, identity_key, year, dismissed_at) VALUES(?,?,?,?,?,?)",
                          [profileID, itemID, i.kind.rawValue, i.key, i.year, now])
            return true
        }
    }

    func undismiss(profileID: String, itemID: String) throws {
        try db.write { try $0.execute("DELETE FROM rec_dismissed WHERE profile_id=? AND item_id=?", [profileID, itemID]) }
    }

    /// The identity keys (with year) this profile dismissed, for the exclusion set of the recommendation code. Any copy of a dismissed title counts as dismissed.
    func dismissedKeys(profileID: String) throws -> Set<String> {
        try db.read { c in
            Set(try c.query("SELECT identity_key, year FROM rec_dismissed WHERE profile_id=?", [profileID]) { "\($0.string(0))|\($0.optInt(1) ?? 0)" })
        }
    }

    // MARK: shown history

    /// Notes which titles a shelf just showed (one row per title and load). Restricted titles are skipped. Returns the rows written.
    @discardableResult
    func recordShown(profileID: String, shelfID: String, itemIDs: [String], loadSeq: Int, now: Date = Date()) throws -> Int {
        let ok = try catalog.recommendableIDs(itemIDs)
        let allowed = itemIDs.filter { ok.contains($0) }
        guard !allowed.isEmpty else { return 0 }
        return try db.write { c in
            var n = 0
            for id in allowed {
                guard let i = try identity(of: id, in: c) else { continue }
                try c.execute("INSERT OR REPLACE INTO smartmix_shown(profile_id, shelf_id, identity_key, year, item_id, load_seq, shown_at) VALUES(?,?,?,?,?,?,?)",
                              [profileID, shelfID, i.key, i.year, id, loadSeq, now])
                n += 1
            }
            return n
        }
    }

    /// The identity keys this profile's shelf showed in its most recent `loads` loads.
    func shownKeys(profileID: String, shelfID: String, loads: Int) throws -> Set<String> {
        try db.read { c in
            let newest = try c.scalarInt("SELECT COALESCE(MAX(load_seq),0) FROM smartmix_shown WHERE profile_id=? AND shelf_id=?", [profileID, shelfID])
            return Set(try c.query("SELECT identity_key FROM smartmix_shown WHERE profile_id=? AND shelf_id=? AND load_seq > ?", [profileID, shelfID, newest - loads]) { $0.string(0) })
        }
    }

    /// Deletes what was remembered about titles that are restricted now (called the moment a folder is locked or hidden, and on launch). Dismissals are kept: they are the person's own choice and are never read for a restricted title.
    @discardableResult
    func purgeRestricted() throws -> Int {
        let shown = try db.read { try $0.query("SELECT DISTINCT item_id FROM smartmix_shown") { $0.string(0) } }
        guard !shown.isEmpty else { return 0 }
        let ok = try catalog.recommendableIDs(shown)
        let gone = shown.filter { !ok.contains($0) }
        guard !gone.isEmpty else { return 0 }
        return try db.write { c in
            var n = 0
            for id in gone { try c.execute("DELETE FROM smartmix_shown WHERE item_id=?", [id]); n += c.changes }
            return n
        }
    }

    /// Everything the shelves remembered for a profile that is being removed.
    func forget(profileID: String) throws {
        try db.write { c in
            for t in ["rec_dismissed", "smartmix_shown", "smartmix_state", "folder_recent"] { try c.execute("DELETE FROM \(t) WHERE profile_id=?", [profileID]) }
        }
    }
}
