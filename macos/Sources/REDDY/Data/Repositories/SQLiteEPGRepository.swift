import Foundation

final class SQLiteEPGRepository: EPGRepository {
    let db: DatabaseManager
    init(db: DatabaseManager) { self.db = db }

    /// Only rows from each source's current import are visible, so a refresh in progress never shows duplicates.
    private static let programSelect = """
        SELECT p.id, p.source_id, p.xmltv_channel_id, p.start_time, p.end_time, p.title, p.subtitle, p.description, p.category, p.image_url
        """

    private static func map(_ r: Row) -> EPGProgram {
        EPGProgram(id: Int64(r.int(0)), sourceID: r.uuid(1) ?? UUID(), xmltvChannelID: r.string(2), start: r.date(3), end: r.date(4),
                   title: r.string(5), subtitle: r.optString(6), description: r.optString(7), category: r.optString(8), imageURL: r.optString(9))
    }

    func nowNext(channelIDs: [String], at date: Date) throws -> [String: [EPGProgram]] {
        var out: [String: [EPGProgram]] = [:]
        let t = date.timeIntervalSince1970
        for chunk in channelIDs.chunked(into: 400) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = Self.programSelect + ", m.channel_id" + """

                FROM epg_channel_mappings m
                JOIN epg_state st ON st.source_id = m.source_id
                JOIN epg_programs p ON p.source_id = m.source_id AND p.xmltv_channel_id = m.xmltv_channel_id
                     AND p.import_id = st.import_id AND p.end_time > ? AND p.start_time < ?
                WHERE m.channel_id IN (\(marks))
                ORDER BY m.channel_id, p.start_time
                """
            var args: [(any SQLConvertible)?] = [t, t + 6 * 3600]
            args += chunk.map { $0 as (any SQLConvertible)? }
            let rows: [(String, EPGProgram)] = try db.read { c in try c.query(sql, args) { ($0.string(10), Self.map($0)) } }
            for (cid, p) in rows where (out[cid]?.count ?? 0) < 2 { out[cid, default: []].append(p) }
        }
        return out
    }

    func programs(channelIDs: [String], from: Date, to: Date) throws -> [String: [EPGProgram]] {
        var out: [String: [EPGProgram]] = [:]
        for chunk in channelIDs.chunked(into: 200) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = Self.programSelect + ", m.channel_id" + """

                FROM epg_channel_mappings m
                JOIN epg_state st ON st.source_id = m.source_id
                JOIN epg_programs p ON p.source_id = m.source_id AND p.xmltv_channel_id = m.xmltv_channel_id
                     AND p.import_id = st.import_id AND p.end_time > ? AND p.start_time < ?
                WHERE m.channel_id IN (\(marks))
                ORDER BY m.channel_id, p.start_time
                """
            var args: [(any SQLConvertible)?] = [from.timeIntervalSince1970, to.timeIntervalSince1970]
            args += chunk.map { $0 as (any SQLConvertible)? }
            let rows: [(String, EPGProgram)] = try db.read { c in try c.query(sql, args) { ($0.string(10), Self.map($0)) } }
            for (cid, p) in rows { out[cid, default: []].append(p) }
        }
        return out
    }

    func program(id: Int64) throws -> EPGProgram? {
        try db.read { try $0.query(Self.programSelect + " FROM epg_programs p WHERE p.id=?", [id], Self.map).first }
    }

    func guideCoverage(sourceID: UUID) throws -> (channels: Int, programs: Int, mapped: Int, lastUpdate: Date?) {
        try db.read { c in
            (try c.scalarInt("SELECT COUNT(*) FROM epg_channels WHERE source_id=?", [sourceID]),
             try c.scalarInt("""
                SELECT COUNT(*) FROM epg_programs p JOIN epg_state st ON st.source_id=p.source_id AND st.import_id=p.import_id
                WHERE p.source_id=?
                """, [sourceID]),
             try c.scalarInt("SELECT COUNT(*) FROM epg_channel_mappings WHERE source_id=?", [sourceID]),
             try c.queryOne("SELECT updated_at FROM epg_state WHERE source_id=?", [sourceID]) { $0.date(0) })
        }
    }

    func guideChannels(sourceID: UUID) throws -> [(id: String, name: String)] {
        try db.read { c in
            try c.query("SELECT xmltv_id, COALESCE(display_name, xmltv_id) FROM epg_channels WHERE source_id=? ORDER BY display_name COLLATE NOCASE", [sourceID]) {
                (id: $0.string(0), name: $0.string(1))
            }
        }
    }

    func purge(before: Date) throws {
        try db.write { c in
            try c.execute("DELETE FROM epg_programs WHERE end_time < ?", [before])
            try c.execute("DELETE FROM epg_programs WHERE import_id != COALESCE((SELECT import_id FROM epg_state st WHERE st.source_id=epg_programs.source_id), -1)")
        }
    }

    func mappedChannelIDs() throws -> Set<String> {
        try db.read { Set(try $0.query("SELECT channel_id FROM epg_channel_mappings") { $0.string(0) }) }
    }

    func searchPrograms(term: String, sourceID: UUID?, from: Date, limit: Int) throws -> [(program: EPGProgram, channelID: String, channelName: String)] {
        let words = MetadataNormalizer.normalize(term).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var sql = Self.programSelect + ", m.channel_id, COALESCE(o.display_name, c.name)" + """

            FROM epg_programs p
            JOIN epg_state st ON st.source_id = p.source_id AND st.import_id = p.import_id
            JOIN epg_channel_mappings m ON m.source_id = p.source_id AND m.xmltv_channel_id = p.xmltv_channel_id
            JOIN channels c ON c.id = m.channel_id
            LEFT JOIN metadata_overrides o ON o.item_id = c.id
            WHERE p.end_time > ?
            """
        var args: [(any SQLConvertible)?] = [from.timeIntervalSince1970]
        if let sourceID { sql += " AND p.source_id = ?"; args.append(sourceID) }
        for w in words { sql += " AND p.title LIKE ? ESCAPE '\\'"; args.append("%" + w.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%") }
        sql += " ORDER BY p.start_time LIMIT ?"; args.append(limit)
        return try db.read { c in try c.query(sql, args) { (Self.map($0), $0.string(10), $0.string(11)) } }
    }
}
