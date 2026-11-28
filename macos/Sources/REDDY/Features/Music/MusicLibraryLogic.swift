import Foundation

// The Library page's rules as plain values: which tabs exist, how they collapse, which sorts and view modes each tab offers, what is remembered, and
// the engine that filters and orders a long list. Nothing here draws anything, so the rules are tested without a screen.

// MARK: - tabs

enum MusicLibraryTab: String, CaseIterable, Identifiable, Sendable, Codable {
    case songs, albums, artists, playlists, podcasts, history, local
    var id: String { rawValue }

    var title: String {
        switch self {
        case .songs: Localized.string("Songs")
        case .albums: Localized.string("Albums")
        case .artists: Localized.string("Artists")
        case .playlists: Localized.string("Playlists")
        case .podcasts: Localized.string("Podcasts")
        case .history: Localized.string("History")
        case .local: Localized.string("Local files")
        }
    }

    var symbol: String {
        switch self {
        case .songs: "heart"
        case .albums: "square.stack"
        case .artists: "person.2"
        case .playlists: "music.note.list"
        case .podcasts: "mic"
        case .history: "clock"
        case .local: "internaldrive"
        }
    }

    /// Where the scroll position of this tab is remembered.
    var scrollKey: String { "library:" + rawValue }

    /// Songs are rows by nature; the other tabs hold cards.
    var holdsSongs: Bool {
        switch self { case .songs, .podcasts, .history, .local: true; case .albums, .artists, .playlists: false }
    }

    var sorts: [MusicLibrarySort] {
        switch self {
        case .songs: [.recentlyAdded, .recentlyPlayed, .mostPlayed, .title, .artist, .album, .duration]
        case .podcasts: [.recentlyAdded, .recentlyPlayed, .title, .duration]
        case .albums: [.recentlyAdded, .title, .artist, .releaseDate]
        case .artists: [.recentlyAdded, .title]
        case .playlists: [.userOrder, .recentlyAdded, .title]
        case .history: [.recentlyPlayed, .title, .artist, .duration]
        case .local: [.userOrder, .recentlyPlayed, .mostPlayed, .title, .artist, .album, .duration]
        }
    }

    var defaultSort: MusicLibrarySort { sorts[0] }

    var modes: [MusicLibraryViewMode] {
        switch self {
        case .songs, .podcasts, .local: [.list, .compact, .table, .grid]
        case .history: [.list, .compact]
        case .albums, .artists, .playlists: [.grid, .list, .compact]
        }
    }

    /// Only tabs whose content is found by the quick filter offer a source filter.
    var offersSourceFilter: Bool { self == .songs || self == .albums || self == .artists }
}

/// The tabs that exist for what this library holds. Songs, Albums, Artists, Playlists and History are always there; Podcasts only while a saved
/// episode exists; Local files only while that source is on.
enum MusicLibraryTabs {
    static func visible(hasPodcasts: Bool, localFilesOn: Bool) -> [MusicLibraryTab] {
        MusicLibraryTab.allCases.filter { t in
            switch t { case .podcasts: hasPodcasts; case .local: localFilesOn; default: true }
        }
    }

    /// A remembered tab that is gone (the last podcast was removed, Local files turned off) falls back to Songs.
    static func resolve(saved: MusicLibraryTab?, visible: [MusicLibraryTab]) -> MusicLibraryTab {
        if let saved, visible.contains(saved) { return saved }
        return .songs
    }
}

/// How the tab bar is drawn: a row of segments, or one menu button that names the current tab.
enum MusicLibraryTabStyle: Equatable, Sendable {
    case segmented, menu

    /// Below this content width the segments would not fit beside each other.
    static let collapseWidth: CGFloat = 760

    static func resolve(layoutClass: MusicLayoutClass, contentWidth: CGFloat) -> MusicLibraryTabStyle {
        if layoutClass == .compact { return .menu }
        guard contentWidth.isFinite, contentWidth > 0 else { return .segmented }
        return contentWidth < collapseWidth ? .menu : .segmented
    }
}

// MARK: - sorting, view modes

enum MusicLibrarySort: String, CaseIterable, Identifiable, Sendable, Codable {
    case recentlyAdded, recentlyPlayed, title, artist, album, releaseDate, duration, userOrder
    /// Added later: the play count over the whole history. Older saved values still decode, since no raw value changed.
    case mostPlayed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: Localized.string("Recently added")
        case .recentlyPlayed: Localized.string("Recently played")
        case .title: Localized.string("A to Z")
        case .artist: Localized.string("Artist")
        case .album: Localized.string("Album")
        case .releaseDate: Localized.string("Release date")
        case .duration: Localized.string("Duration")
        case .userOrder: Localized.string("My order")
        case .mostPlayed: Localized.string("Most played")
        }
    }

    /// What a reversed order means in words, for the menu.
    var reversedTitle: String {
        switch self {
        case .recentlyAdded: Localized.string("Oldest first")
        case .recentlyPlayed: Localized.string("Least recently played first")
        case .title, .artist, .album: Localized.string("Z to A")
        case .releaseDate: Localized.string("Oldest release first")
        case .duration: Localized.string("Longest first")
        case .userOrder: Localized.string("Reverse my order")
        case .mostPlayed: Localized.string("Least played first")
        }
    }
}

enum MusicLibraryViewMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case grid, list, compact, table
    var id: String { rawValue }
    var title: String {
        switch self {
        case .grid: Localized.string("Grid")
        case .list: Localized.string("List")
        case .compact: Localized.string("Compact list")
        case .table: Localized.string("Table")
        }
    }
    var symbol: String {
        switch self { case .grid: "square.grid.2x2"; case .list: "list.bullet"; case .compact: "list.dash"; case .table: "tablecells" }
    }
}

enum MusicLibraryModeRules {
    /// A grid of cards is the default only while it stays a browsable size; past this a list is the default. A choice the person made always wins.
    static let gridDefaultLimit = 600

    static func defaultMode(for tab: MusicLibraryTab, count: Int) -> MusicLibraryViewMode {
        switch tab {
        case .songs, .podcasts, .local, .history: .list
        case .albums, .artists, .playlists: count > gridDefaultLimit ? .list : .grid
        }
    }

    /// The remembered mode when this tab still offers it, else the default for the size.
    static func effective(saved: MusicLibraryViewMode?, tab: MusicLibraryTab, count: Int) -> MusicLibraryViewMode {
        if let saved, tab.modes.contains(saved) { return saved }
        return defaultMode(for: tab, count: count)
    }
}

// MARK: - remembered state

/// A quick filter and a source filter. Remembered per tab, so leaving the page and coming back finds the same view.
struct MusicLibraryFilterState: Codable, Equatable, Sendable {
    var query = ""
    /// A provider id (`local`, `youtube`, ...); nil means every source.
    var source: String?

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isActive: Bool { !trimmedQuery.isEmpty || source != nil }
    /// Every word of the query, folded for comparison.
    var terms: [String] {
        MusicLibraryEngine.fold(trimmedQuery).split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

struct MusicLibraryViewState: Codable, Equatable, Sendable {
    var tab: MusicLibraryTab?
    var modes: [String: MusicLibraryViewMode] = [:]
    var sorts: [String: MusicLibrarySort] = [:]
    var reversed: [String: Bool] = [:]
    var filters: [String: MusicLibraryFilterState] = [:]
}

/// The one UserDefaults value (`music.library.view`, JSON) that holds the tab, view mode, sort and filters of every Library tab.
struct MusicLibraryPrefs: @unchecked Sendable {
    static let key = "music.library.view"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var state: MusicLibraryViewState {
        get {
            guard let s = defaults.string(forKey: Self.key), let d = s.data(using: .utf8),
                  let v = try? JSONDecoder().decode(MusicLibraryViewState.self, from: d) else { return MusicLibraryViewState() }
            return v
        }
        nonmutating set {
            guard let d = try? JSONEncoder().encode(newValue), let s = String(data: d, encoding: .utf8) else { return }
            defaults.set(s, forKey: Self.key)
        }
    }

    var tab: MusicLibraryTab? {
        get { state.tab }
        nonmutating set { var s = state; s.tab = newValue; state = s }
    }
    func mode(_ tab: MusicLibraryTab) -> MusicLibraryViewMode? { state.modes[tab.rawValue] }
    func setMode(_ m: MusicLibraryViewMode, for tab: MusicLibraryTab) { var s = state; s.modes[tab.rawValue] = m; state = s }

    func sort(_ tab: MusicLibraryTab) -> MusicLibrarySort {
        if let v = state.sorts[tab.rawValue], tab.sorts.contains(v) { return v }
        return tab.defaultSort
    }
    func reversed(_ tab: MusicLibraryTab) -> Bool { state.reversed[tab.rawValue] ?? false }
    func setSort(_ sort: MusicLibrarySort, reversed: Bool, for tab: MusicLibraryTab) {
        var s = state
        s.sorts[tab.rawValue] = sort
        s.reversed[tab.rawValue] = reversed
        state = s
    }

    func filter(_ tab: MusicLibraryTab) -> MusicLibraryFilterState { state.filters[tab.rawValue] ?? MusicLibraryFilterState() }
    func setFilter(_ f: MusicLibraryFilterState, for tab: MusicLibraryTab) {
        var s = state
        s.filters[tab.rawValue] = f.isActive ? f : nil
        state = s
    }
}

// MARK: - empty state

/// What an empty Library offers. Every action opens something that already exists.
enum MusicLibraryEmptyAction: String, CaseIterable, Identifiable, Sendable {
    case likeSong, newPlaylist, importMusic, explore, connectAccounts, localFiles, downloads
    var id: String { rawValue }

    var title: String {
        switch self {
        case .likeSong: Localized.string("Like a song")
        case .newPlaylist: Localized.string("New playlist")
        case .importMusic: Localized.string("Import music")
        case .explore: Localized.string("Browse Explore")
        case .connectAccounts: Localized.string("Connect a library")
        case .localFiles: Localized.string("Add local files")
        case .downloads: Localized.string("Open Downloads")
        }
    }

    var detail: String {
        switch self {
        case .likeSong: Localized.string("Find something in Search or Explore and tap its heart.")
        case .newPlaylist: Localized.string("Make a playlist and add songs as you go.")
        case .importMusic: Localized.string("Bring playlists and likes from another service.")
        case .explore: Localized.string("Look through genres, moods and charts.")
        case .connectAccounts: Localized.string("Show your YouTube Music or Spotify library here.")
        case .localFiles: Localized.string("Play music stored in folders on this Mac.")
        case .downloads: Localized.string("Songs you saved for offline listening.")
        }
    }

    var symbol: String {
        switch self {
        case .likeSong: "heart"; case .newPlaylist: "plus.square.on.square"; case .importMusic: "arrow.down.doc"; case .explore: "safari"
        case .connectAccounts: "person.crop.circle.badge.checkmark"; case .localFiles: "internaldrive"; case .downloads: "arrow.down.circle"
        }
    }

    /// Where the action leads. A pure mapping so the wiring is tested; the page performs it.
    enum Destination: Equatable, Sendable {
        case section(MusicSection)
        case settings(MusicSettingsTab)
        case newPlaylistPrompt
        case importSheet
    }

    var destination: Destination {
        switch self {
        case .likeSong: .section(.search)
        case .newPlaylist: .newPlaylistPrompt
        case .importMusic: .importSheet
        case .explore: .section(.explore)
        case .connectAccounts: .settings(.plugins)
        case .localFiles: .settings(.data)
        case .downloads: .section(.downloads)
        }
    }

    /// The actions an empty tab shows, in order.
    static func actions(for tab: MusicLibraryTab) -> [MusicLibraryEmptyAction] {
        switch tab {
        case .songs: [.likeSong, .importMusic, .explore, .connectAccounts, .localFiles]
        case .albums: [.explore, .importMusic, .connectAccounts]
        case .artists: [.explore, .importMusic, .connectAccounts]
        case .playlists: [.newPlaylist, .importMusic, .connectAccounts]
        case .podcasts: [.explore]
        case .history: [.explore, .likeSong]
        case .local: [.localFiles]
        }
    }
}

// MARK: - the engine

/// What the engine needs to know about one row of any tab, taken once and kept: folded text for searching and sorting, plus numbers.
struct MusicLibraryEntry: Sendable, Equatable {
    var title = ""
    var subtitle = ""
    var album = ""
    var provider = ""
    var durationMs: Int64 = 0
    /// 1 for a podcast episode.
    var isPodcast = false
    /// Seconds since 1970 of the last play, 0 when never played.
    var playedAt: Double = 0
    /// How many times it was played over the whole history; 0 when never played.
    var plays = 0
    /// Seconds since 1970 the item was created (a playlist); 0 when unknown.
    var created: Double = 0
    var year = 0
    /// Everything the quick filter searches, folded.
    var haystack = ""
    var sortTitle = ""
    var sortSubtitle = ""
    var sortAlbum = ""
}

struct MusicLibraryRequest: Equatable, Sendable {
    var sort: MusicLibrarySort
    var reversed = false
    var filter = MusicLibraryFilterState()
}

enum MusicLibraryEngine {
    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }

    static func entry(title: String, subtitle: String, album: String = "", provider: String, durationMs: Int64 = 0, isPodcast: Bool = false,
                      playedAt: Double = 0, created: Double = 0, year: Int = 0, plays: Int = 0) -> MusicLibraryEntry {
        let t = fold(title), s = fold(subtitle), a = fold(album)
        return MusicLibraryEntry(title: title, subtitle: subtitle, album: album, provider: provider, durationMs: durationMs, isPodcast: isPodcast,
                                 playedAt: playedAt, plays: plays, created: created, year: year, haystack: t + " " + s + " " + a, sortTitle: t, sortSubtitle: s, sortAlbum: a)
    }

    static func trackEntry(_ t: MusicTrack, playedAt: Double = 0, plays: Int = 0) -> MusicLibraryEntry {
        entry(title: t.title, subtitle: t.artistLine, album: t.album?.title ?? "", provider: t.providerID, durationMs: t.durationMs,
              isPodcast: t.isPodcast == true, playedAt: playedAt, plays: plays)
    }

    static func albumEntry(_ a: MusicAlbum) -> MusicLibraryEntry {
        entry(title: a.title, subtitle: a.artists.map(\.name).joined(separator: ", "), provider: a.providerID, year: year(of: a.releaseDate))
    }

    static func artistEntry(_ a: MusicArtist) -> MusicLibraryEntry {
        entry(title: a.name, subtitle: a.genres.joined(separator: ", "), provider: a.providerID)
    }

    static func playlistEntry(_ p: LocalPlaylist) -> MusicLibraryEntry {
        entry(title: p.name, subtitle: "", provider: "local", created: p.created.timeIntervalSince1970)
    }

    /// The year at the start of a release date such as "2019-05-03" or "2019"; 0 when there is none.
    static func year(of date: String?) -> Int {
        guard let date, date.count >= 4, let y = Int(date.prefix(4)), (1000...3000).contains(y) else { return 0 }
        return y
    }

    /// The last time each track was played, by `uid`. History arrives newest first, so the first sighting wins.
    static func lastPlayed(_ history: [PlayRecord]) -> [String: Double] {
        var out: [String: Double] = [:]
        out.reserveCapacity(min(history.count, 20_000))
        for r in history where out[r.track.uid] == nil { out[r.track.uid] = r.at.timeIntervalSince1970 }
        return out
    }

    /// How many times each track was played over the whole history, by `uid`.
    static func playCounts(_ history: [PlayRecord]) -> [String: Int] {
        var out: [String: Int] = [:]
        out.reserveCapacity(min(history.count, 20_000))
        for r in history { out[r.track.uid, default: 0] += 1 }
        return out
    }

    private static func cmp(_ a: String, _ b: String) -> Int {
        switch a.compare(b, options: [.numeric]) { case .orderedAscending: -1; case .orderedSame: 0; case .orderedDescending: 1 }
    }

    /// The indices of `entries` in the natural order of `sort`: newest first for the time sorts, A to Z for the text sorts, shortest first for
    /// duration, the source order for `userOrder`. Ties keep the source order, so the result is the same every time.
    static func order(_ entries: [MusicLibraryEntry], sort: MusicLibrarySort) -> [Int] {
        let n = entries.count
        var idx = Array(0..<n)
        func by(_ less: @escaping (MusicLibraryEntry, MusicLibraryEntry) -> Int) {
            idx.sort { a, b in
                let c = less(entries[a], entries[b])
                return c != 0 ? c < 0 : a < b
            }
        }
        switch sort {
        case .recentlyAdded, .userOrder: break
        case .mostPlayed: by { $0.plays != $1.plays ? ($0.plays > $1.plays ? -1 : 1) : ($0.playedAt == $1.playedAt ? 0 : ($0.playedAt > $1.playedAt ? -1 : 1)) }
        case .recentlyPlayed: by { $0.playedAt == $1.playedAt ? 0 : ($0.playedAt > $1.playedAt ? -1 : 1) }
        case .title: by { cmp($0.sortTitle, $1.sortTitle) }
        case .artist: by { let c = cmp($0.sortSubtitle, $1.sortSubtitle); return c != 0 ? c : cmp($0.sortTitle, $1.sortTitle) }
        case .album: by { let c = cmp($0.sortAlbum, $1.sortAlbum); return c != 0 ? c : cmp($0.sortTitle, $1.sortTitle) }
        case .releaseDate: by { $0.year == $1.year ? 0 : ($0.year > $1.year ? -1 : 1) }
        case .duration: by { $0.durationMs == $1.durationMs ? 0 : ($0.durationMs < $1.durationMs ? -1 : 1) }
        }
        return idx
    }

    /// Keeps the indices of `order` whose entry passes the filter, in the same order, then reverses when asked.
    static func select(order: [Int], entries: [MusicLibraryEntry], filter: MusicLibraryFilterState, reversed: Bool) -> [Int] {
        let terms = filter.terms
        var out: [Int]
        if terms.isEmpty && filter.source == nil { out = order }
        else {
            out = order.filter { i in
                let e = entries[i]
                if let s = filter.source, e.provider != s { return false }
                for t in terms where !e.haystack.contains(t) { return false }
                return true
            }
        }
        return reversed ? out.reversed() : out
    }

    /// Distinct providers with how many entries each, most first. Feeds the source filter menu.
    static func providers(_ entries: [MusicLibraryEntry]) -> [(id: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in entries { counts[e.provider, default: 0] += 1 }
        return counts.map { (id: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
    }
}

// MARK: - history paging

enum MusicLibraryHistoryPaging {
    static let pageSize = 500
    /// How many of `total` records to show after `pages` pages were asked for.
    static func visible(total: Int, pages: Int) -> Int { min(total, max(1, pages) * pageSize) }
}

/// Which rows start a new day in a history list that is in time order.
enum MusicLibraryHistoryDays {
    static func startsDay(_ i: Int, dates: [Date], calendar: Calendar = .current) -> Bool {
        guard dates.indices.contains(i) else { return false }
        return i == 0 || !calendar.isDate(dates[i], inSameDayAs: dates[i - 1])
    }
}
