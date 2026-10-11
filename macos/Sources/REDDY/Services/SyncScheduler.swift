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
            while !Task.isCancelled {
                await self?.checkNow()
                try? await Task.sleep(nanoseconds: UInt64((self?.checkEvery ?? 900) * 1_000_000_000))
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    /// Which sources are due, given their last successful sync and the staleness window.
    static func dueSources(_ sources: [PlaylistSource], now: Date, interval: TimeInterval) -> [PlaylistSource] {
        sources.filter { s in
            guard s.enabled else { return false }
            guard let last = s.lastSync else { return true }
            return now.timeIntervalSince(last) >= interval
        }
    }

    func checkNow() async {
        let (isConstrained, isOnline) = lock.withLock { (constrained, online) }
        guard let interval = catalogInterval else { return }     // manual refresh only
        guard isOnline, !isConstrained else { return }          // reduce activity on constrained / expensive networks
        if let busy = lock.withLock({ hold }), await busy() { return }     // never while a stream is playing
        guard let all = try? catalog.sources() else { return }
        for s in Self.dueSources(all, now: Date(), interval: interval) {
            await sync.start(sourceID: s.id)
        }
    }
}
