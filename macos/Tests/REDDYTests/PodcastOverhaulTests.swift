import Testing
import Foundation
import MediaPlayer
@testable import REDDY

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0; private(set) var urls: [URL] = []
    func hit(_ u: URL) { lock.lock(); n += 1; urls.append(u); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}
private final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

@MainActor private final class FakeEngine: PodcastAudioEngine {
    var onEnded: (() -> Void)?
    var position: TimeInterval = 0
    var duration: TimeInterval? = 1800
    var loaded: [(URL, TimeInterval)] = []
    var rate = 0.0
    var playing = false
    func load(_ url: URL, start: TimeInterval) { loaded.append((url, start)); position = start }
    func play(rate: Double) { self.rate = rate; playing = true }
    func pause() { playing = false }
    func setRate(_ rate: Double) { self.rate = rate }
    func seek(to: TimeInterval) { position = to }
    func setVolume(_ v: Double) {}
    func stop() { playing = false }
}

private func defaults() -> UserDefaults { UserDefaults(suiteName: "podcast.overhaul.\(UUID())")! }
private let show = PodcastSubscription(feedURL: URL(string: "https://feeds.example/evening.xml")!, title: "The Evening Show", author: "Radio One", artwork: URL(string: "https://img.example/s.jpg"))
private func episode(_ n: Int, published: Date? = nil) -> PodcastEpisode {
    PodcastEpisode(id: "g\(n)", title: "Episode \(n)", summary: "About \(n)", audioURL: URL(string: "https://cdn.example/\(n).mp3")!, published: published ?? Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400), duration: 1800)
}
private func ref(_ n: Int) -> PodcastEpisodeRef { PodcastEpisodeRef(episode(n), show: show) }

@MainActor private func makePlayer(_ d: UserDefaults = defaults()) -> (PodcastPlayer, FakeEngine, PodcastLibrary) {
    let lib = PodcastLibrary(defaults: d); let e = FakeEngine()
    return (PodcastPlayer(library: lib, engine: e, autoTick: false), e, lib)
}

private let chartJSON = #"{"feed":{"results":[{"id":"11","name":"A"},{"id":"22","name":"B"}]}}"#
private let lookupJSON = #"{"resultCount":2,"results":[{"collectionId":22,"collectionName":"B","artistName":"b","feedUrl":"https://b.example/f","artworkUrl600":"https://b.example/b.jpg"},{"collectionId":11,"collectionName":"A","artistName":"a","feedUrl":"https://a.example/f"}]}"#

@Suite("Podcasts: catalog") struct PodcastCatalogTests {
    private func service(_ clock: Clock, _ counter: Counter, fail: @escaping @Sendable () -> Bool = { false }, dir: URL = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID())")) -> PodcastCatalogService {
        PodcastCatalogService(region: "gb", directory: dir, now: { clock.now }, fetch: { url in
            counter.hit(url)
            if fail() { throw URLError(.notConnectedToInternet) }
            return Data((url.host == "itunes.apple.com" && url.path == "/lookup" ? lookupJSON : chartJSON).utf8)
        })
    }

    @Test func genreIdsMatchThePublicDirectory() {
        #expect(PodcastGenre.news.rawValue == 1489 && PodcastGenre.technology.rawValue == 1318 && PodcastGenre.comedy.rawValue == 1303)
        #expect(PodcastGenre.trueCrime.rawValue == 1488 && PodcastGenre.kidsFamily.rawValue == 1305 && PodcastGenre.sports.rawValue == 1545)
        #expect(Set(PodcastGenre.allCases.map(\.rawValue)).count == PodcastGenre.allCases.count)
        #expect(PodcastCatalogService.chartURL(region: "gb", genre: .news, limit: 25).absoluteString == "https://itunes.apple.com/gb/rss/toppodcasts/limit=25/genre=1489/json")
        #expect(PodcastCatalogService.chartURL(region: "gb", genre: nil, limit: 10).absoluteString == "https://rss.marketingtools.apple.com/api/v2/gb/podcasts/top/10/podcasts.json")
    }

    @Test func onlyTheTwoLetterRegionIsUsed() {
        #expect(PodcastCatalogService.region(Locale(identifier: "en_GB")) == "gb")
        #expect(PodcastCatalogService.region(Locale(identifier: "en")) == "us")
        let c = Counter(); let s = service(Clock(), c)
        _ = Task { try await s.top() }
    }

    @Test func chartIsReadInChartOrderWithFeedAddresses() async throws {
        let r = try await service(Clock(), Counter()).top()
        #expect(r.shows.map(\.title) == ["A", "B"] && r.shows[1].feedURL.absoluteString == "https://b.example/f" && !r.fromCache)
    }

    @Test func legacyGenreChartIdsAreRead() {
        let json = #"{"feed":{"entry":[{"id":{"label":"x","attributes":{"im:id":"5"}}},{"id":{"attributes":{"im:id":"6"}}}]}}"#
        #expect(PodcastCatalogService.parseChartIDs(Data(json.utf8)) == ["5", "6"])
    }

    @Test func savedCopyIsUsedForSixHoursThenRefreshed() async throws {
        let clock = Clock(), c = Counter(), s = service(clock, c)
        _ = try await s.top(); let first = c.count
        let again = try await s.top()
        #expect(again.fromCache && c.count == first)
        clock.advance(6 * 3600 + 5)
        let fresh = try await s.top()
        #expect(!fresh.fromCache && c.count > first)
    }

    @Test func offlineServesTheOldCopyElseThrows() async throws {
        let clock = Clock(), c = Counter(); let offline = Counter()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID())")
        _ = try await service(clock, c, dir: dir).top()
        clock.advance(7 * 3600)
        let r = try await service(clock, offline, fail: { true }, dir: dir).top()
        #expect(r.fromCache && r.stale && r.shows.count == 2)
        await #expect(throws: PodcastCatalogError.self) { _ = try await self.service(clock, Counter(), fail: { true }).top() }
    }

    @Test func eachGenreHasItsOwnCopy() async throws {
        let clock = Clock(), c = Counter(), s = service(clock, c)
        _ = try await s.top(); let n = c.count
        let g = try await s.top(genre: .news)
        #expect(!g.fromCache && c.count > n)
    }
}

@Suite("Podcasts: show notes and episode list") struct PodcastTextTests {
    @Test func trailingBoilerplateIsDroppedFromTheDisplayOnly() {
        let raw = "A great chat about gardens.\nSecond paragraph.\n\nLearn more about your ad choices. Visit megaphone.fm/adchoices\nSee Privacy Policy at https://example.com/privacy for information."
        #expect(PodcastText.display(raw) == "A great chat about gardens.\nSecond paragraph.")
        let ep = PodcastEpisode(id: "1", title: "t", summary: raw, audioURL: URL(string: "https://x/a.mp3")!, published: nil, duration: nil)
        #expect(ep.summary == raw && ep.displaySummary == "A great chat about gardens.\nSecond paragraph.")
        #expect(PodcastText.display("We discuss privacy policy design in the middle.\nAnd then more.") == "We discuss privacy policy design in the middle.\nAnd then more.")
    }

    @Test func feedReadsEpisodeArtChaptersTranscriptAndCategories() throws {
        let rss = """
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel>
        <title>S</title><description>About the show</description><itunes:category text="Technology"/><itunes:image href="https://i/s.jpg"/>
        <item><title>E</title><enclosure url="https://c/1.mp3" type="audio/mpeg"/><itunes:image href="https://i/e.jpg"/>
        <podcast:chapters url="https://c/ch.json" type="application/json+chapters"/><podcast:transcript url="https://c/t.vtt" type="text/vtt"/></item></channel></rss>
        """
        let feed = try #require(PodcastParser.parse(Data(rss.utf8)))
        #expect(feed.summary == "About the show" && feed.categories == ["Technology"])
        let e = feed.episodes[0]
        #expect(e.artwork?.absoluteString == "https://i/e.jpg" && e.chaptersURL?.absoluteString == "https://c/ch.json" && e.transcriptURL?.absoluteString == "https://c/t.vtt")
    }

    @Test func chaptersAndTranscriptsAreParsed() {
        let ch = PodcastExtras.parseChapters(Data(#"{"version":"1.2.0","chapters":[{"startTime":60,"title":"B"},{"startTime":0,"title":"A"}]}"#.utf8))
        #expect(ch.map(\.title) == ["A", "B"])
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHello there\n\n00:01:05.500 --> 00:01:08.000\nSecond line\n"
        let t = PodcastExtras.parseTranscript(Data(vtt.utf8))
        #expect(t.count == 2 && t[0].start == 1 && t[1].start == 65.5 && t[1].text == "Second line")
    }

    @Test func listSortsAndSearchesWithinTheShow() {
        let eps = [episode(1), episode(2), episode(3)]
        #expect(PodcastEpisodeList.visible(eps, newestFirst: true, query: "").map(\.title) == ["Episode 3", "Episode 2", "Episode 1"])
        #expect(PodcastEpisodeList.visible(eps, newestFirst: false, query: "").map(\.title) == ["Episode 1", "Episode 2", "Episode 3"])
        #expect(PodcastEpisodeList.visible(eps, newestFirst: true, query: "episode 2").map(\.title) == ["Episode 2"])
    }
}

@Suite("Podcasts: played state, queue, settings") @MainActor struct PodcastLibraryTests {
    @Test func placeAndPlayedStateSurviveARelaunch() {
        let d = defaults(); let lib = PodcastLibrary(defaults: d)
        lib.setPosition(ref(1), position: 600, duration: 1800)
        #expect(lib.progress(ref(1).itemID)?.fraction == 600.0 / 1800.0)
        #expect(lib.startPosition(ref(1)) == 600 && lib.continueListening().count == 1)
        lib.markPlayed(ref(1), true)
        let again = PodcastLibrary(defaults: d)
        #expect(again.isPlayed(ref(1).itemID) && again.startPosition(ref(1)) == 0 && again.continueListening().isEmpty)
        again.markPlayed(ref(1), false); #expect(!again.isPlayed(ref(1).itemID))
    }

    @Test func upNextIsKeptAcrossLaunches() {
        let d = defaults(); let lib = PodcastLibrary(defaults: d)
        lib.addToQueue(ref(1)); lib.addToQueue(ref(2)); lib.playNext(ref(3))
        #expect(PodcastLibrary(defaults: d).queue.map(\.title) == ["Episode 3", "Episode 1", "Episode 2"])
        lib.moveInQueue(from: IndexSet(integer: 2), to: 0)
        lib.removeFromQueue(ref(1).itemID)
        #expect(PodcastLibrary(defaults: d).queue.map(\.title) == ["Episode 2", "Episode 3"])
    }

    @Test func perShowSettingsOverrideTheDefaultsAndPersist() {
        let d = defaults(); let lib = PodcastLibrary(defaults: d)
        let other = URL(string: "https://other.example/f")!
        lib.prefs = PodcastPlaybackPrefs(speed: 1.25, skipBack: 10, skipForward: 45)
        lib.setSettings(PodcastShowSettings(speed: 2, skipBack: nil, skipForward: 60, skipIntro: 30), for: show.feedURL)
        let again = PodcastLibrary(defaults: d)
        #expect(again.speed(for: show.feedURL) == 2 && again.skipBack(for: show.feedURL) == 10 && again.skipForward(for: show.feedURL) == 60)
        #expect(again.speed(for: other) == 1.25 && again.skipForward(for: other) == 45)
        #expect(again.startPosition(ref(9)) == 30)         // a new episode of the show starts after its intro
    }

    @Test func newEpisodeDotAppearsOnlyAfterASeenShowGetsANewerEpisode() {
        let lib = PodcastLibrary(defaults: defaults())
        let t0 = Date(timeIntervalSince1970: 1000)
        lib.noteLatest(t0, for: show.feedURL)
        #expect(!lib.hasNewEpisode(show.feedURL))
        lib.noteLatest(t0.addingTimeInterval(500), for: show.feedURL)
        #expect(lib.hasNewEpisode(show.feedURL))
        lib.markSeen(show.feedURL)
        #expect(!lib.hasNewEpisode(show.feedURL))
    }
}

@Suite("Podcasts: player") @MainActor struct PodcastPlayerTests {
    @Test func playingStartsAtTheSavedPlaceAtTheShowsSpeed() {
        let (p, e, lib) = makePlayer()
        lib.setPosition(ref(1), position: 300, duration: 1800)
        lib.setSettings(PodcastShowSettings(speed: 1.5), for: show.feedURL)
        p.play(ref(1))
        #expect(e.loaded.last?.1 == 300 && e.rate == 1.5 && p.isPlaying && p.speed == 1.5)
    }

    @Test func skipsUseTheShowsLengthsAndStayInRange() {
        let (p, e, lib) = makePlayer()
        lib.setSettings(PodcastShowSettings(skipBack: 10, skipForward: 60), for: show.feedURL)
        p.play(ref(1)); p.seek(to: 100)
        p.skipForward(); #expect(e.position == 160)
        p.skipBack(); #expect(e.position == 150)
        p.seek(to: 5); p.skipBack(); #expect(e.position == 0)
    }

    @Test func speedChangeIsKeptForTheShowOnly() {
        let (p, e, lib) = makePlayer()
        p.play(ref(1)); p.setSpeed(2)
        #expect(e.rate == 2 && lib.speed(for: show.feedURL) == 2 && lib.prefs.speed == 1)
        p.setSpeed(9); #expect(p.speed == 3)
        p.setSpeed(1.4); p.cycleSpeed(); #expect(p.speed == 1.5)
    }

    @Test func endOfEpisodeMarksPlayedAndAdvancesThroughUpNext() {
        let (p, e, lib) = makePlayer()
        lib.addToQueue(ref(2)); lib.addToQueue(ref(3))
        p.play(ref(1)); e.onEnded?()
        #expect(lib.isPlayed(ref(1).itemID) && p.current?.title == "Episode 2" && lib.queue.map(\.title) == ["Episode 3"])
        e.onEnded?(); e.onEnded?()
        #expect(p.current?.title == "Episode 3" && !p.isPlaying && lib.queue.isEmpty)
    }

    @Test func sleepAtEndOfEpisodeStopsInsteadOfAdvancing() {
        let (p, e, lib) = makePlayer()
        lib.addToQueue(ref(2))
        p.play(ref(1)); p.setSleep(.endOfEpisode); e.onEnded?()
        #expect(!p.isPlaying && p.current?.title == "Episode 1" && lib.queue.count == 1 && p.sleep == .off && lib.isPlayed(ref(1).itemID))
    }

    @Test func sleepTimerPausesAfterItsMinutes() {
        let clock = Clock(); let (p, e, _) = makePlayer()
        p.now = { clock.now }
        p.play(ref(1)); p.setSleep(.minutes(10))
        clock.advance(300); p.tick(); #expect(p.isPlaying)
        clock.advance(301); p.tick(); #expect(!p.isPlaying && !e.playing && p.sleep == .off)
    }

    @Test func placeIsSavedOnPauseAndTicks() {
        let (p, e, lib) = makePlayer()
        p.play(ref(1)); e.position = 42; p.tick(); p.pause()
        #expect(lib.progress(ref(1).itemID)?.position == 42)
    }

    @Test func podcastStopsLibraryAndServicesAndOtherMediaPausesPodcast() {
        let (p, _, _) = makePlayer()
        var stopped = 0, paused = 0
        p.stopLibrary = { stopped += 1 }; p.pauseServices = { paused += 1 }
        p.play(ref(1)); #expect(stopped == 1 && paused == 1)
        p.otherMediaStarted(); #expect(!p.isPlaying && p.current != nil)
        p.resume(); #expect(p.isPlaying && stopped == 2 && paused == 2)
        p.close(); #expect(p.current == nil && !p.panelOpen)
    }

    @Test func extrasLoadFromTheFeedsFiles() async throws {
        let (p, _, _) = makePlayer()
        p.loadData = { url in Data((url.lastPathComponent == "ch.json" ? #"{"chapters":[{"startTime":0,"title":"Intro"}]}"# : "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n").utf8) }
        var r = ref(1); r.chaptersURL = URL(string: "https://c/ch.json"); r.transcriptURL = URL(string: "https://c/t.vtt")
        p.play(r)
        for _ in 0..<50 where p.chapters.isEmpty || p.transcript.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(p.chapters.map(\.title) == ["Intro"] && p.transcript.first?.text == "Hi")
    }

    @Test func nowPlayingCarriesTheRealRateAndAudioType() throws {
        let (p, _, _) = makePlayer()
        p.play(ref(1)); p.setSpeed(1.5)
        var s = try #require(p.snapshot)
        #expect(s.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
        #expect(s.info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1.5)
        #expect(s.info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.audio.rawValue)
        #expect(s.info[MPMediaItemPropertyArtist] as? String == "The Evening Show" && s.skipForward == 30 && s.skipBack == 15)
        p.pause(); s = try #require(p.snapshot)
        #expect(s.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    }

    @Test func podcastPlaybackNeverCreatesLibraryState() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("pod-\(UUID()).sqlite").path, credentials: InMemoryCredentialStore())
        let (p, _, _) = makePlayer()
        p.play(ref(1)); p.panelOpen = true
        #expect(c.playback.current == nil && !c.playback.isExpanded && c.playback.primarySurface == .none)
    }
}

@Suite("Podcasts: home, search and Back") @MainActor struct PodcastsHubTests {
    private func hub(delay: UInt64 = 0, defaults d: UserDefaults = defaults()) -> PodcastsHub {
        let json = #"{"results":[{"collectionName":"Found","artistName":"x","feedUrl":"https://f.example/feed"}]}"#
        let service = PodcastService(defaults: d, fetch: { _ in if delay > 0 { try await Task.sleep(nanoseconds: delay) }; return Data(json.utf8) })
        let catalog = PodcastCatalogService(region: "us", directory: FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID())"), fetch: { _ in throw URLError(.notConnectedToInternet) })
        let lib = PodcastLibrary(defaults: d)
        return PodcastsHub(service: service, catalog: catalog, library: lib, player: PodcastPlayer(library: lib, engine: FakeEngine(), autoTick: false))
    }

    @Test func clearingTheSearchReturnsHomeAndCancelsTheRequest() async throws {
        let h = hub(delay: 300_000_000)
        h.term = "garden"; h.search()
        #expect(h.searching && h.isSearchActive)
        h.clearSearch()
        #expect(!h.searching && h.found.isEmpty && h.term == "" && !h.isSearchActive && h.nav.section == .discover && h.nav.top == nil)
        try await Task.sleep(nanoseconds: 450_000_000)
        #expect(h.found.isEmpty && !h.isSearchActive)          // the late answer was dropped
    }

    @Test func emptyingTheTextAlsoReturnsHome() async throws {
        let h = hub()
        h.term = "garden"; h.search()
        for _ in 0..<50 where h.found.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(h.found.count == 1)
        h.term = ""
        #expect(h.found.isEmpty && !h.isSearchActive)
    }

    @Test func backFromAShowReturnsToResultsOrACategory() async throws {
        let h = hub()
        h.term = "garden"; h.search()
        for _ in 0..<50 where h.found.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        h.open(h.found[0]); #expect(h.nav.top != nil)
        h.back(); #expect(h.nav.top == nil && h.found.count == 1)          // back on the results
        h.clearSearch()
        h.openGenre(.news); h.open(show)
        #expect(h.nav.canGoBack); h.back()
        if case .genre(let g)? = h.nav.top { #expect(g == .news) } else { Issue.record("expected the category") }
        h.back(); #expect(h.nav.top == nil)
    }

    @Test func sidebarSectionsResetTheStack() {
        var n = PodcastsNav()
        n.push(.show(show)); n.select(.upNext)
        #expect(n.section == .upNext && n.top == nil)
        #expect(PodcastsSection.allCases.map(\.titleText) == ["Discover", "Following", "Recently Played", "Up Next"])
    }

    @Test func offlineChartsShowTheRetryState() async throws {
        let h = hub()
        h.loadTop()
        for _ in 0..<50 { if case .loading = h.top { try await Task.sleep(nanoseconds: 20_000_000) } else { break } }
        #expect(h.top == .failed)
    }

    @Test func followingListsFollowedShows() async throws {
        let d = defaults(); let rss = PodcastTests.rss
        let service = PodcastService(defaults: d, fetch: { _ in Data(rss.utf8) })
        _ = try await service.subscribe(URL(string: "https://feeds.example/evening.xml")!)
        let lib = PodcastLibrary(defaults: d)
        let h = PodcastsHub(service: service, catalog: PodcastCatalogService(region: "us", fetch: { _ in throw URLError(.cancelled) }), library: lib, player: PodcastPlayer(library: lib, engine: FakeEngine(), autoTick: false))
        #expect(h.following.map(\.title) == ["The Evening Show"])
        h.unfollow(h.following[0]); #expect(h.following.isEmpty)
    }
}

@Suite("Podcasts: library player path is unchanged") @MainActor struct LibraryPathRegressionTests {
    @Test func aLibraryFileStillOpensTheNowPlayingDialogAndVideoSurface() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("pod-\(UUID()).sqlite").path, credentials: InMemoryCredentialStore())
        FilesPlayer.play(file: URL(fileURLWithPath: "/nonexistent/film.mp4"), title: "Film", container: c)
        #expect(c.playback.current != nil && c.playback.isExpanded)
        #expect(PlayerSurfaceModel.showsExpanded(c.playback.primarySurface))
        c.playback.stop()
    }

    @Test func surfaceRulesAreTheSameAsBefore() {
        #expect(PlayerSurfaceModel.primary(PlayerSurfaceInputs(hasPlayback: false)) == .none)
        #expect(PlayerSurfaceModel.primary(PlayerSurfaceInputs(hasPlayback: true)) == .bar)
        #expect(PlayerSurfaceModel.primary(PlayerSurfaceInputs(hasPlayback: true, isExpanded: true)) == .expanded)
        #expect(PlayerSurfaceModel.barHoldsVideo(.bar) && !PlayerSurfaceModel.barHoldsVideo(.popout))
    }

    @Test func libraryPlaybackStopsThePodcastThroughTheSameSignalAsServices() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("pod-\(UUID()).sqlite").path, credentials: InMemoryCredentialStore())
        let (p, _, _) = makePlayer()
        p.play(ref(1))
        FilesPlayer.play(file: URL(fileURLWithPath: "/nonexistent/film.mp4"), title: "Film", container: c)
        if c.playback.isActive { p.otherMediaStarted() }          // what the shell does when `isActive` turns on
        #expect(!p.isPlaying)
        var libraryStopped = false; p.stopLibrary = { libraryStopped = true }
        p.resume(); #expect(libraryStopped)
        c.playback.stop()
    }

    @Test func nowPlayingSnapshotForLibraryStaysVideo() {
        let s = NowPlayingSnapshot(title: "T", subtitle: nil, isLive: false, isPlaying: true, position: 5, duration: 100, rate: 1, hasQueue: false, hasNextEpisode: false, artworkURL: nil)
        #expect(s.info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.video.rawValue)
    }
}
