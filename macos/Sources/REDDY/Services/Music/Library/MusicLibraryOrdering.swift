import Foundation

// Sorting, filtering and column rules for track lists, as pure functions so every list (playlists, liked songs, history, local music) behaves the same
// and the rules can be tested without a screen.

enum MusicTrackSortKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case `default`, newest, oldest, title, artist, album, mostPlayed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .default: "Default"; case .newest: "Newest first"; case .oldest: "Oldest first"; case .title: "Title"
        case .artist: "Artist"; case .album: "Album"; case .mostPlayed: "Most played"
        }
    }
}

enum MusicLibraryOrdering {
    // MARK: filter

    /// Substring over title, artist and album, case-insensitive. `query` is already trimmed and lowercased by callers that loop, but is lowercased here too.
    static func matches(_ t: MusicTrack, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return t.title.lowercased().contains(q) || t.artistLine.lowercased().contains(q) || (t.album?.title.lowercased().contains(q) ?? false)
    }

    static func filter(_ tracks: [MusicTrack], query: String) -> [MusicTrack] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return q.isEmpty ? tracks : tracks.filter { matches($0, query: q) }
    }

    /// Instant search over the local library: every whitespace separated term must appear in the text, in any order. Ranked by the title: equals the
    /// query (0), starts with it (1), contains it (2), otherwise (3). Inside a rank the original order is kept. An empty query returns everything.
    static func localSearch<T>(_ items: [T], query: String, title: (T) -> String, text: (T) -> String) -> [T] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        let terms = q.split(whereSeparator: \.isWhitespace).map(String.init)
        var ranked: [(rank: Int, offset: Int, item: T)] = []
        for (i, item) in items.enumerated() {
            let hay = text(item).lowercased()
            guard terms.allSatisfy({ hay.contains($0) }) else { continue }
            let t = title(item).lowercased()
            ranked.append((t == q ? 0 : t.hasPrefix(q) ? 1 : t.contains(q) ? 2 : 3, i, item))
        }
        return ranked.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.offset < $1.offset }.map(\.item)
    }

    // MARK: sort

    /// Numeric-aware ("track 9" before "track 10"), case and accent insensitive.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.numeric, .caseInsensitive, .diacriticInsensitive], range: nil, locale: .current)
    }

    /// Sorts a track list. A direction toggle reverses whatever the key produced and nothing else. Ties keep the list's own order, and the result always holds
    /// the same tracks. `arrivesNewestFirst` is true for lists whose rows arrive newest first (liked songs); ordinary playlists arrive oldest first.
    static func sorted(_ tracks: [MusicTrack], by key: MusicTrackSortKey, descending: Bool = false, playCounts: [String: Int] = [:], arrivesNewestFirst: Bool = false) -> [MusicTrack] {
        guard tracks.count > 1 else { return tracks }
        let indexed = Array(tracks.enumerated())
        func stable(_ before: (MusicTrack, MusicTrack) -> ComparisonResult) -> [MusicTrack] {
            indexed.sorted { a, b in
                let c = before(a.element, b.element)
                return c != .orderedSame ? c == .orderedAscending : a.offset < b.offset
            }.map(\.element)
        }
        var out: [MusicTrack]
        switch key {
        case .default:
            out = tracks
        case .newest:
            out = arrivesNewestFirst ? tracks : tracks.reversed()
        case .oldest:
            out = arrivesNewestFirst ? tracks.reversed() : tracks
        case .title:
            out = stable { compare($0.title, $1.title) }
        case .artist:
            out = stable { a, b in
                let c = compare(a.artistLine, b.artistLine)
                return c != .orderedSame ? c : compare(a.title, b.title)
            }
        case .album:
            // Albumless tracks are always last, and tracks inside one album keep the playlist's own order.
            var order: [String] = [], groups: [String: [MusicTrack]] = [:], titles: [String: String] = [:], albumless: [MusicTrack] = []
            for t in tracks {
                guard let a = t.album, !a.title.trimmingCharacters(in: .whitespaces).isEmpty else { albumless.append(t); continue }
                let k = a.id.isEmpty ? a.title.lowercased() : a.id
                if groups[k] == nil { order.append(k); titles[k] = a.title }
                groups[k, default: []].append(t)
            }
            var keys = order.enumerated().sorted { x, y in
                let c = compare(titles[x.element] ?? "", titles[y.element] ?? "")
                return c != .orderedSame ? c == .orderedAscending : x.offset < y.offset
            }.map(\.element)
            if descending { keys.reverse() }
            return keys.flatMap { groups[$0] ?? [] } + albumless
        case .mostPlayed:
            out = indexed.sorted { a, b in
                let x = playCounts[a.element.uid] ?? 0, y = playCounts[b.element.uid] ?? 0
                return x != y ? x > y : a.offset < b.offset
            }.map(\.element)
            if descending {
                // Least played first, with ties still in the playlist's order.
                out = indexed.sorted { a, b in
                    let x = playCounts[a.element.uid] ?? 0, y = playCounts[b.element.uid] ?? 0
                    return x != y ? x < y : a.offset < b.offset
                }.map(\.element)
            }
            return out
        }
        if descending { out.reverse() }
        return out
    }

    // MARK: reorder

    /// Drag reordering is allowed only on the real order of the whole list.
    static func canReorder(filterActive: Bool, sort: MusicTrackSortKey, descending: Bool, selecting: Bool, saving: Bool, moreToLoad: Bool = false) -> Bool {
        !filterActive && sort == .default && !descending && !selecting && !saving && !moreToLoad
    }

    /// Moves `moving` in front of `before` (nil = to the end). Returns nil when either id is missing or nothing would change.
    static func moveBefore(_ ids: [String], moving: String, before: String?) -> [String]? {
        guard let from = ids.firstIndex(of: moving) else { return nil }
        if let before, before == moving { return nil }
        var rest = ids; rest.remove(at: from)
        let to: Int
        if let before { guard let i = rest.firstIndex(of: before) else { return nil }; to = i } else { to = rest.count }
        rest.insert(moving, at: to)
        return rest == ids ? nil : rest
    }

    /// A drop on the upper half of a row lands before it, on the lower half after it (before the next row, or at the end).
    static func dropTarget(rows: [String], hovered: String, upperHalf: Bool) -> String? {
        guard let i = rows.firstIndex(of: hovered) else { return nil }
        if upperHalf { return hovered }
        return i + 1 < rows.count ? rows[i + 1] : nil
    }

    // MARK: columns

    enum Column: String, CaseIterable, Codable, Sendable { case album, dateAdded, addedBy, plays, yourPlays, duration }

    static let defaultColumns: [Column] = [.album, .dateAdded, .addedBy, .plays, .duration]

    /// What a list can fill. A column is offered only if at least one row has something for it; "your plays" and duration always are.
    struct ColumnContext: Sendable {
        var onAlbumPage = false, someRowHasAlbum = true, someRowHasDate = false, someRowHasAddedBy = false, someRowHasPlays = false, collaborative = false
    }

    static func offered(_ c: ColumnContext) -> [Column] {
        Column.allCases.filter {
            switch $0 {
            case .album: !c.onAlbumPage && c.someRowHasAlbum
            case .dateAdded: c.someRowHasDate && !c.collaborative
            case .addedBy: c.someRowHasAddedBy
            case .plays: c.someRowHasPlays
            case .yourPlays, .duration: true
            }
        }
    }

    /// Columns that fit the measured width: Album from 640, Your plays from 704, Date added from 832. Narrower lists drop Date added, then Your plays, then Album.
    static func fitting(_ chosen: [Column], width: Double) -> [Column] {
        chosen.filter {
            switch $0 {
            case .album: width >= 640
            case .yourPlays: width >= 704
            case .dateAdded: width >= 832
            default: true
            }
        }
    }

    /// Reads a stored list: unknown ids are dropped and a broken or empty value gives the defaults.
    static func parseColumns(_ raw: [String]?) -> [Column] {
        guard let raw else { return defaultColumns }
        let cols = raw.compactMap(Column.init(rawValue:))
        return cols.isEmpty ? defaultColumns : cols
    }

    // MARK: recent searches

    static let recentSearchLimit = 10

    /// Newest first, at most 10; duplicates ignoring case and spacing collapse to the last typed spelling; runs of spaces collapse; blank is ignored.
    static func addingRecentSearch(_ query: String, to list: [String]) -> [String] {
        let clean = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty else { return list }
        let key = clean.lowercased()
        var out = list.filter { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() != key }
        out.insert(clean, at: 0)
        return Array(out.prefix(recentSearchLimit))
    }

    // MARK: pins

    static let pinLimit = 3
    /// Pins a playlist id; a fourth is refused (nil) so the caller can tell the person.
    static func pinning(_ id: String, in pins: [String]) -> [String]? {
        if pins.contains(id) { return pins }
        return pins.count >= pinLimit ? nil : pins + [id]
    }
}
