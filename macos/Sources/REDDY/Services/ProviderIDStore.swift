import Foundation

/// The TMDB / IMDb ids a provider lists for its titles.
struct ProviderIDs: Sendable, Equatable { var tmdb: Int?; var imdb: String?
    var isEmpty: Bool { tmdb == nil && imdb == nil }
    /// "tt1234567" only; anything else a provider puts there is ignored.
    static func imdb(_ s: String?) -> String? { guard let t = s?.trimmingCharacters(in: .whitespaces), t.range(of: #"^tt\d{6,10}$"#, options: .regularExpression) != nil else { return nil }; return t }
    static func tmdb(_ s: String?) -> Int? { s.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil } }
}

/// Roles of the id tables (see macos/Docs/DATABASE.md): `provider_ids` is what the playlist itself claims (kept as written); `hub_identity` is the one crosswalk every feature reads
/// (playlist ids, TMDB's external ids, TVDB, TVmaze). Every write here is mirrored into hub_identity in the same transaction, and the artwork matcher reads hub_identity too, so an id found by
/// either side is used by both. `content_identity` is derived title grouping (a different meaning) and `metadata_matches.tmdb_id` is the artwork matcher's own result; neither is merged.
struct ProviderIDStore: Sendable {
    let db: DatabaseManager
    func save(_ ids: [String: ProviderIDs]) {
        let rows = ids.filter { !$0.value.isEmpty }
        guard !rows.isEmpty else { return }
        let now = Date()
        do {
            try db.write { c in
                for (id, v) in rows {
                    try c.execute("INSERT OR REPLACE INTO provider_ids(item_id, tmdb_id, imdb_id) VALUES(?,?,?)", [id, v.tmdb, v.imdb])
                    // The playlist's own ids override what is stored, but never blank an id the hub already resolved.
                    try c.execute("""
                        INSERT INTO hub_identity(item_id, tmdb_id, imdb_id, resolved_at) VALUES(?,?,?,?)
                        ON CONFLICT(item_id) DO UPDATE SET tmdb_id = COALESCE(excluded.tmdb_id, tmdb_id), imdb_id = COALESCE(excluded.imdb_id, imdb_id)
                        """, [id, v.tmdb, v.imdb, now])
                }
            }
        } catch { Log.database.error("provider ids not saved: \(error.localizedDescription, privacy: .public)") }
    }
    func ids(for id: String) -> ProviderIDs? {
        (try? db.read { c in try c.queryOne("SELECT tmdb_id, imdb_id FROM provider_ids WHERE item_id=?", [id]) { ProviderIDs(tmdb: $0.optInt(0), imdb: $0.optString(1)) } }) ?? nil
    }
}

/// Providers that hand over the ids they list, once per sync (like `PeopleReporting`).
protocol ProviderIDReporting: AnyObject {
    func takeProviderIDs() -> [String: ProviderIDs]
}
