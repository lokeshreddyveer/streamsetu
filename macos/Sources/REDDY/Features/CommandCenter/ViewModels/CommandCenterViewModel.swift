import SwiftUI
import Observation

enum CCFilter: String, CaseIterable, Identifiable {
    case all = "All", favorites = "Favorites", hidden = "Hidden", edited = "Edited", duplicates = "Duplicates"
    case missingLogo = "No logo", missingGuide = "No guide", missingCategory = "No category"
    var id: String { rawValue }
}

/// The channel manager's state. Everything the list shows is computed once when its inputs change, not while drawing,
/// and every action updates the screen at once and writes to the database in the background.
@MainActor @Observable
final class CommandCenterViewModel {
    private(set) var channels: [Channel] = []
    private(set) var hidden: Set<String> = []
    private(set) var edited: Set<String> = []
    private(set) var mapped: Set<String> = []
    private(set) var duplicateIDs: Set<String> = []
    private(set) var duplicateClusters = 0
    private(set) var categories: [String] = []
    private(set) var loading = false
    /// What the list draws: filtered, and cut to `shown` rows so a library of tens of thousands stays instant.
    private(set) var visible: [Channel] = []
    private(set) var matchCount = 0
    private(set) var counts: [CCFilter: Int] = [:]
    private(set) var shown = pageSize
    static let pageSize = 150

    var search = "" { didSet { if search != oldValue { refilter() } } }
    var filter: CCFilter = .all { didSet { if filter != oldValue { refilter() } } }
    var sourceID: UUID? { didSet { if sourceID != oldValue { loadedFor = nil } } }
    var selection: Set<String> = []
    var message: String?

    private var matching: [Channel] = []
    private var loadedFor: UUID??
    private var favorites: Set<String> = []

    func setFavorites(_ f: Set<String>) { if f != favorites { favorites = f; refilter() } }

    // MARK: loading

    func load(_ c: AppContainer, force: Bool = false) async {
        if !force, let l = loadedFor, l == sourceID, !channels.isEmpty { return }
        loading = channels.isEmpty
        let sid = sourceID
        let r = await Task.detached { () -> ([Channel], Set<String>, Set<String>, Set<String>, Set<String>, Int, [String]) in
            let ch = (try? c.catalog.allChannelsForManagement(sourceID: sid)) ?? []
            let hidden = Set((try? c.favoritesRepo.hiddenIDs(kind: "channel")) ?? [])
            let edited = (try? c.favoritesRepo.overrideIDs()) ?? []
            let mapped = (try? c.epgRepo.mappedChannelIDs()) ?? []
            // duplicates: the same base name anywhere in the library (across sources too), reported but never merged
            var byName: [String: [String]] = [:]
            for x in ch { let b = MetadataNormalizer.baseName(x.normalizedName); if !b.isEmpty { byName[b, default: []].append(x.id) } }
            let clusters = byName.values.filter { $0.count > 1 }
            let cats = Set(ch.compactMap { $0.categoryName.nilIfEmpty }).sorted()
            return (ch, hidden, edited, mapped, Set(clusters.flatMap { $0 }), clusters.count, cats)
        }.value
        channels = r.0; hidden = r.1; edited = r.2; mapped = r.3; duplicateIDs = r.4; duplicateClusters = r.5; categories = r.6
        loadedFor = .some(sid)
        loading = false
        selection = selection.intersection(Set(channels.map(\.id)))
        refilter()
    }

    // MARK: filtering

    func refilter() {
        let q = MetadataNormalizer.normalize(search)
        func passes(_ ch: Channel, _ f: CCFilter) -> Bool {
            switch f {
            case .all: true
            case .favorites: favorites.contains(ch.id)
            case .hidden: hidden.contains(ch.id)
            case .edited: edited.contains(ch.id)
            case .duplicates: duplicateIDs.contains(ch.id)
            case .missingLogo: ch.logoURL.nilIfEmpty == nil
            case .missingGuide: !mapped.contains(ch.id)
            case .missingCategory: ch.categoryName.nilIfEmpty == nil
            }
        }
        let searched = q.isEmpty ? channels : channels.filter { $0.normalizedName.contains(q) || MetadataNormalizer.normalize($0.categoryName ?? "").contains(q) }
        var c: [CCFilter: Int] = [:]
        for f in CCFilter.allCases where f != .all { c[f] = searched.reduce(0) { $0 + (passes($1, f) ? 1 : 0) } }
        c[.all] = searched.count
        counts = c
        matching = filter == .all ? searched : searched.filter { passes($0, filter) }
        matchCount = matching.count
        shown = Self.pageSize
        visible = Array(matching.prefix(shown))
    }

    func showMore() {
        guard shown < matching.count else { return }
        shown = min(matching.count, shown + Self.pageSize)
        visible = Array(matching.prefix(shown))
    }

    var hasMore: Bool { shown < matching.count }

    // MARK: selection

    func toggle(_ id: String) { if selection.contains(id) { selection.remove(id) } else { selection.insert(id) } }
    func selectAllMatching() { selection = Set(matching.map(\.id)) }
    func clearSelection() { selection = [] }
    var selectedChannels: [Channel] { channels.filter { selection.contains($0.id) } }
    var allMatchingSelected: Bool { !matching.isEmpty && matching.count == selection.count && matching.allSatisfy { selection.contains($0.id) } }

    // MARK: edits (instant on screen, saved in the background)

    func isHidden(_ id: String) -> Bool { hidden.contains(id) }
    func isEdited(_ id: String) -> Bool { edited.contains(id) }
    func hasGuide(_ id: String) -> Bool { mapped.contains(id) }

    func setHidden(_ on: Bool, ids: [String], _ c: AppContainer) {
        if on { hidden.formUnion(ids) } else { hidden.subtract(ids) }
        refilter()
        enqueue { for id in ids { if on { try? c.favoritesRepo.hide(id, kind: "channel") } else { try? c.favoritesRepo.unhide(id) } } }
        say(on ? "Hidden \(ids.count)" : "Shown \(ids.count)")
    }

    func rename(_ id: String, to name: String, _ c: AppContainer) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[i].name = trimmed; channels[i].normalizedName = MetadataNormalizer.normalize(trimmed)
        edited.insert(id); refilter()
        enqueue {
            let e = try? c.favoritesRepo.override(for: id)
            try? c.favoritesRepo.setOverride(itemID: id, displayName: trimmed, categoryName: e?.categoryName, epgID: e?.epgID)
        }
        say("Renamed")
    }

    func setCategory(_ name: String, ids: [String], _ c: AppContainer) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let set = Set(ids)
        for i in channels.indices where set.contains(channels[i].id) { channels[i].categoryName = trimmed }
        edited.formUnion(ids)
        if !categories.contains(trimmed) { categories = (categories + [trimmed]).sorted() }
        refilter()
        enqueue {
            for id in ids {
                let e = try? c.favoritesRepo.override(for: id)
                try? c.favoritesRepo.setOverride(itemID: id, displayName: e?.displayName, categoryName: trimmed, epgID: e?.epgID)
            }
        }
        say("Moved \(ids.count) to “\(trimmed)”")
    }

    func assignGuide(_ xmltvID: String?, channel: Channel, _ c: AppContainer) {
        if xmltvID != nil { mapped.insert(channel.id) } else { mapped.remove(channel.id) }
        refilter()
        enqueue { try? XMLTVChannelMatcher(db: c.db).setUserMapping(channelID: channel.id, sourceID: channel.sourceID, xmltvID: xmltvID) }
        say(xmltvID == nil ? "Guide match removed" : "Guide matched")
    }

    func restore(ids: [String], _ c: AppContainer) {
        let set = Set(ids)
        let chans = channels.filter { set.contains($0.id) }
        hidden.subtract(ids); edited.subtract(ids); mapped.subtract(ids)
        refilter()
        enqueue {
            for ch in chans {
                try? c.favoritesRepo.clearOverride(itemID: ch.id)
                try? c.favoritesRepo.unhide(ch.id)
                try? XMLTVChannelMatcher(db: c.db).setUserMapping(channelID: ch.id, sourceID: ch.sourceID, xmltvID: nil)
            }
        }
        say("Restored \(ids.count) to provider defaults")
        loadedFor = nil                                         // names and categories come back from the catalog on the next load
    }

    /// Saves run one after another, in the order the edits were made, so a rename and a folder change on the same channel
    /// can never overwrite each other.
    private var writes: Task<Void, Never>?
    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        let previous = writes
        writes = Task.detached { await previous?.value; work() }
    }

    /// Waits until everything edited so far is saved.
    func flush() async { await writes?.value }

    private func say(_ text: String) {
        message = text
        Task { try? await Task.sleep(nanoseconds: 2_500_000_000); if message == text { message = nil } }
    }
}
