import Testing
import Foundation
@testable import REDDY

// Fakes -----------------------------------------------------------------------------------------------------------------------------

private final class Log: @unchecked Sendable {
    private let l = NSLock()
    private var names: [String] = []
    private var running = 0
    private(set) var peak = 0
    func begin(_ n: String) { l.withLock { names.append(n); running += 1; peak = max(peak, running) } }
    func end() { l.withLock { running -= 1 } }
    var order: [String] { l.withLock { names } }
    var count: Int { l.withLock { names.count } }
}

private func row(_ n: Int, provider: String = "discover-itunes-charts", ms: Int64 = 0, title: String? = nil) -> MusicTrack {
    MusicTrack(id: "r\(n)", providerID: provider, title: title ?? "Song \(n)", durationMs: ms,
               artists: [MusicArtistRef(id: "a\(n)", name: "Artist \(n)")], album: MusicAlbumRef(id: "al\(n)", title: "Album \(n)"))
}

private func twin(_ id: String, _ title: String, channel: String?, album: String? = nil, score: Float = 0.8, provider: String = "youtube-music") -> MusicCanonicalTwin {
    MusicCanonicalTwin(providerID: provider, sourceID: id, title: title, artist: channel, album: album, durationMs: 200_000, score: score)
}

private func canon(_ t: MusicTrack, twins: [MusicCanonicalTwin]) -> MusicCanonicalTrack {
    var c = MusicCatalogCanon.make(from: t)
    c.twins = twins
    return c
}

/// Dependencies where every song has one Topic copy, unless `has` says otherwise.
private func deps(log: Log = Log(), delay: UInt64 = 0, has: @escaping @Sendable (MusicTrack) -> Bool = { _ in true }) -> MusicChartDependencies {
    var d = MusicChartDependencies()
    d.twin = { t in
        log.begin(t.uid); defer { log.end() }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        guard has(t) else { return nil }
        return canon(t, twins: [twin("v-" + t.id, t.title, channel: "\(t.artistLine) - Topic", album: "Album")])
    }
    return d
}

private func tempCache(now: @escaping @Sendable () -> Date = { Date() }) -> MusicChartCache {
    MusicChartCache(file: FileManager.default.temporaryDirectory.appendingPathComponent("chart-\(UUID().uuidString)/c.json"), now: now)
}

@MainActor private func settle(_ s: MusicChartSession, seconds: Double = 5) async {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end, s.isResolving { try? await Task.sleep(nanoseconds: 10_000_000) }
}

private struct FakeAudio: MusicAudioProvider {
    var info = MusicProviderInfo(id: "youtube-music", name: "yt", summary: "")
    var capabilities: MusicCapabilities { [.audio] }
    var answer: @Sendable (MusicTrack) -> [MusicAudioSource]
    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] { answer(track) }
    func streams(for source: MusicAudioSource) async throws -> [MusicStream] { [] }
}

// Version order -----------------------------------------------------------------------------------------------------------------------

struct ChartVersionRulesTests {
    @Test func preferenceOrderIsAudioThenAlbumThenLyricThenVideo() {
        let lyric = twin("l", "Song 1 (Lyric Video)", channel: "T-Series", score: 0.9)
        let video = twin("v", "Song 1 (Official Video)", channel: "Artist", score: 0.9)
        let topic = twin("t", "Song 1", channel: "Artist 1 - Topic", score: 0.85)
        let albumRow = twin("a", "Song 1", channel: "Artist 1", album: "Album 1", score: 0.85)
        let order = MusicChartVersionRules.ordered([lyric, video, albumRow, topic]).map(\.version)
        #expect(order == [.officialAudio, .albumTrack, .lyricVideo, .officialVideo])
    }

    @Test func aMuchWeakerOfficialCopyDoesNotBeatAGoodOne() {
        let good = twin("g", "Song 1 (Lyric Video)", channel: "Label", score: 0.95)
        let weak = twin("w", "Song 1", channel: "Artist 1 - Topic", score: 0.62)
        #expect(MusicChartVersionRules.ordered([weak, good]).first?.twin.sourceID == "g")
    }

    @Test func classifyReadsTitleAndChannel() {
        #expect(MusicChartVersionRules.classify(twin("1", "X - Full Audio Song", channel: "Lahari Music")) == .officialAudio)
        #expect(MusicChartVersionRules.classify(twin("2", "X", channel: "Someone", album: "Film")) == .albumTrack)
        #expect(MusicChartVersionRules.classify(twin("3", "X (Lyrical)", channel: "Someone")) == .lyricVideo)
        #expect(MusicChartVersionRules.classify(twin("4", "X", channel: "Someone", provider: "other")) == .other)
    }

    @Test func noteShownOnlyWhenTheCopyDiffersMaterially() {
        var video = row(1, provider: "youtube-music"); video.isVideo = true
        #expect(MusicChartVersionRules.note(.officialAudio, original: video) == Localized.string("Audio version"))
        #expect(MusicChartVersionRules.note(.officialAudio, original: row(1)) == nil)
        #expect(MusicChartVersionRules.note(.albumTrack, original: row(1)) == nil)
        #expect(MusicChartVersionRules.note(.own, original: video) == nil)
        #expect(MusicChartVersionRules.note(.lyricVideo, original: row(1)) == Localized.string("Lyric video"))
    }

    @Test func carryKeepsTheChartsWordsAndThePlayableIdentity() {
        let chart = row(7, ms: 0, title: "Chart Title")
        var playable = MusicTrack(id: "vid", providerID: "youtube-music", title: "Chart Title (Official Audio)", durationMs: 201_000, artists: [MusicArtistRef(id: "x", name: "Chan")])
        playable.videoID = "vid"
        let t = MusicChartVersionRules.carry(chart, playable: playable)
        #expect(t.title == "Chart Title" && t.artistLine == "Artist 7" && t.providerID == "youtube-music" && t.id == "vid" && t.videoID == "vid" && t.durationMs == 201_000)
    }

    @Test func chartsAreRecognised() {
        #expect(MusicChartRules.isChart(title: "Top Weekly Videos Telugu", providerID: "youtube-music"))
        #expect(MusicChartRules.isChart(title: "Telugu: India Superhits Top 50", providerID: "jiosaavn"))
        #expect(MusicChartRules.isChart(title: "Anything", providerID: "discover-deezer"))
        #expect(MusicChartRules.isChart(title: "New releases", providerID: "x"))
        #expect(!MusicChartRules.isChart(title: "My road trip", providerID: "x"))
    }
}

// One song ----------------------------------------------------------------------------------------------------------------------------

struct ChartEngineTests {
    @Test func theSourcesOwnPlayableRowComesFirst() async {
        var d = deps()
        d.providesAudio = { _ in true }
        d.verifyOwn = { _ in true }
        let t = row(1, provider: "youtube-music")
        let out = await MusicChartEngine(deps: d).resolve(t)
        #expect(out.track == t && out.version == .own)
    }

    @Test func aVideoRowFallsBackToItsNamedAudioTwin() async {
        var d = deps()
        d.providesAudio = { _ in true }
        d.verifyOwn = { $0.isVideo != true }
        var v = row(2, provider: "youtube-music"); v.isVideo = true; v.videoID = "vid"; v.id = "vid"; v.counterpartVideoID = "aud"
        let out = await MusicChartEngine(deps: d).resolve(v)
        #expect(out.version == .officialAudio && out.track?.id == "aud" && out.track?.title == v.title)
    }

    @Test func aCatalogueOnlyRowIsNeverItsOwnCopy() async {
        let d = deps()      // providesAudio is false for the discovery source
        let t = row(3)
        let out = await MusicChartEngine(deps: d).resolve(t)
        #expect(out.version == .officialAudio && out.track?.providerID == "youtube-music" && out.track?.id == "v-r3")
        #expect(out.track?.title == "Song 3" && out.track?.artistLine == "Artist 3")
    }

    @Test func aCopyThatFailsTheCheckGivesWayToTheNext() async {
        var d = deps()
        d.twin = { t in canon(t, twins: [twin("bad", "Song", channel: "A - Topic", score: 0.9), twin("ok", "Song (Lyric Video)", channel: "L", score: 0.85)]) }
        d.verifyTwin = { $0.id == "ok" }
        let out = await MusicChartEngine(deps: d).resolve(row(4))
        #expect(out.track?.id == "ok" && out.version == .lyricVideo)
    }

    @Test func noCopyIsUnavailableAndRemembered() async {
        let out = await MusicChartEngine(deps: deps(has: { _ in false })).resolve(row(5))
        #expect(out.track == nil && out.reason == .noPlayableCopy && out.cacheable)
    }

    @Test func theLockAndTheNeverPlayListWin() async {
        var d = deps()
        d.gated = { true }
        let held = await MusicChartEngine(deps: d).resolve(row(1))
        #expect(held.reason == .held && held.track == nil && !held.cacheable)
        var b = deps()
        b.blacklisted = { _ in true }
        let blocked = await MusicChartEngine(deps: b).resolve(row(1))
        #expect(blocked.reason == .blocked && blocked.track == nil)
    }

    @Test func withTheCatalogueOffOnlyPlayableOwnRowsAppear() async {
        var d = deps()
        d.catalogueEnabled = { false }
        d.providesAudio = { $0 == "audius" }
        d.verifyOwn = { $0.id == "good" }
        let engine = MusicChartEngine(deps: d)
        var good = row(1, provider: "audius"); good.id = "good"
        var bad = row(2, provider: "audius"); bad.id = "bad"
        let a = await engine.resolve(good), b = await engine.resolve(bad), c = await engine.resolve(row(3))
        #expect(a.version == .own && b.reason == .catalogueOff && c.reason == .catalogueOff)
    }

    @Test func offlineAndSlowLookupsAreNotRemembered() async {
        var d = deps()
        d.online = { false }
        let off = await MusicChartEngine(deps: d).resolve(row(1))
        #expect(off.reason == .offline && !off.cacheable)
        var slow = deps()
        slow.twin = { _ in try? await Task.sleep(nanoseconds: 2_000_000_000); return nil }
        let late = await MusicChartEngine(deps: slow, itemBudget: 0.05).resolve(row(1))
        #expect(late.reason == .timedOut && !late.cacheable)
    }

    @Test func appleRowsWithoutARuntimeStillMatchThroughTheMatcher() async {
        let audio = FakeAudio { t in
            [MusicAudioSource(id: "topic", providerID: "youtube-music", title: t.title, artist: "\(t.artists.first?.name ?? "") - Topic", album: "Album",
                              durationMs: 215_000, externalURL: nil, confidence: 0.8),
             MusicAudioSource(id: "cover", providerID: "youtube-music", title: t.title + " (Cover)", artist: "Someone Else", durationMs: 90_000, externalURL: nil, confidence: 0.8)]
        }
        let store = MusicCanonicalStore(file: FileManager.default.temporaryDirectory.appendingPathComponent("chart-\(UUID().uuidString)/s.json"))
        let providers: [any MusicAudioProvider] = [audio]
        let matcher = MusicCatalogMatcher(store: store, environment: .init(audio: { providers }, catalogue: { [] }))
        var d = MusicChartDependencies()
        d.twin = { await matcher.twin(for: $0) }
        let apple = MusicTrack(id: "1", providerID: "discover-itunes-charts", title: "Daakko Daakko Meka", durationMs: 0,
                               artists: [MusicArtistRef(id: "s", name: "Sivam")], album: MusicAlbumRef(id: "p", title: "Pushpa"))
        let out = await MusicChartEngine(deps: d).resolve(apple)
        #expect(out.track?.id == "topic" && out.version == .officialAudio)
    }
}

// A chart ------------------------------------------------------------------------------------------------------------------------------

@MainActor
struct ChartSessionTests {
    @Test func allRowsResolveInChartOrderWithTheirRanks() async {
        let tracks = (1...12).map { row($0) }
        let s = MusicChartSession(chartID: "c", tracks: tracks, deps: deps(), cache: nil, config: MusicChartConfig())
        s.start()
        await settle(s)
        #expect(s.resolvedCount == 12 && s.entries.map(\.rank) == Array(1...12))
        #expect(s.playableTracks.map(\.title) == tracks.map(\.title))
        s.cancel()
    }

    @Test func rowsInViewAndTheNextTenGoFirstAndWorkIsBounded() async {
        let log = Log()
        let tracks = (1...40).map { row($0) }
        let s = MusicChartSession(chartID: "w", tracks: tracks, deps: deps(log: log, delay: 20_000_000), cache: nil, config: MusicChartConfig())
        s.noteVisible(uid: tracks[24].uid, true)
        s.noteVisible(uid: tracks[26].uid, true)
        s.start()
        await settle(s)
        let firstNine = log.order.prefix(9).compactMap { Int($0.dropFirst("discover-itunes-charts:r".count)) }
        #expect(firstNine.allSatisfy { $0 >= 25 && $0 <= 37 })
        #expect(log.peak <= 3)
        #expect(s.resolvedCount == 40)
        s.cancel()
    }

    @Test func leavingThePageCancelsTheLookups() async {
        let log = Log()
        let tracks = (1...20).map { row($0) }
        var d = MusicChartDependencies()
        d.twin = { t in log.begin(t.uid); defer { log.end() }; try? await Task.sleep(nanoseconds: 3_000_000_000); return nil }
        let s = MusicChartSession(chartID: "x", tracks: tracks, deps: d, cache: nil, config: MusicChartConfig())
        s.start()
        try? await Task.sleep(nanoseconds: 100_000_000)
        s.cancel()
        try? await Task.sleep(nanoseconds: 150_000_000)
        let started = log.count
        #expect(started <= 3 + 3)
        #expect(!s.entries.contains { $0.state == .resolving } && s.entries.allSatisfy { !$0.isFinal })
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(log.count == started)
    }

    @Test func aReopenedChartIsAnsweredFromTheCache() async {
        let cache = tempCache()
        let tracks = (1...6).map { row($0) }
        let first = MusicChartSession(chartID: "daily", tracks: tracks, deps: deps(has: { $0.id != "r3" }), cache: cache, config: MusicChartConfig())
        first.start()
        await settle(first)
        first.cancel()
        let log = Log()
        let again = MusicChartSession(chartID: "daily", tracks: tracks, deps: deps(log: log), cache: cache, config: MusicChartConfig())
        #expect(again.cacheHits == 6 && !again.isResolving)
        #expect(again.resolvedCount == 5 && again.unavailableCount == 1 && log.count == 0)
        // Another day asks again.
        let tomorrow = MusicChartCache(file: FileManager.default.temporaryDirectory.appendingPathComponent("chart-\(UUID().uuidString)/c.json"), now: { Date().addingTimeInterval(86_400) })
        #expect(tomorrow.items(chartID: "daily").isEmpty)
    }

    @Test func chartCacheSurvivesARestartButNotATimeout() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chart-\(UUID().uuidString)/c.json")
        let cache = MusicChartCache(file: file)
        cache.put(chartID: "k", uid: "u1", .init(track: row(1), version: .own, reason: nil))
        cache.put(chartID: "k", uid: "u2", .init(track: nil, version: nil, reason: .noPlayableCopy))
        cache.flush()
        let reopened = MusicChartCache(file: file)
        #expect(reopened.items(chartID: "k").count == 2)
        var d = deps()
        d.online = { false }
        let s = MusicChartSession(chartID: "t", tracks: [row(9)], deps: d, cache: cache, config: MusicChartConfig())
        s.start()
        await settle(s)
        #expect(s.entries[0].state == .unavailable(.offline) && cache.items(chartID: "t").isEmpty)
        s.cancel()
    }

    @Test func unavailableRowsAreHiddenButKeepTheirRankAndAreCounted() async {
        let tracks = (1...8).map { row($0) }
        let s = MusicChartSession(chartID: "h", tracks: tracks, deps: deps(has: { !["r2", "r5"].contains($0.id) }), cache: nil, config: MusicChartConfig())
        s.start()
        await settle(s)
        #expect(s.unavailableCount == 2 && s.shownEntries.count == 6)
        #expect(s.shownEntries.map(\.rank) == [1, 3, 4, 6, 7, 8])
        s.showUnavailable = true
        #expect(s.shownEntries.count == 8 && s.shownTracks.count == 8)
        let hidden = s.entries[1]
        #expect(hidden.status.phase == .unavailable && hidden.status.reason == MusicChartReason.noPlayableCopy.text)
        s.cancel()
    }

    @Test func aRowThatResolvesLaterClearsItsUnavailableState() async {
        let t = row(1)
        let box = Box()
        var d = MusicChartDependencies()
        d.twin = { t in box.on ? canon(t, twins: [twin("v", "Song 1", channel: "Artist 1 - Topic")]) : nil }
        let s = MusicChartSession(chartID: "retry", tracks: [t], deps: d, cache: nil, config: MusicChartConfig())
        s.start(); await settle(s)
        #expect(s.entries[0].isUnavailable)
        box.on = true
        let e = await s.resolveNow(0, force: true)
        #expect(e?.isPlayable == true && s.unavailableCount == 0)
        s.cancel()
    }

    @Test func playQueuesOnlyPlayableRowsInOrderAndFeedsTheRestLazily() async {
        let tracks = (1...10).map { row($0) }
        let log = Log()
        let s = MusicChartSession(chartID: "p", tracks: tracks, deps: deps(log: log, delay: 5_000_000, has: { t in let n = Int(t.id.dropFirst()) ?? 0; return n % 2 == 1 || n == 10 }),
                                  cache: nil, config: MusicChartConfig(concurrency: 1))
        let played = PlayLog()
        let hooks = MusicChartPlayerHooks(play: { q, i in played.queue = q; played.start = i }, enqueue: { played.added.append(contentsOf: $0) }, currentUID: { played.queue.first?.uid })
        let ok = await s.play(player: hooks)
        #expect(ok)
        await settle(s)
        let all = played.queue + played.added
        #expect(all.map(\.title) == s.playableTracks.map(\.title))
        #expect(all.allSatisfy { $0.providerID == "youtube-music" })
        let ranks = all.compactMap { t in s.entry(forUID: t.uid)?.rank }
        #expect(ranks == ranks.sorted() && Set(ranks).isDisjoint(with: s.entries.filter(\.isUnavailable).map(\.rank)))
        s.cancel()
    }

    @Test func shuffledChartSendsLateBatchesThroughTheShuffledHook() async {
        let tracks = (1...10).map { row($0) }
        let s = MusicChartSession(chartID: "sh", tracks: tracks, deps: deps(delay: 5_000_000), cache: nil, config: MusicChartConfig(concurrency: 1))
        let plain = PlayLog()
        let shuffled = PlayLog()
        let hooks = MusicChartPlayerHooks(play: { q, i in plain.queue = q; plain.start = i }, enqueue: { plain.added.append(contentsOf: $0) }, currentUID: { shuffled.queue.first?.uid },
                                          playShuffled: { shuffled.queue = $0 }, enqueueShuffled: { shuffled.added.append(contentsOf: $0) })
        let ok = await s.play(shuffle: true, player: hooks)
        #expect(ok)
        await settle(s)
        // A late batch added with plain `enqueue` would play rank 1..n unshuffled; every batch must take the shuffled hook.
        #expect(plain.added.isEmpty)
        #expect(plain.queue.isEmpty)
        #expect(shuffled.queue.count + shuffled.added.count == s.playableTracks.count)
        s.cancel()
    }

    @Test func playFromAFailingFirstRowStartsAtTheNextPlayable() async {
        let tracks = (1...4).map { row($0) }
        let s = MusicChartSession(chartID: "f", tracks: tracks, deps: deps(has: { $0.id != "r1" }), cache: nil, config: MusicChartConfig())
        let played = PlayLog()
        let hooks = MusicChartPlayerHooks(play: { q, _ in played.queue = q }, enqueue: { played.added.append(contentsOf: $0) }, currentUID: { nil })
        #expect(await s.play(player: hooks))
        #expect(played.queue.first?.title == "Song 2")
        s.cancel()
    }

    @Test func nothingPlaysWhenNothingIsPlayable() async {
        let s = MusicChartSession(chartID: "n", tracks: (1...3).map { row($0) }, deps: deps(has: { _ in false }), cache: nil, config: MusicChartConfig())
        let played = PlayLog()
        let hooks = MusicChartPlayerHooks(play: { q, _ in played.queue = q }, enqueue: { _ in }, currentUID: { nil })
        #expect(await s.play(player: hooks) == false && played.queue.isEmpty)
        s.cancel()
    }

    @Test func aFailedCopyIsDimmedAndNotChosenAgain() async {
        let s = MusicChartSession(chartID: "z", tracks: [row(1)], deps: deps(), cache: nil, config: MusicChartConfig())
        s.start(); await settle(s)
        let uid = s.entries[0].shown.uid
        s.noteFailed(uid: uid)
        #expect(s.entries[0].state == .unavailable(.failedToPlay) && s.shownEntries.isEmpty)
        s.cancel()
    }

    @Test func pagesThatArriveLaterJoinWithTheNextRanks() async {
        let s = MusicChartSession(chartID: "pg", tracks: (1...3).map { row($0) }, deps: deps(), cache: nil, config: MusicChartConfig())
        s.update(tracks: (1...5).map { row($0) })
        #expect(s.entries.map(\.rank) == [1, 2, 3, 4, 5])
        s.update(tracks: (1...5).map { row($0) })
        #expect(s.entries.count == 5)
        s.start(); await settle(s)
        #expect(s.resolvedCount == 5)
        s.cancel()
    }

    @Test func topRowsAreWarmedOnce() async {
        let warmed = Box()
        var d = deps()
        d.prewarm = { tracks in warmed.count += tracks.count; warmed.calls += 1 }
        let s = MusicChartSession(chartID: "warm", tracks: (1...8).map { row($0) }, deps: d, cache: nil, config: MusicChartConfig())
        s.start(); await settle(s)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(warmed.calls == 1 && warmed.count == 3)
        s.cancel()
    }

    @Test func shelvesKeepOnlyPlayableSongsInOrder() async {
        let section = MusicBrowseSection(id: "s", title: "Top", items: [.track(row(1)), .track(row(2)), .album(MusicAlbum(id: "al", providerID: "p", title: "A")), .track(row(3))])
        let r = MusicChartResolver(cache: tempCache())
        r.configure(deps(has: { $0.id != "r2" }))
        let out = await r.playableSection(section, budget: 5)
        let titles = out.items.compactMap { i -> String? in if case .track(let t) = i { t.title } else { nil } }
        #expect(titles == ["Song 1", "Song 3"] && out.items.count == 3)
    }
}

private final class PlayLog: @unchecked Sendable {
    var queue: [MusicTrack] = []
    var start = 0
    var added: [MusicTrack] = []
}

private final class Box: @unchecked Sendable {
    var on = false
    var count = 0
    var calls = 0
}
