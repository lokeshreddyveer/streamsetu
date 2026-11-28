import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Builds the object graph once. Views get services from here, never construct them.
@MainActor
final class AppContainer {
    /// Light screen models kept across tab switches (Movies, Series, their folder rows, Live TV, Guide), keyed by profile and playlist. Bounded by `ScreenRetention`.
    let screens = ScreenRetention.makeStore()
    /// Filter languages and qualities per playlist and catalog state, shared by every Movies / Series model.
    let filterOptionsStore = FilterOptionsStore()
    let db: DatabaseManager
    let catalog: SQLiteCatalogRepository
    let epgRepo: SQLiteEPGRepository
    let searchRepo: SQLiteSearchRepository
    let favoritesRepo: SQLiteFavoritesRepository
    let historyRepo: SQLiteHistoryRepository
    let videoPrefs: SQLiteVideoPreferencesRepository

    let settings: AppSettings
    private var appliedDNS = AppDNSConfiguration()
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
    /// Continue Watching as the widget and the lock screen may show it: read through the always-restricted view, so nothing from a locked or hidden folder is ever written to them.
    let widgetHistory: HistoryService
    let recommendationMemory: RecommendationMemory
    /// Smart Mix: candidate pool from the identity tables, per-profile shown history, TMDB weekly trending (only with the person's own key).
    let smartMix: SmartMixCoordinator
    let privacy: PrivacyPurge
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
    /// Matches missing artwork by itself in the background (see ArtworkAutoMatcher).
    let artworkMatcher: ArtworkAutoMatcher
    private let matchProfile = MatchProfileBox()
    /// The system's view of the connection; "offline" is only ever said when it reports no path at all.
    let matchNetwork = PathMatchNetwork()
    let newEpisodes: NewEpisodeService
    let people: PeopleIndexService
    let watchQueue: WatchQueue
    let downloads: DownloadService
    /// Set by the app: called on the main actor when the list of series with new episodes changed.
    var onNewEpisodesChanged: (@MainActor () -> Void)?
    /// The last value of each setting whose effect was applied, so the same change is not applied twice (see `settingChanged`).
    var appliedSettingValues: [String: String] = [:]
    private(set) var cloud: CloudSyncCoordinator!
    private(set) var lan: LanSyncService!
    private(set) var profiles: ProfileService!
    private(set) var lanAdapter: LanDataAdapter!
    private(set) var viewingLimits: ViewingLimits!
    let connectivity = Connectivity()
    private(set) var trakt: TraktService!
    var debrid: DebridStore { DebridStore(store: credentials) }
    let nowBoard = NowPlayingBoard()
    let podcasts: PodcastService
    private(set) var accounts: AccountStatusService!
    private(set) var alerts: KeywordAlertService!
    #if os(macOS)
    private(set) var scheduledRecordings: ScheduledRecordingService!
    #endif
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

    init(databasePath: String? = nil, openedDatabase: DatabaseManager? = nil, credentials: CredentialStore = StandardCredentialStore()) throws {
        #if os(macOS)
        if databasePath == nil { LegacyDefaults.migrate(from: AppConfiguration.legacyBundleID, into: .standard) }     // keep the settings made under the old name
        #endif
        db = try openedDatabase ?? databasePath.map { try DatabaseManager(path: $0) } ?? DatabaseManager.standard()          // an already opened (and migrated) database comes from the launch task, so the main thread does not wait for it
        catalog = SQLiteCatalogRepository(db: db)
        epgRepo = SQLiteEPGRepository(db: db)
        searchRepo = SQLiteSearchRepository(db: db, restriction: catalog.restriction)
        favoritesRepo = SQLiteFavoritesRepository(db: db)
        historyRepo = SQLiteHistoryRepository(db: db)
        videoPrefs = SQLiteVideoPreferencesRepository(db: db)

        settings = AppSettings()
        AppDNSController.apply(settings.appDNS)          // before the first session or player is created
        http = HTTPClient()
        HTTPClient.app = http          // services that are not handed the client reach the same one (and so the same proxy)
        self.credentials = credentials
        podcasts = PodcastService(defaults: settings.defaultsStore)
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
        discover = DiscoverService(catalog: catalog, history: historyRepo, people: PeopleIndex(db: db))
        widgetHistory = HistoryService(repo: historyRepo, catalog: catalog.baseline)
        recommendationMemory = RecommendationMemory(db: db, catalog: catalog)
        smartMix = SmartMixCoordinator(db: db, catalog: catalog, memory: recommendationMemory, credentials: credentials, defaults: settings.defaultsStore)
        spelling = SpellingIndex(db: db)
        details = DetailService(catalog: catalog, indexer: indexer, sources: sources)
        featured = FeaturedService(catalog: catalog, details: details)
        artwork = ArtworkService(cache: ImageCache(root: StorageService.caches, http: http, headers: { [sources] url in sources.artworkHeaders(for: url) }))
        try? PlexTokenCleanup.run(db)
        memoryGuard = MemoryPressureGuard { [artwork, screens, filterOptionsStore] in
            await AppContainer.relieveMemory(artwork: artwork, screens: screens, filterOptions: filterOptionsStore)
        }
        diagnostics = DiagnosticsService(db: db, catalog: catalog)
        reminders = ReminderService()
        health = IndexHealthMonitor(db: db)
        categoryDiagnostics = CategoryDiagnosticsService(catalog: catalog, sources: sources)
        privacy = PrivacyPurge(db: db, artwork: artwork)
        parental = ParentalControls(catalog: catalog)
        appLock = AppLock(settings: settings)
        statistics = StatisticsService(db: db, catalog: catalog)
        metadata = MetadataMatchService(db: db, credentials: credentials, http: http, defaults: settings.defaultsStore, pacer: RequestPacer(interval: ArtworkAutoMatcher.interval))
        let box = matchProfile
        let matchStore = MatchStateStore(defaults: settings.defaultsStore, profileID: { box.id })
        metadata.lookupsAllowed = { matchStore.enabled }
        let filmTMDB = metadata; MusicFilmTMDBGate.shared.install { path, query in try await filmTMDB.get(path, query: query) }          // Music's film info asks through the app's one TMDB client
        let providerDetails = details
        metadata.setProviderLookup { c in c.isSeries ? await providerDetails.extras(series: c.id)?.tmdbID : await providerDetails.extras(movie: c.id)?.tmdbID }          // the provider's own TMDB id for a title that is opened
        artworkMatcher = ArtworkAutoMatcher(service: metadata, store: matchStore, network: matchNetwork)
        maintenance = LibraryMaintenanceService(db: db, health: health)
        backup = BackupService(db: db, catalog: catalog, sources: sources)
        dataReset = DataResetService(db: db, catalog: catalog, sources: sources, history: historyRepo)
        let localFiles = LocalFiles()
        let resolver = StreamResolver(catalog: catalog, sources: sources, history: historyRepo, localFiles: localFiles)
        channelHealth = ChannelHealthService(resolver: resolver)
        playback = PlaybackCoordinator(factory: PlaybackEngineFactory(), resolver: resolver, history: historyRepo, historyService: history,
                                       catalog: catalog, settings: settings, diagnostics: diagnostics, videoPrefs: videoPrefs)
        downloads = DownloadService(db: db, catalog: catalog, resolver: resolver, defaults: settings.defaultsStore,
                                    busy: { [playback] in await MainActor.run { playback.state == .playing || playback.state.isBusy } })
        let downloadDB = db
        localFiles.set { DownloadService.savedFile(for: $0, in: downloadDB) }
        newEpisodes = NewEpisodeService(db: db, catalog: catalog, history: history, details: details,
                                        busy: { [playback] in await MainActor.run { playback.state == .playing || playback.state.isBusy } })
        people = PeopleIndexService(index: PeopleIndex(db: db), catalog: catalog, sources: sources, indexer: indexer,
                                    busy: { [playback] in await MainActor.run { playback.state == .playing || playback.state.isBusy } })
        watchQueue = WatchQueue(catalog: catalog, defaults: settings.defaultsStore)
        let subtitleCredentials = credentials
        playback.movieCopies = { [catalog] m in (try? catalog.movieCopies(of: m)) ?? [m] }
        playback.movieAllowed = { [catalog] m in !catalog.restriction.isActive || ((try? catalog.movie(id: m.id)) ?? nil) != nil }
        playback.subtitleFetcher = { title, year, language, season, episode in
            let account = OnlineSubtitles.Account.load(from: subtitleCredentials)
            guard account.isComplete else { return nil }
            let service = OnlineSubtitles(account: account)
            guard let best = try? await service.search(title: title, year: year, language: language, season: season, episode: episode).first else { return nil }
            return try? await service.download(best)
        }
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
            },
            connectionLimit: { [unowned self] source in self.accounts.statuses[source]?.maxConnections })
        #if os(macOS)
        fullscreen = FullscreenController(playback: playback, makeWindow: { [unowned self] in
            PlayerFullscreenWindow(title: self.playback.title.isEmpty ? "StreamSetu" : self.playback.title, content: FullscreenPlayerRoot(container: self))
        })
        #endif
        nowPlaying = NowPlayingService(playback: playback, artwork: artwork)
        nowPlaying.isLocked = { [appLock] in appLock.isLocked }
        autoBackup = AutoBackupService(backup: backup, settings: settings, channelPrefs: playback.channelPrefs)
        cloud = CloudSyncCoordinator(db: db, defaults: settings.defaultsStore) { [weak self] result in
            Task { @MainActor in self?.cloudApplied(result) }
        }
        let nowID: String = {
            if let id = settings.defaultsStore.string(forKey: "lan.nowID") { return id }
            let id = UUID().uuidString.lowercased(); settings.defaultsStore.set(id, forKey: "lan.nowID"); return id
        }()
        let board = nowBoard, player = playback
        lanAdapter = LanDataAdapter(db: db, nowKey: nowID, deviceName: Self.deviceName, now: {
            await MainActor.run {
                guard let r = player.current, player.state.isActive, !player.isPrivate else { return nil }
                return LanDataAdapter.Now(itemID: r.itemID.components(separatedBy: "|catchup|").first ?? r.itemID, title: player.title, position: player.position)
            }
        }, board: { records in Task { @MainActor in board.ingest(records) } })
        lan = LanSyncService(credentials: credentials, defaults: settings.defaultsStore, data: lanAdapter, deviceName: Self.deviceName) { [weak self] n in
            self?.onCloudChange?(SyncApplyResult(applied: n, tables: ["favorites", "playback_progress", "collections"]))
        }
        #if os(macOS)
        scheduledRecordings = ScheduledRecordingService(find: { [catalog] in try catalog.channel(id: $0) }, resolve: { try resolver.resolve(channel: $0) }, defaults: settings.defaultsStore)
        #endif
        accounts = AccountStatusService(catalog: catalog, defaults: settings.defaultsStore, provider: { [sources] in try sources.makeProvider(for: $0) })
        nonisolated(unsafe) let remindersStore = settings.defaultsStore          // UserDefaults is safe to read from any thread
        alerts = KeywordAlertService(defaults: settings.defaultsStore,
            search: { [epgRepo] term, from in
                guard remindersStore.object(forKey: "reminders") as? Bool ?? true else { return [] }
                return try epgRepo.searchPrograms(term: term, sourceID: nil, from: from, limit: 30).map { (program: $0.program, channelName: $0.channelName) }
            },
            schedule: { [reminders] program, channel in await reminders.schedule(program: program, channelName: channel) })
        sources.protectGuideAddresses()
        trakt = TraktService(store: credentials)
        viewingLimits = ViewingLimits(defaults: settings.defaultsStore)
        profiles = ProfileService(db: db, defaults: settings.defaultsStore) { [weak self] _ in self?.profileSwitched() }
        profiles.willSwitch = { [weak self] in self?.playback.stop(); self?.lan.setEnabled(false) }       // nothing in flight may touch the tables while they change hands
        parental.kidsMode = profiles.active.kind == .kids
        matchProfile.id = profiles.active.id
        applyViewingLimits()
        playback.onSessionChange = { [weak self] in self?.lan.nudge() }
        trakt.allowed = { [weak self] in !(self?.parental.kidsMode ?? false) }
        playback.onWatchEvent = { [weak self] event in
            switch event {
            case .started(let item): self?.trakt.scrobble(.start, item, progress: 0)
            case .stopped(let item, let progress): self?.trakt.scrobble(.stop, item, progress: progress)
            }
        }
        playback.programOnNow = { [epgRepo] channel in ((try? epgRepo.nowNext(channelIDs: [channel.id], at: Date())) ?? [:])[channel.id]?.first { $0.isLive(at: Date()) } }
        wirePrivacy()
        applySettings()
    }

    private var profileObservers: [() -> Void] = []
    /// Called whenever another profile becomes the one in use (after its rows are in place).
    func observeProfileSwitch(_ f: @escaping () -> Void) { profileObservers.append(f) }

    /// What is dropped, at once, when a folder is locked or hidden or an unlocked session ends: caches, what the shelves remembered, the pictures. See PrivacyPurge.
    private func wirePrivacy() {
        let memory = recommendationMemory, purge = privacy, featured = featured
        let smart = smartMix, matcher = artworkMatcher
        parental.observeRestriction { [matcher] in Task { await featured.purge() }; smart.invalidate(.lockOrRestrictionChange); matcher.restrictionChanged() }
        observeProfileSwitch { [matcher] in smart.invalidate(.profileSwitch); matcher.restrictionChanged(); matcher.start() }
        indexer.identityChanged.value = { [weak self] _ in
            smart.invalidate(.syncChanged)
            matcher.start()          // new titles may be waiting for artwork
            // A sync (a playlist added after a folder was locked or hidden) can lock or hide its twin folders in the database: the lock badges and the purge hooks are told now, not at the next reload.
            Task { @MainActor in self?.parental.reloadLocks(onlyIfChanged: true); self?.hiddenArrived() }
        }
        let metadata = metadata
        let hub = HubStore(db: db)          // the extra sources' saved details follow the same purge rules
        parental.onFoldersLocked = { [weak self] ids in
            matcher.restrictionChanged()
            _ = try? memory.purgeRestricted()
            smart.invalidate(.lockOrRestrictionChange)
            Task.detached(priority: .utility) { metadata.purgeStored(inFolders: ids); hub.purge(inFolders: ids); await purge.evictArtwork(inFolders: ids) }
        }
        favoritesRepo.onFoldersHidden = { [weak self] ids in
            matcher.restrictionChanged()
            _ = try? memory.purgeRestricted()
            smart.invalidate(.hideChange)
            Task.detached(priority: .utility) { metadata.purgeStored(inFolders: ids); hub.purge(inFolders: ids); await purge.evictArtwork(inFolders: ids) }
            // The featured slideshow, Home, the folder rows and the widget were built while these folders were visible: a restriction change rebuilds them all.
            Task { @MainActor in self?.syncKnownHidden(); self?.parental.foldersHiddenChanged() }
        }
        favoritesRepo.onHiddenChanged = { [weak self] ids, hidden in
            if hidden {
                matcher.restrictionChanged()
                _ = try? memory.purgeRestricted()
                Task.detached(priority: .utility) { metadata.purgeStoredTitles(ids); hub.purge(items: ids) }
            }
            smart.invalidate(.hideChange)
            Task { @MainActor in self?.syncKnownHidden(); self?.parental.foldersHiddenChanged() }
        }
        parental.onRelock = { [weak self] in self?.sweepRestrictedArtwork() }
        if parental.artworkSweepPending { sweepRestrictedArtwork() }          // the last session ended while unlocked (a crash or a quit): its pictures are still on disk
        _ = try? memory.purgeRestricted()
        _ = metadata.purgeExpired(); hub.purgeExpired()
        let restrictedNow = (try? purge.restrictedFolderIDs()) ?? []
        knownHidden = Set((try? db.read { try $0.query("SELECT item_id FROM hidden_items WHERE kind='category'") { $0.string(0) } }) ?? [])
        if ProcessInfo.processInfo.environment["STREAMSETU_TESTING"] == nil {
            let identity = IdentityStore(db: db), database = db
            Task.detached(priority: .background) {
                metadata.purgeStored(inFolders: restrictedNow); hub.purge(inFolders: restrictedNow)          // anything saved about a title that is locked or hidden now
                SchemaV19.ensureQueryIndexes(db: database)              // the big indexes are built here, never in the launch migration
                identity.backfillAll()
            }          // titles that have no identity yet, a few thousand at a time
        }
    }

    /// Hidden folders that arrived from another device: the same-named folders of the other playlists follow, and what was kept about the newly hidden ones is dropped, as for a hide made here.
    private var knownHidden: Set<String> = []
    /// A hide or unhide made here: what is hidden is re-read, so the next sync's check sees it as already known and does not purge and rebuild a second time.
    private func syncKnownHidden() { knownHidden = (try? db.read { try Self.hiddenFolders($0) }) ?? knownHidden }
    nonisolated private static func hiddenFolders(_ c: Connection) throws -> Set<String> { Set(try c.query("SELECT item_id FROM hidden_items WHERE kind='category'") { $0.string(0) }) }
    private func hiddenArrived() {
        let db = db
        Task.detached { [weak self] in
            // The write (twin folders follow) runs off the main actor.
            let now: Set<String>? = try? db.write { c in _ = try FolderFamily.apply(in: c); return try Self.hiddenFolders(c) }
            await MainActor.run {
                guard let self, let now else { return }
                let arrived = now.subtracting(self.knownHidden)
                self.knownHidden = now
                if !arrived.isEmpty { self.favoritesRepo.onFoldersHidden?(Array(arrived)) }
            }
        }
    }

    private func sweepRestrictedArtwork() {
        Task { [privacy] in
            await privacy.sweepRestrictedArtwork()
            parental.artworkSweepPending = false
        }
    }

    /// A kids profile with limits counts and stops playback; any other profile plays freely.
    func applyViewingLimits() {
        let p = profiles.active
        playback.viewingBlock = nil
        guard p.kind == .kids, !viewingLimits.limit(for: p.id).isOff else { playback.viewingGuard = nil; return }
        let limits: ViewingLimits = viewingLimits, id = p.id
        playback.viewingGuard = .init(block: { limits.block(for: id) }, add: { limits.addUsage($0, for: id) }, remaining: { limits.remaining(for: id) })
    }

    /// Another profile is now in use: its own data is in place, so screens reload; kids profiles hide the locked folders; sync, which carries the first profile only, pauses.
    private func profileSwitched() {
        matchProfile.id = profiles.active.id
        let activeProfile = profiles.active.id
        screens.removeAll { $0.profile != activeProfile }          // nothing kept for the profile that was just left can be shown to this one
        filterOptionsStore.invalidate()
        parental.kidsMode = profiles.active.kind == .kids
        for f in profileObservers { f() }
        applyViewingLimits()
        watchQueue.reload()
        Task { await updateCloudSync() }
        lan.setEnabled(settings.lanSync && profiles.isMainActive)
        onCloudChange?(SyncApplyResult(applied: 1, tables: ["favorites", "playback_progress", "collections", "profiles"]))
    }

    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    /// Another device changed something: refresh what depends on it.
    private func cloudApplied(_ r: SyncApplyResult) {
        if r.tables.contains(SyncTable.settingsName) { settings.reloadFromStore() }
        if r.tables.contains("hidden_items") { hiddenArrived() }
        if r.tables.contains("locked_categories") { parental.reloadLocks() }
        onCloudChange?(r)
    }

    /// Begins syncing when the person has switched it on. Call once the app has started.
    func startCloudIfEnabled() async {
        if ProcessInfo.processInfo.environment["STREAMSETU_SELFTEST_MEDIA"] != nil { return }          // a release smoke test never starts iCloud sync
        alerts.start()
        Task { try? await Task.sleep(nanoseconds: 8_000_000_000); await accounts.refresh(); refreshWeeklyDigest(); refreshUsualEvening() }          // when each subscription ends, a little after the first screens are up
        #if os(macOS)
        scheduledRecordings.start()
        #endif
        await updateCloudSync(); lan.setEnabled(settings.lanSync && profiles.isMainActive) }

    /// Carries on reading who is in the movies, a little at a time (see `PeopleIndexService`).
    func startPeopleIndex(fast: Bool = false) { people.start(fast: fast) }

    /// Makes iCloud sync and the login storage match the two switches in Settings.
    func updateCloudSync() async {
        let all = (try? catalog.sources()) ?? []
        let refs = all.compactMap(\.credentialRef) + all.map { SourceManager.guideRef($0.id) } + [MetadataMatchService.keyRef]
        (credentials as? StandardCredentialStore)?.applySync(settings.iCloudSync && settings.syncLogins, refs: refs)
        await cloud.setEnabled(settings.iCloudSync && profiles.isMainActive)
    }

    /// Pushes the refresh preferences into the services that act on them, now and every time one of them changes.
    func applySettings() {
        scheduler.holdWhile { [playback] in await MainActor.run { playback.state == .playing || playback.state.isBusy } }
        scheduler.setCatalogInterval(settings.catalogRefresh.seconds)
        scheduler.setRefreshOnOpen(settings.refreshOnOpen)
        http.setProxy(settings.proxy.isActive ? settings.proxy : nil)
        if settings.appDNS != appliedDNS {                // a change of resolver: clear the caches and start the network sessions afresh; playing streams carry on
            appliedDNS = settings.appDNS
            AppDNSController.apply(appliedDNS)
            http.setProxy(settings.proxy.isActive ? settings.proxy : nil)
        }
        epgSync.configure(refreshInterval: settings.guideRefresh.seconds, pastRetentionDays: settings.guideRetentionDays)
        withObservationTracking {
            _ = settings.catalogRefresh; _ = settings.refreshOnOpen; _ = settings.guideRefresh; _ = settings.guideRetentionDays; _ = settings.proxyKind; _ = settings.proxyHost; _ = settings.proxyPort; _ = settings.appDNS
        } onChange: { [weak self] in
            Task { @MainActor in self?.applySettings() }
        }
    }

    /// What a memory-pressure event gives back: pictures held in memory, kept screen models, cached filter options. Nothing here touches playback or stored data.
    static func relieveMemory(artwork: ArtworkService, screens: ScreenRetention.Store, filterOptions: FilterOptionsStore) async {
        await artwork.relieveMemory()
        await MainActor.run { screens.clear(); filterOptions.invalidate() }          // kept screen models are the first thing to give back
    }
}

/// UserDefaults is safe to use from any thread; this says so to the compiler.
struct SendableDefaults: @unchecked Sendable { let value: UserDefaults; init(_ v: UserDefaults) { value = v } }
