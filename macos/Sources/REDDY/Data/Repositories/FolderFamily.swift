import Foundation

/// Folders with the same name in different playlists are one "family": the same shelf in a twin playlist. A lock or a hide made on one of them applies to all of
/// them, including folders of playlists added later, so a twin folder can never be browsed or recommended while the original is locked or hidden.
/// This writes only the person's own preference tables (`locked_categories`, `hidden_items`), never playlist data.
enum FolderFamily {
    /// Every folder (in any playlist, enabled or not) that has the same kind and name as `categoryID`, the folder itself included.
    static func members(of categoryID: String, in c: Connection) throws -> [String] {
        let rows = try c.query("""
            SELECT c2.id FROM categories c1 JOIN categories c2 ON c2.kind = c1.kind AND c2.normalized_name = c1.normalized_name
            WHERE c1.id = ?
            """, [categoryID]) { $0.string(0) }
        return rows.contains(categoryID) ? rows : rows + [categoryID]
    }

    /// Brings every family in line with its marked members: a folder is locked (hidden) when any folder of its family is. Idempotent; returns how many folders were newly marked.
    @discardableResult
    static func apply(in c: Connection) throws -> Int {
        var changed = 0
        try c.execute("""
            INSERT OR IGNORE INTO locked_categories(category_id)
            SELECT c2.id FROM locked_categories l JOIN categories c1 ON c1.id = l.category_id
            JOIN categories c2 ON c2.kind = c1.kind AND c2.normalized_name = c1.normalized_name AND c2.id <> c1.id
            """)
        changed += c.changes
        try c.execute("""
            INSERT OR IGNORE INTO hidden_items(item_id, kind, hidden_at)
            SELECT c2.id, 'category', h.hidden_at FROM hidden_items h JOIN categories c1 ON c1.id = h.item_id AND h.kind = 'category'
            JOIN categories c2 ON c2.kind = c1.kind AND c2.normalized_name = c1.normalized_name AND c2.id <> c1.id
            """)
        changed += c.changes
        return changed
    }
}
