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
            }
            throw error
        }
    }

    /// Synchronous core, also used directly by tests.
    func importFile(_ file: URL, sourceID: UUID) throws -> EPGSyncResult {
        let sid = sourceID.uuidString.lowercased()
        let importID = Int(Date().timeIntervalSince1970 * 1000)
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
        guard stats.programmesKept > 0 || stats.channels > 0 else {
            try? db.write { try $0.execute("DELETE FROM epg_programs WHERE source_id=? AND import_id=?", [sid, importID]) }
            throw SourceError.invalidResponse("The guide contained no programmes.")
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
        return EPGSyncResult(skipped: false, channels: stats.channels, programmes: stats.programmesKept, mapped: mapped)
    }
}


/// A value shared between threads.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    var value: T { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
