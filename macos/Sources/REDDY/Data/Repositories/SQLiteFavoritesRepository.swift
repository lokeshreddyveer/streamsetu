import Foundation

final class SQLiteFavoritesRepository: FavoritesRepository {
    let db: DatabaseManager
    init(db: DatabaseManager) { self.db = db }

    func isFavorite(_ id: String) throws -> Bool {
        try db.read { try $0.scalarInt("SELECT COUNT(*) FROM favorites WHERE item_id=?", [id]) > 0 }
    }

    func setFavorite(_ id: String, kind: ContentKind, on: Bool) throws {
        try db.write { c in
            if on {
                let next = try c.scalarInt("SELECT COALESCE(MAX(sort_order),0)+1 FROM favorites WHERE kind=?", [kind.rawValue])
                try c.execute("INSERT OR IGNORE INTO favorites(item_id, kind, created_at, sort_order) VALUES(?,?,?,?)", [id, kind.rawValue, Date(), next])
            } else {
                try c.execute("DELETE FROM favorites WHERE item_id=?", [id])
            }
        }
    }

    func favoriteIDs(kind: ContentKind) throws -> [String] {
        try db.read { try $0.query("SELECT item_id FROM favorites WHERE kind=? ORDER BY sort_order, created_at", [kind.rawValue]) { $0.string(0) } }
    }

    func reorder(kind: ContentKind, ids: [String]) throws {
        try db.write { c in
            let st = try c.prepare("UPDATE favorites SET sort_order=? WHERE item_id=? AND kind=?")
            for (i, id) in ids.enumerated() { try st.run([i, id, kind.rawValue]) }
        }
    }

    func move(_ id: String, kind: ContentKind, toFront: Bool) throws {
        try db.write { c in
            let edge = try c.scalarInt(toFront ? "SELECT COALESCE(MIN(sort_order),0)-1 FROM favorites WHERE kind=?" : "SELECT COALESCE(MAX(sort_order),0)+1 FROM favorites WHERE kind=?", [kind.rawValue])
            try c.execute("UPDATE favorites SET sort_order=? WHERE item_id=? AND kind=?", [edge, id, kind.rawValue])
        }
    }

    // MARK: collections

    func collections() throws -> [CatalogCollection] {
        try db.read { c in
            try c.query("""
                SELECT c.id, c.name, c.created_at, (SELECT COUNT(*) FROM collection_items i WHERE i.collection_id=c.id)
                FROM collections c ORDER BY c.name COLLATE NOCASE
                """) { CatalogCollection(id: $0.string(0), name: $0.string(1), createdAt: $0.date(2), itemCount: $0.int(3)) }
        }
    }

    func createCollection(name: String) throws -> CatalogCollection {
        let col = CatalogCollection(id: UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespaces), createdAt: Date())
        try db.write { try $0.execute("INSERT INTO collections(id, name, created_at) VALUES(?,?,?)", [col.id, col.name, col.createdAt]) }
        return col
    }

    func renameCollection(id: String, name: String) throws {
        try db.write { try $0.execute("UPDATE collections SET name=? WHERE id=?", [name.trimmingCharacters(in: .whitespaces), id]) }
    }

    func deleteCollection(id: String) throws { try db.write { try $0.execute("DELETE FROM collections WHERE id=?", [id]) } }

    func collectionItems(id: String) throws -> [(itemID: String, kind: ContentKind)] {
        try db.read { c in
            try c.query("SELECT item_id, kind FROM collection_items WHERE collection_id=? ORDER BY sort_order, added_at", [id]) {
                (itemID: $0.string(0), kind: ContentKind(rawValue: $0.string(1)) ?? .channel)
            }
        }
    }

    func add(itemID: String, kind: ContentKind, toCollection id: String) throws {
        try db.write { c in
            let next = try c.scalarInt("SELECT COALESCE(MAX(sort_order),0)+1 FROM collection_items WHERE collection_id=?", [id])
            try c.execute("INSERT OR IGNORE INTO collection_items(collection_id, item_id, kind, sort_order, added_at) VALUES(?,?,?,?,?)",
                          [id, itemID, kind.rawValue, next, Date()])
        }
    }

    func remove(itemID: String, fromCollection id: String) throws {
        try db.write { try $0.execute("DELETE FROM collection_items WHERE collection_id=? AND item_id=?", [id, itemID]) }
    }

    // MARK: hidden / overrides (local metadata only; the provider catalog is never modified)

    func hide(_ id: String, kind: String) throws {
        try db.write { try $0.execute("INSERT OR REPLACE INTO hidden_items(item_id, kind, hidden_at) VALUES(?,?,?)", [id, kind, Date()]) }
    }

    func unhide(_ id: String) throws { try db.write { try $0.execute("DELETE FROM hidden_items WHERE item_id=?", [id]) } }

    func hiddenIDs(kind: String?) throws -> [String] {
        try db.read { c in
            if let kind { return try c.query("SELECT item_id FROM hidden_items WHERE kind=?", [kind]) { $0.string(0) } }
            return try c.query("SELECT item_id FROM hidden_items") { $0.string(0) }
        }
    }

    func setOverride(itemID: String, displayName: String?, categoryName: String?, epgID: String?) throws {
        try db.write { c in
            let dn = displayName.nilIfEmpty, cn = categoryName.nilIfEmpty, ep = epgID.nilIfEmpty
            if dn == nil && cn == nil && ep == nil {
                try c.execute("DELETE FROM metadata_overrides WHERE item_id=?", [itemID])
            } else {
                try c.execute("INSERT OR REPLACE INTO metadata_overrides(item_id, display_name, category_name, epg_id) VALUES(?,?,?,?)", [itemID, dn, cn, ep])
            }
            // keep search in step with the renamed title
            if let dn {
                try c.execute("UPDATE search_docs SET title=?, normalized=? WHERE item_id=?", [dn, MetadataNormalizer.normalize(dn), itemID])
            } else {
                try c.execute("""
                    UPDATE search_docs SET title=(SELECT name FROM channels WHERE id=?), normalized=(SELECT normalized_name FROM channels WHERE id=?)
                    WHERE item_id=? AND kind='channel'
                    """, [itemID, itemID, itemID])
            }
        }
    }

    func override(for itemID: String) throws -> (displayName: String?, categoryName: String?, epgID: String?)? {
        try db.read { c in
            try c.queryOne("SELECT display_name, category_name, epg_id FROM metadata_overrides WHERE item_id=?", [itemID]) {
                (displayName: $0.optString(0), categoryName: $0.optString(1), epgID: $0.optString(2))
            }
        }
    }

    func clearOverride(itemID: String) throws { try setOverride(itemID: itemID, displayName: nil, categoryName: nil, epgID: nil) }

    func overrideIDs() throws -> Set<String> {
        try db.read { Set(try $0.query("SELECT item_id FROM metadata_overrides") { $0.string(0) }) }
    }
}
