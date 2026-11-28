import Foundation

// Playlist rules (pure): sort, drag-reorder permission and drop position, unique-track adds, and the undo log for destructive edits and reorders.

struct MusicPlaylistItem: Hashable, Sendable {
    var uid: String
    var title: String
    var artist: String
    var album: String?
    var addedAt: Date?
    var plays: Int = 0
}

enum MusicPlaylistSortKey: String, CaseIterable, Sendable { case `default`, newest, oldest, title, artist, album, mostPlayed }

enum MusicPlaylistRules {
    /// Natural-number, case-insensitive comparison ("Track 2" before "Track 10").
    static func natural(_ a: String, _ b: String) -> ComparisonResult { a.compare(b, options: [.caseInsensitive, .numeric, .diacriticInsensitive]) }

    /// `sourceListsNewestFirst`: Liked-style lists list newest first, everything else oldest first; "newest" and "oldest" depend on it. A flipped direction
    /// reverses the final order. Ties keep the playlist's own order. Album sort groups an album's songs (kept in playlist order inside the group) and puts
    /// songs with no album last; artist sort breaks ties on title; most played uses the local play counts.
    static func sorted(_ items: [MusicPlaylistItem], by key: MusicPlaylistSortKey, descending: Bool = false, sourceListsNewestFirst: Bool = false) -> [MusicPlaylistItem] {
        let indexed = Array(items.enumerated())
        func less(_ a: (offset: Int, element: MusicPlaylistItem), _ b: (offset: Int, element: MusicPlaylistItem)) -> Bool {
            let x = a.element, y = b.element
            switch key {
            case .default: return a.offset < b.offset
            case .newest, .oldest:
                // listing order stands in for the date when none is stored
                let dx = x.addedAt ?? Date(timeIntervalSince1970: Double(sourceListsNewestFirst ? -a.offset : a.offset)), dy = y.addedAt ?? Date(timeIntervalSince1970: Double(sourceListsNewestFirst ? -b.offset : b.offset))
                if dx != dy { return key == .newest ? dx > dy : dx < dy }
                return a.offset < b.offset
            case .title:
                let c = natural(x.title, y.title); return c != .orderedSame ? c == .orderedAscending : a.offset < b.offset
            case .artist:
                let c = natural(x.artist, y.artist); if c != .orderedSame { return c == .orderedAscending }
                let t = natural(x.title, y.title); return t != .orderedSame ? t == .orderedAscending : a.offset < b.offset
            case .album:
                switch (x.album, y.album) {
                case (nil, nil): return a.offset < b.offset
                case (nil, _): return false
                case (_, nil): return true
                case (let p?, let q?):
                    let c = natural(p, q)
                    if c != .orderedSame { return c == .orderedAscending }
                    return a.offset < b.offset   // inside one album: playlist order
                }
            case .mostPlayed:
                return x.plays != y.plays ? x.plays > y.plays : a.offset < b.offset
            }
        }
        let out = indexed.sorted(by: less).map(\.element)
        return descending ? out.reversed() : out
    }

    /// Drag-reorder works only on a playlist the person owns, in the default manual order (not flipped), with no filter and no selection.
    static func reorderAllowed(owned: Bool, sort: MusicPlaylistSortKey, flipped: Bool, filterActive: Bool, selecting: Bool) -> Bool {
        owned && sort == .default && !flipped && !filterActive && !selecting
    }

    /// The row a drop lands on: above the row's middle drops before it, below drops after it.
    static func dropIndex(row: Int, pointerY: Double, rowMidY: Double) -> Int { pointerY < rowMidY ? row : row + 1 }

    /// Moves one row (the index is the position BEFORE removal, as a list drop reports it).
    static func move(_ uids: [String], from: Int, toGap gap: Int) -> [String] {
        guard uids.indices.contains(from), gap >= 0, gap <= uids.count else { return uids }
        var out = uids
        let item = out.remove(at: from)
        out.insert(item, at: gap > from ? gap - 1 : gap)
        return out
    }

    /// Adds without duplicating: returns the new list, how many were added and how many were already there.
    static func adding(_ new: [String], to uids: [String]) -> (list: [String], added: Int, duplicates: Int) {
        var have = Set(uids), out = uids, added = 0
        for u in new where have.insert(u).inserted { out.append(u); added += 1 }
        return (out, added, new.count - added)
    }
}

/// An edit that can be undone: what changed, with enough to put it back exactly. The toast shows "Removed 3 songs. Undo" for about eight seconds.
enum MusicPlaylistEdit: Equatable, Sendable {
    case removed([(index: Int, uid: String)])
    case reordered(before: [String])
    case cleared(before: [String])
    case added(uids: [String])

    static func == (a: MusicPlaylistEdit, b: MusicPlaylistEdit) -> Bool {
        switch (a, b) {
        case (.removed(let x), .removed(let y)): return x.map(\.index) == y.map(\.index) && x.map(\.uid) == y.map(\.uid)
        case (.reordered(let x), .reordered(let y)), (.cleared(let x), .cleared(let y)): return x == y
        case (.added(let x), .added(let y)): return x == y
        default: return false
        }
    }
}

struct MusicPlaylistEditLog: Sendable {
    static let capacity = 20
    private(set) var stack: [MusicPlaylistEdit] = []
    var canUndo: Bool { !stack.isEmpty }
    var last: MusicPlaylistEdit? { stack.last }

    /// Removes songs and records where each was.
    mutating func remove(_ uids: Set<String>, from list: [String]) -> [String] {
        let removed = list.enumerated().filter { uids.contains($0.element) }.map { (index: $0.offset, uid: $0.element) }
        guard !removed.isEmpty else { return list }
        push(.removed(removed))
        return list.filter { !uids.contains($0) }
    }
    mutating func reorder(_ newOrder: [String], from list: [String]) -> [String] {
        guard newOrder != list else { return list }
        push(.reordered(before: list)); return newOrder
    }
    mutating func clear(_ list: [String]) -> [String] { guard !list.isEmpty else { return list }; push(.cleared(before: list)); return [] }
    mutating func add(_ uids: [String], to list: [String]) -> [String] {
        let r = MusicPlaylistRules.adding(uids, to: list)
        if r.added > 0 { push(.added(uids: Array(uids.filter { !list.contains($0) }))) }
        return r.list
    }

    /// Reverses the newest edit on `list` and returns the list as it was.
    mutating func undo(_ list: [String]) -> [String] {
        guard let e = stack.popLast() else { return list }
        switch e {
        case .removed(let removed):
            var out = list
            for r in removed.sorted(by: { $0.index < $1.index }) where !out.contains(r.uid) { out.insert(r.uid, at: min(r.index, out.count)) }
            return out
        case .reordered(let before), .cleared(let before): return before
        case .added(let uids): return list.filter { !uids.contains($0) }
        }
    }

    private mutating func push(_ e: MusicPlaylistEdit) { stack.append(e); if stack.count > Self.capacity { stack.removeFirst() } }
    mutating func reset() { stack = [] }
}

/// Home look-ahead: how many continuation pages to walk up front. Only while a section the person ranked above the first loaded one is still missing,
/// never more than `maxPages`; the rest of the feed loads by scroll.
enum MusicHomeLookAhead {
    static let maxPages = 6
    static func pagesToWalk(rankedKeys: [String], loaded: Set<String>, pagesWalked: Int, forgottenWanted: Bool = false) -> Int {
        guard pagesWalked < maxPages else { return 0 }
        let missing = rankedKeys.contains { !loaded.contains($0) } || forgottenWanted
        return missing ? maxPages - pagesWalked : 0
    }
}
