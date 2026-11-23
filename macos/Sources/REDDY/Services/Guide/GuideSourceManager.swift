import Foundation

/// Adding, testing, removing and refreshing guide sources. A user guide address is kept in the credential store (it may carry a token); the database holds only a reference and the host.
struct GuideSourceManager: Sendable {
    let db: DatabaseManager
    let credentials: any CredentialStore
    let fetcher: any GuideFileFetching

    struct TestReport: Sendable, Equatable { var valid: Bool; var channels = 0; var programmes = 0; var first: Date?; var last: Date?; var gzip = false; var message: String }

    enum AddError: Error, Equatable, LocalizedError {
        case badAddress
        var errorDescription: String? { "Enter a web address that starts with https:// (or http://)." }
    }

    static func parse(_ raw: String) throws -> URL {
        guard let u = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), let s = u.scheme?.lowercased(), s == "https" || s == "http", u.host?.isEmpty == false else { throw AddError.badAddress }
        return u
    }

    /// Reads the first part of the guide and says what it is. Never lists channel names.
    func test(_ raw: String) async -> TestReport {
        guard let url = try? Self.parse(raw) else { return TestReport(valid: false, message: AddError.badAddress.localizedDescription) }
        do {
            let f = try await fetcher.get(url, etag: nil, lastModified: nil, maxBytes: GuideLimits.standard.maxWireBytes)
            guard let file = f.file else { return TestReport(valid: false, message: "The server returned nothing.") }
            defer { try? FileManager.default.removeItem(at: file) }
            var r = TestReport(valid: true, gzip: GzipInflater.isGzip(file), message: "")
            let stats = try XMLTVFileStream(file: file).read(window: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 4_000_000_000), timeZone: .automatic, limits: .standard, onChannel: { _ in }, onBatch: { _ in })
            r.channels = stats.channels; r.programmes = stats.programmesKept; r.first = stats.firstStart; r.last = stats.lastStop
            r.message = stats.programmesKept == 0 ? "A valid guide, but it holds no programmes." : "Valid guide: \(stats.channels) channels, \(stats.programmesKept) programmes."
            return r
        } catch { return TestReport(valid: false, message: CredentialRedactor.redact(error.localizedDescription)) }
    }

    @discardableResult
    func add(name: String, address: String, now: Date = Date()) throws -> String {
        let url = try Self.parse(address)
        let id = "user:" + UUID().uuidString.lowercased()
        try credentials.save(Credentials(url: url.absoluteString), ref: "guide." + id)
        try SQLiteGuideRepository(db: db).add(.init(id: id, kind: .userXMLTV, name: name.isEmpty ? (url.host ?? "Guide") : name, urlRef: "guide." + id, url: nil, enabled: true, priority: 20, refreshHours: 6, tz: .automatic, offsetMinutes: 0,
                                                    lastAttempt: nil, lastSuccess: nil, etag: nil, lastModified: nil, status: "idle", error: nil, channelsCount: 0, programmesCount: 0, windowEnd: nil), now: now)
        return id
    }
    func remove(_ id: String) throws {
        try? credentials.delete(ref: "guide." + id)
        try SQLiteGuideRepository(db: db).remove(id)
    }

    /// Provider guide addresses stay in `sources.epg_url`; user addresses come from the credential store.
    func resolveURL(_ row: SQLiteGuideRepository.SourceRow) -> URL? {
        switch row.kind {
        case .userXMLTV: return row.urlRef.flatMap { try? credentials.load(ref: $0)?.url }.flatMap(URL.init(string:))
        case .provider:
            let sid = String(row.id.dropFirst("provider:".count))
            return (try? db.read { c in try c.queryOne("SELECT epg_url FROM sources WHERE id=?", [sid]) { $0.optString(0) } })?.flatMap { $0 }.flatMap(URL.init(string:))
        default: return nil
        }
    }

    func registry(publicIndex: IPTVOrgIndexSource? = nil) throws -> GuideSourceRegistry {
        GuideSourceRegistry(rows: try SQLiteGuideRepository(db: db).sources(), fetcher: fetcher, resolveURL: { resolveURL($0) }, publicIndex: publicIndex)
    }

    /// "Refresh now" or the scheduled run; returns what each source did.
    @discardableResult
    func refresh(force: Bool, publicIndex: IPTVOrgIndexSource? = nil, onUnmetered: Bool = true, wifiOnly: Bool = false, now: Date = Date()) async throws -> [String: GuideImportPipeline.Result] {
        try await GuideRefreshRunner(db: db, registry: try registry(publicIndex: publicIndex)).run(conditions: .init(now: now, onUnmeteredNetwork: onUnmetered, wifiOnly: wifiOnly, force: force))
    }
}

/// What Settings > Guide shows. Plain data so the Mac and iPhone pages (and tests) read the same model.
struct GuideSettingsModel: Sendable {
    struct Row: Sendable, Equatable { var id: String; var title: String; var kind: GuideSourceKind; var host: String?; var enabled: Bool; var freshness: GuideFreshness; var summary: String; var findings: [GuideFinding] }
    var rows: [Row]
    var enrichmentEnabled: Bool
    var worst: GuideFreshnessLevel { rows.filter(\.enabled).map(\.freshness.level).max() ?? .fresh }

    static let enrichmentKey = "guide.enrichment.enabled"       // default on
    static func enrichmentEnabled(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: enrichmentKey) as? Bool ?? true }

    static func load(db: DatabaseManager, defaults: UserDefaults = .standard, now: Date = Date()) throws -> GuideSettingsModel {
        try? SQLiteGuideRepository(db: db).ensureProviderRows(now: now)
        let rows = try SQLiteGuideRepository(db: db).diagnostics(now: now).map { d -> Row in
            let f = GuideDiagnosisAdvisor.freshness(d, now: now)
            var text = GuideMessages.text[f.key] ?? f.key
            if let a = f.amount, let r = text.range(of: "%d") { text.replaceSubrange(r, with: String(a)) }
            return Row(id: d.sourceID, title: d.name, kind: d.kind, host: d.host, enabled: d.enabled, freshness: f, summary: text, findings: GuideDiagnosisAdvisor.findings(d, now: now))
        }
        return GuideSettingsModel(rows: rows, enrichmentEnabled: enrichmentEnabled(defaults))
    }
}
