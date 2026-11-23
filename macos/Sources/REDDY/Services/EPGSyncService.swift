import Foundation

struct EPGSyncResult: Sendable {
    var skipped: Bool
    var channels: Int
    var programmes: Int
    var mapped: Int
}

/// Downloads, decompresses, stream-parses and indexes an XMLTV guide.
/// New programmes are written under a fresh `import_id`; readers only see the old import until the final switch,
/// so a failed or cancelled import never leaves a half-updated guide.
final class EPGSyncService: Sendable {
    private static let lastImportID = ImportIDBox()
    /// Milliseconds since 1970, but always above the one before.
    static func nextImportID() -> Int { lastImportID.next(Int(Date().timeIntervalSince1970 * 1000)) }

    let db: DatabaseManager
    let catalog: CatalogRepository
    let http: HTTPClient
    let windowDays: Int
    /// Minutes to move this playlist's guide by, chosen in Settings (providers' guides are often hours off).
    private let shiftMinutes: @Sendable (UUID) -> Int
    /// Changed from Settings while a sync may be running, so it lives behind a lock.
    private struct Tuning { var refreshInterval: TimeInterval?; var pastHours: Double }
    private let tuning: LockedBox<Tuning>
    /// Minimum time between automatic guide downloads. nil means "manual": only an explicit refresh downloads.
    var refreshInterval: TimeInterval? { tuning.value.refreshInterval }
    var pastHours: Double { tuning.value.pastHours }

    init(db: DatabaseManager, catalog: CatalogRepository, http: HTTPClient, refreshInterval: TimeInterval? = 6 * 3600, windowDays: Int = 7, pastHours: Double = 3,
         shiftMinutes: @escaping @Sendable (UUID) -> Int = { _ in 0 }) {
        self.db = db; self.catalog = catalog; self.http = http; self.shiftMinutes = shiftMinutes
        self.windowDays = windowDays
        self.tuning = LockedBox(Tuning(refreshInterval: refreshInterval, pastHours: pastHours))
    }

    /// Applies the Settings choices. Retention only affects the next import; nothing already stored is removed early.
    func configure(refreshInterval: TimeInterval?, pastRetentionDays: Int) {
        tuning.value = Tuning(refreshInterval: refreshInterval, pastHours: max(3, Double(pastRetentionDays) * 24))
    }

    @discardableResult
    func sync(source: PlaylistSource, location: URL?, force: Bool = false, headers: SourceHeaders = SourceHeaders()) async throws -> EPGSyncResult {
        guard let location else { return EPGSyncResult(skipped: true, channels: 0, programmes: 0, mapped: 0) }
        let state = try catalog.syncStates(sourceID: source.id).first { $0.scope == "epg" }
        if !force {
            guard let interval = refreshInterval else { return EPGSyncResult(skipped: true, channels: 0, programmes: 0, mapped: 0) }       // manual
            if let last = state?.lastSuccess, Date().timeIntervalSince(last) < interval { return EPGSyncResult(skipped: true, channels: 0, programmes: 0, mapped: 0) }
        }
        do {
            let download = try await XMLTVClient(http: http).fetch(location, etag: force ? nil : state?.etag, lastModified: force ? nil : state?.lastModified, headers: headers)
            guard let file = download.xmlFile else {   // 304 Not Modified
                try catalog.recordSync(sourceID: source.id, scope: "epg", success: true, itemCount: nil, etag: download.etag, lastModified: download.lastModified, error: nil)
                return EPGSyncResult(skipped: true, channels: 0, programmes: 0, mapped: 0)
            }
            defer { try? FileManager.default.removeItem(at: file) }

            let result = try await Task.detached(priority: .utility) { [self] in
                try importFile(file, sourceID: source.id)
            }.value
            try catalog.recordSync(sourceID: source.id, scope: "epg", success: true, itemCount: result.programmes,
                                   etag: download.etag, lastModified: download.lastModified, error: nil)
            return result
        } catch {
            if !(error is CancellationError) {
                try? catalog.recordSync(sourceID: source.id, scope: "epg", success: false, itemCount: nil, etag: nil, lastModified: nil,
                                        error: CredentialRedactor.redact(error.localizedDescription))
                if !error.localizedDescription.hasPrefix("The guide contained no programmes"), (try? SQLiteGuideRepository(db: db).ensureProviderRow(sourceID: source.id)) != nil {
                    try? SQLiteGuideRepository(db: db).recordFetch(sourceID: "provider:" + source.id.uuidString.lowercased(), .init(outcome: "failed", error: error.localizedDescription))
                }
            }
            throw error
        }
    }

    /// Settings > Guide reads these (what the file held, what was skipped, why a guide is empty). Never fails the import.
    private func recordDiagnostics(_ sid: String, outcome: String, stats: XMLTVStats, mapped: Int, error: String?) {
        var r = GuideReadStats(channels: stats.channels, programmesSeen: stats.programmesSeen, programmesKept: stats.programmesKept, droppedPast: stats.droppedPast, droppedFuture: stats.droppedFuture,
                               droppedInvalid: stats.droppedInvalid, truncated: stats.truncated)
        r.firstStart = stats.firstStart; r.lastStop = stats.lastStop
        let repo = SQLiteGuideRepository(db: db)
        if let id = UUID(uuidString: sid) { try? repo.ensureProviderRow(sourceID: id) }
        try? repo.recordFetch(sourceID: "provider:" + sid, .init(outcome: outcome, stats: r, mapped: mapped, error: error))
    }

    /// Synchronous core, also used directly by tests.
    func importFile(_ file: URL, sourceID: UUID) throws -> EPGSyncResult {
        let sid = sourceID.uuidString.lowercased()
        let importID = Self.nextImportID()          // never the same as an earlier import, even within one millisecond (a failed import deletes only its own rows)
        let now = Date()
        let shift = TimeInterval(shiftMinutes(sourceID) * 60)
        // The guide's own times are read in the window shifted the other way, then stored moved by `shift`.
        let window = now.addingTimeInterval(-pastHours * 3600 - shift)...now.addingTimeInterval(TimeInterval(windowDays) * 86400 - shift)

        var guideChannels: [XMLTVChannel] = []
        let ins = "INSERT INTO epg_programs(source_id, xmltv_channel_id, start_time, end_time, title, subtitle, description, category, image_url, import_id) VALUES(?,?,?,?,?,?,?,?,?,?)"
        let parser = XMLTVParser(window: window, onChannel: { guideChannels.append($0) }, onBatch: { [db] batch in
            try db.write { c in
                let st = try c.prepare(ins)
                for p in batch {
                    try st.run([sid, p.channel, p.start.addingTimeInterval(shift), p.stop.addingTimeInterval(shift), p.title, p.subtitle, p.description, p.category, p.icon, importID])
                }
            }
        })
        let stats: XMLTVStats
        do { stats = try parser.parse(fileURL: file) }
        catch {
            // Remove whatever this failed import wrote; the previous guide stays active.
            try? db.write { try $0.execute("DELETE FROM epg_programs WHERE source_id=? AND import_id=?", [sid, importID]) }
            throw error
        }
        guard stats.programmesKept > 0 else {
            // A guide that keeps no programmes never replaces a working one; the diagnostics say why (all past, wrong times, channels only).
            try? db.write { try $0.execute("DELETE FROM epg_programs WHERE source_id=? AND import_id=?", [sid, importID]) }
            recordDiagnostics(sid, outcome: "empty", stats: stats, mapped: 0, error: stats.programmesSeen == 0 ? "The guide contained no programmes." : "The guide contained no programmes for the days kept.")
            throw SourceError.invalidResponse(stats.programmesSeen == 0 ? "The guide contained no programmes." : "The guide contained no programmes for the days kept.")
        }

        // Atomic switch to the new import.
        try db.write { c in
            try c.execute("DELETE FROM epg_channels WHERE source_id=?", [sid])
            let st = try c.prepare("INSERT OR REPLACE INTO epg_channels(source_id, xmltv_id, display_name, normalized_name, icon_url) VALUES(?,?,?,?,?)")
            for ch in guideChannels {
                let name = ch.displayNames.first
                try st.run([sid, ch.id, name, name.map(MetadataNormalizer.normalize), ch.icon])
            }
            try c.execute("INSERT OR REPLACE INTO epg_state(source_id, import_id, updated_at) VALUES(?,?,?)", [sid, importID, now])
            try c.execute("DELETE FROM epg_programs WHERE source_id=? AND import_id != ?", [sid, importID])
        }
        let mapped = try XMLTVChannelMatcher(db: db).rebuild(sourceID: sourceID).mapped
        recordDiagnostics(sid, outcome: "ok", stats: stats, mapped: mapped, error: nil)
        return EPGSyncResult(skipped: false, channels: stats.channels, programmes: stats.programmesKept, mapped: mapped)
    }
}


private final class ImportIDBox: @unchecked Sendable {
    private let lock = NSLock(); private var last = 0
    func next(_ ms: Int) -> Int { lock.withLock { last = max(ms, last + 1); return last } }
}
