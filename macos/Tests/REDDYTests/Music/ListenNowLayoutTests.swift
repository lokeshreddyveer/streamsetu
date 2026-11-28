import Foundation
import Testing
@testable import REDDY

// Listen Now's layout table, small rules, tap mapping, graph block order, spacing rules and the saved feed. Pure values only.

@MainActor @Suite("Listen Now layout")
struct ListenNowLayoutTests {
    @Test func sizesGrowWithTheLayoutClassAndStayInsideTheirRanges() {
        let specs = MusicLayoutClass.allCases.map(MusicHomeLayout.spec(for:))
        for (a, b) in zip(specs, specs.dropFirst()) {
            #expect(a.tileWidth <= b.tileWidth && a.heroHeight < b.heroHeight && a.continueColumns <= b.continueColumns && a.sectionGap <= b.sectionGap)
        }
        for s in specs {
            #expect(MusicHomeLayout.heroHeightRange.contains(s.heroHeight))
            #expect(s.tileWidth >= 128 && s.tileWidth <= 190)
            #expect(s.rowArtwork * 1.2 <= MusicHomeLayout.rowHeight, "the artwork fits the fixed row height")
        }
        #expect(MusicHomeLayout.spec(for: .compact).continueColumns == 1)
        #expect(MusicHomeLayout.spec(for: .wide).continueColumns == 3)
        #expect(!MusicHomeLayout.spec(for: .compact).rowShowsAlbum && MusicHomeLayout.spec(for: .wide).rowShowsAlbum)
        #expect(!MusicHomeLayout.spec(for: .compact).heroShowsCover && MusicHomeLayout.spec(for: .medium).heroShowsCover)
    }

    @Test func continueRowsRoundUp() {
        let s = MusicHomeLayout.spec(for: .expanded)
        #expect(s.continueRows(count: 0) == 0 && s.continueRows(count: 1) == 1 && s.continueRows(count: 3) == 1 && s.continueRows(count: 4) == 2 && s.continueRows(count: 6) == 2)
        #expect(MusicHomeLayout.spec(for: .compact).continueRows(count: 6) == 6)
        #expect(MusicHomeLayout.continueHeight > MusicHomeLayout.continueArtwork)
    }

    @Test func theResumeHintOnlyShowsForLongListens() {
        #expect(!MusicHomeContinueRules.showsProgress(isPodcast: nil, durationSeconds: 240))
        #expect(!MusicHomeContinueRules.showsProgress(isPodcast: false, durationSeconds: 1199))
        #expect(MusicHomeContinueRules.showsProgress(isPodcast: nil, durationSeconds: 1200))
        #expect(MusicHomeContinueRules.showsProgress(isPodcast: true, durationSeconds: 300))
        #expect(MusicHomeContinueRules.fraction(position: 2, duration: 100) == nil)
        #expect(MusicHomeContinueRules.fraction(position: 50, duration: 100) == 0.5)
        #expect(MusicHomeContinueRules.fraction(position: 500, duration: 100) == 1)
        #expect(MusicHomeContinueRules.fraction(position: 50, duration: 0) == nil)
    }

    @Test func quickActionsAppearOnlyWhenTheyCanDoSomethingAndTheGreetingFollowsTheHour() {
        #expect(MusicHomeQuickAction.available(hasRecent: false, hasLiked: false, canRadio: false) == [.openLibrary])
        #expect(MusicHomeQuickAction.available(hasRecent: true, hasLiked: true, canRadio: true) == [.playRecent, .shuffleLiked, .startRadio, .openLibrary])
        #expect(MusicHomeQuickAction.available(hasRecent: false, hasLiked: true, canRadio: false) == [.shuffleLiked, .openLibrary])
        #expect(MusicHomeGreeting.text(hour: 7) == "Good morning" && MusicHomeGreeting.text(hour: 13) == "Good afternoon")
        #expect(MusicHomeGreeting.text(hour: 19) == "Good evening" && MusicHomeGreeting.text(hour: 23) == "Good night" && MusicHomeGreeting.text(hour: 2) == "Good night")
    }

    @Test func tappingMapsToTheRightEntityForEveryKind() {
        let t = HomePersona.track("1", "Song", artist: "Kilo Hart")
        #expect(MusicHomeActions.entity(of: HomeItem.make(t)) == .track(t))
        let a = HomePersona.album("x", artist: "Kilo Hart", daysAgo: 1)
        #expect(MusicHomeActions.entity(of: HomeItem.make(a)) == .album(a))
        let artist = MusicArtist(id: "r", providerID: "p", name: "Lima Stone")
        #expect(MusicHomeActions.entity(of: HomeItem.make(artist)) == .artist(artist))
        let local = LocalPlaylist(name: "Mine", tracks: [t])
        if case .playlist(let p)? = MusicHomeActions.entity(of: HomeItem.make(local, count: "1 song")) { #expect(p.providerID == MusicStatsRules.localProviderID && p.id == local.id.uuidString) }
        else { Issue.record("a local playlist is a playlist entity") }
        #expect(MusicHomeActions.entity(of: HomeItem.mix(id: "m", title: "M", subtitle: "", tracks: [t])) == nil, "a mix plays, it has no page")
        #expect(MusicHomeActions.entity(of: HomeItem.entity(raw: "film:abc", title: "F", subtitle: "", imageURL: nil)) == nil, "a film opens by its graph id")
    }

    @Test func aMixIsMadeOfItsSongsAndWearsTheCoverOfTheFirstWithArt() {
        let bare = HomePersona.track("1", "A", artist: "X")
        var noArt = bare; noArt.thumbnails = []
        let mix = HomeItem.mix(id: "d", title: "Daily mix", subtitle: "X", tracks: [noArt, HomePersona.track("2", "B", artist: "Y")])
        #expect(mix.kind == .mix && mix.mixTracks.count == 2 && !mix.thumbnails.isEmpty)
        #expect(mix.thumbnails.first?.url.contains("/2.jpg") == true)
    }

    @Test func theFilmUsesItsPictureOnlyWhenItIsAnAddress() {
        #expect(HomeItem.entity(raw: "film:a", title: "F", subtitle: "", imageURL: "https://x/y.jpg").thumbnails.count == 1)
        #expect(HomeItem.entity(raw: "film:a", title: "F", subtitle: "", imageURL: "not-an-address").thumbnails.isEmpty)
    }
}

@MainActor @Suite("Listen Now graph block and spacing")
struct ListenNowGraphAndSpacingTests {
    private func tile(_ name: String) -> MusicFillTile {
        MusicFillTile(entity: .provisional(kind: .person, name: name), kind: .singer, title: name, subtitle: "", imageRef: nil, role: .singer, year: nil)
    }
    private func shelf(_ id: String, _ names: [String]) -> MusicFillShelf { MusicFillShelf(id: id, title: id, reason: "r", scope: .personal, tiles: names.map(tile)) }

    @Test func filmsLeadThenTheComposerThenThePeopleAndShortShelvesAreDropped() {
        let shelves = [shelf("fill.personal.singers", ["a", "b", "c"]), shelf("fill.personal.films", ["f1", "f2", "f3"]), shelf("fill.related.byComposer", ["x", "y", "z"]), shelf("fill.personal.actors", ["p", "q"])]
        #expect(MusicConnectedHomeBlock.shown(shelves).map(\.id) == ["fill.personal.films", "fill.related.byComposer", "fill.personal.singers"])
    }

    @Test func aShelfThatMostlyRepeatsAnEarlierOneIsDropped() {
        let shelves = [shelf("fill.personal.films", ["a", "b", "c", "d"]), shelf("fill.personal.singers", ["a", "b", "c", "e"])]
        #expect(MusicConnectedHomeBlock.shown(shelves).map(\.id) == ["fill.personal.films"])
        #expect(MusicConnectedHomeBlock.shown((0..<9).map { shelf("other\($0)", ["n\($0)a", "n\($0)b", "n\($0)c"]) }).count == MusicConnectedHomeBlock.limit)
    }

    private func item(_ artist: String, _ n: Int) -> HomeItem { HomeItem.make(HomePersona.track("\(artist)\(n)", "S\(n)", artist: artist)) }

    @Test func spreadKeepsTheSameArtistApartAndCapsThem() {
        let list = [item("a", 1), item("a", 2), item("a", 3), item("b", 1), item("c", 1), item("b", 2)]
        let out = HomeDiversity.spread(list)
        for (x, y) in zip(out, out.dropFirst()) { #expect(x.artistKey != y.artistKey) }
        #expect(out.filter { $0.artistKey == HomeKeys.fold("a") }.count <= HomeDiversity.maxPerArtist)
        #expect(HomeDiversity.spread((0..<5).map { item("solo", $0) }).count == 5, "one artist is left as it is")
    }

    @Test func interleaveFollowsTheShareOfEachGroup() {
        var items: [HomeItem] = []
        for i in 0..<12 {
            items.append(HomeItem.make(HomePersona.track("t\(i)", "పాట \(i)", artist: "Ta\(i % 6)")))
            items.append(HomeItem.make(HomePersona.track("h\(i)", "गाना \(i)", artist: "Ha\(i % 6)")))
            items.append(HomeItem.make(HomePersona.track("e\(i)", "Song \(i)", artist: "Ea\(i % 6)")))
        }
        let share = ["telugu": 0.5, "hindi": 0.3, "latin": 0.2]
        let out = HomeDiversity.interleave(items, share: share, limit: 20)
        #expect(out.count == 20)
        let count = Dictionary(grouping: out, by: \.bucket).mapValues(\.count)
        #expect(abs(Double(count["telugu"] ?? 0) - 10) <= 1 && abs(Double(count["hindi"] ?? 0) - 6) <= 1 && abs(Double(count["latin"] ?? 0) - 4) <= 1, "got \(count)")
    }

    @Test func aGroupOverSeventyPercentIsHeldToIt() {
        let items = (0..<30).map { HomeItem.make(HomePersona.track("t\($0)", "పాట \($0)", artist: "Ta\($0 % 8)")) }
            + (0..<10).map { HomeItem.make(HomePersona.track("e\($0)", "Song \($0)", artist: "Ea\($0 % 8)")) }
        let out = HomeDiversity.interleave(items, share: ["telugu": 0.95, "latin": 0.05], limit: 20)
        #expect(Double(out.filter { $0.bucket == "telugu" }.count) / Double(out.count) <= 0.75)
    }

    @Test func theSeededGeneratorRepeatsAndTheSampleHonoursTheCount() {
        var a = HomeSeededGenerator(seed: 9), b = HomeSeededGenerator(seed: 9), c = HomeSeededGenerator(seed: 10)
        let x = (0..<5).map { _ in a.next() }, y = (0..<5).map { _ in b.next() }, z = (0..<5).map { _ in c.next() }
        #expect(x == y && x != z)
        var g = HomeSeededGenerator(seed: 1)
        let picked = HomeRandom.sample(Array(0..<10), count: 4, weight: { Double($0 + 1) }, using: &g)
        #expect(picked.count == 4 && Set(picked).count == 4)
        #expect(HomeRandom.sample([1, 2, 3], count: 5, weight: { _ in 0 }, using: &g).isEmpty, "a weight of zero is never drawn")
    }
}

@Suite("Listen Now saved feed")
struct ListenNowFeedCacheTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("home-feed-\(UUID().uuidString)", isDirectory: true) }

    @Test func aFeedSurvivesTheRoundTripAndAnOldOneIsIgnored() {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let feed = HomeEngine.compose(HomePersona.heavy(), ctx: HomePersona.ctx(seed: 11))
        HomeFeedCache.save(feed, in: dir)
        #expect(HomeFeedCache.load(in: dir, now: HomePersona.now.addingTimeInterval(60)) == feed)
        #expect(HomeFeedCache.load(in: dir, now: HomePersona.now.addingTimeInterval(HomeFeedCache.maxAge + 10)) == nil)
        HomeFeedCache.clear(in: dir)
        #expect(HomeFeedCache.load(in: dir, now: HomePersona.now) == nil)
    }

    @Test func aMissingOrBrokenFileIsAMissNotACrash() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(HomeFeedCache.load(in: dir) == nil)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: HomeFeedCache.file(in: dir))
        #expect(HomeFeedCache.load(in: dir) == nil)
    }

    @Test func theRecentSongsForSeedsAreRealListensOnly() {
        let a = HomePersona.track("a", "A", artist: "X"), b = HomePersona.track("b", "B", artist: "Y")
        var skipped = HomePersona.play(b, daysAgo: 1); skipped.playedMs = 5_000
        let seeds = MusicHomeFeedModel.listenedSeeds(history: [HomePersona.play(a, daysAgo: 1), HomePersona.play(a, daysAgo: 2), skipped], now: HomePersona.now)
        #expect(seeds.map(\.id) == ["a"])
        #expect(MusicHomeFeedModel.listenedSeeds(history: [], now: HomePersona.now).isEmpty)
    }
}
