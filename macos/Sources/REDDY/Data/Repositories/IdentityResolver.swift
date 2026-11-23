import Foundation

/// Every copy of one title, with the one a card shows and the others kept reachable.
struct IdentityGroup: Sendable {
    let kind: ContentKind
    let key: String
    /// Every copy, in any playlist, in any state.
    let members: [IdentityMember]
    /// The copy a card shows (nil when no copy is reachable).
    let canonical: IdentityMember?
    /// The other copies the person may open: playlist on, folder neither locked nor hidden, title not hidden. Best first.
    let alternatives: [IdentityMember]
    /// Some copy sits in a locked or hidden folder, so the title is withheld from every recommendation surface.
    let restricted: Bool
}

/// Reads `content_identity` to group copies. Read-only: nothing here changes a playlist row.
struct IdentityResolver: Sendable {
    let db: DatabaseManager

    private struct Raw { var member: IdentityMember; var duration: Double?; var rating: Double?; var folder: String?; var enabled: Bool }

    private static func corroboration(_ a: Raw, _ b: Raw) -> Int {
        var n = 0
        if let x = a.duration, let y = b.duration, x > 0, y > 0, abs(x - y) <= max(x, y) * 0.08 { n += 1 }
        if let x = a.rating, let y = b.rating, x > 0, x == y { n += 1 }
        return n
    }

    /// The same title when the years agree. A year's difference is accepted when other facts agree (two facts for a short one-word title); a missing year is accepted for a
    /// title of two words or more, or when the facts agree. A remake decades apart never matches.
    private static func same(_ a: Raw, _ b: Raw, key: String) -> Bool {
        let short = !key.contains(" ") && key.count <= 7
        let needed = short ? 2 : 1
        switch (a.member.year, b.member.year) {
        case let (x?, y?):
            if x == y { return true }
            return abs(x - y) == 1 && corroboration(a, b) >= needed
        default:
            return key.contains(" ") || corroboration(a, b) >= needed
        }
    }

    func group(of itemID: String, preferredLanguage: String? = nil, userPreferredSource: UUID? = nil, now: Date = Date()) throws -> IdentityGroup? {
        try groups(of: [itemID], preferredLanguage: preferredLanguage, userPreferredSource: userPreferredSource, now: now)[itemID] ?? nil
    }

    /// The groups of many titles at once: playlist standing and the locked and hidden folders are read once, then one indexed lookup per title.
    func groups(of itemIDs: [String], preferredLanguage: String? = nil, userPreferredSource: UUID? = nil, now: Date = Date()) throws -> [String: IdentityGroup?] {
        let health = try IdentityStore(db: db).sourceHealth()
        let context = CanonicalPick.Context(preferredLanguage: preferredLanguage, sourceRank: PreferredSource.ranking(health, userPreferred: userPreferredSource, now: now))
        return try db.read { c in
            let locked = Set(try c.query("SELECT category_id FROM locked_categories") { $0.string(0) })
            let hiddenFolders = Set(try c.query("SELECT item_id FROM hidden_items WHERE kind='category'") { $0.string(0) })
            var out: [String: IdentityGroup?] = [:]
            for itemID in itemIDs {
                out[itemID] = try one(itemID, locked: locked, hiddenFolders: hiddenFolders, context: context, in: c)
            }
            return out
        }
    }

    private func one(_ itemID: String, locked: Set<String>, hiddenFolders: Set<String>, context: CanonicalPick.Context, in c: Connection) throws -> IdentityGroup? {
        guard let head = try c.queryOne("SELECT kind, identity_key FROM content_identity WHERE item_id=?", [itemID], { ($0.string(0), $0.string(1)) }),
              let kind = ContentKind(rawValue: head.0) else { return nil }
        let table = kind == .movie ? "movies" : "series"
        let extra = kind == .movie ? "x.duration_seconds, x.rating, COALESCE(x.added_at, x.created_at, 0)" : "NULL, x.rating, COALESCE(x.added_at, x.first_seen_at, 0)"
        let raws: [Raw] = try c.query("""
            SELECT ci.item_id, ci.source_id, ci.lang, ci.quality_rank, ci.is_cam, ci.year, \(extra), x.category_id, s.enabled
            FROM content_identity ci JOIN \(table) x ON x.id = ci.item_id JOIN sources s ON s.id = ci.source_id
            WHERE ci.kind = ? AND ci.identity_key = ?
            """, [head.0, head.1]) { r in
            Raw(member: IdentityMember(itemID: r.string(0), sourceID: r.uuid(1) ?? UUID(), language: r.optString(2), qualityRank: r.int(3), isCam: r.bool(4), year: r.optInt(5), addedAt: r.double(8)),
                duration: r.optDouble(6), rating: RatingRule.credible(r.optString(7)), folder: r.optString(9), enabled: r.bool(10))
        }
        guard let me = raws.first(where: { $0.member.itemID == itemID }) else { return nil }
        let group = raws.filter { $0.member.itemID == itemID || Self.same(me, $0, key: head.1) }
        let marks = group.map { _ in "?" }.joined(separator: ",")
        let hiddenItems = Set(try c.query("SELECT item_id FROM hidden_items WHERE kind<>'category' AND item_id IN (\(marks))", group.map { $0.member.itemID as (any SQLConvertible)? }) { $0.string(0) })
        func folderRestricted(_ r: Raw) -> Bool { r.folder.map { locked.contains($0) || hiddenFolders.contains($0) } ?? false }
        let reachable = group.filter { $0.enabled && !folderRestricted($0) && !hiddenItems.contains($0.member.itemID) }.map(\.member)
        let ordered = CanonicalPick.ordered(reachable, context: context)
        return IdentityGroup(kind: kind, key: head.1, members: CanonicalPick.ordered(group.map(\.member), context: context), canonical: ordered.first,
                             alternatives: Array(ordered.dropFirst()), restricted: group.contains(where: folderRestricted))
    }
}
