import Foundation

/// The rules that keep a shelf from being one artist, one language or one repeated song, and that keep the same thing off two shelves.
enum HomeDiversity {
    /// How many of one artist a shelf may hold.
    static let maxPerArtist = 2
    /// A mix of twenty songs may hold a little more of one artist than a shelf of cards does.
    static let mixMaxPerArtist = 3
    /// Share of a mix or shelf that is unfamiliar but adjacent, and its bounds.
    static let explorationShare = 0.2
    static let explorationBounds = 0.1...0.3

    /// What the page has already shown: an item is claimed once, whatever its spelling (the same recording from two providers is one).
    struct Claims: Sendable {
        private(set) var keys = Set<String>()

        func has(_ item: HomeItem) -> Bool { item.keys.contains { keys.contains($0) } || keys.contains(item.id) }
        mutating func claim(_ item: HomeItem) { keys.formUnion(item.keys); keys.insert(item.id) }
        /// The items not claimed yet, without repeats inside the list itself.
        func fresh(_ items: [HomeItem]) -> [HomeItem] {
            var local = self
            var out: [HomeItem] = []
            for i in items where !local.has(i) { local.claim(i); out.append(i) }
            return out
        }
    }

    /// Orders `items` so the same artist never sits twice in a row and no artist has more than `maxPerArtist`. Items with no artist are never held back.
    /// The input order is kept as far as the rules allow. An item that cannot be placed is dropped rather than breaking a rule.
    static func spread(_ items: [HomeItem], maxPerArtist: Int = maxPerArtist) -> [HomeItem] {
        // With one artist in the list there is nothing to spread (an artist's own mix, a listener who only plays one artist): the list is kept as it is.
        if Set(items.map(\.artistKey).filter { !$0.isEmpty }).count <= 1 { return items }
        var pending = items
        var out: [HomeItem] = []
        var count: [String: Int] = [:]
        while !pending.isEmpty {
            let last = out.last?.artistKey ?? ""
            guard let i = pending.firstIndex(where: { it in
                it.artistKey.isEmpty || (it.artistKey != last && (count[it.artistKey] ?? 0) < maxPerArtist)
            }) else { break }
            let it = pending.remove(at: i)
            if !it.artistKey.isEmpty { count[it.artistKey, default: 0] += 1 }
            out.append(it)
        }
        return out
    }

    /// Picks `limit` items so each bucket (writing system) gets about its own share of the slots: at every step the bucket that is furthest behind its
    /// share goes next. Buckets over 70% of a mixed shelf are held to that, and a bucket with at least 8% always gets a slot. Artist rules apply as in `spread`.
    /// `share` is the person's own mix; with no share (or one bucket) the candidates keep their order.
    static func interleave(_ candidates: [HomeItem], share: [String: Double], limit: Int, maxPerArtist: Int = maxPerArtist) -> [HomeItem] {
        guard limit > 0 else { return [] }
        let known = share.filter { $0.value > 0 }
        guard known.count > 1 else { return Array(spread(candidates, maxPerArtist: maxPerArtist).prefix(limit)) }
        var queues: [String: [HomeItem]] = [:]
        for c in candidates { queues[known[c.bucket] != nil ? c.bucket : "", default: []].append(c) }
        var capped = known
        if let top = capped.max(by: { $0.value < $1.value }), top.value > 0.7 {
            let extra = top.value - 0.7
            capped[top.key] = 0.7
            for k in capped.keys where k != top.key { capped[k, default: 0] += extra / Double(max(1, capped.count - 1)) }
        }
        let order = capped.keys.sorted { capped[$0]! != capped[$1]! ? capped[$0]! > capped[$1]! : $0 < $1 }
        var taken: [String: Int] = [:]
        var out: [HomeItem] = []
        var perArtist: [String: Int] = [:]
        while out.count < limit {
            let last = out.last?.artistKey ?? ""
            func allowed(_ it: HomeItem) -> Bool { it.artistKey.isEmpty || (it.artistKey != last && (perArtist[it.artistKey] ?? 0) < maxPerArtist) }
            // the bucket furthest behind its share that still has a placeable item
            let n = Double(out.count + 1)
            let candidatesBuckets = order.filter { b in queues[b]?.contains(where: allowed) == true }
            guard let bucket = candidatesBuckets.max(by: { a, b in
                let da = capped[a]! * n - Double(taken[a] ?? 0), db = capped[b]! * n - Double(taken[b] ?? 0)
                return da != db ? da < db : a > b
            }) else {
                // buckets that have no share (unknown writing system) fill what is left
                guard let i = queues[""]?.firstIndex(where: allowed) else { break }
                let it = queues[""]!.remove(at: i)
                if !it.artistKey.isEmpty { perArtist[it.artistKey, default: 0] += 1 }
                out.append(it)
                continue
            }
            let i = queues[bucket]!.firstIndex(where: allowed)!
            let it = queues[bucket]!.remove(at: i)
            taken[bucket, default: 0] += 1
            if !it.artistKey.isEmpty { perArtist[it.artistKey, default: 0] += 1 }
            out.append(it)
        }
        return out
    }

    /// How many unfamiliar items a list of `size` takes: about 20%, never above 30%, and at least one in a list of ten or more when there is one to add.
    static func explorationCount(size: Int, available: Int, share: Double = explorationShare) -> Int {
        guard size > 0, available > 0 else { return 0 }
        let s = min(max(share, explorationBounds.lowerBound), explorationBounds.upperBound)
        var n = Int((Double(size) * s).rounded())
        if size >= 10 { n = max(n, 1) }
        let cap = Int((Double(size) * explorationBounds.upperBound).rounded(.down))
        return min(available, n, max(cap, 1))
    }

    /// Mixes unfamiliar items into a familiar list at seeded positions (never the first slot), keeping the artist rule.
    static func blend(familiar: [HomeItem], adjacent: [HomeItem], maxPerArtist: Int = maxPerArtist, using rng: inout some RandomNumberGenerator) -> [HomeItem] {
        guard !adjacent.isEmpty else { return familiar }
        // one artist's own mix: the unfamiliar songs are placed in it as they are, there is nothing to spread
        let isOneArtist = Set(familiar.map(\.artistKey).filter { !$0.isEmpty }).count <= 1
        var out = familiar
        for a in adjacent {
            let at = out.isEmpty ? 0 : Int.random(in: min(1, out.count)...out.count, using: &rng)
            out.insert(a, at: at)
        }
        return isOneArtist ? out : spread(out, maxPerArtist: maxPerArtist)
    }
}
