import SwiftUI
import Observation

/// Filters and orders one Library tab off the main actor. The entries and the natural order of each sort are built once per change of the
/// source list and kept, so typing in the filter or flipping the direction never sorts again, and a body pass never sorts at all.
/// A newer request cancels the one still running; the list on screen stays until the new one is ready.
@MainActor @Observable
final class MusicLibraryListModel<Item: Sendable> {
    private(set) var shown: [Item] = []
    private(set) var total = 0
    private(set) var isWorking = false
    private(set) var providers: [(id: String, count: Int)] = []
    /// True once the first result arrived, so the page can tell "loading" from "empty".
    private(set) var hasResult = false

    @ObservationIgnored private let makeEntry: @Sendable (Item, Int, MusicPlayInfo) -> MusicLibraryEntry
    @ObservationIgnored private var entries: [MusicLibraryEntry]?
    @ObservationIgnored private var orders: [MusicLibrarySort: [Int]] = [:]
    @ObservationIgnored private var signature = ""
    @ObservationIgnored private var lastRequest: MusicLibraryRequest?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(makeEntry: @escaping @Sendable (Item, Int, MusicPlayInfo) -> MusicLibraryEntry) { self.makeEntry = makeEntry }

    /// `signature` names the source list cheaply (count plus first and last id); a different one rebuilds the entries. `history` is only read
    /// while the entries are rebuilt, and only when the sort needs play times.
    func apply(items: [Item], signature: String, request: MusicLibraryRequest, history: [PlayRecord] = []) {
        if signature == self.signature, request == lastRequest, hasResult { return }
        task?.cancel()
        let rebuild = signature != self.signature
        if rebuild { self.signature = signature; entries = nil; orders = [:] }
        lastRequest = request
        generation += 1
        let gen = generation
        let cachedEntries = entries
        let cachedOrder = orders[request.sort]
        let make = makeEntry
        let needsPlays = request.sort == .recentlyPlayed || request.sort == .mostPlayed
        if items.count > 400 { isWorking = true }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let built: [MusicLibraryEntry]
            if let cachedEntries { built = cachedEntries } else {
                let played = needsPlays ? MusicPlayInfo(last: MusicLibraryEngine.lastPlayed(history), counts: MusicLibraryEngine.playCounts(history)) : MusicPlayInfo()
                var list: [MusicLibraryEntry] = []
                list.reserveCapacity(items.count)
                for (i, item) in items.enumerated() {
                    if i % 2048 == 0, Task.isCancelled { return }
                    list.append(make(item, i, played))
                }
                built = list
            }
            if Task.isCancelled { return }
            let order = cachedOrder ?? MusicLibraryEngine.order(built, sort: request.sort)
            if Task.isCancelled { return }
            let picked = MusicLibraryEngine.select(order: order, entries: built, filter: request.filter, reversed: request.reversed)
            let out = picked.map { items[$0] }
            let providers = cachedEntries == nil ? MusicLibraryEngine.providers(built) : nil
            if Task.isCancelled { return }
            await self?.finish(gen, entries: built, sort: request.sort, order: order, shown: out, total: items.count, providers: providers)
        }
    }

    private func finish(_ gen: Int, entries: [MusicLibraryEntry], sort: MusicLibrarySort, order: [Int], shown: [Item], total: Int, providers: [(id: String, count: Int)]?) {
        guard gen == generation else { return }
        self.entries = entries
        orders[sort] = order
        self.shown = shown
        self.total = total
        if let providers { self.providers = providers }
        isWorking = false
        hasResult = true
    }

    func cancel() { task?.cancel(); isWorking = false }
}

/// What the history says about each track, read once while the entries are built: the last play time and the number of plays, by `uid`.
struct MusicPlayInfo: Sendable {
    var last: [String: Double] = [:]
    var counts: [String: Int] = [:]
}

/// Everything the Library page keeps between tabs. One model per kind of list; each is created once and reused.
@MainActor
final class MusicLibraryModels {
    let songs = MusicLibraryListModel<MusicTrack> { t, _, played in MusicLibraryEngine.trackEntry(t, playedAt: played.last[t.uid] ?? 0, plays: played.counts[t.uid] ?? 0) }
    let podcasts = MusicLibraryListModel<MusicTrack> { t, _, played in MusicLibraryEngine.trackEntry(t, playedAt: played.last[t.uid] ?? 0, plays: played.counts[t.uid] ?? 0) }
    let local = MusicLibraryListModel<MusicTrack> { t, _, played in MusicLibraryEngine.trackEntry(t, playedAt: played.last[t.uid] ?? 0, plays: played.counts[t.uid] ?? 0) }
    let albums = MusicLibraryListModel<MusicAlbum> { a, _, _ in MusicLibraryEngine.albumEntry(a) }
    let artists = MusicLibraryListModel<MusicArtist> { a, _, _ in MusicLibraryEngine.artistEntry(a) }
    let playlists = MusicLibraryListModel<LocalPlaylist> { p, _, _ in MusicLibraryEngine.playlistEntry(p) }
    let history = MusicLibraryListModel<PlayRecord> { r, _, _ in MusicLibraryEngine.trackEntry(r.track, playedAt: r.at.timeIntervalSince1970) }
    /// The local files tab loads its tracks once from the local provider.
    var localTracks: [MusicTrack] = []
    var localLoaded = false
}

/// A cheap name for a list: its length and the ids at both ends. Used to know when a list changed without comparing it.
enum MusicLibrarySignature {
    static func make<T>(_ items: [T], id: (T) -> String) -> String {
        guard let f = items.first, let l = items.last else { return "0" }
        return "\(items.count)|\(id(f))|\(id(l))"
    }
}
