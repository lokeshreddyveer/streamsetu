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

    init() { AppDelegate.coordinator = self }

    func boot() async {
        guard container == nil else { return }
        do {
            let c = try AppContainer()
            container = c
            switch c.settings.sidebarLaunch {
            case .expanded: router.sidebarCollapsed = false
            case .collapsed: router.sidebarCollapsed = true
            case .remember: router.sidebarCollapsed = c.settings.sidebarWasCollapsed
            }
            router.rememberFolders = c.settings.rememberFolders
            let s = AppState(container: c)
            state = s
            c.parental.onChange = { [weak s] in s?.reloadFolders(); s?.catalogVersion += 1 }
            cleanLegacyFiles()
            let migrated = await c.sources.importLegacyPreferences()
            await s.start()
            c.onCloudChange = { [weak s] r in
                s?.reload(); s?.catalogVersion += 1
                for id in r.newSources { if let u = UUID(uuidString: id) { s?.sync(u) } }          // a playlist added on another device: load it here too
            }
            if !migrated.isEmpty { s.toasts.show("Moved \(migrated.count) source\(migrated.count == 1 ? "" : "s") into the new library", symbol: "arrow.right.circle.fill", kind: .info) }
            if migrated.isEmpty == false { s.syncAll() }
            Task.detached { [artwork = c.artwork] in await artwork.trim() }
            phase = .ready                                  // the app opens now; iCloud starts in the background, it is never waited for
            Task { await c.startCloudIfEnabled() }
            c.autoBackup.runIfDue()
            resumeLastChannelIfWanted(c, s)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Deletes the cache database from earlier builds (it is rebuilt from the sources).
    private func cleanLegacyFiles() {
        let root = StorageService.applicationSupport
        for n in ["reddy.db", "reddy.db-wal", "reddy.db-shm"] { try? FileManager.default.removeItem(at: root.appendingPathComponent(n)) }
    }

    func resetDatabaseAndRetry() async {
        let dir = StorageService.databaseDirectory
        try? FileManager.default.removeItem(at: dir)
        phase = .starting
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
