import Foundation
import Network

/// Opportunistic background refresh while the app is running. Not a daemon: macOS gives no post-quit execution.
/// Live/VOD catalogs refresh every 12h, the guide roughly every 6h (the sync service enforces the guide interval).
final class SyncScheduler: @unchecked Sendable {
    private let catalog: CatalogRepository
    private let sync: CatalogSyncService
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var loop: Task<Void, Never>?
    private var constrained = false
    private var online = true
    private var interval: TimeInterval?
    /// nil means manual: the scheduler never starts a sync on its own.
    var catalogInterval: TimeInterval? { lock.withLock { interval } }
    func setCatalogInterval(_ i: TimeInterval?) { lock.withLock { interval = i } }
    private var refreshOnOpen = true
    func setRefreshOnOpen(_ on: Bool) { lock.withLock { refreshOnOpen = on } }
    /// How old a playlist has to be before opening the app refreshes it.
    static let openStaleness: TimeInterval = 3600
    let checkEvery: TimeInterval
    /// Asked before every automatic refresh. While a stream is playing the answer is true and the refresh waits for the next check:
    /// reading a big playlist or guide competes with the stream for network and processor time.
    private var hold: (@Sendable () async -> Bool)?
    func holdWhile(_ busy: @escaping @Sendable () async -> Bool) { lock.withLock { hold = busy } }

    init(catalog: CatalogRepository, sync: CatalogSyncService, catalogInterval: TimeInterval? = 12 * 3600, checkEvery: TimeInterval = 15 * 60) {
        self.catalog = catalog; self.sync = sync; self.interval = catalogInterval; self.checkEvery = checkEvery
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.withLock { self?.constrained = path.isConstrained || path.isExpensive; self?.online = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "app.reddy.netmonitor"))
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.appOpened()
            while !Task.isCancelled {
                await self?.checkNow()
                try? await Task.sleep(nanoseconds: UInt64((self?.checkEvery ?? 900) * 1_000_000_000))
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    /// The app was opened (or came back to the front): playlists older than an hour are refreshed even when the schedule is Manual.
    /// Like every automatic refresh it waits while a stream is playing and does nothing on a constrained network.
    func appOpened() async {
        let (isConstrained, isOnline, wanted) = lock.withLock { (constrained, online, refreshOnOpen) }
        guard wanted, isOnline, !isConstrained else { return }
        if let busy = lock.withLock({ hold }), await busy() { return }
        guard let all = try? catalog.sources() else { return }
        for s in Self.dueSources(all, now: Date(), interval: Self.openStaleness) { await sync.start(sourceID: s.id) }
    }

    /// Which sources are due, given their last successful sync and the staleness window.
    static func dueSources(_ sources: [PlaylistSource], now: Date, interval: TimeInterval) -> [PlaylistSource] {
        sources.filter { s in
            guard s.enabled else { return false }
            guard let last = s.lastSync else { return true }
            return now.timeIntervalSince(last) >= interval
        }
    }

    /// With [wait], returns only when the refreshes it started have finished (a background task has to know when it is done).
    func checkNow(wait: Bool = false) async {
        let (isConstrained, isOnline) = lock.withLock { (constrained, online) }
        guard isOnline, !isConstrained else { return }          // reduce activity on constrained / expensive networks
        if let busy = lock.withLock({ hold }), await busy() { return }     // never while a stream is playing
        guard let all = try? catalog.sources() else { return }
        var started: [Task<Void, Never>] = []
        var busyIDs = Set<UUID>()
        if let interval = catalogInterval {          // nil is manual: the catalog is never refreshed on its own
            for s in Self.dueSources(all, now: Date(), interval: interval) {
                busyIDs.insert(s.id)
                if let t = await sync.start(sourceID: s.id) { started.append(t) }
            }
        }
        // The guide keeps its own interval (Settings > Library): a source whose catalog is not being refreshed now still gets its guide when that is due.
        for s in all where s.enabled && !busyIDs.contains(s.id) { await sync.refreshGuideIfDue(sourceID: s.id) }
        if wait { for t in started { await t.value } }
    }
}
