import Foundation
import Testing
@testable import REDDY

// Listen Now's engine, tested with synthetic listeners (never the owner's library): a new user, a light listener with 12 plays, a heavy listener in three
// scripts with 500 plays and likes, a gated (kids) profile, an offline one, and a listener who only ever plays one artist.

/// Synthetic listeners. Titles are in three writing systems so the spread across the person's own mix can be checked; artist names are invented.
enum HomePersona {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let telugu = ["Alpha Rao", "Bravo Reddy", "Charlie Naidu", "Delta Sastry"]
    static let hindi = ["Echo Sharma", "Foxtrot Verma", "Golf Kapoor", "Hotel Joshi"]
    static let english = ["Kilo Hart", "Lima Stone", "Mike Gray", "Oscar Fox"]

    static func track(_ id: String, _ title: String, artist: String, album: String? = nil, ms: Int64 = 200_000, provider: String = "p", isrc: String? = nil) -> MusicTrack {
        var t = MusicTrack(id: id, providerID: provider, title: title, durationMs: ms, artists: [MusicArtistRef(id: "id-" + artist, name: artist)])
        t.thumbnails = [MusicThumbnail(url: "https://art.example/\(id).jpg", width: 300, height: 300)]
        t.isrc = isrc
        if let album { t.album = MusicAlbumRef(id: "al-" + album, title: album, thumbnails: t.thumbnails) }
        return t
    }

    static func play(_ t: MusicTrack, daysAgo: Double) -> PlayRecord {
        PlayRecord(track: t, at: now.addingTimeInterval(-daysAgo * 86_400), playedMs: Int64(Double(t.durationMs) * 0.9))
    }

    /// `perArtist` songs for each artist, titled in one writing system.
    static func catalogue(_ word: String, _ artists: [String], perArtist: Int, prefix: String) -> [MusicTrack] {
        artists.enumerated().flatMap { a, name in (0..<perArtist).map { track("\(prefix)-\(a)-\($0)", "\(word) \($0 + 1) \(a + 1)", artist: name, album: "\(prefix) album \(a)") } }
    }

    static func dateText(daysAgo: Double) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: now.addingTimeInterval(-daysAgo * 86_400))
    }

    static func album(_ id: String, artist: String, daysAgo: Double) -> MusicAlbum {
        MusicAlbum(id: id, providerID: "p", title: "Album \(id)", artists: [MusicArtistRef(id: "id-" + artist, name: artist)],
                   thumbnails: [MusicThumbnail(url: "https://art.example/\(id).jpg", width: 300, height: 300)], releaseDate: dateText(daysAgo: daysAgo))
    }

    /// 500 plays across three scripts (about 50, 30 and 20 percent), 30 likes, 3 followed artists, 2 playlists, new releases, unfamiliar neighbours and two films.
    static func heavy() -> HomeSignals {
        let te = catalogue("పాట", telugu, perArtist: 8, prefix: "te"), hi = catalogue("गाना", hindi, perArtist: 8, prefix: "hi"), en = catalogue("Song", english, perArtist: 8, prefix: "en")
        var g = HomeSeededGenerator(seed: 42)
        var s = HomeSignals()
        for _ in 0..<500 {
            let r = Double.random(in: 0..<1, using: &g)
            let pool = r < 0.5 ? te : (r < 0.8 ? hi : en)
            let pick = Int(pow(Double.random(in: 0..<1, using: &g), 2) * Double(pool.count))
            s.history.append(play(pool[pick], daysAgo: Double.random(in: 0..<120, using: &g)))
        }
        s.history.sort { $0.at > $1.at }
        s.liked = Array(te.prefix(10)) + Array(hi.prefix(10)) + Array(en.prefix(10))
        s.followed = (telugu.prefix(1) + hindi.prefix(1) + english.prefix(1)).map { MusicArtist(id: "id-" + $0, providerID: "p", name: $0, genres: ["pop"]) }
        s.playlists = [LocalPlaylist(name: "Drive", tracks: Array(te.prefix(5)), created: now.addingTimeInterval(-86_400)), LocalPlaylist(name: "Focus", tracks: Array(en.prefix(6)), created: now.addingTimeInterval(-3 * 86_400))]
        s.releases = [album("n1", artist: telugu[0], daysAgo: 6), album("n2", artist: hindi[1], daysAgo: 12), album("n3", artist: english[2], daysAgo: 20), album("n4", artist: telugu[1], daysAgo: 25), album("n5", artist: hindi[2], daysAgo: 8), album("old", artist: english[0], daysAgo: 300)]
        s.adjacent = neighbours(of: [telugu[0], hindi[0]])
        s.films = [HomeFilmPick(entityRaw: "film:abc", title: "Film One", subtitle: "Soundtrack", imageURL: "https://art.example/f1.jpg"), HomeFilmPick(entityRaw: "film:def", title: "Film Two", subtitle: "Soundtrack", imageURL: "https://art.example/f2.jpg")]
        return s
    }

    /// Songs and artists the person has never played, tied to the artist they sit next to.
    static func neighbours(of seeds: [String]) -> [HomeItem] {
        seeds.flatMap { seed in
            (0..<8).map { HomeItem.make(track("adj-\(seed)-\($0)", "Newcomer \($0)", artist: "Stranger \(seed) \($0 % 4)")).adjacent(to: seed) }
                + (0..<4).map { HomeItem.make(MusicArtist(id: "adj-a-\(seed)-\($0)", providerID: "p", name: "Neighbour \(seed) \($0)", thumbnails: [MusicThumbnail(url: "https://art.example/n\($0).jpg")])).adjacent(to: seed) }
        }
    }

    static func light() -> HomeSignals {
        let songs = catalogue("Song", english, perArtist: 2, prefix: "l")
        var s = HomeSignals()
        for (i, t) in songs.prefix(6).enumerated() { s.history.append(play(t, daysAgo: Double(i))); s.history.append(play(t, daysAgo: Double(i) + 0.5)) }
        s.history.sort { $0.at > $1.at }
        return s
    }

    static func oneArtist() -> HomeSignals {
        let songs = catalogue("Song", ["Solo Singer"], perArtist: 20, prefix: "solo")
        var s = HomeSignals()
        for (i, t) in songs.enumerated() { for k in 0..<4 { s.history.append(play(t, daysAgo: Double(i % 5) + Double(k) * 0.3)) } }
        s.history.sort { $0.at > $1.at }
        return s
    }

    static func ctx(seed: UInt64 = 1, gated: Bool = false, offline: Bool = false, heroHistory: [String] = []) -> HomeContext {
        var c = HomeContext(); c.now = now; c.seed = seed; c.gated = gated; c.offline = offline; c.heroHistory = heroHistory
        c.calendar = Calendar(identifier: .gregorian)
        return c
    }

    static func ids(_ f: HomeFeed) -> [[String]] { f.sections.map { $0.items.map(\.id) } }
}

@Suite("Listen Now engine: who sees what")
struct HomeEnginePersonaTests {
    @Test func aNewUserGetsNothingMadeUpBecauseListenNowFollowsListening() {
        let f = HomeEngine.compose(HomeSignals(), ctx: HomePersona.ctx())
        #expect(f.mode == .newUser)
        #expect(f.continueItems.isEmpty && f.topTracks.isEmpty && f.sections.isEmpty, "no listening, no charts: Explore is where the world's music is")
        #expect(f.hero == nil)
    }

    @Test func aNewUserWithNoSourceStillGetsAPageWithoutCrashing() {
        let f = HomeEngine.compose(HomeSignals(), ctx: HomePersona.ctx())
        #expect(f.mode == .newUser && f.sections.isEmpty && f.hero == nil)
    }

    @Test func aLightListenerWithTwelvePlaysSeesContinueTheHeroAndChartsAsFill() {
        let s = HomePersona.light()
        #expect(s.history.count == 12)
        let f = HomeEngine.compose(s, ctx: HomePersona.ctx())
        #expect(f.mode == .light)
        #expect(!f.continueItems.isEmpty && f.continueItems.count <= HomeEngine.continueLimit)
        #expect(f.hero != nil)
        #expect(!f.sections.contains { $0.kind == .onRepeat }, "two plays of a song is not on repeat")
        #expect(f.hidden.contains { $0.hasPrefix("onRepeat") })
    }

    @Test func aHeavyListenerGetsEverythingAndNoCharts() {
        let f = HomeEngine.compose(HomePersona.heavy(), ctx: HomePersona.ctx())
        #expect(f.mode == .full)
        let kinds = Set(f.sections.map(\.kind))
        #expect(kinds.isSuperset(of: [.madeForYou, .newForYou, .artistsYouLove, .graph]))
        #expect(f.topTracks.count >= HomeEngine.topTracksMin && f.topTracks.count <= HomeEngine.topTracksShown)
        #expect(f.hero != nil)
    }

    @Test func everyShelfHasAtLeastThreeItemsOrIsNotThere() {
        for seed in UInt64(1)...12 {
            for s in [HomePersona.heavy(), HomePersona.light(), HomePersona.oneArtist()] {
                let f = HomeEngine.compose(s, ctx: HomePersona.ctx(seed: seed))
                for sec in f.sections where sec.kind != .graph { #expect(sec.items.count >= HomeEngine.minItems, "\(sec.id) has \(sec.items.count)") }
            }
        }
    }

    @Test func aGatedProfileUsesNoNetworkAndNothingFromTheSources() {
        let s = HomePersona.heavy()
        let f = HomeEngine.compose(s, ctx: HomePersona.ctx(gated: true))
        #expect(f.mode == .gated)
        let banned: Set<HomeSectionKind> = [.newForYou, .because, .artistsYouLove, .graph]
        #expect(f.sections.allSatisfy { !banned.contains($0.kind) })
        if let h = f.hero { #expect([HomeHero.Kind.randomFavourite, .rediscover, .playlist].contains(h.kind)) }
        #expect(f.sections.flatMap(\.items).allSatisfy { $0.becauseOf == nil || $0.becauseOf?.isEmpty == false })
    }

    @Test func offlineShowsOnlyDownloadedSongsAndNoNetworkShelves() {
        var s = HomePersona.heavy()
        let downloaded = Set(s.history.prefix(200).map(\.track.uid))
        s.downloaded = downloaded
        let f = HomeEngine.compose(s, ctx: HomePersona.ctx(offline: true))
        #expect(f.mode == .offline)
        for sec in f.sections where [.onRepeat, .rediscover].contains(sec.kind) { #expect(sec.items.compactMap(\.track).allSatisfy { downloaded.contains($0.uid) }) }
        for sec in f.sections where sec.kind == .madeForYou { #expect(sec.items.flatMap(\.mixTracks).allSatisfy { downloaded.contains($0.uid) }) }
        #expect(f.topTracks.allSatisfy { downloaded.contains($0.uid) })
        #expect(f.sections.allSatisfy { ![.newForYou, .because, .artistsYouLove, .graph].contains($0.kind) })
    }

    @Test func aListenerWhoOnlyPlaysOneArtistStillGetsAWorkingPage() {
        let f = HomeEngine.compose(HomePersona.oneArtist(), ctx: HomePersona.ctx())
        #expect(f.mode == .full || f.mode == .light)
        #expect(f.hero != nil)
        #expect(f.sections.contains { $0.kind == .onRepeat }, "four plays of each song in a few days is on repeat")
        #expect(!f.sections.contains { $0.kind == .artistsYouLove }, "one artist is not a shelf of artists")
        #expect(f.sections.filter { $0.kind == .because }.isEmpty, "no neighbours were found")
    }
}

@Suite("Listen Now engine: shuffle, spacing, no repeats")
struct HomeEngineShuffleTests {
    @Test func theSameSeedGivesTheSameFeedAndAnotherSeedAnotherOrder() {
        let s = HomePersona.heavy()
        let a = HomeEngine.compose(s, ctx: HomePersona.ctx(seed: 7)), b = HomeEngine.compose(s, ctx: HomePersona.ctx(seed: 7))
        #expect(a == b)
        var orders = Set<[[String]]>()
        for seed in UInt64(1)...10 { orders.insert(HomePersona.ids(HomeEngine.compose(s, ctx: HomePersona.ctx(seed: seed)))) }
        #expect(orders.count > 5, "ten seeds should give clearly different pages")
    }

    @Test func theHeroNeverRepeatsTheOneBefore() {
        for s in [HomePersona.heavy(), HomePersona.light(), HomePersona.oneArtist()] {
            var history: [String] = []
            var last: String?
            for seed in UInt64(1)...150 {
                let f = HomeEngine.compose(s, ctx: HomePersona.ctx(seed: seed, heroHistory: history))
                guard let h = f.hero else { continue }
                if let last { #expect(h.id != last) }
                last = h.id; history = f.heroHistory
            }
        }
    }

    @Test func theHeroIsRandomByWeightNotAlwaysTheSame() {
        let s = HomePersona.heavy()
        var kinds = Set<HomeHero.Kind>(), ids = Set<String>()
        for seed in UInt64(1)...80 { if let h = HomeEngine.compose(s, ctx: HomePersona.ctx(seed: seed)).hero { kinds.insert(h.kind); ids.insert(h.id) } }
        #expect(kinds.count >= 3 && ids.count >= 6)
    }

    @Test func aStrongerWeightWinsMoreOftenButNotAlways() {
        var heavy = 0
        let n = 4000
        for seed in 0..<n {
            var g = HomeSeededGenerator(seed: UInt64(seed))
            if HomeRandom.pick(["a", "b"], weight: { $0 == "a" ? 3 : 1 }, using: &g) == "a" { heavy += 1 }
        }
        let share = Double(heavy) / Double(n)
        #expect(share > 0.70 && share < 0.80, "a 3:1 weight should win about 75 percent, got \(share)")
        // the same through the hero pool: a new release (weight 5) leads a radio idea (1.5) more often, never always
        func cand(_ k: HomeHero.Kind) -> HomeHeroPicker.Candidate {
            HomeHeroPicker.Candidate(hero: HomeHero(kind: k, item: HomeItem.make(HomePersona.track(k.rawValue, k.rawValue, artist: "X")), reason: "r"), weight: HomeHeroPicker.baseWeight(k))
        }
        var wins = 0
        for seed in 0..<n { var g = HomeSeededGenerator(seed: UInt64(seed)); if HomeHeroPicker.choose([cand(.newRelease), cand(.radioIdea)], previous: [], using: &g)?.kind == .newRelease { wins += 1 } }
        let w = Double(wins) / Double(n)
        #expect(w > 0.70 && w < 0.86, "5 against 1.5 should be about 77 percent, got \(w)")
    }

    @Test func aVisitWithinNinetySecondsKeepsTheSeedAndRefreshOrTimeDrawsANewOne() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let prev = HomeSeedPolicy.Previous(seed: 99, at: t0)
        let within = HomeSeedPolicy.seed(now: t0.addingTimeInterval(89), previous: prev, refresh: false, fresh: 5)
        #expect(within.seed == 99 && within.reused)
        let after = HomeSeedPolicy.seed(now: t0.addingTimeInterval(91), previous: prev, refresh: false, fresh: 5)
        #expect(after.seed == 5 && !after.reused)
        let pressed = HomeSeedPolicy.seed(now: t0.addingTimeInterval(10), previous: prev, refresh: true, fresh: 5)
        #expect(pressed.seed == 5 && !pressed.reused)
        let first = HomeSeedPolicy.seed(now: t0, previous: nil, refresh: false, fresh: 5)
        #expect(first.seed == 5 && !first.reused)
        #expect(!HomeSeedPolicy.seed(now: t0.addingTimeInterval(-5), previous: prev, refresh: false, fresh: 5).reused)
    }

    @Test func noItemAppearsOnTwoShelvesOrTwiceInTheTopList() {
        for seed in UInt64(1)...20 {
            let f = HomeEngine.compose(HomePersona.heavy(), ctx: HomePersona.ctx(seed: seed))
            var seen = Set<String>()
            if let h = f.hero { seen.formUnion(h.item.keys) }
            for sec in f.sections { for item in sec.items { for k in item.keys { #expect(seen.insert(k).inserted, "\(k) is on two shelves (\(sec.id))") } } }
            let topKeys = f.topTracks.map { HomeKeys.recording($0) }
            #expect(Set(topKeys).count == topKeys.count)
            for t in f.topTracks { #expect(!seen.contains(HomeKeys.recording(t)) && !seen.contains(HomeKeys.provider(t.uid)), "a top track is also on a shelf") }
        }
    }

    @Test func theSameArtistNeverSitsTwiceInARowAndNeverMoreThanTwiceOnAShelf() {
        for seed in UInt64(1)...15 {
            let f = HomeEngine.compose(HomePersona.heavy(), ctx: HomePersona.ctx(seed: seed))
            for sec in f.sections where sec.kind != .graph {
                let keys = sec.items.map(\.artistKey)
                for (a, b) in zip(keys, keys.dropFirst()) where !a.isEmpty { #expect(a != b, "\(sec.id): \(a) twice in a row") }
                for k in Set(keys.filter { !$0.isEmpty }) { #expect(keys.filter { $0 == k }.count <= HomeDiversity.maxPerArtist, "\(sec.id): \(k) too often") }
                for mix in sec.items where mix.kind == .mix {
                    let artists = mix.mixTracks.map { HomeKeys.firstArtist($0) }
                    for (a, b) in zip(artists, artists.dropFirst()) where !a.isEmpty && Set(artists).count > 1 && !mix.id.hasPrefix("mix:artist-") { #expect(a != b, "\(mix.title): the same artist twice in a row") }
                }
            }
        }
    }

    @Test func aMixFollowsThePersonsOwnMixAndTakesAboutAFifthUnfamiliar() {
        let s = HomePersona.heavy()
        let taste = HomeTaste.build(history: s.history, liked: s.liked, followed: s.followed, now: HomePersona.now, calendar: Calendar(identifier: .gregorian))
        #expect(taste.bucketShare.count == 3)
        let adjacentUIDs = Set(s.adjacent.compactMap { $0.track?.uid })
        var shares: [Double] = []
        for seed in UInt64(1)...10 {
            let f = HomeEngine.compose(s, ctx: HomePersona.ctx(seed: seed))
            guard let daily = f.sections.first(where: { $0.kind == .madeForYou })?.items.first(where: { $0.id == "mix:daily" }) else { Issue.record("no daily mix"); continue }
            let tracks = daily.mixTracks
            #expect(tracks.count >= HomeMixes.minTracks && tracks.count <= HomeMixes.size)
            let unfamiliar = Double(tracks.filter { adjacentUIDs.contains($0.uid) }.count) / Double(tracks.count)
            shares.append(unfamiliar)
            #expect(unfamiliar >= 0.05 && unfamiliar <= HomeDiversity.explorationBounds.upperBound + 0.001, "exploration share \(unfamiliar)")
            let own = tracks.filter { !adjacentUIDs.contains($0.uid) }
            var counts: [String: Int] = [:]
            for t in own { counts[HomeKeys.bucket(t), default: 0] += 1 }
            for (b, share) in taste.bucketShare { #expect(abs(Double(counts[b] ?? 0) / Double(max(own.count, 1)) - share) < 0.3, "bucket \(b) is far from the person's own mix") }
        }
        #expect(shares.contains { $0 > 0.1 })
        // without anything unfamiliar to add, nothing is added
        var plain = s; plain.adjacent = []
        let none = HomeEngine.compose(plain, ctx: HomePersona.ctx(seed: 3)).sections.flatMap(\.items).filter { $0.kind == .mix }.flatMap(\.mixTracks)
        #expect(none.allSatisfy { !adjacentUIDs.contains($0.uid) })
    }

    @Test func explorationCountStaysInsideItsBounds() {
        for size in 1...40 {
            for available in [0, 1, 3, 50] {
                let n = HomeDiversity.explorationCount(size: size, available: available)
                #expect(n <= available && n >= 0)
                if size >= 10, available > 0 { #expect(n >= 1) }
                if size > 0 { #expect(Double(n) / Double(size) <= 0.3 + 1.0 / Double(size)) }
            }
        }
        #expect(HomeDiversity.explorationCount(size: 20, available: 30) == 4)
    }

    @Test func theSameSongFromTwoProvidersIsOneItem() {
        let a = HomePersona.track("1", "Song one", artist: "Kilo Hart", provider: "youtube-music", isrc: "US1234567890")
        let b = HomePersona.track("zz", "Song one (official)", artist: "Kilo Hart", provider: "ytmusic", isrc: "US1234567890")
        #expect(HomeKeys.recording(a) == HomeKeys.recording(b))
        #expect(HomeKeys.provider("youtube-music:abc") == HomeKeys.provider("piped:abc"))
        var claims = HomeDiversity.Claims()
        claims.claim(HomeItem.make(a))
        #expect(claims.has(HomeItem.make(b)))
        #expect(claims.fresh([HomeItem.make(a), HomeItem.make(b)]).isEmpty)
    }
}

@Suite("Listen Now engine: words")
struct HomeEngineWordsTests {
    @Test func nothingIsLabelledByCountryOrLanguage() {
        let languages = MusicLanguage.allCases.map(\.displayName).filter { $0.count > 3 }
        let regions = Locale.Region.isoRegions.compactMap { Locale(identifier: "en").localizedString(forRegionCode: $0.identifier) }.filter { $0.count > 3 }
        var texts: [String] = []
        for seed in UInt64(1)...12 {
            let s = HomePersona.heavy()
            for sig in [s, HomePersona.light(), HomePersona.oneArtist()] {
                let f = HomeEngine.compose(sig, ctx: HomePersona.ctx(seed: seed))
                let plain = f.sections.filter { $0.kind != .languageMix }      // a language mix says which language it holds; nothing else names one
                texts += plain.map(\.title) + plain.compactMap(\.reason) + [f.hero?.reason ?? ""]
                texts += f.sections.flatMap(\.items).filter { $0.kind == .mix }.map(\.title)
            }
        }
        for t in texts where !t.isEmpty {
            for word in languages + regions { #expect(!t.localizedCaseInsensitiveContains(word), "'\(t)' names '\(word)'") }
        }
        #expect(texts.count > 50)
    }

    @Test func reasonsAreMadeFromThePersonsDataNotFixedText() {
        func reason(_ artist: String) -> String? {
            let t = HomePersona.track("t1", "Song 1", artist: artist, album: "A")
            var s = HomeSignals()
            for i in 0..<6 { s.history.append(HomePersona.play(t, daysAgo: Double(i))) }
            s.releases = [HomePersona.album("r1", artist: artist, daysAgo: 4)]
            var found: String?
            for seed in UInt64(1)...60 { if let h = HomeEngine.compose(s, ctx: HomePersona.ctx(seed: seed)).hero, h.kind == .newRelease { found = h.reason; break } }
            return found
        }
        let a = reason("Kilo Hart"), b = reason("Oscar Fox")
        #expect(a == "New from Kilo Hart" && b == "New from Oscar Fox")
        // a song loved long ago is explained by the month it was last played in
        let old = HomePersona.track("t9", "Song 9", artist: "Mike Gray", album: "Z")
        var s = HomeSignals(); s.liked = [old]; s.history = (0..<4).map { HomePersona.play(old, daysAgo: 100 + Double($0)) }
        let last = HomePersona.now.addingTimeInterval(-100 * 86_400)
        let expected = "You loved this in " + HomeHeroPicker.monthText(last, now: HomePersona.now, calendar: Calendar(identifier: .gregorian))
        var seen = Set<String>()
        for seed in UInt64(1)...40 { if let h = HomeEngine.compose(s, ctx: HomePersona.ctx(seed: seed)).hero { seen.insert(h.reason) } }
        #expect(seen.contains(expected), "got \(seen)")
    }

    @Test func theTopListIsByPlaysAndSkipsWhatAShelfAlreadyShows() {
        let f = HomeEngine.compose(HomePersona.heavy(), ctx: HomePersona.ctx(seed: 5))
        #expect(f.topTracks.count <= HomeEngine.topTracksShown)
        let repeating = Set(f.sections.filter { $0.kind == .onRepeat }.flatMap(\.items).flatMap(\.keys))
        for t in f.topTracks { #expect(!repeating.contains(HomeKeys.recording(t))) }
    }

    @Test func continueListeningLeadsWithTheLoadedSongAndHasNoRepeats() {
        let a = HomePersona.track("a", "A", artist: "X"), b = HomePersona.track("b", "B", artist: "Y"), c = HomePersona.track("c", "C", artist: "Z")
        let items = HomeEngine.continueItems(history: [HomePersona.play(a, daysAgo: 0), HomePersona.play(b, daysAgo: 1), HomePersona.play(a, daysAgo: 2), HomePersona.play(c, daysAgo: 3)], current: b)
        #expect(items.compactMap(\.track?.id) == ["b", "a", "c"])
        let many = (0..<30).map { HomePersona.play(HomePersona.track("m\($0)", "M\($0)", artist: "A\($0)"), daysAgo: Double($0)) }
        #expect(HomeEngine.continueItems(history: many, current: nil).count == HomeEngine.continueLimit)
    }
}
