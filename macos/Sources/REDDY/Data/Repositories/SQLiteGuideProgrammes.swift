import Foundation

/// Programmes of the guide hub tables (`guide_programmes` through `channel_guide_map`), for channels the playlist's own guide does not cover. The highest priority source wins per channel;
/// a source's time shift and a channel's own shift are applied here, at read time. Ids are offset so they never collide with `epg_programs` ids.
extension SQLiteEPGRepository {
    static let hubIDBase: Int64 = 1 << 40

    func hubProgrammes(channelIDs: [String], from: Date, to: Date) throws -> [String: [EPGProgram]] {
        var out: [String: [EPGProgram]] = [:]
        guard !channelIDs.isEmpty else { return out }
        for chunk in channelIDs.chunked(into: 200) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT p.id, p.guide_source_id, p.xmltv_id, p.start_time, p.end_time, p.title, p.subtitle, p.description, p.category, p.image_url, m.channel_id,
                       COALESCE(o.tz_offset_minutes, s.offset_minutes, 0), s.priority
                FROM channel_guide_map m
                JOIN guide_sources s ON s.id = m.guide_source_id AND s.enabled = 1 AND s.kind != 'provider'
                JOIN guide_import_state st ON st.guide_source_id = m.guide_source_id
                JOIN guide_programmes p ON p.guide_source_id = m.guide_source_id AND p.xmltv_id = m.xmltv_id AND p.import_id = st.import_id
                     AND p.end_time > ? - 86400 AND p.start_time < ? + 86400
                LEFT JOIN channel_overrides o ON o.channel_id = m.channel_id
                WHERE m.channel_id IN (\(marks)) AND COALESCE(o.guide_off, 0) = 0
                ORDER BY m.channel_id, s.priority, p.start_time
                """
            var args: [(any SQLConvertible)?] = [from.timeIntervalSince1970, to.timeIntervalSince1970]
            args += chunk.map { $0 as (any SQLConvertible)? }
            struct R { var cid: String; var prio: Int; var p: EPGProgram }
            let rows: [R] = try db.read { c in try c.query(sql, args) { r in
                let shift = TimeInterval(r.int(11) * 60)
                let sid = UUID(uuidString: String(r.string(1).drop(while: { $0 != ":" }).dropFirst())) ?? UUID()
                return R(cid: r.string(10), prio: r.int(12), p: EPGProgram(id: Self.hubIDBase + Int64(r.int(0)), sourceID: sid, xmltvChannelID: r.string(2), start: r.date(3).addingTimeInterval(shift), end: r.date(4).addingTimeInterval(shift),
                                                                      title: r.string(5), subtitle: r.optString(6), description: r.optString(7), category: r.optString(8), imageURL: r.optString(9)))
            } }
            // One source per channel: the best priority that has anything in the asked range after the shift.
            var best: [String: Int] = [:]
            for r in rows where r.p.end > from && r.p.start < to { best[r.cid] = min(best[r.cid] ?? .max, r.prio) }
            for r in rows where r.p.end > from && r.p.start < to && best[r.cid] == r.prio { out[r.cid, default: []].append(r.p) }
        }
        return out
    }

    func hubProgram(id: Int64) throws -> EPGProgram? {
        guard id >= Self.hubIDBase else { return nil }
        let raw = id - Self.hubIDBase
        return try db.read { try $0.query("SELECT p.id, p.guide_source_id, p.xmltv_id, p.start_time, p.end_time, p.title, p.subtitle, p.description, p.category, p.image_url FROM guide_programmes p WHERE p.id=?", [raw]) { r in
            EPGProgram(id: id, sourceID: UUID(uuidString: String(r.string(1).drop(while: { $0 != ":" }).dropFirst())) ?? UUID(), xmltvChannelID: r.string(2), start: r.date(3), end: r.date(4), title: r.string(5), subtitle: r.optString(6),
                       description: r.optString(7), category: r.optString(8), imageURL: r.optString(9))
        }.first }
    }
}
