import Foundation

enum SourceSyncState: Equatable, Sendable {
    case idle, connecting, authenticating, downloading, parsing, indexing
    case completed(Date)
    case failed(String)

    var isBusy: Bool {
        switch self { case .connecting, .authenticating, .downloading, .parsing, .indexing: true; default: false }
    }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .connecting: "Connecting…"
        case .authenticating: "Signing in…"
        case .downloading: "Downloading…"
        case .parsing: "Reading catalog…"
        case .indexing: "Indexing…"
        case .completed(let d): "Updated \(d.formatted(.relative(presentation: .named)))"
        case .failed(let m): "Failed: \(m)"
        }
    }
}

struct SyncProgress: Sendable, Equatable {
    var sourceID: UUID
    var state: SourceSyncState = .idle
    var liveCount: Int?
    var movieCount: Int?
    var seriesCount: Int?
    var guide: String?
    var notes: [String] = []
}

/// One sync per source at a time. Everything is downloaded and validated before the database is touched,
/// and each content type is committed independently, so a failed series refresh never discards live channels.
actor CatalogSyncService {
    typealias Observer = @Sendable (SyncProgress) -> Void

    private let catalog: CatalogRepository
    private let indexer: CatalogIndexer
    private let sources: SourceManager
    private let epg: EPGSyncService
    private let db: DatabaseManager
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var observers: [UUID: Observer] = [:]
    private var latest: [UUID: SyncProgress] = [:]
    private var onCompleted: (@Sendable (UUID) async -> Void)?

    init(catalog: CatalogRepository, indexer: CatalogIndexer, sources: SourceManager, epg: EPGSyncService, db: DatabaseManager) {
        self.catalog = catalog; self.indexer = indexer; self.sources = sources; self.epg = epg; self.db = db
    }

    func addObserver(_ o: @escaping Observer) -> UUID {
        let id = UUID()
        observers[id] = o
        for p in latest.values { o(p) }
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }
    /// Called, off to the side and at low priority, after a source was read successfully (a manual refresh or a scheduled one).
    func setOnCompleted(_ f: @escaping @Sendable (UUID) async -> Void) { onCompleted = f }
    func isRunning(_ id: UUID) -> Bool { tasks[id] != nil }
    func progress(for id: UUID) -> SyncProgress? { latest[id] }

    /// Starts a sync unless one is already running for this source.
    @discardableResult
    func start(sourceID: UUID, forceGuide: Bool = false) -> Task<Void, Never>? {
        if tasks[sourceID] != nil { return tasks[sourceID] }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(sourceID: sourceID, forceGuide: forceGuide)
            await self.finished(sourceID)
        }
        tasks[sourceID] = task
        return task
    }

    func cancel(sourceID: UUID) { tasks[sourceID]?.cancel() }
    func cancelAll() { tasks.values.forEach { $0.cancel() } }
    /// Reasons are about entries ("no category_id"), never URLs or logins.
    nonisolated static func logRejections(_ f: CategoryFetch, kind: ContentKind) {
        Log.sync.info("\(kind.rawValue) categories: provider \(f.providerCount), parsed \(f.parsedCount), rejected \(f.rejected.count)")
        for r in f.rejected.prefix(20) { Log.sync.info("\(kind.rawValue) category rejected: \(r, privacy: .public)") }
    }

    private func finished(_ id: UUID) { tasks[id] = nil }

    private func emit(_ p: SyncProgress) {
        latest[p.sourceID] = p
        observers.values.forEach { $0(p) }
    }

    private func run(sourceID: UUID, forceGuide: Bool) async {
        guard let source = try? catalog.source(id: sourceID) else { return }
        var p = SyncProgress(sourceID: sourceID)
        let jobID = try? db.write { c -> Int64 in
            try c.execute("INSERT INTO sync_jobs(source_id, started_at, state) VALUES(?,?, 'running')", [sourceID, Date()])
            return c.lastInsertRowID
        }
        func setState(_ s: SourceSyncState) { p.state = s; emit(p) }

        do {
            setState(.connecting)
            let provider = try sources.makeProvider(for: source)
            setState(.authenticating)
            let caps = try await provider.validate()
            try catalog.saveCapabilities(caps, sourceID: sourceID)
            try catalog.updateSyncStatus(sourceID: sourceID, status: "syncing", lastSync: nil)
            var failures: [String] = [], scopes = 0

            // Live TV
            if caps.live {
                scopes += 1
                do {
                    setState(.downloading)
                    var all: [Channel] = []
                    for try await batch in provider.channels() { all += batch; p.liveCount = all.count; setState(.parsing) }
                    let fetch = try await provider.categoryFetch(.channel); let cats = fetch.categories; Self.logRejections(fetch, kind: .channel)
                    setState(.indexing)
                    let r = try indexer.commitChannels(source: source, categories: cats, channels: all)
                    p.liveCount = r.total
                    try? catalog.recordCategoryStats(sourceID: sourceID, kind: .channel, fetch: fetch, reconcile: r.categories)
                    try catalog.recordSync(sourceID: sourceID, scope: "live", success: true, itemCount: r.total, etag: nil, lastModified: nil, error: nil)
                } catch is CancellationError { throw CancellationError() }
                catch { failures.append("Live TV: \(Self.message(error))"); try? catalog.recordSync(sourceID: sourceID, scope: "live", success: false, itemCount: nil, etag: nil, lastModified: nil, error: Self.message(error)) }
            }
            // Movies
            if caps.movies {
                scopes += 1
                do {
                    setState(.downloading)
                    var all: [Movie] = []
                    for try await batch in provider.movies() { all += batch; p.movieCount = all.count; setState(.parsing) }
                    let fetch = try await provider.categoryFetch(.movie); let cats = fetch.categories; Self.logRejections(fetch, kind: .movie)
                    setState(.indexing)
                    let r = try indexer.commitMovies(source: source, categories: cats, movies: all)
                    p.movieCount = r.total
                    try? catalog.recordCategoryStats(sourceID: sourceID, kind: .movie, fetch: fetch, reconcile: r.categories)
                    try catalog.recordSync(sourceID: sourceID, scope: "movies", success: true, itemCount: r.total, etag: nil, lastModified: nil, error: nil)
                } catch is CancellationError { throw CancellationError() }
                catch { failures.append("Movies: \(Self.message(error))"); try? catalog.recordSync(sourceID: sourceID, scope: "movies", success: false, itemCount: nil, etag: nil, lastModified: nil, error: Self.message(error)) }
            }
            // Series
            if caps.series {
                scopes += 1
                do {
                    setState(.downloading)
                    var all: [Series] = []
                    for try await batch in provider.series() { all += batch; p.seriesCount = all.count; setState(.parsing) }
                    let fetch = try await provider.categoryFetch(.series); let cats = fetch.categories; Self.logRejections(fetch, kind: .series)
                    setState(.indexing)
                    let r = try indexer.commitSeries(source: source, categories: cats, series: all)
                    if let people = (provider as? PeopleReporting)?.takeSeriesPeople() { PeopleIndex(db: db).saveSeries(people, sourceID: sourceID) }
                    p.seriesCount = r.total
                    try? catalog.recordCategoryStats(sourceID: sourceID, kind: .series, fetch: fetch, reconcile: r.categories)
                    try catalog.recordSync(sourceID: sourceID, scope: "series", success: true, itemCount: r.total, etag: nil, lastModified: nil, error: nil)
                } catch is CancellationError { throw CancellationError() }
                catch { failures.append("Series: \(Self.message(error))"); try? catalog.recordSync(sourceID: sourceID, scope: "series", success: false, itemCount: nil, etag: nil, lastModified: nil, error: Self.message(error)) }
            }

            if scopes == 0 { throw SourceError.invalidResponse("No channels, movies or series were found in this source.") }
            if failures.count == scopes { throw SourceError.invalidResponse(failures.joined(separator: " ")) }
            p.notes = failures

            // The guide is separate: its failure never invalidates a good catalog.
            if caps.epg || provider.epgLocation() != nil {
                p.guide = "Updating"; setState(.indexing)
                do {
                    let latestSource = try catalog.source(id: sourceID) ?? source
                    let r = try await epg.sync(source: latestSource, location: provider.epgLocation(), force: forceGuide, headers: sources.headers(for: sourceID, host: provider.epgLocation()?.host))
                    p.guide = r.skipped ? "Up to date" : "\(r.programmes) programs"
                } catch is CancellationError { throw CancellationError() }
                catch { p.guide = "Unavailable"; p.notes.append("Guide: \(Self.message(error))") }
            }

            let now = Date()
            try catalog.updateSyncStatus(sourceID: sourceID, status: "completed", lastSync: now)
            if let jobID { try? db.write { try $0.execute("UPDATE sync_jobs SET finished_at=?, state='completed', detail=? WHERE id=?", [now, p.notes.joined(separator: "; "), jobID]) } }
            db.optimize()
            setState(.completed(now))
            if let cb = onCompleted { Task.detached(priority: .utility) { await cb(sourceID) } }
        } catch is CancellationError {
            try? catalog.updateSyncStatus(sourceID: sourceID, status: "idle", lastSync: nil)
            if let jobID { try? db.write { try $0.execute("UPDATE sync_jobs SET finished_at=?, state='cancelled' WHERE id=?", [Date(), jobID]) } }
            setState(.idle)
        } catch {
            let m = Self.message(error)
            try? catalog.updateSyncStatus(sourceID: sourceID, status: "failed", lastSync: nil)
            if let jobID { try? db.write { try $0.execute("UPDATE sync_jobs SET finished_at=?, state='failed', detail=? WHERE id=?", [Date(), m, jobID]) } }
            Log.sync.error("sync failed: \(m)")
            setState(.failed(m))
        }
    }

    static func message(_ e: Error) -> String {
        CredentialRedactor.redact((e as? LocalizedError)?.errorDescription ?? e.localizedDescription)
    }
}
