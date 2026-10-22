import Testing
import Foundation
@testable import REDDY

/// Vague requests ("play something"), typing slips, exact titles, no matches, parental restrictions, and an honest account of whether playback really started.
@Suite("Assistant: vague requests are searches, not titles") struct AssistantDiscoveryParseTests {
    @Test func vagueRequestsAreRecognisedWhateverTheTypingSlip() {
        for text in ["play something", "play somwthing", "play someting", "play sumthing", "Play Something!", "watch anything", "put on something", "stream somthing", "play something best series",
                     "play something new", "play a movie", "watch a good series", "play the best series", "put on a random film", "show me something funny"] {
            #expect(AssistantDiscovery.parse(text) != nil, "“\(text)” asks for something to watch")
        }
    }

    @Test func whatWasAskedForIsExtracted() throws {
        let a = try #require(AssistantDiscovery.parse("play something best series"))
        #expect(a.kind == .series && a.best && a.rest.isEmpty); #expect(a.query == "top rated series")
        let b = try #require(AssistantDiscovery.parse("play somwthing"))
        #expect(b.kind == .any && !b.best); #expect(b.query == "surprise me")
        let c = try #require(AssistantDiscovery.parse("put on a new movie"))
        #expect(c.kind == .movie && c.newest)
        let d = try #require(AssistantDiscovery.parse("play something funny in telugu"))
        #expect(d.rest == "funny in telugu", "everything else said is handed to the search")
        let e = try #require(AssistantDiscovery.parse("play somthing with prabhas"))
        #expect(e.rest == "with prabhas")
    }

    @Test func exactTitlesAreNotRequests() {
        for text in ["play Star", "play Bigg Boss (Telugu)", "play BIGG BOSS TELUGU 24X7", "play bigg bos", "watch Inception", "go to live tv", "resume", "add Star to favourites", "what should I watch tonight"] {
            #expect(AssistantDiscovery.parse(text) == nil, "“\(text)” is not a request for something unspecified")
        }
    }

    @Test func theVagueWordToleratesSlipsButNotOtherWords() {
        #expect(AssistantDiscovery.isVague("something") && AssistantDiscovery.isVague("somwthing") && AssistantDiscovery.isVague("anythng") && AssistantDiscovery.isVague("sumthing"))
        #expect(!AssistantDiscovery.isVague("nothing") && !AssistantDiscovery.isVague("someone") && !AssistantDiscovery.isVague("some") && !AssistantDiscovery.isVague("songs"))
    }
}

@MainActor @Suite("Assistant: showing real titles before offering to play") struct AssistantDiscoveryLibraryTests {
    private func rig() throws -> (AppContainer, PlaylistSource) {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-dl-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        return (c, try c.sources.addM3U(name: "Mine", url: "http://127.0.0.1:9/list.m3u"))
    }
    private func series(_ src: PlaylistSource, _ pid: String, _ title: String, _ rating: String, category: CatalogCategory? = nil) -> Series {
        var s = TestSupport.series(src, pid, title); s.rating = rating
        if let category { s.categoryID = category.id; s.categoryName = category.name }
        return s
    }
    private func ids(_ r: AssistantReply) -> [String] { (r.answer?.results ?? []).map(\.item.title) }

    @Test func playSomethingBestSeriesShowsRealSeriesBestRatedFirstThenOffersTheTopOne() async throws {
        let (c, src) = try rig()
        try c.indexer.commitSeries(source: src, categories: [], series: [series(src, "a", "Plain Show", "6.1"), series(src, "b", "Great Show", "9.2"), series(src, "c", "Good Show", "7.8")])
        try c.indexer.commitMovies(source: src, categories: [], movies: [TestSupport.movie(src, "m", "A Movie", year: 2020)])
        let r = try #require(await AssistantToolbox(container: c).discoveryReply("play something best series"))
        #expect(ids(r) == ["Great Show", "Good Show", "Plain Show"], "real series only, best rated first")
        #expect(r.proposals.count == 1, "one offer, after the titles")
        guard case .playItem(let id, let isChannel, let title) = r.proposals[0].kind else { Issue.record("expected an offer for a real title"); return }
        #expect(title == "Great Show" && !isChannel && r.answer?.results.first?.item.id == id, "the offer is for the exact top title shown")
        #expect(r.say.contains("best rated first"))
    }

    @Test func typosAndPlainSomethingGiveTheSameKindOfAnswer() async throws {
        let (c, src) = try rig()
        try c.indexer.commitSeries(source: src, categories: [], series: [series(src, "a", "Show A", "7.0"), series(src, "b", "Show B", "8.0")])
        try c.indexer.commitMovies(source: src, categories: [], movies: [TestSupport.movie(src, "m", "Film M", year: 2021)])
        for text in ["play something", "play somwthing", "play someting"] {
            let r = try #require(await AssistantToolbox(container: c).discoveryReply(text), "“\(text)”")
            #expect(!ids(r).isEmpty, "“\(text)” shows real titles")
            #expect(r.proposals.count == 1)
            if case .playItem(let id, _, _) = r.proposals[0].kind { #expect(r.answer?.results.contains { $0.item.id == id } == true, "the offer is for a title that is shown") } else { Issue.record("expected a real offer") }
        }
    }

    @Test func aRealTitleThatStartsWithSomethingIsATitleNotARequest() async throws {
        let (c, src) = try rig()
        try c.indexer.commitMovies(source: src, categories: [], movies: [TestSupport.movie(src, "m1", "Something Wicked", year: 1983)])
        #expect(AssistantDiscovery.parse("play Something Wicked") != nil, "by its words alone it looks like a request")
        #expect(await AssistantToolbox(container: c).discoveryReply("play Something Wicked") == nil, "but the library has exactly that title")
        let offers = try #require(c.assistantCommandProposals("play Something Wicked"))
        if case .playItem(_, _, let title) = offers[0].kind { #expect(title == "Something Wicked") } else { Issue.record("expected an offer for the exact title") }
        #expect(await AssistantToolbox(container: c).discoveryReply("play something funny") != nil, "while a real request still is one")
    }

    @Test func topRatedIsAnOrderingNotAPersonsName() async throws {
        let (c, src) = try rig()
        var s = TestSupport.series(src, "a", "Great Show"); s.rating = "9.2"
        try c.indexer.commitSeries(source: src, categories: [], series: [s])
        let a = try await c.askWhatToWatch("top rated series", useAI: false)
        #expect(a.results.map(\.item.title) == ["Great Show"]); #expect(a.intent.people.isEmpty)
        let b = try await c.askWhatToWatch("best series", useAI: false)
        #expect(b.intent.people.isEmpty)
    }

    @Test func aPercentageRatingDoesNotOutrankARealNine() async throws {
        #expect(AssistantToolbox.tenPointRating("57") == 5.7); #expect(AssistantToolbox.tenPointRating("9.2") == 9.2); #expect(AssistantToolbox.tenPointRating("10") == 10)
        #expect(AssistantToolbox.tenPointRating("250") == 0 && AssistantToolbox.tenPointRating(nil) == 0 && AssistantToolbox.tenPointRating("n/a") == 0)
        let (c, src) = try rig()
        try c.indexer.commitSeries(source: src, categories: [], series: [series(src, "a", "Percent Show", "57"), series(src, "b", "Real Nine", "9.0"), series(src, "c", "Seven", "7.0")])
        let r = try #require(await AssistantToolbox(container: c).discoveryReply("play something best series"))
        #expect(ids(r).first == "Real Nine", "9.0 beats a 57% rating: \(ids(r))")
    }

    @Test func movieRequestsReturnMoviesOnly() async throws {
        let (c, src) = try rig()
        try c.indexer.commitSeries(source: src, categories: [], series: [series(src, "a", "Show A", "9.9")])
        try c.indexer.commitMovies(source: src, categories: [], movies: [TestSupport.movie(src, "m", "Film M", year: 2021)])
        let r = try #require(await AssistantToolbox(container: c).discoveryReply("put on a movie"))
        #expect(ids(r) == ["Film M"])
    }

    @Test func nothingMatchingMeansNoTitlesAndNoPlayButton() async throws {
        let (c, src) = try rig()
        try c.indexer.commitMovies(source: src, categories: [], movies: [TestSupport.movie(src, "m", "Film M", year: 2021)])
        let r = try #require(await AssistantToolbox(container: c).discoveryReply("play something best series"))
        #expect(r.say.contains("couldn’t find")); #expect(r.proposals.isEmpty); #expect(r.answer == nil)
        let empty = try rig().0
        let none = try #require(await AssistantToolbox(container: empty).discoveryReply("play something"))
        #expect(none.proposals.isEmpty && none.answer == nil, "an empty library gives no Play button")
    }

    @Test func anUnresolvedPhraseNeverBecomesAPlayButton() async throws {
        let (c, src) = try rig()
        try c.indexer.commitSeries(source: src, categories: [], series: [series(src, "a", "Show A", "7.0")])
        for text in ["play somwthing", "play something best series", "play zzzz qqqq", "play asdfgh"] {
            let model = AssistantModel()
            model.send(text, container: c, look: { ("Home", nil, nil) })
            for _ in 0..<750 where model.busy || model.messages.count < 3 { try? await Task.sleep(nanoseconds: 20_000_000) }
            for offer in model.messages.flatMap(\.proposals) {
                switch offer.kind {
                case .playItem(let id, _, _): #expect(((try? c.catalog.seriesItem(id: id)) ?? nil) != nil || ((try? c.catalog.movie(id: id)) ?? nil) != nil || ((try? c.catalog.channel(id: id)) ?? nil) != nil, "“\(text)”: the offer is for a real title")
                case .command(let cmd): if case .play = cmd.kind { Issue.record("“\(text)”: a Play button was made for the phrase itself") }
                default: break
                }
            }
        }
    }

    // MARK: parental restrictions

    @Test func titlesInLockedFoldersAreNeverShownOrOfferedWhileLocked() async throws {
        try await IsolatedDefaults.with("disc-par") { d in
            let (c, src) = try rig()
            let kids = CatalogCategory(id: CatalogCategory.makeID(source: src.id, kind: .series, provider: "k"), sourceID: src.id, kind: .series, providerID: "k", name: "Kids", sortOrder: 0)
            let adult = CatalogCategory(id: CatalogCategory.makeID(source: src.id, kind: .series, provider: "a"), sourceID: src.id, kind: .series, providerID: "a", name: "Adults", sortOrder: 1)
            try c.indexer.commitSeries(source: src, categories: [kids, adult], series: [series(src, "k1", "Kids Show", "6.0", category: kids), series(src, "a1", "Adult Show", "9.5", category: adult)])
            let parental = ParentalControls(catalog: c.catalog, defaults: d)
            #expect(parental.setPIN("2468")); #expect(parental.setFolder(adult.id, locked: true))
            let locked = try #require(await AssistantToolbox(container: c).discoveryReply("play something best series"))
            #expect(ids(locked) == ["Kids Show"], "the locked folder's series is not shown")
            if case .playItem(_, _, let title) = locked.proposals[0].kind { #expect(title == "Kids Show") }
            #expect(!locked.say.contains("Adult"))
            _ = parental.unlock(pin: "2468")
            let open = try #require(await AssistantToolbox(container: c).discoveryReply("play something best series"))
            #expect(ids(open) == ["Adult Show", "Kids Show"], "visible while the person has unlocked restricted content")
            parental.lockNow()
            let again = try #require(await AssistantToolbox(container: c).discoveryReply("play something best series"))
            #expect(ids(again) == ["Kids Show"], "and hidden again when it relocks")
        }
    }

    @Test func anOfferIsRefusedAtTheMomentOfRunningIfItsFolderLockedSince() async throws {
        try await IsolatedDefaults.with("disc-run") { d in
            let (c, src) = try rig()
            let adult = CatalogCategory(id: CatalogCategory.makeID(source: src.id, kind: .series, provider: "a"), sourceID: src.id, kind: .series, providerID: "a", name: "Adults", sortOrder: 0)
            try c.indexer.commitSeries(source: src, categories: [adult], series: [series(src, "a1", "Adult Show", "9.5", category: adult)])
            let offered = try #require(await AssistantToolbox(container: c).discoveryReply("play something best series"))
            let offer = try #require(offered.proposals.first)
            let parental = ParentalControls(catalog: c.catalog, defaults: d)
            #expect(parental.setPIN("2468")); #expect(parental.setFolder(adult.id, locked: true))
            let sit = AssistantAuthorizer.situation(profiles: c.profiles, parental: parental, playback: c.playback, catalog: c.catalog)
            if case .deny(let why) = AssistantAuthorizer.decide(offer, sit) { #expect(why.contains("locked folder")) } else { Issue.record("a folder locked after the offer must refuse it") }
        }
    }
}

@MainActor @Suite("Assistant: a tick only when it really worked") struct AssistantHonestResultTests {
    private func playing() -> PlaybackState { .playing }
    /// A player that goes through the given states, one per poll.
    private func probe(_ states: [PlaybackState], key: String? = "item", lastError: (PlaybackError, Date)? = nil) -> AssistantPlaybackWatch.Probe {
        var i = 0
        return AssistantPlaybackWatch.Probe(current: { key.map { Optional($0) } ?? nil }, state: { defer { i += 1 }; return states[min(i, states.count - 1)] },
                                            lastError: { lastError.map { (error: $0.0, at: $0.1) } }, pause: 5_000_000)
    }

    @Test func successIsReportedOnlyOncePlaybackStarts() async {
        let out = await AssistantPlaybackWatch.started(probe: probe([.resolving, .preparing, .buffering, .playing]), expecting: "item", timeout: 30)
        #expect(out == .done(nil))
    }

    @Test func aFailureIsReportedWithItsActualReason() async {
        let out = await AssistantPlaybackWatch.started(probe: probe([.resolving, .failed(PlaybackError(.authorization))]), expecting: "item", timeout: 30)
        guard case .failed(let why) = out else { Issue.record("must not be success"); return }
        #expect(why.contains("rejected the playback request")); #expect(why.contains("login"), "with what to try next")
    }

    @Test func aStreamThatNeverStartsIsNotSaidToHaveWorked() async {
        let out = await AssistantPlaybackWatch.started(probe: probe([.preparing]), expecting: "item", timeout: 0.3)
        guard case .failed(let why) = out else { Issue.record("must not be success"); return }
        #expect(why.contains("not started playing")); #expect(why.contains("preparing"), "it says what the player is doing")
    }

    @Test func somethingThatWasNeverOpenedIsNotSuccessEither() async {
        let out = await AssistantPlaybackWatch.started(probe: probe([.idle], key: nil), expecting: "item", timeout: 0.3)
        guard case .failed(let why) = out else { Issue.record("must not be success"); return }
        #expect(why.contains("did not start"))
    }

    @Test func aDifferentStreamPlayingIsNotTheOneAskedFor() async {
        let out = await AssistantPlaybackWatch.started(probe: probe([.playing], key: "another-item"), expecting: "item", timeout: 0.3)
        #expect(!out.isDone)
    }

    @Test func theButtonShowsRunningThenTickOnlyOnSuccess() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-hr-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let model = AssistantModel()
        let p = AssistantProposal(kind: .refresh, origin: c.assistantOrigin())
        var release: CheckedContinuation<Void, Never>?
        let task = Task { await model.execute(p, perform: { _ in await withCheckedContinuation { release = $0 }; return .done("Fine.") }) }
        for _ in 0..<100 where release == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(model.states[p.id] == .running, "no tick while it is still being done")
        release?.resume(); await task.value
        #expect(model.states[p.id] == .done); #expect(model.messages.last?.text == "Fine.")
    }

    @Test func aFailureShowsTheReasonAndNoTick() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-hf-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let model = AssistantModel()
        let p = AssistantProposal(kind: .refresh, origin: c.assistantOrigin())
        await model.execute(p, perform: { _ in .failed("The provider rejected the request.") })
        #expect(model.states[p.id] == .failed("The provider rejected the request.")); #expect(model.messages.last?.text == "The provider rejected the request.")
        #expect(model.states[p.id] != .done)
    }

    @Test func playingATitleThatIsGoneFailsInsteadOfTicking() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-hg-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let state = AppState(container: c, defaults: .standard)
        let out = await SearchCommandRunner.execute(.playItem(id: "missing", isChannel: false, title: "Missing Show"), container: c, router: AppRouter(), state: state)
        #expect(out == .failed("“Missing Show” is no longer in your library."))
        let resume = await SearchCommandRunner.execute(.command(.init(kind: .resume)), container: c, router: AppRouter(), state: state)
        #expect(!resume.isDone, "nothing to resume is not success")
    }

    @Test func aChannelThatCannotBeReachedIsNeverReportedAsPlaying() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-hp-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let src = try c.sources.addM3U(name: "Mine", url: "http://127.0.0.1:9/list.m3u")
        var ch = TestSupport.channel(src, "a", "Dead Channel", cat: nil); ch.streamRef = "http://127.0.0.1:9/live/a.ts"
        try c.indexer.commitChannels(source: src, categories: [], channels: [ch])
        let stored = try #require(try c.catalog.channels(ChannelQuery(collapseVariants: false)).first)
        AssistantPlaybackWatch.timeout = 6; defer { AssistantPlaybackWatch.timeout = 20 }
        let out = await SearchCommandRunner.execute(.playItem(id: stored.id, isChannel: true, title: "Dead Channel"), container: c, router: AppRouter(), state: AppState(container: c, defaults: .standard))
        guard case .failed(let why) = out else { Issue.record("a channel that cannot play must not be a success"); return }
        #expect(!why.isEmpty)
        c.playback.stop()
    }
}
