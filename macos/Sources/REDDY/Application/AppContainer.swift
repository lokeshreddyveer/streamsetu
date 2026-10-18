import Foundation

/// Builds the object graph once. Views get services from here, never construct them.
@MainActor
final class AppContainer {
    let db: DatabaseManager
    let catalog: SQLiteCatalogRepository
    let epgRepo: SQLiteEPGRepository
    let searchRepo: SQLiteSearchRepository
    let favoritesRepo: SQLiteFavoritesRepository
    let historyRepo: SQLiteHistoryRepository
    let videoPrefs: SQLiteVideoPreferencesRepository

    let settings: AppSettings
    let http: HTTPClient
    let credentials: CredentialStore
    let sources: SourceManager
    let indexer: CatalogIndexer
    let epgSync: EPGSyncService
    let sync: CatalogSyncService
    let scheduler: SyncScheduler
    let search: SearchService
    let globalSearch: GlobalSearchService
    let favorites: FavoritesService
    let history: HistoryService
    let discover: DiscoverService
    /// Fixes misspelt searches from the words in the library (built the first time it is needed).
    let spelling: SpellingIndex
    let featured: FeaturedService
    let details: DetailService
    let artwork: ArtworkService
    let diagnostics: DiagnosticsService
    let reminders: ReminderService
    let playback: PlaybackCoordinator
    let appLock: AppLock
    let vpn = VPNMonitor()
    private let memoryGuard: MemoryPressureGuard
    let health: IndexHealthMonitor
    let categoryDiagnostics: CategoryDiagnosticsService
    let parental: ParentalControls
    let channelHealth: ChannelHealthService
    let statistics: StatisticsService
    let metadata: MetadataMatchService
    let newEpisodes: NewEpisodeService
    let people: PeopleIndexService
    let watchQueue: WatchQueue
    /// Set by the app: called on the main actor when the list of series with new episodes changed.
    var onNewEpisodesChanged: (@MainActor () -> Void)?
    private(set) var cloud: CloudSyncCoordinator!
    /// Set by the app once its state exists: called (on the main actor) when another device changed something that is on screen.
    var onCloudChange: (@MainActor (SyncApplyResult) -> Void)?
    private(set) var multiView: MultiViewModel!
    let maintenance: LibraryMaintenanceService
    let backup: BackupService
    let dataReset: DataResetService
    private(set) var autoBackup: AutoBackupService!
    #if os(macOS)
    private(set) var fullscreen: FullscreenController!
    #endif
    private(set) var nowPlaying: NowPlayingService!

    init(databasePath: String? = nil, credentials: CredentialStore = StandardCredentialStore()) throws {
        #if os(macOS)
        if databasePath == nil { LegacyDefaults.migrate(from: AppConfiguration.legacyBundleID, into: .standard) }     // keep the settings made under the old name
        #endif
        db = try databasePath.map { try DatabaseManager(path: $0) } ?? DatabaseManager.standard()
        catalog = SQLiteCatalogRepository(db: db)
        epgRepo = SQLiteEPGRepository(db: db)
        searchRepo = SQLiteSearchRepository(db: db)
        favoritesRepo = SQLiteFavoritesRepository(db: db)
        historyRepo = SQLiteHistoryRepository(db: db)
        videoPrefs = SQLiteVideoPreferencesRepository(db: db)

        settings = AppSettings()
        http = HTTPClient()
        self.credentials = credentials
        sources = SourceManager(catalog: catalog, credentials: credentials, http: http, headers: SourceHeadersStore(defaults: settings.defaultsStore))
        indexer = CatalogIndexer(db: db)
        let prefs = SendableDefaults(settings.defaultsStore)
        epgSync = EPGSyncService(db: db, catalog: catalog, http: http, shiftMinutes: { prefs.value.object(forKey: AppSettings.guideShiftKey($0)) as? Int ?? 0 })
        sync = CatalogSyncService(catalog: catalog, indexer: indexer, sources: sources, epg: epgSync, db: db)
        scheduler = SyncScheduler(catalog: catalog, sync: sync)
        search = SearchService(searchRepo: searchRepo, catalog: catalog)
        globalSearch = GlobalSearchService(searchRepo: searchRepo, catalog: catalog, epg: epgRepo, favorites: favoritesRepo)
        favorites = FavoritesService(repo: favoritesRepo, catalog: catalog)
        history = HistoryService(repo: historyRepo, catalog: catalog)
        discover = DiscoverService(catalog: catalog, history: historyRepo)
        spelling = SpellingIndex(db: db)
        details = DetailService(catalog: catalog, indexer: indexer, sources: sources)
        featured = FeaturedService(catalog: catalog, details: details)
        artwork = ArtworkService(cache: ImageCache(root: StorageService.caches, http: http, headers: { [sources] url in sources.artworkHeaders(for: url) }))
        try? PlexTokenCleanup.run(db)
        memoryGuard = MemoryPressureGuard { [artwork] in await artwork.relieveMemory() }
        diagnostics = DiagnosticsService(db: db, catalog: catalog)
        reminders = ReminderService()
        health = IndexHealthMonitor(db: db)
        categoryDiagnostics = CategoryDiagnosticsService(catalog: catalog, sources: sources)
        parental = ParentalControls(catalog: catalog)
        appLock = AppLock(settings: settings)
        statistics = StatisticsService(db: db, catalog: catalog)
        metadata = MetadataMatchService(db: db, credentials: credentials, http: http)
        maintenance = LibraryMaintenanceService(db: db, health: health)
        backup = BackupService(db: db, catalog: catalog, sources: sources)
        dataReset = DataResetService(db: db, catalog: catalog, sources: sources, history: historyRepo)
        let resolver = StreamResolver(catalog: catalog, sources: sources, history: historyRepo)
        channelHealth = ChannelHealthService(resolver: resolver)
        playback = PlaybackCoordinator(factory: PlaybackEngineFactory(), resolver: resolver, history: historyRepo, historyService: history,
                                       catalog: catalog, settings: settings, diagnostics: diagnostics, videoPrefs: videoPrefs)
        newEpisodes = NewEpisodeService(db: db, catalog: catalog, history: history, details: details,
                                        busy: { [playback] in await MainActor.run { playback.state == .playing || playback.state.isBusy } })
        people = PeopleIndexService(index: PeopleIndex(db: db), catalog: catalog, sources: sources, indexer: indexer,
                                    busy: { [playback] in await MainActor.run { playback.state == .playing || playback.state.isBusy } })
        watchQueue = WatchQueue(catalog: catalog)
        let peopleService = people
        let newEpisodeService = newEpisodes
        Task { [weak self] in
            // After a playlist was read, look (gently, never while something plays) for new episodes of the series being watched.
            await self?.sync.setOnCompleted { id in
                peopleService.start()
                let n = await newEpisodeService.refresh(sourceID: id)
                if n > 0 { await MainActor.run { self?.onNewEpisodesChanged?() } }
            }
        }
        let catalog = self.catalog, epg = epgRepo
        multiView = MultiViewModel(
            resolve: { try resolver.resolve(channel: $0) },
            willStart: { [unowned self] in self.playback.stop() },
            guide: { ids in
                let now = Date()
                let all = (try? epg.nowNext(channelIDs: ids, at: now)) ?? [:]
                return all.compactMapValues { $0.first { $0.start <= now && $0.end > now } }
            },
            lookup: { ids in
                var q = ChannelQuery(); q.collapseVariants = false; q.ids = ids
                return (try? catalog.channels(q)) ?? []
            },
            find: { text, favourites in
                var q = ChannelQuery(); q.search = text; q.favoritesOnly = favourites; q.limit = 80; q.sortAlphabetically = true
                return (try? catalog.channels(q)) ?? []
            })
        #if os(macOS)
        fullscreen = FullscreenController(playback: playback, makeWindow: { [unowned self] in
            PlayerFullscreenWindow(title: self.playback.title.isEmpty ? "StreamSetu" : self.playback.title, content: FullscreenPlayerRoot(container: self))
        })
        #endif
        nowPlaying = NowPlayingService(playback: playback, artwork: artwork)
        autoBackup = AutoBackupService(backup: backup, settings: settings, channelPrefs: playback.channelPrefs)
        cloud = CloudSyncCoordinator(db: db, defaults: settings.defaultsStore) { [weak self] result in
            Task { @MainActor in self?.cloudApplied(result) }
        }
        applySettings()
    }

    /// Another device changed something: refresh what depends on it.
    private func cloudApplied(_ r: SyncApplyResult) {
        if r.tables.contains(SyncTable.settingsName) { settings.reloadFromStore() }
        if r.tables.contains("locked_categories") { parental.reloadLocks() }
        onCloudChange?(r)
    }

    /// Begins syncing when the person has switched it on. Call once the app has started.
    func startCloudIfEnabled() async { await updateCloudSync() }

    /// Carries on reading who is in the movies, a little at a time (see `PeopleIndexService`).
    func startPeopleIndex() { people.start() }

    /// Makes iCloud sync and the login storage match the two switches in Settings.
    func updateCloudSync() async {
        let refs = ((try? catalog.sources()) ?? []).compactMap(\.credentialRef) + [MetadataMatchService.keyRef]
        (credentials as? StandardCredentialStore)?.applySync(settings.iCloudSync && settings.syncLogins, refs: refs)
        await cloud.setEnabled(settings.iCloudSync)
    }

    /// Pushes the refresh preferences into the services that act on them, now and every time one of them changes.
    func applySettings() {
        scheduler.holdWhile { [playback] in await MainActor.run { playback.state == .playing || playback.state.isBusy } }
        scheduler.setCatalogInterval(settings.catalogRefresh.seconds)
        scheduler.setRefreshOnOpen(settings.refreshOnOpen)
        http.setProxy(settings.proxy.isActive ? settings.proxy : nil)
        epgSync.configure(refreshInterval: settings.guideRefresh.seconds, pastRetentionDays: settings.guideRetentionDays)
        withObservationTracking {
            _ = settings.catalogRefresh; _ = settings.refreshOnOpen; _ = settings.guideRefresh; _ = settings.guideRetentionDays; _ = settings.proxyKind; _ = settings.proxyHost; _ = settings.proxyPort
        } onChange: { [weak self] in
            Task { @MainActor in self?.applySettings() }
        }
    }
}

/// UserDefaults is safe to use from any thread; this says so to the compiler.
struct SendableDefaults: @unchecked Sendable { let value: UserDefaults; init(_ v: UserDefaults) { value = v } }
