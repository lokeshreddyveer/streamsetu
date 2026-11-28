import Foundation

// The queue panel's structure as pure values: which part of the queue a row belongs to, where each part starts, the search over rows and the
// selection rules. The queue itself stays `MusicQueue`; nothing here keeps a second copy of it.

/// The parts of the queue, in the order they appear: played rows, the playing row, rows put next by hand, the rest of the queue and the rows autoplay added.
enum MusicQueueSection: Int, Sendable, CaseIterable, Equatable {
    case played, nowPlaying, playNext, upNext, autoplay

    /// The English wording (the key in the Hindi and Telugu tables).
    var title: String {
        switch self {
        case .played: "Previously played"
        case .nowPlaying: "Now playing"
        case .playNext: "Play next"
        case .upNext: "Up next"
        case .autoplay: "Autoplay"
        }
    }
}

enum MusicQueueSections {
    /// The part row `i` belongs to. With no playing row everything counts as Up next.
    static func section(of e: MusicQueue.Entry, at i: Int, current: Int?) -> MusicQueueSection {
        guard let c = current else { return e.auto ? .autoplay : .upNext }
        if i < c { return .played }
        if i == c { return .nowPlaying }
        if e.auto { return .autoplay }
        if e.queued { return .playNext }
        return .upNext
    }

    /// The row index each part starts at (a header goes in front of that row). A part with no rows has none.
    static func headers(rows: [MusicQueue.Entry], current: Int?) -> [Int: MusicQueueSection] {
        var out: [Int: MusicQueueSection] = [:]
        var previous: MusicQueueSection?
        for (i, e) in rows.enumerated() {
            let s = section(of: e, at: i, current: current)
            if s != previous { out[i] = s }
            previous = s
        }
        return out
    }

    /// How many rows each part holds, for the header's count.
    static func counts(rows: [MusicQueue.Entry], current: Int?) -> [MusicQueueSection: Int] {
        var out: [MusicQueueSection: Int] = [:]
        for (i, e) in rows.enumerated() { out[section(of: e, at: i, current: current), default: 0] += 1 }
        return out
    }

    /// Whether a row matches the words typed in the queue search: every word must appear in the title, the artists or the album, ignoring case and accents.
    static func matches(_ e: MusicQueue.Entry, query: String) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return true }
        let t = e.track
        let hay = [t.title, t.artistLine, t.album?.title ?? ""].joined(separator: " ")
        return words.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The row indices that match, in queue order. An empty query matches everything.
    static func matchingIndices(rows: [MusicQueue.Entry], query: String) -> [Int] {
        rows.indices.filter { matches(rows[$0], query: query) }
    }

    /// The ids a bulk remove may touch: the selected rows that still exist and come after the playing one (Undo brings back upcoming rows only; played rows and the
    /// playing row are never part of it). With nothing playing every selected row counts.
    static func removableIDs(selected: Set<UUID>, rows: [MusicQueue.Entry], current: Int?) -> Set<UUID> {
        var out = Set<UUID>()
        for (i, e) in rows.enumerated() where selected.contains(e.id) {
            if let c = current, i <= c { continue }
            out.insert(e.id)
        }
        return out
    }

    /// Where "Move to Bottom" sends row `from`: the end of the person's own rows, which is just in front of the autoplay rows. An autoplay row goes to the very end.
    static func bottomIndex(rows: [MusicQueue.Entry], from: Int, current: Int?) -> Int {
        let end = max(0, rows.count - 1)
        guard let c = current, rows.indices.contains(from), !rows[from].auto,
              let a = rows.indices.first(where: { $0 > c && $0 != from && rows[$0].auto }) else { return end }
        return from < a ? a - 1 : a
    }

    /// Whether "Move Down" would do anything for row `i`: not on the last row, and not for a row of the list that already sits just above the autoplay rows.
    static func canMoveDown(rows: [MusicQueue.Entry], row i: Int) -> Bool {
        guard rows.indices.contains(i), i + 1 < rows.count else { return false }
        return rows[i].auto || !rows[i + 1].auto
    }

    /// Whether the playing row is out of sight: `firstVisible` is the first row on screen and `visibleCount` how many fit.
    static func currentIsOffscreen(current: Int?, firstVisible: Int, visibleCount: Int) -> Bool {
        guard let c = current else { return false }
        return c < firstVisible || c > firstVisible + max(1, visibleCount) - 1
    }
}
