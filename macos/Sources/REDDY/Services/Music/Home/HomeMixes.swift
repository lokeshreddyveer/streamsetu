import Foundation

/// "Made for you": mixes drawn from the person's own plays. A Daily mix, one mix per strongest artist, one per writing-system group when they listen
/// across several, one per genre of the artists they follow, and a mix of their likes. Names come from the data (an artist's name, a genre the artists
/// carry), never from a list. Each mix is a seeded weighted draw, spread by artist, with about a fifth of unfamiliar songs from next to what they play.
enum HomeMixes {
    static let size = 20
    static let minTracks = 8
    static let limit = 8
    static let artistMixCount = 3
    static let bucketMinShare = 0.15

    static func build(taste: HomeTaste, signals: HomeSignals, ctx: HomeContext, rng: inout some RandomNumberGenerator) -> [HomeItem] {
        let w = ctx.wording
        let network = !ctx.gated && !ctx.offline
        let pool = taste.tracks.filter { !ctx.offline || signals.downloaded.contains($0.track.uid) }
        guard pool.count >= minTracks else { return [] }
        let adjacentSongs = network ? signals.adjacent.filter { $0.kind == .track && $0.track != nil } : []
        var out: [HomeItem] = []
        var used: [Set<String>] = []

        func add(_ id: String, _ title: String, _ stats: [HomeTaste.TrackStat], adjacent: [HomeItem], spreadBuckets: Bool) {
            guard stats.count >= minTracks else { return }
            let extra = HomeDiversity.explorationCount(size: size, available: adjacent.count)
            let drawn = HomeRandom.sample(stats, count: size - extra, weight: { taste.drawWeight($0) }, using: &rng)
            let items = drawn.map { HomeItem.make($0.track) }
            let cap = HomeDiversity.mixMaxPerArtist
            let familiar = spreadBuckets ? HomeDiversity.interleave(items, share: taste.bucketShare, limit: size - extra, maxPerArtist: cap) : HomeDiversity.spread(items, maxPerArtist: cap)
            let picked = HomeRandom.sample(adjacent, count: extra, weight: { _ in 1 }, using: &rng)
            let tracks = HomeDiversity.blend(familiar: familiar, adjacent: picked, maxPerArtist: cap, using: &rng).compactMap(\.track)
            guard tracks.count >= minTracks else { return }
            let keys = Set(tracks.map { HomeKeys.recording($0) })
            // a mix that is mostly the same songs as one already made adds nothing
            if used.contains(where: { Double($0.intersection(keys).count) / Double(max(1, keys.count)) > 0.7 }) { return }
            used.append(keys)
            var names: [String] = []
            for t in tracks { if let n = t.artists.first?.name, !n.isEmpty, !names.contains(n) { names.append(n) }; if names.count == 3 { break } }
            out.append(.mix(id: id, title: title, subtitle: names.joined(separator: ", "), tracks: tracks))
        }

        add("daily", w.s("Daily mix"), pool, adjacent: adjacentSongs, spreadBuckets: true)

        // one mix per writing-system group the person really listens in (only with two or more)
        let groups = taste.bucketShare.filter { $0.value >= bucketMinShare }
        if groups.count >= 2 {
            for b in groups.keys.sorted(by: { groups[$0]! != groups[$1]! ? groups[$0]! > groups[$1]! : $0 < $1 }) {
                let stats = pool.filter { HomeKeys.bucket($0.track) == b }
                guard let lead = stats.first?.track.artists.first?.name, !lead.isEmpty else { continue }
                add("group-" + b, w.f("%@ and more", lead), stats, adjacent: [], spreadBuckets: false)
            }
        }

        for a in taste.artists.prefix(artistMixCount) {
            let stats = pool.filter { s in s.track.artists.prefix(2).contains { HomeKeys.fold($0.name) == a.key } }
            let near = adjacentSongs.filter { $0.becauseOf.map(HomeKeys.fold) == a.key }
            add("artist-" + a.key, w.f("%@ mix", a.name), stats, adjacent: near, spreadBuckets: false)
        }

        // a mix per genre the followed artists share (the genre text comes from the artists themselves)
        var byGenre: [String: (name: String, keys: Set<String>)] = [:]
        for f in signals.followed {
            for g in f.genres.prefix(3) {
                let k = HomeKeys.fold(g)
                guard !k.isEmpty else { continue }
                var e = byGenre[k] ?? (g, [])
                e.keys.insert(HomeKeys.fold(f.name)); byGenre[k] = e
            }
        }
        for (k, g) in byGenre.sorted(by: { $0.value.keys.count != $1.value.keys.count ? $0.value.keys.count > $1.value.keys.count : $0.key < $1.key }) where g.keys.count >= 2 {
            let stats = pool.filter { s in s.track.artists.prefix(2).contains { g.keys.contains(HomeKeys.fold($0.name)) } }
            add("genre-" + k, w.f("%@ mix", String(g.name.prefix(1)).uppercased() + String(g.name.dropFirst())), stats, adjacent: [], spreadBuckets: false)
            if out.count >= limit { break }
        }

        let liked = pool.filter { $0.liked }
        add("favourites", w.s("Favourites mix"), liked, adjacent: [], spreadBuckets: true)
        return Array(out.prefix(limit))
    }
}
