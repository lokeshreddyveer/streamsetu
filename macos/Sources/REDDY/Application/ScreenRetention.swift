import Foundation

/// What a retained screen model belongs to. The person and the playlist are part of the key, so a model made for one profile or playlist can never be handed to another
/// (locked, hidden and kids-only titles stay with the profile that was allowed to see them).
struct ScreenKey: Hashable, Sendable {
    enum Screen: Hashable, Sendable { case library(ContentKind), folders(ContentKind), liveTV, guide }
    let screen: Screen
    let profile: String
    let source: UUID?
}

/// The retention rules for screen models kept across tab switches. There is one store (a `PageSnapshotCache` held by the container); this file only names the limits and the typed access.
/// A retained model is a light object: filter, search text, sort, the pages already loaded (capped), the scroll anchor. Players, web views, images and anything else heavy are never kept here.
enum ScreenRetention {
    /// Models kept at once (Movies, Series, their folder rows, Live TV, Guide, with room for one more of each pair). The least recently used goes first.
    static let maxModels = 8
    /// Loaded list items kept per Movies / Series model when its screen goes away (four pages of 120 minus one); a longer list is cut back and loads again on scroll.
    static let maxRetainedItems = 480
    /// A Live TV or Guide channel list longer than this is dropped when its screen goes away and read again on return, so a 30,000-channel playlist is never held while hidden.
    static let maxRetainedChannels = 2_000
    /// A guide window older than this is not reused on return (the grid would show a stale time range).
    static let guideMaxAge: TimeInterval = 10 * 60

    typealias Store = PageSnapshotCache<ScreenKey, AnyObject>
}

/// A number that is never reused for another model in this run (an object's address can be, once it is freed). Screens put it in their task keys.
@MainActor enum ScreenModelID {
    private static var last = 0
    static func next() -> Int { last += 1; return last }
}

extension ScreenRetention {

    /// Every model costs 1, so the cost bound equals the count bound.
    @MainActor static func makeStore() -> Store { Store(maxEntries: maxModels, maxCost: maxModels) }
}

extension PageSnapshotCache where Value == AnyObject {
    /// The retained model for `key` (and `revision`), or a new one that is retained from now on. Asking again makes it the most recently used.
    func model<T: AnyObject>(_ key: Key, revision: Int, make: () -> T) -> T {
        if let m = get(key, revision: revision) as? T { Perf.bump("ScreenModelReuse"); return m }
        let m = make()
        put(key, value: m, cost: 1, revision: revision)
        return m
    }
}

/// The languages and qualities a list really has, read once per (playlist, kind, catalog state) and shared by every screen model, however many are made.
/// The read runs off the main thread, and a second ask for the same key while it runs waits for the first instead of starting another.
/// Whatever changes the answer changes the key: the number of titles, the restriction revision, the playlist's last sync. `invalidate` drops everything (profile, memory warning).
@MainActor final class FilterOptionsStore {
    struct Key: Hashable, Sendable {
        let source: UUID?
        let kind: ContentKind
        let total: Int
        let restriction: Int
        let stamp: Double
    }

    let maxEntries: Int
    private var done: [Key: LibraryFilterOptions] = [:]
    private var order: [Key] = []
    private var inFlight: [Key: Task<LibraryFilterOptions, Never>] = [:]
    /// Bumped by every invalidation. An answer computed before the bump is returned to its asker but never stored or shared.
    private var epoch = 0
    /// How many reads were started (tests and measurements).
    private(set) var computeCount = 0

    init(maxEntries: Int = 8) { self.maxEntries = max(1, maxEntries) }

    var count: Int { done.count }

    func options(for key: Key, compute: @escaping @Sendable () -> LibraryFilterOptions) async -> LibraryFilterOptions {
        if let hit = done[key] { touch(key); Perf.bump("FilterOptionsHit"); return hit }
        if let running = inFlight[key] { return await running.value }
        computeCount += 1; Perf.bump("FilterOptionsCompute")
        let mine = epoch
        let task = Task.detached(priority: .userInitiated) { compute() }
        inFlight[key] = task
        let value = await task.value
        // Only an answer that is still the current one is kept: an `invalidate` while it ran removed the task from `inFlight`.
        if mine == epoch, inFlight[key] != nil {
            inFlight[key] = nil
            done[key] = value; touch(key)
            while order.count > maxEntries, let oldest = order.first { order.removeFirst(); done[oldest] = nil }
        }
        return value
    }

    func invalidate() { epoch += 1; done.removeAll(); order.removeAll(); inFlight.removeAll() }
    /// A playlist changed or went away.
    func invalidate(source: UUID?) {
        epoch += 1
        for k in done.keys where k.source == source { done[k] = nil }
        order.removeAll { $0.source == source }
        for k in inFlight.keys where k.source == source { inFlight[k] = nil }
    }

    private func touch(_ key: Key) { order.removeAll { $0 == key }; order.append(key) }
}
