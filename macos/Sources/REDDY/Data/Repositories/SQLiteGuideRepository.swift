import Foundation

/// Guide sources, per-source diagnostics, the channel-to-guide map and the manual overrides (SchemaV25).
struct SQLiteGuideRepository: Sendable {
    let db: DatabaseManager

    struct SourceRow: Sendable, Equatable {
        var id: String
        var kind: GuideSourceKind
        var name: String
        var urlRef: String?
        var url: String?
        var enabled: Bool
        var priority: Int
        var refreshHours: Int
        var tz: GuideTimeZoneMode
        var offsetMinutes: Int
        var lastAttempt: Date?
        var lastSuccess: Date?
        var etag: String?
        var lastModified: String?
        var status: String
        var error: String?
        var channelsCount: Int
        var programmesCount: Int
        var windowEnd: Date?
        var failures = 0
    }

    private static let cols = "id, kind, name, url_ref, url, enabled, priority, refresh_hours, tz_mode, tz_default, offset_minutes, last_attempt, last_success, etag, last_modified, status, error, channels_count, programmes_count, window_end"
    private static func row(_ r: Row) -> SourceRow {
        SourceRow(id: r.string(0), kind: GuideSourceKind(rawValue: r.string(1)) ?? .userXMLTV, name: r.string(2), urlRef: r.optString(3), url: r.optString(4), enabled: r.bool(5), priority: r.int(6),
                  refreshHours: r.int(7), tz: GuideTimeZoneMode(stored: r.optString(8), zone: r.optString(9)), offsetMinutes: r.int(10), lastAttempt: r.optDate(11), lastSuccess: r.optDate(12),
                  etag: r.optString(13), lastModified: r.optString(14), status: r.string(15), error: r.optString(16), channelsCount: r.int(17), programmesCount: r.int(18), windowEnd: r.optDate(19))
    }

    func sources() throws -> [SourceRow] {
        try db.read { c in try c.query("SELECT \(Self.cols) FROM guide_sources ORDER BY priority, name", [], Self.row) }
    }
    func source(_ id: String) throws -> SourceRow? {
        try db.read { c in try c.queryOne("SELECT \(Self.cols) FROM guide_sources WHERE id=?", [id], Self.row) }
    }

    /// A user guide. `url` is kept only when it has no secret; otherwise store the address elsewhere (Keychain) and pass its reference.
    func add(_ s: SourceRow, now: Date = Date()) throws {
        let zone: String? = { if case .local(let z) = s.tz { return z }; return nil }()
        try db.write { c in
            try c.execute("""
            INSERT INTO guide_sources(id, kind, name, url_ref, url, enabled, priority, refresh_hours, tz_mode, tz_default, offset_minutes, created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, url_ref=excluded.url_ref, url=excluded.url, enabled=excluded.enabled, priority=excluded.priority, refresh_hours=excluded.refresh_hours,
                tz_mode=excluded.tz_mode, tz_default=excluded.tz_default, offset_minutes=excluded.offset_minutes
            """, [s.id, s.kind.rawValue, s.name, s.urlRef, s.url, s.enabled, s.priority, max(s.refreshHours, s.kind.minRefreshHours), s.tz.storedValue, zone, s.offsetMinutes, now])
        }
    }
    func setEnabled(_ id: String, _ on: Bool) throws { try db.write { try $0.execute("UPDATE guide_sources SET enabled=? WHERE id=?", [on, id]) } }
    func remove(_ id: String) throws {
        try db.write { c in
            try c.execute("DELETE FROM guide_programmes WHERE guide_source_id=?", [id])
            try c.execute("DELETE FROM guide_channels WHERE guide_source_id=?", [id])
            try c.execute("DELETE FROM channel_guide_map WHERE guide_source_id=? AND locked=0", [id])
            try c.execute("DELETE FROM guide_import_state WHERE guide_source_id=?", [id])
            try c.execute("DELETE FROM guide_diagnostics WHERE guide_source_id=?", [id])
            try c.execute("DELETE FROM guide_sources WHERE id=?", [id])
        }
    }

    /// A playlist's guide registered as `provider:<id>`; the address stays in `sources.epg_url`.
    func ensureProviderRow(sourceID: UUID, now: Date = Date()) throws {
        try db.write { c in
            try c.execute("INSERT OR IGNORE INTO guide_sources(id, kind, name, priority, created_at) SELECT ?, 'provider', name, 10, ? FROM sources WHERE id=?", ["provider:" + sourceID.uuidString.lowercased(), now, sourceID])
        }
    }

    /// Registers the guide of every playlist that has one: an address on the playlist, an Xtream login (its guide is `xmltv.php`), or a guide that was already downloaded.
    func ensureProviderRows(now: Date = Date()) throws {
        try db.write { c in
            try c.execute("""
            INSERT OR IGNORE INTO guide_sources(id, kind, name, priority, enabled, created_at)
            SELECT 'provider:' || id, 'provider', name, 10, enabled, ? FROM sources
            WHERE (epg_url IS NOT NULL AND epg_url != '') OR type='xtream' OR id IN (SELECT source_id FROM epg_state)
            """, [now])
        }
    }

    // MARK: diagnostics

    struct FetchOutcome: Sendable {
        var outcome: String
        var httpStatus: Int? = nil
        var bytes: Int64? = nil
        var stats = GuideReadStats()
        var mapped = 0
        var error: String? = nil
    }

    func recordFetch(sourceID: String, _ o: FetchOutcome, now: Date = Date(), validators: GuideValidators? = nil) throws {
        let ok = o.outcome == "ok" || o.outcome == "notModified"
        try db.write { c in
            try c.execute("""
            INSERT INTO guide_diagnostics(guide_source_id, last_attempt, last_success, outcome, http_status, bytes, channels, mapped, programmes_seen, programmes_kept, dropped_past, dropped_future, dropped_invalid, file_first_start, file_last_stop, truncated, error)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(guide_source_id) DO UPDATE SET last_attempt=excluded.last_attempt, last_success=CASE WHEN ? THEN excluded.last_success ELSE guide_diagnostics.last_success END,
                outcome=excluded.outcome, http_status=excluded.http_status, bytes=excluded.bytes,
                channels=CASE WHEN excluded.outcome='notModified' THEN guide_diagnostics.channels ELSE excluded.channels END,
                mapped=CASE WHEN excluded.outcome='notModified' THEN guide_diagnostics.mapped ELSE excluded.mapped END,
                programmes_seen=CASE WHEN excluded.outcome='notModified' THEN guide_diagnostics.programmes_seen ELSE excluded.programmes_seen END,
                programmes_kept=CASE WHEN excluded.outcome='notModified' THEN guide_diagnostics.programmes_kept ELSE excluded.programmes_kept END,
                dropped_past=CASE WHEN excluded.outcome='notModified' THEN guide_diagnostics.dropped_past ELSE excluded.dropped_past END,
                dropped_future=CASE WHEN excluded.outcome='notModified' THEN guide_diagnostics.dropped_future ELSE excluded.dropped_future END,
                dropped_invalid=CASE WHEN excluded.outcome='notModified' THEN guide_diagnostics.dropped_invalid ELSE excluded.dropped_invalid END,
                file_first_start=CASE WHEN excluded.outcome='notModified' THEN guide_diagnostics.file_first_start ELSE excluded.file_first_start END,
                file_last_stop=CASE WHEN excluded.outcome='notModified' THEN guide_diagnostics.file_last_stop ELSE excluded.file_last_stop END,
                truncated=excluded.truncated, error=excluded.error
            """, [sourceID, now, ok ? now : nil, o.outcome, o.httpStatus, o.bytes, o.stats.channels, o.mapped, o.stats.programmesSeen, o.stats.programmesKept, o.stats.droppedPast, o.stats.droppedFuture,
                  o.stats.droppedInvalid, o.stats.firstStart, o.stats.lastStop, o.stats.truncated, o.error.map { CredentialRedactor.redact($0) }, ok])
            try c.execute("""
            UPDATE guide_sources SET last_attempt=?, last_success=CASE WHEN ? THEN ? ELSE last_success END, status=?, error=?,
                etag=COALESCE(?, etag), last_modified=COALESCE(?, last_modified),
                channels_count=CASE WHEN ?='ok' THEN ? ELSE channels_count END, programmes_count=CASE WHEN ?='ok' THEN ? ELSE programmes_count END
            WHERE id=?
            """, [now, ok, now, o.outcome, o.error.map { CredentialRedactor.redact($0) }, validators?.etag, validators?.lastModified, o.outcome, o.stats.channels, o.outcome, o.stats.programmesKept, sourceID])
        }
    }

    /// One row per source for Settings: the last fetch plus what the guide tables hold right now (so a guide that is empty today is shown as empty even if the last fetch looked fine).
    func diagnostics(now: Date = Date()) throws -> [GuideSourceDiagnostics] {
        try db.read { c in
            let src = try c.query("SELECT id, kind, name, enabled, refresh_hours, url FROM guide_sources ORDER BY priority, name") { r in (r.string(0), GuideSourceKind(rawValue: r.string(1)) ?? .userXMLTV, r.string(2), r.bool(3), r.int(4), r.optString(5)) }
            return try src.map { (id, kind, name, enabled, hours, url) in
                var d = GuideSourceDiagnostics(sourceID: id, name: name, kind: kind, host: url.flatMap { URL(string: $0)?.host }, enabled: enabled, refreshInterval: TimeInterval(hours) * 3600)
                _ = try c.queryOne("SELECT last_attempt, last_success, outcome, http_status, bytes, channels, mapped, programmes_seen, programmes_kept, dropped_past, dropped_future, dropped_invalid, file_first_start, file_last_stop, truncated, error FROM guide_diagnostics WHERE guide_source_id=?", [id]) { r in
                    d.lastAttempt = r.optDate(0); d.lastSuccess = r.optDate(1); d.outcome = r.string(2); d.httpStatus = r.optInt(3); d.bytes = r.optInt(4).map(Int64.init)
                    d.channelsInFile = r.int(5); d.channelsMapped = r.int(6); d.programmesSeen = r.int(7); d.programmesKept = r.int(8); d.droppedPast = r.int(9); d.droppedFuture = r.int(10)
                    d.droppedInvalid = r.int(11); d.fileFirstStart = r.optDate(12); d.fileLastStop = r.optDate(13); d.truncated = r.bool(14); d.error = r.optString(15)
                    return 0
                }
                // Live counts: the playlist guide tables for providers, the new tables for the rest.
                if id.hasPrefix("provider:") {
                    let sid = String(id.dropFirst("provider:".count))
                    let st = try c.queryOne("SELECT import_id, updated_at FROM epg_state WHERE source_id=?", [sid]) { ($0.int(0), $0.date(1)) }
                    if let st {
                        let r = try c.queryOne("SELECT COUNT(*), MAX(end_time) FROM epg_programs WHERE source_id=? AND import_id=?", [sid, st.0]) { ($0.int(0), $0.optDate(1)) }
                        d.storedProgrammes = r?.0 ?? 0; d.storedWindowEnd = r?.1
                        if d.lastSuccess == nil { d.lastSuccess = st.1 }
                        if d.lastAttempt == nil { d.lastAttempt = st.1; d.outcome = d.storedProgrammes > 0 ? "ok" : "empty" }
                        if d.channelsInFile == 0 { d.channelsInFile = try c.scalarInt("SELECT COUNT(*) FROM epg_channels WHERE source_id=?", [sid]) }
                    }
                    d.channelsMapped = try c.scalarInt("SELECT COUNT(*) FROM epg_channel_mappings WHERE source_id=?", [sid])
                } else {
                    let st = try c.queryOne("SELECT import_id FROM guide_import_state WHERE guide_source_id=?", [id]) { $0.int(0) }
                    if let st {
                        let r = try c.queryOne("SELECT COUNT(*), MAX(end_time) FROM guide_programmes WHERE guide_source_id=? AND import_id=?", [id, st]) { ($0.int(0), $0.optDate(1)) }
                        d.storedProgrammes = r?.0 ?? 0; d.storedWindowEnd = r?.1
                    }
                    d.channelsMapped = try c.scalarInt("SELECT COUNT(*) FROM channel_guide_map WHERE guide_source_id=?", [id])
                }
                return d
            }
        }
    }

    // MARK: map

    /// Replaces the automatic rows of one guide source and keeps every locked (manual) row.
    func saveMappings(guideSourceID: String, channelIDs: Set<String>, matches: [(channelID: String, match: GuideMatch)], now: Date = Date()) throws {
        try db.write { c in
            try c.execute("DELETE FROM channel_guide_map WHERE guide_source_id=? AND locked=0", [guideSourceID])
            let st = try c.prepare("INSERT OR IGNORE INTO channel_guide_map(channel_id, guide_source_id, xmltv_id, method, confidence, reason, locked, updated_at) VALUES(?,?,?,?,?,?,0,?)")
            for m in matches where m.match.guideSourceID == guideSourceID && channelIDs.contains(m.channelID) {
                try st.run([m.channelID, guideSourceID, m.match.xmltvID, m.match.method.rawValue, m.match.confidence, m.match.reason, now])
            }
        }
    }
    /// A manual choice: stored locked, never recomputed.
    func setUserMapping(channelID: String, guideSourceID: String, xmltvID: String?, now: Date = Date()) throws {
        try db.write { c in
            try c.execute("DELETE FROM channel_guide_map WHERE channel_id=? AND guide_source_id=?", [channelID, guideSourceID])
            if let xmltvID {
                try c.execute("INSERT INTO channel_guide_map(channel_id, guide_source_id, xmltv_id, method, confidence, reason, locked, updated_at) VALUES(?,?,?,?,1,'chosen by you',1,?)", [channelID, guideSourceID, xmltvID, GuideMatchMethod.user.rawValue, now])
            }
        }
    }
    /// Channels of the guides the person added (and enabled), for the manual match sheet. Public-database channels are not guide channels and are never listed.
    func addedGuideChannels(limit: Int = 20000) throws -> [(source: String, id: String, name: String)] {
        try db.read { c in try c.query("SELECT g.guide_source_id, g.xmltv_id, COALESCE(g.display_name, g.xmltv_id) FROM guide_channels g JOIN guide_sources s ON s.id=g.guide_source_id WHERE s.enabled=1 AND s.kind='userXMLTV' ORDER BY g.display_name COLLATE NOCASE LIMIT ?", [limit]) { (source: $0.string(0), id: $0.string(1), name: $0.string(2)) } }
    }
    func clearUserMappings(channelID: String) throws { try db.write { try $0.execute("DELETE FROM channel_guide_map WHERE channel_id=? AND locked=1", [channelID]) } }

    func userMappings() throws -> [String: GuideMatch] {
        let rows = try db.read { c in try c.query("SELECT channel_id, guide_source_id, xmltv_id FROM channel_guide_map WHERE locked=1") { ($0.string(0), GuideMatch(guideSourceID: $0.string(1), xmltvID: $0.string(2), method: .user, confidence: 1, reason: "chosen by you")) } }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }
}
