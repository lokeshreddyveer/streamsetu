import SwiftUI
import Observation

/// Starts the app: builds the object graph, migrates anything from earlier builds, and begins syncing.
@MainActor @Observable
final class AppCoordinator {
    enum Phase { case starting, ready, failed(String) }
    private(set) var phase: Phase = .starting
    private(set) var container: AppContainer?
    private(set) var state: AppState?
    let router = AppRouter()
    let keys = PlayerKeyMonitor()
    /// Which top-level destination is showing (StreamSetu or an outside service), and the registry of the web models that host the services on
    /// this Mac. A service's model (and its store and web view) is made only when it is first needed.
    let services = ServiceNavigation()
    let hosts = ServiceHostRegistry(ownership: .shared)
    /// The first service's model, for the call sites that have not moved to the registry yet.
    var netflix: ServiceWebModel { hosts.model(for: .netflix)! }

    init() {
        AppDelegate.coordinator = self
        services.hosts = hosts
        services.attach(to: router)
    }

    /// How the theme key last changed, so the window is rebuilt for a new theme but not for the container simply arriving (that rebuild restarted the opening's own view tree).
    private(set) var themeChanges = 0
    private var knownThemeKey: String?
    func themeKeyChanged(_ key: String?) {
        defer { knownThemeKey = key }
        guard let key, let known = knownThemeKey, known != key else { return }
        themeChanges += 1
    }

    /// Work that is not needed to show the first screens waits until the opening is gone (at most ten seconds), so the opening's frames are not competing with it.
    private func afterOpening(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            for _ in 0..<100 where OpeningCoordinator.shared.isVisible { try? await Task.sleep(nanoseconds: 100_000_000) }
            work()
        }
    }

    func boot() async {
        guard container == nil else { return }
        do {
            let opened = try await Task.detached(priority: .userInitiated) { try DatabaseManager.standard() }.value          // open + migrate off the main thread
            let c = try AppContainer(openedDatabase: opened)
            container = c
            services.gate = { [weak c] in c?.parental.kidsMode == true || c?.appLock.isLocked == true }
            services.lockGate = { [weak c] in c?.appLock.isLocked == true }
            services.kidsGate = { [weak c] in c?.parental.kidsMode == true }
            EnhancementRuntime.shared.isRestricted = { [weak c] in c == nil || c?.parental.kidsMode == true || c?.appLock.isLocked == true }          // page options never run for a kids profile or while locked
            switch c.settings.sidebarLaunch {
            case .expanded: router.sidebarCollapsed = false
            case .collapsed: router.sidebarCollapsed = true
            case .remember: router.sidebarCollapsed = c.settings.sidebarWasCollapsed
            }
            router.rememberFolders = c.settings.rememberFolders
            MusicFilmWatchBridgeHost.shared.install(MusicFilmWatchBridgeImpl(container: c, router: router))          // Music's Watch Movie button asks the app's library through this
            let s = AppState(container: c)
            state = s
            afterOpening { c.artworkMatcher.start() }          // artwork is matched in the background, on Wi-Fi, with a TMDB key (own or built in)
            c.parental.onChange = { [weak self, weak s, weak c] in s?.reloadFolders(); s?.catalogVersion += 1; self?.services.enforcePodcastsRule(); self?.services.enforceMusicRule(); if c?.parental.kidsMode == true { self?.hosts.safetyStop(.kidsProfile) } }
            cleanLegacyFiles()
            let migrated = await c.sources.importLegacyPreferences()
            await s.start()
            #if DEBUG
            await Self.loadUITestFixture(c, s)
            #endif
            c.onCloudChange = { [weak s] r in
                s?.reload(); s?.catalogVersion += 1
                for id in r.newSources { if let u = UUID(uuidString: id) { s?.sync(u) } }          // a playlist added on another device: load it here too
            }
            if !migrated.isEmpty { s.toasts.show("Moved \(Localized.plural(migrated.count, one: "%@ source", other: "%@ sources")) into the new library", symbol: "arrow.right.circle.fill", kind: .info) }
            if migrated.isEmpty == false { s.syncAll() }
            Task.detached { [artwork = c.artwork] in await artwork.trim() }
            phase = .ready                                  // the app opens now; iCloud starts in the background, it is never waited for
            if let note = recoveryNote { s.toasts.show(note, symbol: "lifepreserver", kind: .warning); recoveryNote = nil }
            afterOpening { Task { await c.startCloudIfEnabled() } }
            Task { try? await Task.sleep(nanoseconds: 12_000_000_000); await c.accounts.refresh()
                if let w = c.accounts.warnings().first { s.toasts.show("\(w.sourceName): \(w.text)", symbol: "exclamationmark.triangle.fill", kind: .warning) } }
            Task { try? await Task.sleep(nanoseconds: 20_000_000_000); c.startPeopleIndex() }          // after the first screens are up and playing
            afterOpening { c.autoBackup.runIfDue(); self.resumeLastChannelIfWanted(c, s) }
            Task { await AtlasSpotlight.reindexPlainItemsIfNeeded(AtlasSpotlight.indexable(Atlas.entries, platform: .mac, appStore: AtlasAssistant.appStore), suppressed: c.parental.kidsMode) }          // Spotlight finds screens and settings
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    #if DEBUG
    /// UI tests only (debug builds, and only with STREAMSETU_TESTING so the data folder is a throwaway one): loads the M3U file named by STREAMSETU_UITEST_M3U as the one playlist. Never in a release build, never touches the real library.
    private static func loadUITestFixture(_ c: AppContainer, _ s: AppState) async {
        let env = ProcessInfo.processInfo.environment
        guard env["STREAMSETU_TESTING"] != nil, let path = env["STREAMSETU_UITEST_M3U"], s.sources.isEmpty else { return }
        _ = try? await c.sources.addM3UFile(name: "UITest Fixture", fileURL: URL(fileURLWithPath: path)).id.uuidString
        s.reload()
        s.syncAll()
    }
    #endif

    /// Deletes the cache database from earlier builds (it is rebuilt from the sources).
    private func cleanLegacyFiles() {
        let root = StorageService.applicationSupport
        for n in ["reddy.db", "reddy.db-wal", "reddy.db-shm"] { try? FileManager.default.removeItem(at: root.appendingPathComponent(n)) }
    }

    /// Said once the library is open again after a recovery.
    private var recoveryNote: String?

    /// What a damaged library holds, for the confirmation that comes before starting fresh.
    func inventoryOfDamagedLibrary() -> DatabaseRecovery.Inventory { DatabaseRecovery.inspect(StorageService.databaseDirectory) }

    /// Moves the damaged library aside (never deletes it) and opens a new one; with `keepPersonalData` the playlists, favourites, lists, profiles, locks and history are copied into it.
    func recoverLibrary(keepPersonalData: Bool) async {
        phase = .starting
        do {
            let out = try DatabaseRecovery.recover(keepPersonalData: keepPersonalData)
            recoveryNote = keepPersonalData ? out.message : "A fresh library was started. The old one is kept in the Recovery folder."
        } catch {
            phase = .failed("The damaged library could not be moved aside (\(error.localizedDescription)). Nothing was changed.")
            return
        }
        await boot()
    }

    func shutdown() {
        container?.playback.stop()
        container?.scheduler.stop()
        Task { await container?.sync.cancelAll() }
    }

    /// With "Resume the last channel" on, starts the channel that was playing when REDDY was closed. Only when that channel still
    /// exists in an enabled playlist; otherwise nothing happens.
    private func resumeLastChannelIfWanted(_ c: AppContainer, _ s: AppState) {
        guard c.settings.resumeLastChannel, !s.needsOnboarding, let id = c.settings.lastChannelID else { return }
        Task { @MainActor in
            let found = await Task.detached { () -> (Channel, [Channel])? in
                guard let ch = (try? c.catalog.channels(ChannelQuery(collapseVariants: false, ids: [id])))?.first,
                      let source = try? c.catalog.source(id: ch.sourceID), source.enabled else { return nil }
                let queue = (try? c.catalog.channels(ChannelQuery(sourceID: ch.sourceID, categoryID: ch.categoryID, limit: 400))) ?? [ch]
                return (ch, queue.contains { $0.id == ch.id } ? queue : [ch] + queue)
            }.value
            guard let (channel, queue) = found, c.playback.current == nil else { return }
            c.playback.play(channel: channel, queue: queue)
        }
    }
}
