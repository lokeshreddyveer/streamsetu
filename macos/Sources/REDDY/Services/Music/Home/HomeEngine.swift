import Foundation

/// Composes the Listen Now feed from signals: plays with recency and completion, likes, follows, the part of the day (a gentle nudge only), fresh releases,
/// unfamiliar-but-adjacent items, and the person's own songs, albums, playlists, films and genres. Never charts and never the first-run setup picks. Pure: the same signals, context and seed give the same feed, so
/// it runs off the main thread and is tested with synthetic listeners. It labels nothing by country; a language appears only as "More <language>" drawn from
/// the person's own plays, and the writing system of a title is otherwise used inside only, to spread a shelf in proportion to their mix.
enum HomeEngine {
    /// A shelf shorter than this is not shown.
    static let minItems = 3
    static let freshDays = 28.0
    static let onRepeatMinPlays = 3
    static let rediscoverGapDays = 60.0
    static let topTracksMin = 5
    static let topTracksShown = 8
    static let lightListenerPlays = 30
    static let continueLimit = 6

    // MARK: small rules

    private nonisolated(unsafe) static let isoDay: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(secondsFromGMT: 0); return f
    }()

    /// True when a release date ("2026-11-10"; a bare year says nothing) falls in the last 28 days.
    static func isFresh(releaseDate: String?, now: Date) -> Bool {
        guard let s = releaseDate, s.count >= 10 else { return false }
        guard let d = Self.isoDay.date(from: String(s.prefix(10))) else { return false }
        return d <= now.addingTimeInterval(86_400) && d >= now.addingTimeInterval(-freshDays * 86_400)
    }

    /// The song in the player first, then the last songs played, one entry per recording.
    static func continueItems(history: [PlayRecord], current: MusicTrack?, limit: Int = continueLimit) -> [HomeItem] {
        var seen = Set<String>()
        var out: [HomeItem] = []
        func add(_ t: MusicTrack) {
            guard out.count < limit else { return }
            let key = HomeKeys.recording(t)
            guard seen.insert(key).inserted else { return }
            out.append(.make(t))
        }
        if let current { add(current) }
        // Songs heard for under half their length are skips, not something to continue.
        for r in history where HomeTaste.counts(r) && !(r.track.isPodcast ?? false) { add(r.track); if out.count >= limit { break } }
        return out
    }

    static func mode(taste: HomeTaste, signals: HomeSignals, ctx: HomeContext) -> HomeFeed.Mode {
        if ctx.gated { return .gated }
        if ctx.offline { return .offline }
        if taste.countedPlays == 0 && signals.liked.isEmpty && signals.playlists.isEmpty && signals.followed.isEmpty { return .newUser }
        return taste.countedPlays < lightListenerPlays ? .light : .full
    }

    // MARK: compose

    static func compose(_ input: HomeSignals, ctx: HomeContext) -> HomeFeed {
        var signals = input
        if ctx.gated || ctx.offline { signals.releases = []; signals.adjacent = []; signals.films = [] }
        let w = ctx.wording
        let taste = HomeTaste.build(history: signals.history, liked: signals.liked, followed: signals.followed, now: ctx.now, calendar: ctx.calendar, languageOf: signals.trackLanguages)
        // What was ever played, a recommendations reset or a half-heard song included: nothing below calls such a thing new or unplayed.
        let heard = HomeHeard([signals.allHistory, signals.history])
        // "Next to what you play" is for things the person does not know yet: an answer cached hours ago is checked again against what they have played since.
        let known = Set(taste.tracks.map(\.key))
        signals.adjacent = signals.adjacent.filter { item in
            !taste.isFamiliar(artistKey: item.artistKey) && !(!item.artistKey.isEmpty && heard.has("art:" + item.artistKey))
                && item.keys.allSatisfy { !known.contains($0) && !heard.has($0) }
        }
        let mode = Self.mode(taste: taste, signals: signals, ctx: ctx)
        var feed = HomeFeed(seed: ctx.seed, composedAt: ctx.now, mode: mode)
        feed.continueItems = continueItems(history: signals.history, current: signals.current)
        var claims = HomeDiversity.Claims()
        let network = !ctx.gated && !ctx.offline
        func playable(_ t: MusicTrack) -> Bool { !ctx.offline || signals.downloaded.contains(t.uid) }

        // the hero first: it claims its item, so no shelf repeats it
        var heroRng = HomeRandom.child(of: ctx.seed, "hero")
        let pool = HomeHeroPicker.candidates(taste: taste, signals: signals, ctx: ctx, mode: mode, heard: heard)
        feed.hero = HomeHeroPicker.choose(pool, previous: ctx.heroHistory, using: &heroRng)
        if let h = feed.hero { claims.claim(h.item); feed.heroHistory = Array(([h.id] + ctx.heroHistory).prefix(5)) }
        else { feed.hidden.append("hero: no candidate with artwork") }
        feed.hidden.append("hero pool: \(pool.count) candidates")

        func finish(_ id: String, _ kind: HomeSectionKind, _ title: String, reason: String?, _ items: [HomeItem], min: Int = HomeEngine.minItems) {
            // Items another shelf already claimed are dropped first, and then the artists are spread again: dropping can leave two songs of one artist side by side.
            let fresh = HomeDiversity.spread(claims.fresh(items))
            guard fresh.count >= min else { feed.hidden.append("\(id): \(fresh.count) items, needs \(min)"); return }
            for i in fresh { claims.claim(i) }
            feed.sections.append(HomeSection(id: id, kind: kind, title: title, reason: reason, items: fresh))
        }

        // On repeat is worked out first, so Quick picks (a wider pool that contains these songs) cannot take them all; it is shown further down, where it always was.
        var deferredRepeat: HomeSection?
        do {
            var rng = HomeRandom.child(of: ctx.seed, "repeat")
            let stats = taste.tracks.filter { $0.recentPlays >= onRepeatMinPlays && playable($0.track) }
            let drawn = HomeRandom.sample(stats, count: 20, weight: { Double($0.recentPlays) + $0.weight }, using: &rng).map { HomeItem.make($0.track) }
            finish("onRepeat", .onRepeat, w.s("On repeat"), reason: w.s("Songs you have played again and again lately"), HomeDiversity.spread(drawn))
            if feed.sections.last?.kind == .onRepeat { deferredRepeat = feed.sections.removeLast() }
        }

        // Quick picks: songs the person plays and likes, ready to start (the first thing under the hero, like the services' "start here" row). Drawn anew each visit.
        do {
            var rng = HomeRandom.child(of: ctx.seed, "quick")
            let stats = taste.tracks.filter { ($0.liked || $0.plays >= 2) && playable($0.track) }
            let drawn = HomeRandom.sample(stats, count: 12, weight: { $0.weight + Double($0.plays) * 0.5 + ($0.liked ? 2 : 0) }, using: &rng).map { HomeItem.make($0.track) }
            finish("quickPicks", .quickPicks, w.s("Quick picks"), reason: w.s("Songs you like and play, to start in one tap"), HomeDiversity.spread(drawn), min: 6)
        }

        // The part of the day: songs the person really plays in the morning, afternoon, evening or late at night (counted from their own plays, nothing guessed).
        do {
            var rng = HomeRandom.child(of: ctx.seed, "daypart")
            let part = taste.daypart.rawValue
            let stats = taste.tracks.filter { part < $0.dayPlays.count && $0.dayPlays[part] >= 1 && playable($0.track) }
            let drawn = HomeRandom.sample(stats, count: 14, weight: { Double($0.dayPlays[part]) + $0.weight * 0.2 }, using: &rng).map { HomeItem.make($0.track) }
            let title: String
            switch taste.daypart { case .morning: title = "Your morning songs"; case .afternoon: title = "Your afternoon songs"; case .evening: title = "Your evening songs"; case .night: title = "Your late-night songs" }
            finish("timeOfDay", .timeOfDay, w.s(title), reason: w.s("Songs you often play at this time of day"), HomeDiversity.spread(drawn), min: 4)
        }

        // Made for you
        var mixRng = HomeRandom.child(of: ctx.seed, "mixes")
        finish("madeForYou", .madeForYou, w.s("Made for you"), reason: w.s("Mixes from what you play"), HomeMixes.build(taste: taste, signals: signals, ctx: ctx, rng: &mixRng))

        // New for you: fresh albums from artists they play that they have not played yet
        if network {
            var rng = HomeRandom.child(of: ctx.seed, "new")
            let played = Set(taste.tracks.compactMap { s -> String? in
                guard let a = s.track.album else { return nil }
                return "alb:" + HomeKeys.fold(a.title) + "|" + HomeKeys.fold((a.artists.first ?? s.track.artists.first)?.name ?? "")
            })
            let top = max(taste.topArtistWeight, 0.0001)
            let fresh = signals.releases.filter { isFresh(releaseDate: $0.releaseDate, now: ctx.now) && !played.contains(HomeKeys.album($0)) && !heard.has(HomeKeys.album($0)) && taste.artistWeight(named: $0.artists.first?.name ?? "") > 0 }
            let drawn = HomeRandom.sample(fresh, count: 14, weight: { 1 + taste.artistWeight(named: $0.artists.first?.name ?? "") / top }, using: &rng).map { HomeItem.make($0) }
            let spreadAlbums = HomeDiversity.spread(drawn)
            let near = signals.adjacent.filter { $0.kind == .album }
            let extra = HomeDiversity.explorationCount(size: max(spreadAlbums.count, 5), available: near.count)
            let picked = HomeRandom.sample(near, count: extra, weight: { _ in 1 }, using: &rng)
            let items = HomeDiversity.blend(familiar: spreadAlbums, adjacent: picked, using: &rng)
            finish("newForYou", .newForYou, w.s("New for you"), reason: w.s("From artists you play"), items)
        } else { feed.hidden.append("newForYou: no network") }

        // More in the languages the person listens to most: their own songs in that language
        do {
            // "latin" is a writing system, not a language (English and romanised titles fall there), so it never makes a "More ..." shelf.
            let shares = taste.bucketShare.filter { !$0.key.isEmpty && $0.key != MusicLanguage.latin.rawValue }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(2)
            for (bucket, _) in shares {
                guard let lang = MusicLanguage(rawValue: bucket) else { continue }
                var rng = HomeRandom.child(of: ctx.seed, "lang-" + bucket)
                let stats = taste.tracks.filter { taste.bucket($0.track) == bucket && playable($0.track) }
                // The person's own songs in this language, and new songs in it from the source (so the shelf is not limited to what they have already played): about half and half when there are both.
                // Songs another shelf has already claimed are left out before drawing (so the draw is from what is still free, and the shelf is not emptied by the shelves above it).
                let freeIDs = Set(claims.fresh(stats.map { HomeItem.make($0.track) }).map(\.id))
                let free = stats.filter { freeIDs.contains(HomeItem.make($0.track).id) }
                let own = HomeRandom.sample(free, count: 8, weight: { $0.weight + 0.2 }, using: &rng).map { s -> HomeItem in var i = HomeItem.make(s.track); i.bucket = bucket; return i }
                let ownKeys = Set(stats.map(\.key))
                let fresh = (signals.languageSongs[bucket] ?? []).filter { i in i.keys.allSatisfy { !ownKeys.contains($0) && !heard.has($0) } && (i.track.map(playable) ?? true) }
                let more = HomeRandom.sample(fresh, count: 16 - own.count, weight: { _ in 1 }, using: &rng).map { i -> HomeItem in var i = i; i.bucket = bucket; return i }
                let drawn = own + more
                let name = w.s(lang.englishName)
                finish("languageMix-" + bucket, .languageMix, w.f("More %@", name), reason: w.f("Songs in %@ from what you play and like", name), HomeDiversity.spread(drawn), min: 5)
            }
        }

        // The genres the person listens to most: songs the source returns for that genre that they have not played
        for sec in signals.genreShelves { finish(sec.id, .genrePicks, sec.title, reason: sec.reason, HomeDiversity.spread(sec.items)) }

        if let r = deferredRepeat { feed.sections.append(r) }

        // Albums the person plays most: albums with several of their songs played
        do {
            var rng = HomeRandom.child(of: ctx.seed, "albums")
            struct A { var ref: MusicAlbumRef; var provider: String; var plays: Int; var songs: Int }
            var by: [String: A] = [:]
            for s in taste.tracks where s.plays > 0 {
                guard let a = s.track.album, !a.title.isEmpty, !a.id.isEmpty else { continue }
                let k = s.track.providerID + ":" + a.id
                var x = by[k] ?? A(ref: a, provider: s.track.providerID, plays: 0, songs: 0)
                x.plays += s.plays; x.songs += 1; by[k] = x
            }
            let cands = by.values.filter { $0.songs >= 2 && $0.plays >= 3 && !$0.ref.thumbnails.isEmpty }.sorted { ($0.provider + $0.ref.id) < ($1.provider + $1.ref.id) }
            let drawn = HomeRandom.sample(cands, count: 14, weight: { Double($0.plays) }, using: &rng).map {
                HomeItem.make(MusicAlbum(id: $0.ref.id, providerID: $0.provider, title: $0.ref.title, artists: $0.ref.artists, thumbnails: $0.ref.thumbnails, releaseDate: $0.ref.releaseDate, totalTracks: $0.ref.totalTracks, albumType: $0.ref.albumType, externalURL: $0.ref.externalURL))
            }
            finish("albumsMostPlayed", .albumsMostPlayed, w.s("Albums you play most"), reason: w.s("Albums where you have played several songs"), HomeDiversity.spread(drawn), min: 3)
        }

        // Rediscover
        do {
            var rng = HomeRandom.child(of: ctx.seed, "rediscover")
            let cutoff = ctx.now.addingTimeInterval(-rediscoverGapDays * 86_400)
            let stats = taste.tracks.filter { ($0.liked || $0.plays >= 3) && ($0.lastPlay.map { $0 <= cutoff } ?? false) && (heard.lastPlay($0.track).map { $0 <= cutoff } ?? true) && playable($0.track) }
            let drawn = HomeRandom.sample(stats, count: 14, weight: { $0.weight + Double($0.plays) }, using: &rng).map { HomeItem.make($0.track) }
            finish("rediscover", .rediscover, w.s("Rediscover"), reason: w.s("Songs you loved and have not heard for a while"), HomeDiversity.spread(drawn))
        }

        // The decade the person's songs come from most
        do {
            var rng = HomeRandom.child(of: ctx.seed, "decade")
            func decade(_ t: MusicTrack) -> Int? { t.album?.releaseDate.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil }.map { ($0 / 10) * 10 } }
            var weight: [Int: Double] = [:]
            for s in taste.tracks where s.plays > 0 || s.liked { if let d = decade(s.track), d >= 1950 { weight[d, default: 0] += s.weight + 0.5 } }
            if let top = weight.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key {
                let stats = taste.tracks.filter { decade($0.track) == top && playable($0.track) }
                let drawn = HomeRandom.sample(stats, count: 14, weight: { $0.weight + 0.2 }, using: &rng).map { HomeItem.make($0.track) }
                finish("yourDecade", .yourDecade, w.f("Songs from the %@s", String(top)), reason: w.s("The decade most of your songs come from"), HomeDiversity.spread(drawn), min: 6)
            }
        }

        // Artists you love
        if network {
            var rng = HomeRandom.child(of: ctx.seed, "artists")
            // An artist is "loved" when followed or played at least twice, and has a usable id (an id equal to the name is not one).
            let artists = taste.artists.filter { !$0.ref.id.isEmpty && $0.ref.id != $0.name && ($0.followed || $0.plays >= 2) }
            let drawn = HomeRandom.sample(artists, count: 14, weight: { $0.weight }, using: &rng)
            finish("artistsYouLove", .artistsYouLove, w.s("Artists you love"), reason: nil,
                   drawn.map { HomeItem.make(MusicArtist(id: $0.ref.id, providerID: $0.providerID, name: $0.name, thumbnails: $0.ref.thumbnails)) })
        } else { feed.hidden.append("artistsYouLove: no network") }

        // The person's own playlists
        do {
            var rng = HomeRandom.child(of: ctx.seed, "playlists")
            let lists = signals.playlists.filter { $0.tracks.count >= 3 && (!ctx.offline || $0.tracks.contains { signals.downloaded.contains($0.uid) }) }.sorted { $0.id.uuidString < $1.id.uuidString }
            let drawn = HomeRandom.sample(lists, count: 14, weight: { _ in 1 }, using: &rng).map { HomeItem.make($0, count: Localized.plural($0.tracks.count, one: "%@ song", other: "%@ songs")) }
            finish("yourPlaylists", .yourPlaylists, w.s("Your playlists"), reason: nil, drawn)
        }

        // Songs from the person's own music folders
        do {
            var rng = HomeRandom.child(of: ctx.seed, "local")
            let drawn = HomeRandom.sample(signals.localTracks, count: 14, weight: { _ in 1 }, using: &rng).map { HomeItem.make($0) }
            finish("localMusic", .localMusic, w.s("From your music folders"), reason: w.s("Songs from the folders you added"), HomeDiversity.spread(drawn), min: 4)
        }

        // Playlists that feature the artists the person plays most
        do {
            var rng = HomeRandom.child(of: ctx.seed, "playlistsForYou")
            let drawn = HomeRandom.sample(signals.playlistsForYou, count: 14, weight: { _ in 1 }, using: &rng)
            finish("playlistsForYou", .because, w.s("Playlists for you"), reason: w.s("Playlists that feature artists you play"), drawn, min: 3)
        }

        // Because you play X: the exploration shelves, one per strongest artist
        if network {
            // The shelf says what it is: other artists next to one the person plays (not that the person played these). One shelf per artist the page drew this visit.
            var seen = Set<String>(), leads: [String] = []
            for i in signals.adjacent { if let n = i.becauseOf, seen.insert(HomeKeys.fold(n)).inserted { leads.append(n) } }
            for name in leads.prefix(2) {
                let key = HomeKeys.fold(name)
                var rng = HomeRandom.child(of: ctx.seed, "because-" + key)
                let near = signals.adjacent.filter { $0.becauseOf.map(HomeKeys.fold) == key }
                let drawn = HomeRandom.sample(near, count: 14, weight: { _ in 1 }, using: &rng)
                // One shelf per kind, so each says what it is: artists, songs and albums that sit next to an artist the person plays (none of them played yet).
                let reason = w.f("Fans of %@ also play these. You have not played them yet.", name)
                finish("similarArtists-" + key, .because, w.f("Artists like %@", name), reason: reason, HomeDiversity.spread(drawn.filter { $0.kind == .artist }))
                finish("similarSongs-" + key, .because, w.f("Songs like those of %@", name), reason: reason, HomeDiversity.spread(drawn.filter { $0.kind == .track }))
                finish("similarAlbums-" + key, .because, w.f("Albums like those of %@", name), reason: reason, HomeDiversity.spread(drawn.filter { $0.kind == .album }))
            }
        }

        // the graph block (films with soundtracks, people, "because you played"): the view fills it from the graph
        if network && (mode == .light || mode == .full) { feed.sections.append(HomeSection(id: "graph", kind: .graph, title: "", reason: nil, items: [])) }
        else { feed.hidden.append("graph: \(mode.rawValue)") }

        // Top tracks: a list, not a shelf; the songs already on a shelf above are left out
        let ranked = taste.tracks.filter { playable($0.track) && $0.plays > 0 }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : ($0.weight != $1.weight ? $0.weight > $1.weight : $0.key < $1.key) }
        let tops = claims.fresh(ranked.map { HomeItem.make($0.track) }).prefix(topTracksShown).compactMap(\.track)
        if tops.count >= topTracksMin { feed.topTracks = tops } else { feed.hidden.append("topTracks: \(tops.count) songs, needs \(topTracksMin)") }

        return feed
    }
}
