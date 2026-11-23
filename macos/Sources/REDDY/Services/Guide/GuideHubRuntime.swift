import Foundation

/// Mapping of the library to one guide source, run after that source changed. Locked and restricted channels are skipped; manual choices are kept.
struct GuideMappingRunner: Sendable {
    let db: DatabaseManager

    @discardableResult
    func rebuild(guideSourceID: String, priority: Int = 20) throws -> Int {
        let restricted = try ChannelEnrichmentService(db: db).restrictedIDs()
        let locks = try SQLiteGuideRepository(db: db).userMappings()
        let guide = try db.read { c in try c.query("SELECT xmltv_id, COALESCE(display_name, xmltv_id), lang, country_hint FROM guide_channels WHERE guide_source_id=?", [guideSourceID]) {
            GuideMapGuideChannel(sourceID: guideSourceID, xmltvID: $0.string(0), names: [$0.string(1)], country: $0.optString(3), language: $0.optString(2), priority: priority) } }
        let channels = try db.read { c in try c.query("SELECT id, name, epg_id, provider_id, country, language FROM channels WHERE is_primary=1") {
            GuideMapChannel(id: $0.string(0), name: $0.string(1), tvgID: $0.optString(2), providerID: $0.optString(3), country: $0.optString(4), language: $0.optString(5), ownGuideSource: guideSourceID) } }
        let input = channels.map { ch -> GuideMapChannel in
            var c = ch; c.restricted = restricted.contains(ch.id); if let l = locks[ch.id], l.guideSourceID == guideSourceID { c.userLock = l }; return c
        }
        let results = GuideMappingEngine.map(channels: input, guide: guide)
        let matches = results.compactMap { r in r.match.map { (r.channelID, $0) } }.filter { $0.1.method != .user }
        try SQLiteGuideRepository(db: db).saveMappings(guideSourceID: guideSourceID, channelIDs: Set(channels.map(\.id)), matches: matches)
        return matches.count
    }
}

private final class HubBox: @unchecked Sendable {
    static let shared = HubBox()
    private let lock = NSLock(); private var running = false
    func begin() -> Bool { lock.withLock { if running { return false }; running = true; return true } }
    func end() { lock.withLock { running = false } }
}

extension AppContainer {
    var guideManager: GuideSourceManager { GuideSourceManager(db: db, credentials: credentials, fetcher: HTTPGuideFileFetcher(http: http)) }

    static var guideHubDirectory: URL { StorageService.applicationSupport.appendingPathComponent("GuideHub/iptvorg", isDirectory: true) }

    /// One pass of the guide hub: guides the person added (and the public channel database when enrichment is on) that are due, then mapping and enrichment.
    /// Playlist guides keep going through `EPGSyncService`. Safe to call often: it does nothing when nothing is due, and only one run at a time.
    @discardableResult
    func runGuideHub(force: Bool = false, now: Date = Date()) async -> [String: GuideImportPipeline.Result] {
        GuideLogoOverlay.reload(db: db)
        guard HubBox.shared.begin() else { return [:] }
        defer { HubBox.shared.end(); GuideLogoOverlay.reload(db: db) }
        let enrich = GuideSettingsModel.enrichmentEnabled(settings.defaultsStore)
        let mgr = guideManager
        let repo = SQLiteGuideRepository(db: db)
        let database = IPTVOrgDatabase(directory: Self.guideHubDirectory, fetcher: mgr.fetcher)
        let indexSource = enrich ? IPTVOrgIndexSource(database: database) : nil
        if enrich, (try? repo.source("iptvorg-db")) == nil {
            try? repo.add(.init(id: "iptvorg-db", kind: .publicIndex, name: "Public channel database", urlRef: nil, url: nil, enabled: true, priority: 30, refreshHours: 24, tz: .automatic, offsetMinutes: 0,
                                lastAttempt: nil, lastSuccess: nil, etag: nil, lastModified: nil, status: "idle", error: nil, channelsCount: 0, programmesCount: 0, windowEnd: nil))
        }
        if !enrich { try? repo.setEnabled("iptvorg-db", false) } else { try? repo.setEnabled("iptvorg-db", true) }
        let rows = ((try? repo.sources()) ?? []).filter { $0.kind != .provider }
        let registry = GuideSourceRegistry(rows: rows, fetcher: mgr.fetcher, resolveURL: { mgr.resolveURL($0) }, publicIndex: indexSource)
        let results = (try? await GuideRefreshRunner(db: db, registry: registry).run(conditions: .init(now: now, onUnmeteredNetwork: true, wifiOnly: false, force: force))) ?? [:]
        for (id, r) in results where r.outcome == "ok" && id != "iptvorg-db" { _ = try? GuideMappingRunner(db: db).rebuild(guideSourceID: id) }
        if enrich, results["iptvorg-db"]?.outcome == "ok" || force, let index = try? await database.loadIndex() {
            _ = try? ChannelEnrichmentService(db: db).apply(index: index)
        }
        return results
    }
}
