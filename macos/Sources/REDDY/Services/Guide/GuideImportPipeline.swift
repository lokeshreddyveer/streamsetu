import Foundation

/// The shared import: fetch (adapter), open (decoder), stream into `guide_programmes` under a fresh import id, switch atomically, record diagnostics.
/// An import that keeps no programmes never replaces a working guide: the old one stays and the diagnostics say why the new one was useless.
struct GuideImportPipeline: Sendable {
    let db: DatabaseManager
    var repo: SQLiteGuideRepository { SQLiteGuideRepository(db: db) }

    struct Result: Sendable, Equatable { var outcome: String; var stats: GuideReadStats; var error: String? }

    func run(_ source: any EPGSource, row: SQLiteGuideRepository.SourceRow?, windowDays: Int = 3, pastHours: Double = 3, budget: GuideBudget = GuideBudget(), now: Date = Date()) async -> Result {
        let sid = source.id
        var validators: GuideValidators?
        if let row { validators = GuideValidators(etag: row.etag, lastModified: row.lastModified) }
        var fetched: GuideFetched?
        do {
            let f = try await source.fetch(since: validators, budget: budget)
            fetched = f
            defer { if let file = f.file { try? FileManager.default.removeItem(at: file) } }
            if f.notModified {
                try repo.recordFetch(sourceID: sid, .init(outcome: "notModified", httpStatus: 304), now: now, validators: f.validators)
                return Result(outcome: "notModified", stats: GuideReadStats(), error: nil)
            }
            let stream = try source.open(f)
            let offset = TimeInterval((row?.offsetMinutes ?? 0) * 0)       // shifts are applied at read time; nothing is baked in
            let window = now.addingTimeInterval(-pastHours * 3600 - offset)...now.addingTimeInterval(TimeInterval(windowDays) * 86400)
            let importID = EPGSyncService.nextImportID()
            var channels: [GuideChannelRecord] = []
            let ins = "INSERT INTO guide_programmes(guide_source_id, xmltv_id, start_time, end_time, title, subtitle, description, category, image_url, lang, episode_num, content_rating, import_id) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)"
            let stats: GuideReadStats
            do {
                stats = try stream.read(window: window, timeZone: row?.tz ?? .automatic, limits: budget.limits, onChannel: { channels.append($0) }, onBatch: { [db] batch in
                    try db.write { c in
                        let st = try c.prepare(ins)
                        for p in batch { try st.run([sid, p.channel, p.start, p.stop, p.title, p.subtitle, p.description, p.category, p.icon, p.lang, p.episodeNum, p.rating, importID]) }
                    }
                })
            } catch {
                try? db.write { try $0.execute("DELETE FROM guide_programmes WHERE guide_source_id=? AND import_id=?", [sid, importID]) }
                throw error
            }
            let wantsProgrammes = source.capabilities.contains(.programmes)
            if wantsProgrammes && stats.programmesKept == 0 {
                try? db.write { try $0.execute("DELETE FROM guide_programmes WHERE guide_source_id=? AND import_id=?", [sid, importID]) }
                let msg = stats.programmesSeen == 0 ? "The guide contained no programmes." : "The guide contained no programmes for the days kept."
                try repo.recordFetch(sourceID: sid, .init(outcome: "empty", httpStatus: f.status, bytes: f.bytes, stats: stats, error: msg), now: now, validators: f.validators)
                return Result(outcome: "empty", stats: stats, error: msg)
            }
            try db.write { c in
                try c.execute("DELETE FROM guide_channels WHERE guide_source_id=?", [sid])
                let st = try c.prepare("INSERT OR REPLACE INTO guide_channels(guide_source_id, xmltv_id, display_name, normalized_name, icon_url, lang, country_hint) VALUES(?,?,?,?,?,?,?)")
                for ch in channels { try st.run([sid, ch.id, ch.displayNames.first, ch.displayNames.first.map(MetadataNormalizer.normalize), ch.icon, ch.lang, ch.countryHint]) }
                if wantsProgrammes {
                    try c.execute("INSERT OR REPLACE INTO guide_import_state(guide_source_id, import_id, updated_at) VALUES(?,?,?)", [sid, importID, now])
                    try c.execute("DELETE FROM guide_programmes WHERE guide_source_id=? AND import_id != ?", [sid, importID])
                    try c.execute("UPDATE guide_sources SET window_start=?, window_end=? WHERE id=?", [stats.firstStart, stats.lastStop, sid])
                }
            }
            try repo.recordFetch(sourceID: sid, .init(outcome: "ok", httpStatus: f.status, bytes: f.bytes, stats: stats), now: now, validators: f.validators)
            return Result(outcome: "ok", stats: stats, error: nil)
        } catch {
            if error is CancellationError { return Result(outcome: "cancelled", stats: GuideReadStats(), error: nil) }
            let msg = CredentialRedactor.redact(error.localizedDescription)
            try? repo.recordFetch(sourceID: sid, .init(outcome: "failed", httpStatus: fetched?.status, error: msg), now: now)
            return Result(outcome: "failed", stats: GuideReadStats(), error: msg)
        }
    }
}
