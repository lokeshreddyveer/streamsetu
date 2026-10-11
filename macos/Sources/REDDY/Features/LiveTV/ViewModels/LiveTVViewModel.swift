import SwiftUI
import Observation

@MainActor @Observable
final class LiveTVViewModel {
    var filter: LiveFilter = .all
    var search = ""
    var channels: [Channel] = []
    var nowNext: [String: [EPGProgram]] = [:]
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

    private var queryGen = 0
    private var wanted = Set<String>()
    private var fetchTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

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
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)    // debounce keystrokes; stale queries are dropped
            if !Task.isCancelled { await self?.reload(c) }
        }
    }

    /// Rows ask for their program info as they appear; requests are batched so scrolling stays cheap.
    func want(_ id: String, _ c: AppContainer) {
        if nowNext[id] != nil { return }
        wanted.insert(id)
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled, let self else { return }
            let ids = Array(self.wanted); self.wanted.removeAll()
            let map = await Task.detached { (try? c.epgRepo.nowNext(channelIDs: ids, at: Date())) ?? [:] }.value
            for id in ids { self.nowNext[id] = map[id] ?? [] }       // [] = "no guide data", remembered so we don't re-ask
        }
    }

    func refreshNowNext(_ c: AppContainer) async {
        let ids = Array(nowNext.keys)
        guard !ids.isEmpty else { return }
        let map = await Task.detached { (try? c.epgRepo.nowNext(channelIDs: ids, at: Date())) ?? [:] }.value
        for id in ids { nowNext[id] = map[id] ?? [] }
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
