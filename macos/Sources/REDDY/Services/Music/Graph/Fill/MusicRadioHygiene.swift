import Foundation

// Radio and autoplay hygiene (pure): what a hop may add to the queue and in what order.
//   - id de-duplication on every hop: nothing already queued, and nothing twice inside the hop;
//   - a 30-day "heard recently" demotion: songs not heard in the last 30 days keep their order and come first, the heard ones follow;
//   - a cap of 20 per hop; if everything was dropped or heard, the hop escalates (it returns the heard ones too, flagged) instead of ending the radio;
//   - autoplay rows are marked and removable as one group.

struct MusicHopCandidate: Hashable, Sendable {
    var id: String
    /// The artist, for the "no more than two in a row" spacing the recommender applies.
    var artist: String? = nil
    var blocked = false
}

struct MusicHopResult: Hashable, Sendable {
    var ids: [String]
    /// Every candidate was heard recently or already queued, so the heard ones were let back in.
    var escalated: Bool
    /// How many were demoted behind unheard songs.
    var demoted: Int
}

enum MusicRadioHygiene {
    static let hopLimit = 20
    static let heardDays = 30

    static func nextHop(_ candidates: [MusicHopCandidate], queued: Set<String>, lastHeard: [String: Date], now: Date = Date(), limit: Int = hopLimit,
                        maxRun: Int = 2) -> MusicHopResult {
        var seen = queued
        let fresh = candidates.filter { !$0.blocked && seen.insert($0.id).inserted }
        let cutoff = now.addingTimeInterval(-Double(heardDays) * 86_400)
        func heard(_ c: MusicHopCandidate) -> Bool { lastHeard[c.id].map { $0 >= cutoff } ?? false }
        let unheard = fresh.filter { !heard($0) }, heardOnes = fresh.filter(heard)
        var ordered = unheard
        var escalated = false
        if unheard.isEmpty, !heardOnes.isEmpty { ordered = heardOnes; escalated = true }
        else { ordered += heardOnes }
        let spaced = space(ordered, maxRun: maxRun, limit: limit)
        return MusicHopResult(ids: spaced.map(\.id), escalated: escalated, demoted: heardOnes.count)
    }

    /// No artist more than `maxRun` times in a row; otherwise the order is kept.
    static func space(_ items: [MusicHopCandidate], maxRun: Int, limit: Int) -> [MusicHopCandidate] {
        var pool = items, out: [MusicHopCandidate] = []
        var run = 0
        var last: String?
        while out.count < limit, !pool.isEmpty {
            let i = pool.firstIndex { c in !(c.artist != nil && c.artist == last && run >= maxRun) } ?? 0
            let c = pool.remove(at: i)
            run = (c.artist != nil && c.artist == last) ? run + 1 : 1
            last = c.artist
            out.append(c)
        }
        return out
    }

    struct QueueRow: Hashable, Sendable { var id: String; var isAutoplay: Bool; var isPlaying = false }

    /// Removes the autoplay rows after the playing row as one group; the playing row and the person's own rows stay.
    static func removeAutoplayGroup(_ queue: [QueueRow]) -> (remaining: [QueueRow], removed: [QueueRow]) {
        var remaining: [QueueRow] = [], removed: [QueueRow] = []
        for r in queue { if r.isAutoplay && !r.isPlaying { removed.append(r) } else { remaining.append(r) } }
        return (remaining, removed)
    }

    /// Puts a removed group back where it was (undo): by original index.
    static func restore(_ removed: [(index: Int, row: QueueRow)], into queue: [QueueRow]) -> [QueueRow] {
        var out = queue
        for (i, r) in removed.sorted(by: { $0.index < $1.index }) { out.insert(r, at: min(i, out.count)) }
        return out
    }
}
