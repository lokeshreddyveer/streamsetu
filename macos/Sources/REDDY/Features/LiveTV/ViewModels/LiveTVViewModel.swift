import SwiftUI
import Observation

/// One channel's now/next, observed by that channel's row alone.
@MainActor @Observable final class NowNextBox {
    /// nil: not asked yet. []: asked, no guide data.
    var programs: [EPGProgram]?
    init(_ p: [EPGProgram]? = nil) { programs = p }
}

/// Now/next for the channels on screen, keyed by channel id. The dictionary itself is not observed: a row reads only its own box, so a fetch for forty channels
/// re-draws at most those rows (and only the ones whose answer changed), never the 30,000-row list.
@MainActor final class NowNextStore {
    private var boxes: [String: NowNextBox] = [:]
    var knownIDs: [String] { boxes.compactMap { $0.value.programs != nil ? $0.key : nil } }
    func isKnown(_ id: String) -> Bool { boxes[id]?.programs != nil }
    func box(for id: String) -> NowNextBox {
        if let b = boxes[id] { return b }
        let b = NowNextBox(); boxes[id] = b; return b
    }
    func programs(for id: String) -> [EPGProgram]? { boxes[id]?.programs }
    /// Forgets every answer (a kept model that is hidden does not hold programme data that goes stale).
    func removeAll() { boxes.removeAll() }
    /// Stores answers; only a box whose value changed is written. Returns the ids that changed.
    @discardableResult func publish(_ ids: [String], _ map: [String: [EPGProgram]]) -> [String] {
        var changed: [String] = []
        for id in ids {
            let v = map[id] ?? []
            let b = box(for: id)
            if b.programs != v { b.programs = v; changed.append(id) }
        }
        return changed
    }
}

@MainActor @Observable
final class LiveTVViewModel {
    init() { Perf.bump("LiveTVViewModel") }
    /// Never reused for another model (screens put it in their task keys).
    let uid = ScreenModelID.next()
    var filter: LiveFilter = .all
    var search = ""
    var channels: [Channel] = []
    @ObservationIgnored let nowNext = NowNextStore()
    var upcoming: [EPGProgram] = []
    /// Programmes that already aired and are still in the provider's archive (empty for channels without catch-up).
    var past: [EPGProgram] = []
    var variants: [(variant: Channel, label: String)] = []
    var selectedID: String?
    /// The named list being viewed, or nil. It narrows whatever the sidebar is showing to the channels in that list.
    var listID: String?
    /// The person's lists that hold at least one channel.
    private(set) var lists: [CatalogCollection] = []
    var loading = false
    /// The active playlist. Everything here is scoped to it.
    var sourceID: UUID?

    /// What the screen last finished loading for (its task key); a returning screen with the same key does not read again.
    var loadedKey: String?

    /// Called when the screen goes away while this model is kept: a pending search stops, and a very long channel list is dropped (it is read again on return).
    func trimForRetention() {
        searchTask?.cancel(); fetchTask?.cancel()
        // A cancelled fetch must not leave the guard in `want` shut: rows asking again after the return start a new one. What aired while hidden is asked again too.
        fetchTask = nil; wanted.removeAll(); nowNext.removeAll()
        if searchPending { searchPending = false; loadedKey = nil }          // the text and the list disagree: the return reads the list again
        if channels.count > ScreenRetention.maxRetainedChannels { channels = []; loadedKey = nil }
    }

    /// Whether the list is the same until the catalog changes.
    func isStaticListing(_ f: LiveFilter) -> Bool {
        guard listID == nil else { return false }
        switch f { case .all, .category: return true; default: return false }
    }

    private var queryGen = 0
    private var wanted = Set<String>()
    private var fetchTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchPending = false

    func reload(_ c: AppContainer) async {
        queryGen += 1
        let gen = queryGen
        loading = channels.isEmpty
        let q = search, f: LiveFilter = listID.map { .list($0) } ?? filter, collapse = c.settings.collapseDuplicates, sid = sourceID
        let order = c.settings.defaultChannelSort
        let result = await Task.detached { () -> [Channel] in
            switch f {
            case .all: return (try? c.catalog.channels(ChannelQuery(sourceID: sid, search: q, collapseVariants: collapse, recentlyAdded: order == .recentlyAdded, sortAlphabetically: order == .alphabetical))) ?? []
            case .favorites: return (try? c.catalog.channels(ChannelQuery(sourceID: sid, favoritesOnly: true, search: q, collapseVariants: false))) ?? []
            case .added: return (try? c.catalog.channels(ChannelQuery(sourceID: sid, search: q, collapseVariants: collapse, recentlyAdded: true, limit: 300))) ?? []
            case .category(let id): return (try? c.catalog.channels(ChannelQuery(sourceID: sid, categoryID: id, search: q, collapseVariants: collapse, recentlyAdded: order == .recentlyAdded, sortAlphabetically: order == .alphabetical))) ?? []
            case .list(let id): return Self.channelsInList(id, sid: sid, query: q, c: c)
            case .recent:
                let ids = (try? c.historyRepo.recentIDs(kind: .channel, limit: 60)) ?? []
                let by = Dictionary(((try? c.catalog.channels(ChannelQuery(collapseVariants: false, ids: ids))) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let list = ids.compactMap { by[$0] }.filter { sid == nil || $0.sourceID == sid }
                return q.isEmpty ? list : list.filter { MetadataNormalizer.normalize($0.name).contains(MetadataNormalizer.normalize(q)) }
            }
        }.value
        guard gen == queryGen else { return }
        channels = result
        loading = false
        lists = await Task.detached { Self.listsWithChannels(c) }.value
        if let id = listID, !lists.contains(where: { $0.id == id }) { listID = nil }          // the list was deleted or emptied
    }

    /// Channels of a named list, in the order they were added, narrowed by the search text.
    nonisolated static func channelsInList(_ id: String, sid: UUID?, query: String, c: AppContainer) -> [Channel] {
        let ids = ((try? c.favoritesRepo.collectionItems(id: id)) ?? []).filter { $0.kind == .channel }.map(\.itemID)
        guard !ids.isEmpty else { return [] }
        let by = Dictionary(((try? c.catalog.channels(ChannelQuery(collapseVariants: false, ids: ids))) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let list = ids.compactMap { by[$0] }.filter { sid == nil || $0.sourceID == sid }
        return query.isEmpty ? list : list.filter { MetadataNormalizer.normalize($0.name).contains(MetadataNormalizer.normalize(query)) }
    }

    /// Lists that contain channels, each with its channel count.
    nonisolated static func listsWithChannels(_ c: AppContainer) -> [CatalogCollection] {
        ((try? c.favoritesRepo.collections()) ?? []).compactMap { col in
            let n = ((try? c.favoritesRepo.collectionItems(id: col.id)) ?? []).filter { $0.kind == .channel }.count
            guard n > 0 else { return nil }
            var copy = col; copy.itemCount = n
            return copy
        }
    }

    func scheduleSearch(_ c: AppContainer) {
        searchTask?.cancel()
        searchPending = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)    // debounce keystrokes; stale queries are dropped
            if !Task.isCancelled { await self?.reload(c); if !Task.isCancelled { self?.searchPending = false } }
        }
    }

    /// Rows ask for their program info as they appear; requests are batched so scrolling stays cheap.
    func want(_ id: String, _ c: AppContainer) {
        if nowNext.isKnown(id) { return }
        wanted.insert(id)
        guard fetchTask == nil else { return }          // one fetch at a time, collecting what rows ask for meanwhile (not restarted by every row)
        fetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            let ids = Array(self.wanted); self.wanted.removeAll()
            self.fetchTask = nil
            guard !ids.isEmpty else { return }
            let map = await Task.detached { (try? c.epgRepo.nowNext(channelIDs: ids, at: Date())) ?? [:] }.value
            self.nowNext.publish(ids, map)       // [] = "no guide data", remembered so we don't re-ask
        }
    }

    func refreshNowNext(_ c: AppContainer) async {
        let ids = nowNext.knownIDs
        guard !ids.isEmpty else { return }
        let map = await Task.detached { (try? c.epgRepo.nowNext(channelIDs: ids, at: Date())) ?? [:] }.value
        nowNext.publish(ids, map)
    }

    func loadDetails(for channel: Channel?, _ c: AppContainer) async {
        guard let channel else { upcoming = []; past = []; variants = []; return }
        let id = channel.id, archiveDays = channel.archiveDays
        let (progs, earlier, vars) = await Task.detached { () -> ([EPGProgram], [EPGProgram], [(variant: Channel, label: String)]) in
            let now = Date()
            let list = ((try? c.epgRepo.programs(channelIDs: [id], from: now, to: now.addingTimeInterval(12 * 3600)))?[id]) ?? []
            // Only what the provider still keeps: up to the archive window, and never more than three days back.
            let back = TimeInterval(min(archiveDays, 3)) * 86400
            let old = archiveDays > 0 ? (((try? c.epgRepo.programs(channelIDs: [id], from: now.addingTimeInterval(-back), to: now))?[id]) ?? []) : []
            return (list, old.filter { $0.end <= now }.sorted { $0.start > $1.start }, (try? c.catalog.variants(ofChannel: id)) ?? [])
        }.value
        upcoming = progs
        past = earlier
        variants = vars.count > 1 ? vars : []
    }
}
