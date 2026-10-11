import Foundation

/// Maps catalog channels to guide channels. Order of trust:
/// 1. user-defined mapping (never overwritten)  2. exact EPG id  3. provider id equals guide id
/// 4. conservative name match (only when the name is unique on both sides).
/// An ambiguous or missing match is left unmapped rather than guessed.
struct XMLTVChannelMatcher: Sendable {
    let db: DatabaseManager

    @discardableResult
    func rebuild(sourceID: UUID) throws -> (mapped: Int, byMethod: [String: Int]) {
        let sid = sourceID.uuidString.lowercased()
        let guideChannels = try db.read { c in
            try c.query("SELECT xmltv_id, COALESCE(normalized_name,'') FROM epg_channels WHERE source_id=?", [sid]) { ($0.string(0), $0.string(1)) }
        }
        let guideIDs = Set(guideChannels.map(\.0))
        let channels = try db.read { c in
            try c.query("""
                SELECT c.id, COALESCE(o.epg_id, c.epg_id), c.provider_id, c.normalized_name
                FROM channels c LEFT JOIN metadata_overrides o ON o.item_id = c.id WHERE c.source_id=?
                """, [sid]) { (id: $0.string(0), epg: $0.optString(1), provider: $0.string(2), name: $0.string(3)) }
        }
        let userMapped = Set(try db.read { c in
            try c.query("SELECT channel_id FROM epg_channel_mappings WHERE source_id=? AND method='user'", [sid]) { $0.string(0) }
        })

        // name -> guide ids (only unique names are eligible)
        var guideByName: [String: [String]] = [:]
        for (id, name) in guideChannels where !name.isEmpty { guideByName[MetadataNormalizer.baseName(name), default: []].append(id) }
        var channelNameCount: [String: Int] = [:]
        for ch in channels { channelNameCount[MetadataNormalizer.baseName(ch.name), default: 0] += 1 }

        var rows: [(String, String, String, Double)] = []   // channel, xmltv, method, confidence
        for ch in channels where !userMapped.contains(ch.id) {
            if let e = ch.epg, guideIDs.contains(e) { rows.append((ch.id, e, "exact", 1)); continue }
            if guideIDs.contains(ch.provider) { rows.append((ch.id, ch.provider, "provider", 0.9)); continue }
            let base = MetadataNormalizer.baseName(ch.name)
            if !base.isEmpty, channelNameCount[base] == 1, let g = guideByName[base], g.count == 1 {
                rows.append((ch.id, g[0], "name", 0.6))
            }
        }

        try db.write { c in
            try c.execute("DELETE FROM epg_channel_mappings WHERE source_id=? AND method!='user'", [sid])
            let st = try c.prepare("INSERT OR REPLACE INTO epg_channel_mappings(channel_id, source_id, xmltv_channel_id, method, confidence) VALUES(?,?,?,?,?)")
            for r in rows { try st.run([r.0, sid, r.1, r.2, r.3]) }
        }
        var by: [String: Int] = [:]
        for r in rows { by[r.2, default: 0] += 1 }
        return (rows.count, by)
    }

    func setUserMapping(channelID: String, sourceID: UUID, xmltvID: String?) throws {
        try db.write { c in
            if let xmltvID {
                try c.execute("INSERT OR REPLACE INTO epg_channel_mappings(channel_id, source_id, xmltv_channel_id, method, confidence) VALUES(?,?,?,'user',1)",
                              [channelID, sourceID, xmltvID])
            } else {
                try c.execute("DELETE FROM epg_channel_mappings WHERE channel_id=?", [channelID])
            }
        }
    }
}
