import Foundation

// History with page memory (section 4.2). Pure values: the shell drives them, the tests drive them without a window.

/// What a page remembers so Back and Forward return to the same view: where it was scrolled, which role or tab was chosen, its filters and sort,
/// and which sections were expanded. Small by design (it is persisted with the last session).
struct MusicPageMemory: Codable, Hashable, Sendable {
    var scrollOffset: Double?
    /// Role, decade, language, sort...: short text values under the page's own keys.
    var filters: [String: String] = [:]
    var expandedSections: Set<String> = []
    var selectedTab: String?
    var selection: MusicEntityID?

    init(scrollOffset: Double? = nil, filters: [String: String] = [:], expandedSections: Set<String> = [], selectedTab: String? = nil, selection: MusicEntityID? = nil) {
        self.scrollOffset = scrollOffset; self.filters = filters; self.expandedSections = expandedSections
        self.selectedTab = selectedTab; self.selection = selection
    }

    var isEmpty: Bool { scrollOffset == nil && filters.isEmpty && expandedSections.isEmpty && selectedTab == nil && selection == nil }

    /// Bounds what a session file can hold: a page cannot grow this without limit.
    func bounded() -> MusicPageMemory {
        var m = self
        if let y = m.scrollOffset, !(y.isFinite && y >= 0) { m.scrollOffset = nil }
        if m.filters.count > 12 { m.filters = Dictionary(uniqueKeysWithValues: m.filters.sorted { $0.key < $1.key }.prefix(12).map { ($0.key, $0.value) }) }
        m.filters = m.filters.mapValues { String($0.prefix(64)) }
        if m.expandedSections.count > 24 { m.expandedSections = Set(m.expandedSections.sorted().prefix(24)) }
        return m
    }
}

/// The live page memory of the pages the person has visited, by scroll key: a bounded LRU (60 keys). Pages write into it as the person changes a
/// filter or tab; the shell copies the current page's memory into the history entry when the person leaves.
struct MusicPageMemoryBook: Sendable, Equatable {
    static let capacity = 60
    private var order: [String] = []
    private var values: [String: MusicPageMemory] = [:]

    func memory(for key: String) -> MusicPageMemory? { values[key] }
    var keys: [String] { order }

    mutating func set(_ m: MusicPageMemory, for key: String) {
        if m.isEmpty { values[key] = nil; order.removeAll { $0 == key }; return }
        order.removeAll { $0 == key }
        order.append(key)
        values[key] = m
        while order.count > Self.capacity { values[order.removeFirst()] = nil }
    }
    mutating func update(_ key: String, _ change: (inout MusicPageMemory) -> Void) {
        var m = values[key] ?? MusicPageMemory()
        change(&m)
        set(m, for: key)
    }
    mutating func clear() { order = []; values = [:] }
}

/// The shared, observable face of the book for pages (`MusicPageMemoryCenter.shared.update(key) { $0.filters["sort"] = "year" }`).
@MainActor
final class MusicPageMemoryCenter {
    static let shared = MusicPageMemoryCenter()
    private(set) var book = MusicPageMemoryBook()
    func memory(for key: String) -> MusicPageMemory { book.memory(for: key) ?? MusicPageMemory() }
    func set(_ m: MusicPageMemory, for key: String) { book.set(m, for: key) }
    func update(_ key: String, _ change: (inout MusicPageMemory) -> Void) { book.update(key, change) }
    func clear() { book.clear() }
}

/// One place in Music: the section, the pages stacked above it, and the memory of the top page. Equality ignores the memory (it is not where the
/// person is), so a repeat of the current place is still recognised as a repeat.
struct MusicNavEntry: Equatable, Sendable {
    var section: MusicSection
    var stack: [MusicRoute] = []
    var memory = MusicPageMemory()

    var route: MusicRoute? { stack.last }
    var scrollKey: String { route?.scrollKey ?? ("section:" + section.rawValue) }
    init(section: MusicSection, stack: [MusicRoute] = [], memory: MusicPageMemory = MusicPageMemory()) { self.section = section; self.stack = stack; self.memory = memory }
    init(_ nav: MusicNav) { self.init(section: nav.section, stack: nav.stack) }

    static func == (a: MusicNavEntry, b: MusicNavEntry) -> Bool { a.section == b.section && a.stack == b.stack }
}

/// What is kept of the last session: the newest entries (ids and memory only, never a legacy value) and where the person was.
struct MusicSessionSnapshot: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var section: String
        var stack: [String]
        var memory: MusicPageMemory
    }
    static let maxEntries = 20
    var entries: [Entry]
    var index: Int
}

/// A real history of places. Choosing a section, opening a page and stepping Back or Forward all move through it, so Back after switching a
/// section returns to the section you came from. The page's own Back button (which only pops the page) lands on the previous entry and is
/// recognised as a step back, so the two kinds of Back never disagree.
struct MusicNavHistory: Equatable, Sendable {
    static let capacity = 100
    enum Change: Equatable, Sendable { case unchanged, recorded, steppedBack, steppedForward }

    private(set) var entries: [MusicNavEntry]
    private(set) var index: Int

    init(start: MusicNavEntry = MusicNavEntry(section: .home)) { entries = [start]; index = 0 }

    var current: MusicNavEntry { entries[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < entries.count - 1 }
    /// The same numbers in the older shape, for code that still talks about depth.
    var depth: MusicNavDepth { MusicNavDepth(depth: index, deepest: entries.count - 1) }

    /// Takes the place the person is now at. A repeat is ignored; the entry just before or after the current one moves the index (keeping that
    /// entry's page memory); anything else is new navigation, which forgets what was ahead.
    @discardableResult mutating func observe(_ e: MusicNavEntry) -> Change {
        if e == current { return .unchanged }
        if index > 0, e == entries[index - 1] { index -= 1; return .steppedBack }
        if canGoForward, e == entries[index + 1] { index += 1; return .steppedForward }
        entries.removeSubrange((index + 1)...)
        entries.append(e)
        index += 1
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity); index = entries.count - 1 }
        return .recorded
    }

    /// Stores the memory of the current place (call before leaving it).
    mutating func remember(_ m: MusicPageMemory) { entries[index].memory = m.bounded() }

    /// Moves one step back and returns where to go, or nil at the start. The returned entry carries its page memory.
    mutating func back() -> MusicNavEntry? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    mutating func forward() -> MusicNavEntry? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }

    /// The scroll keys of every place in the history, newest last (what the shell keeps scroll positions for).
    var scrollKeys: [String] { entries.map(\.scrollKey) }

    /// Forgets pages that no longer exist: they leave every place's stack, and neighbours that became the same place are joined so Back never repeats a page.
    mutating func purge(where gone: (MusicRoute) -> Bool) {
        var out: [MusicNavEntry] = []
        var newIndex = 0
        for (i, entry) in entries.enumerated() {
            var e = entry
            e.stack.removeAll(where: gone)
            if e.route != entry.route { e.memory = MusicPageMemory() }          // the memory was of the page that is gone
            if out.last != e { out.append(e) }
            if i == index { newIndex = out.count - 1 }
        }
        entries = out
        index = newIndex
    }

    // MARK: last session

    /// The newest entries as plain text. A stack is cut at its first legacy route (a value cannot be saved as an id); a settings place is skipped.
    func snapshot(limit: Int = MusicSessionSnapshot.maxEntries) -> MusicSessionSnapshot {
        let start = max(0, entries.count - limit)
        var out: [MusicSessionSnapshot.Entry] = []
        var newIndex = 0
        for (i, e) in entries.enumerated() where i >= start {
            if e.section == .settings { continue }
            var stack: [String] = []
            for r in e.stack { guard let p = r.persisted else { break }; stack.append(p) }
            let cutShort = stack.count < e.stack.count
            out.append(.init(section: e.section.rawValue, stack: stack, memory: cutShort ? MusicPageMemory() : e.memory.bounded()))
            if i <= index { newIndex = out.count - 1 }
        }
        return MusicSessionSnapshot(entries: out, index: out.isEmpty ? 0 : newIndex)
    }

    init?(snapshot s: MusicSessionSnapshot) {
        var list: [MusicNavEntry] = []
        for e in s.entries.suffix(MusicSessionSnapshot.maxEntries) {
            guard let section = MusicSection(rawValue: e.section), section != .settings else { continue }
            list.append(MusicNavEntry(section: section, stack: e.stack.compactMap { MusicRoute(persisted: $0) }, memory: e.memory.bounded()))
        }
        guard !list.isEmpty else { return nil }
        // Entries that became equal after a route dropped out are collapsed so Back never lands on the place the person is already at.
        var out: [MusicNavEntry] = []
        for e in list where out.last != e { out.append(e) }
        entries = out
        index = min(max(0, s.index), out.count - 1)
    }
}
