import Foundation
#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
#endif

// Public surface for shelves, lists and the player.
//
//   MusicArtworkPrefetcher.shared.prefetch(addresses: nextRows, artworkClass: .trackThumb, scale: displayScale, priority: .normal, owner: "library.songs")
//     - call from onAppear of a row with the addresses of the next rows (the window is capped at `maxWindow`, 16; default 12).
//     - a new call from the same owner replaces its window: addresses that left the window are cancelled.
//   MusicArtworkPrefetcher.shared.cancel(owner:)  - call when the list or shelf disappears or its content changes wholesale.
//   MusicArtworkService.shared.prefetch(addresses:priority:artworkClass:scale:owner:) is the same call through the service.
//
// Requests are deduplicated across owners (same address and bucket), covers already in memory are skipped, and invalid addresses are dropped
// before any task is made.

/// Seam between the prefetcher and the real service so tests can use fakes.
protocol MusicArtworkLoading: Sendable {
    func isCached(_ address: String, pixels: Int) async -> Bool
    func load(_ address: String, pixels: Int) async
}

struct MusicServiceArtworkLoader: MusicArtworkLoading {
    func isCached(_ address: String, pixels: Int) async -> Bool {
        await MainActor.run { MusicArtworkService.shared.cachedImage(address, targetPixelSize: pixels) != nil }
    }
    func load(_ address: String, pixels: Int) async {
        let store = await MainActor.run { MusicArtworkService.shared.store }
        _ = await store.load(address, targetPixelSize: pixels)
    }
}

@MainActor
final class MusicArtworkPrefetcher {
    static let shared = MusicArtworkPrefetcher(loader: MusicServiceArtworkLoader())
    static let maxWindow = 16
    static let defaultWindow = 12

    private struct Key: Hashable { let address: String; let bucket: Int }
    private let loader: MusicArtworkLoading
    private var tasks: [String: Task<Void, Never>] = [:]
    private var ownerKeys: [String: Set<Key>] = [:]
    private var inFlight: [Key: String] = [:]

    init(loader: MusicArtworkLoading) { self.loader = loader }

    /// Number of addresses currently being warmed, across owners.
    var inFlightCount: Int { inFlight.count }

    func prefetch(addresses: [String], artworkClass: MusicArtworkClass = .tile, scale: CGFloat = 2, priority: MusicArtworkPriority = .low,
                  owner: String = "default", window: Int = MusicArtworkPrefetcher.defaultWindow) {
        let bucket = artworkClass.bucket(scale: scale)
        var seen = Set<String>()
        let list = addresses.filter { !$0.isEmpty && MusicArtworkPolicy.validate($0) != nil && seen.insert($0).inserted }
            .prefix(min(max(window, 0), Self.maxWindow))
        let wanted = Set(list.map { Key(address: $0, bucket: bucket) })
        // Cancel what left the window.
        let previous = ownerKeys[owner] ?? []
        if wanted == previous, tasks[owner] != nil { return }
        tasks[owner]?.cancel(); tasks[owner] = nil
        for k in previous where !wanted.contains(k) && inFlight[k] == owner { inFlight[k] = nil }
        // Keys another owner is already fetching are not repeated.
        let mine = list.map { Key(address: $0, bucket: bucket) }.filter { inFlight[$0] == nil || inFlight[$0] == owner }
        guard !mine.isEmpty else { ownerKeys[owner] = nil; return }
        ownerKeys[owner] = Set(mine)
        for k in mine { inFlight[k] = owner }
        let loader = self.loader
        let pixels = bucket
        tasks[owner] = Task(priority: priority.taskPriority) { [weak self] in
            for k in mine {
                if Task.isCancelled { break }
                if !(await loader.isCached(k.address, pixels: pixels)) { await loader.load(k.address, pixels: pixels) }
                self?.finished(k, owner: owner)
            }
            self?.ended(owner)
        }
    }

    /// Stops everything the owner asked for (a list scrolled away, a shelf left the screen).
    func cancel(owner: String) {
        tasks[owner]?.cancel(); tasks[owner] = nil
        for k in ownerKeys[owner] ?? [] where inFlight[k] == owner { inFlight[k] = nil }
        ownerKeys[owner] = nil
    }

    func cancelAll() { for o in Array(tasks.keys) { cancel(owner: o) } }

    /// Resolves when every task started so far has ended (used by tests and teardown).
    func waitUntilIdle() async {
        for t in Array(tasks.values) { await t.value }
    }

    private func finished(_ k: Key, owner: String) {
        if inFlight[k] == owner { inFlight[k] = nil }
        ownerKeys[owner]?.remove(k)
    }

    private func ended(_ owner: String) {
        if ownerKeys[owner]?.isEmpty ?? true { ownerKeys[owner] = nil; tasks[owner] = nil }
    }
}

extension MusicArtworkService {
    /// The call shelves and lists make for the next rows. Bounded (16), deduplicated, cancellable by `owner`.
    func prefetch(addresses: [String], priority: MusicArtworkPriority = .low, artworkClass: MusicArtworkClass = .tile,
                  scale: CGFloat = 2, owner: String = "default") {
        MusicArtworkPrefetcher.shared.prefetch(addresses: addresses, artworkClass: artworkClass, scale: scale, priority: priority, owner: owner)
    }
}

/// Clears the decoded-image tier when the system reports memory pressure. Disk files stay.
final class MusicArtworkMemoryPressure: @unchecked Sendable {
    private let memory: MusicArtworkMemory
    private var source: DispatchSourceMemoryPressure?
    private var observer: NSObjectProtocol?

    init(memory: MusicArtworkMemory) {
        self.memory = memory
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        s.setEventHandler { [weak self] in self?.evict() }
        s.resume()
        source = s
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in self?.evict() }
        #endif
    }

    /// Drops every decoded cover from memory.
    func evict() { memory.removeAll() }

    deinit {
        source?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// Caps simultaneous cover decodes so a scroll full of new covers cannot saturate every core.
actor MusicDecodeGate {
    static let shared = MusicDecodeGate(limit: 3)
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = max(1, limit) }

    var active: Int { running }

    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { running = max(0, running - 1) } else { waiters.removeFirst().resume() }
    }
}
