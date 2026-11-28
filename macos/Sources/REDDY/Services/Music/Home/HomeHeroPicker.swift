import Foundation

/// The hero of Listen Now: one pick from a weighted pool of candidates of seven kinds (a favourite, the latest from an artist they play, a new release,
/// something loved long ago, a film soundtrack from their graph, a playlist of theirs, a radio idea). Each candidate carries a short
/// reason line made from the person's own data. The pick is random by weight, so strong matches lead more often but the hero is not always the same,
/// and it is never the hero the page showed last time.
enum HomeHeroPicker {
    struct Candidate: Sendable {
        var hero: HomeHero
        var weight: Double
    }

    /// How strongly each kind leads before the person's own affinity is applied.
    static func baseWeight(_ k: HomeHero.Kind) -> Double {
        switch k {
        case .newRelease: 5
        case .latestFromArtist: 4
        case .randomFavourite: 3
        case .rediscover: 3
        case .filmSoundtrack: 2
        case .playlist: 2
        case .radioIdea: 1.5
        }
    }

    static let rediscoverGapDays = 60.0

    static func candidates(taste: HomeTaste, signals: HomeSignals, ctx: HomeContext, mode: HomeFeed.Mode, heard known: HomeHeard? = nil) -> [Candidate] {
        let heard = known ?? HomeHeard([signals.allHistory, signals.history])
        let w = ctx.wording
        let network = !ctx.gated && !ctx.offline
        let top = max(taste.topArtistWeight, 0.0001)
        var out: [Candidate] = []
        func add(_ kind: HomeHero.Kind, _ item: HomeItem, _ reason: String, affinity: Double = 0) {
            guard !item.title.isEmpty, !item.thumbnails.isEmpty else { return }
            out.append(Candidate(hero: HomeHero(kind: kind, item: item, reason: reason), weight: baseWeight(kind) * (1 + min(max(affinity, 0), 1))))
        }
        func affinityOf(_ name: String) -> Double { taste.artistWeight(named: name) / top }
        func playable(_ t: MusicTrack) -> Bool { !ctx.offline || signals.downloaded.contains(t.uid) }

        // a favourite: the album of one of their strongest songs (a song with no album art stands as itself)
        for s in taste.tracks.prefix(8) where playable(s.track) {
            let artist = s.track.artists.first?.name ?? ""
            if let ref = s.track.album, !ref.id.isEmpty, !ref.thumbnails.isEmpty, network {
                let album = MusicAlbum(id: ref.id, providerID: s.track.providerID, title: ref.title, artists: ref.artists.isEmpty ? s.track.artists : ref.artists, thumbnails: ref.thumbnails)
                add(.randomFavourite, .make(album), artist.isEmpty ? w.s("A favourite of yours") : w.f("You play %@ a lot", artist), affinity: affinityOf(artist))
            } else {
                add(.randomFavourite, .make(s.track), artist.isEmpty ? w.s("A favourite of yours") : w.f("You play %@ a lot", artist), affinity: affinityOf(artist))
            }
        }

        // loved long ago, not heard for a while
        let cutoff = ctx.now.addingTimeInterval(-rediscoverGapDays * 86_400)
        for s in taste.tracks where playable(s.track) && (s.liked || s.plays >= 3) && (s.lastPlay ?? .distantPast) <= cutoff && (heard.lastPlay(s.track) ?? .distantPast) <= cutoff {
            guard let last = s.lastPlay else { continue }
            add(.rediscover, .make(s.track), w.f("You loved this in %@", monthText(last, now: ctx.now, calendar: ctx.calendar)), affinity: affinityOf(s.track.artists.first?.name ?? ""))
            if out.filter({ $0.hero.kind == .rediscover }).count >= 4 { break }
        }

        // a playlist of theirs
        for p in signals.playlists.filter({ !$0.tracks.isEmpty && (!ctx.offline || $0.tracks.contains { signals.downloaded.contains($0.uid) }) }).sorted(by: { $0.created > $1.created }).prefix(3) {
            add(.playlist, .make(p, count: Localized.plural(p.tracks.count, one: "%@ song", other: "%@ songs")), w.s("From your playlists"))
        }

        guard network else { return dedupe(out) }

        // new from artists they play, or the latest from them (never an album they have already played)
        let playedAlbums = Set(taste.tracks.compactMap { s -> String? in
            guard let al = s.track.album else { return nil }
            return "alb:" + HomeKeys.fold(al.title) + "|" + HomeKeys.fold((al.artists.first ?? s.track.artists.first)?.name ?? "")
        })
        for a in signals.releases {
            guard let artist = a.artists.first?.name, !playedAlbums.contains(HomeKeys.album(a)), !heard.has(HomeKeys.album(a)) else { continue }
            let known = taste.artistWeight(named: artist) > 0
            if !known { continue }
            if HomeEngine.isFresh(releaseDate: a.releaseDate, now: ctx.now) { add(.newRelease, .make(a), w.f("New from %@", artist), affinity: affinityOf(artist)) }
            else { add(.latestFromArtist, .make(a), w.f("Because you play %@", artist), affinity: affinityOf(artist)) }
        }

        // from a film they saved
        for f in signals.films.prefix(4) {
            add(.filmSoundtrack, .entity(raw: f.entityRaw, title: f.title, subtitle: f.subtitle, imageURL: f.imageURL), w.s("From a film whose songs you play"))
        }

        // a station idea built on an artist they play
        for a in taste.artists.prefix(3) where !a.ref.id.isEmpty {
            let artist = MusicArtist(id: a.ref.id, providerID: a.providerID, name: a.name, thumbnails: a.ref.thumbnails)
            var item = HomeItem.make(artist)
            if item.thumbnails.isEmpty, let art = taste.tracks.first(where: { $0.track.artists.contains { $0.name == a.name } })?.track.thumbnails { item.thumbnails = art }
            add(.radioIdea, item, w.f("A radio built on %@", a.name), affinity: a.weight / top)
        }
        return dedupe(out)
    }

    /// The same thing offered by two kinds keeps its strongest offer.
    static func dedupe(_ list: [Candidate]) -> [Candidate] {
        var best: [String: Candidate] = [:]
        var order: [String] = []
        for c in list {
            if let cur = best[c.hero.id] { if c.weight > cur.weight { best[c.hero.id] = c } } else { best[c.hero.id] = c; order.append(c.hero.id) }
        }
        return order.compactMap { best[$0] }
    }

    /// One candidate by weight, never the previous hero (when there is any other).
    static func choose(_ list: [Candidate], previous: [String], using rng: inout some RandomNumberGenerator) -> HomeHero? {
        guard !list.isEmpty else { return nil }
        let last = previous.first
        let pool = list.filter { $0.hero.id != last }
        return HomeRandom.pick(pool.isEmpty ? list : pool, weight: { $0.weight }, using: &rng)?.hero
    }

    /// "March" for a date this year or last 11 months, "March 2025" for older.
    static func monthText(_ d: Date, now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.locale = Locale.current; f.timeZone = calendar.timeZone
        let months = calendar.dateComponents([.month], from: d, to: now).month ?? 0
        f.setLocalizedDateFormatFromTemplate(months >= 11 ? "LLLL yyyy" : "LLLL")
        return f.string(from: d)
    }
}
