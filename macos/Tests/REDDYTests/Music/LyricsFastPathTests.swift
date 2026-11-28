import Testing
import Foundation
@testable import REDDY

// The fast path: the race (first good answer wins, the rest is cancelled), the plain-text window, waves and health, the persistent cache,
// the prefetch of the next songs and the new regional source. Sources are fakes; waits are short real sleeps with wide margins.

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0, peak = 0, total = 0, cancelled = 0
    func enter() { lock.lock(); running += 1; total += 1; peak = max(peak, running); lock.unlock() }
    func leave() { lock.lock(); running -= 1; lock.unlock() }
    func markCancelled() { lock.lock(); cancelled += 1; lock.unlock() }
    var snapshot: (peak: Int, total: Int, cancelled: Int) { lock.lock(); defer { lock.unlock() }; return (peak, total, cancelled) }
}

private func timed(_ id: String, words: Bool = false, last: Int64 = 150_000) -> MusicLyrics {
    let w = words ? [MusicLyricWord(text: "a", startMs: 1000, endMs: 1500)] : nil
    return MusicLyrics(synced: [MusicLyricLine(timeMs: 1000, text: "first line", words: w), MusicLyricLine(timeMs: last, text: "last line")], providerID: id)
}

private func job(_ id: String, variant: Int = 0, wave: Int = 0, after: Double = 0, timeout: Double = 5, counter: Counter? = nil,
                 _ result: MusicLyrics?, fail: Bool = false) -> MusicLyricsRaceJob {
    MusicLyricsRaceJob(id: id, variant: variant, wave: wave, timeout: timeout) {
        counter?.enter()
        defer { counter?.leave() }
        if after > 0 {
            do { try await Task.sleep(nanoseconds: UInt64(after * 1e9)) } catch { counter?.markCancelled(); throw error }
        }
        if fail { throw MusicError.network("down") }
        return result
    }
}

private func config(_ edit: (inout MusicLyricsRaceConfig) -> Void = { _ in }) -> MusicLyricsRaceConfig {
    var c = MusicLyricsRaceConfig()
    c.secondWaveAt = 0.25; c.lastWaveAt = 0.5; c.plainWindow = 0.3; c.upgradeWindow = 1.5; c.soft = 1.0; c.budget = 3
    c.durationSeconds = 200
    edit(&c)
    return c
}

@Suite struct LyricsRaceTests {
    @Test func firstGoodHitWinsAndCancelsTheRest() async {
        let c = Counter()
        let out = await MusicLyricsRace.run([job("slow", after: 2, counter: c, timed("slow")), job("fast", counter: c, timed("fast"))], config: config())
        #expect(out.walk.lyrics?.providerID == "fast")
        #expect(out.elapsed < 1)
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(c.snapshot.cancelled == 1)
    }

    @Test func aTimedAnswerInsideThePlainWindowBeatsPlainText() async {
        let shown = FastLocked<Int>(0)
        let out = await MusicLyricsRace.run([job("p", MusicLyrics(plain: "words words words", providerID: "p")), job("s", after: 0.1, timed("s"))],
                                            config: config(), onProvisional: { _ in shown.withLock { $0 += 1 } })
        #expect(out.walk.lyrics?.providerID == "s")
        #expect(shown.value == 0)
    }

    @Test func plainTextIsShownAfterTheWindowAndUpgradedWhenTimedLyricsArrive() async {
        let early = FastLocked<String?>(nil)
        let out = await MusicLyricsRace.run([job("p", MusicLyrics(plain: "words words words", providerID: "p")), job("s", after: 0.8, timed("s"))],
                                            config: config(), onProvisional: { l in early.value = l.providerID })
        #expect(early.value == "p")
        #expect(out.walk.lyrics?.providerID == "s")
        let plainOnly = await MusicLyricsRace.run([job("p", MusicLyrics(plain: "words words words", providerID: "p")), job("n", nil)], config: config())
        #expect(plainOnly.walk.lyrics?.providerID == "p")
    }

    @Test func aTimedAnswerFarPastTheSongsEndIsAnotherCut() async {
        #expect(!MusicLyricsRace.plausible(timed("x", last: 400_000), durationSeconds: 200))
        #expect(MusicLyricsRace.plausible(timed("x", last: 190_000), durationSeconds: 200))
        #expect(MusicLyricsRace.plausible(MusicLyrics(plain: "plain text here"), durationSeconds: 200))
        let out = await MusicLyricsRace.run([job("wrong", timed("wrong", last: 600_000)), job("right", after: 0.1, timed("right"))], config: config())
        #expect(out.walk.lyrics?.providerID == "right")
    }

    @Test func variantsRunSideBySideUpToTheCap() async {
        let c = Counter()
        let jobs = (0..<10).map { job("s\($0 % 2)", variant: $0 / 2, after: 0.12, counter: c, nil) }
        _ = await MusicLyricsRace.run(jobs, config: config { $0.maxConcurrent = 4 })
        let s = c.snapshot
        #expect(s.peak == 4 && s.total == 10)
    }

    @Test func theSecondWaveStartsEarlyOnlyWhenTheFirstIsSpent() async {
        let late = Counter(), early = Counter()
        // The first wave answers "none" at once: the second wave does not wait for its time.
        let o1 = await MusicLyricsRace.run([job("a", nil), job("b", wave: 1, counter: early, timed("b"))], config: config { $0.secondWaveAt = 2 })
        #expect(o1.walk.lyrics?.providerID == "b" && o1.elapsed < 1)
        // The first wave finds timed lyrics inside the second wave's time: the second wave never starts.
        let o2 = await MusicLyricsRace.run([job("a", after: 0.05, timed("a")), job("b", wave: 1, counter: late, timed("b"))], config: config())
        #expect(o2.walk.lyrics?.providerID == "a")
        #expect(late.snapshot.total == 0)
    }

    @Test func aSlowWaveOpensAtItsTimeWhenTheFirstIsStillBusy() async {
        let out = await MusicLyricsRace.run([job("a", after: 1.5, timed("a")), job("b", wave: 1, timed("b"))], config: config())
        #expect(out.walk.lyrics?.providerID == "b")
        #expect(out.elapsed >= 0.2 && out.elapsed < 1)
    }

    @Test func aMissWithAnErrorIsNotAnAnswerOfNone() async {
        let out = await MusicLyricsRace.run([job("a", nil, fail: true), job("b", nil)], config: config())
        #expect(out.walk.lyrics == nil && out.walk.answered && out.walk.errored == 1)
        #expect(out.walk.errorIDs == ["a"] && out.walk.noneIDs == ["b"])
        let offline = await MusicLyricsRace.run([job("a", nil, fail: true)], config: config())
        #expect(!offline.walk.answered)
    }

    @Test func theSoftTimeSaysSoWhenSourcesAnsweredNoneButOthersAreSlow() async {
        let said = FastLocked<Bool>(false)
        let out = await MusicLyricsRace.run([job("a", nil), job("slow", after: 2, timed("slow"))], config: config { $0.soft = 0.2; $0.budget = 0.6 }, onSoftMiss: { said.value = true })
        #expect(said.value)
        #expect(out.walk.lyrics == nil)
        #expect(out.elapsed < 1.5)
    }

    @Test func aHangingSourceIsCutAtItsOwnTimeout() async {
        let out = await MusicLyricsRace.run([job("hang", after: 10, timeout: 0.2, timed("h")), job("miss", nil)], config: config())
        #expect(out.elapsed < 1.5)
        #expect(out.walk.errorIDs == ["hang"])
    }
}

@Suite struct LyricsSourcePlanTests {
    private func plan(_ enabled: [String], _ locale: MusicLyricsLocale, _ stats: MusicLyricsSourceStats = MusicLyricsSourceStats()) -> [MusicLyricsSourcePlan.Choice] {
        MusicLyricsSourcePlan.plan(enabled: enabled, locale: locale, stats: stats)
    }
    private let all = MusicLyricsSources.defaultOrder

    @Test func aTeluguSongAsksTheOpenSourcesFirst() {
        let locale = MusicLyricsLocale.detect(title: "సమజవరగమన", artists: "సిద్ శ్రీరామ్", album: nil)
        #expect(locale.language == .telugu && locale.indian)
        let p = plan(all, locale)
        let ids = p.map(\.id)
        #expect(ids.firstIndex(of: MusicLyricsSources.lrclib)! < ids.firstIndex(of: MusicLyricsSources.netease)!)
        #expect(ids.firstIndex(of: MusicLyricsSources.jioSaavn)! < ids.firstIndex(of: MusicLyricsSources.kugou)!)
        #expect(p.first { $0.id == MusicLyricsSources.jioSaavn }?.wave == 0)
        #expect(p.first { $0.id == MusicLyricsSources.netease }?.wave == 1)
        #expect(p.first { $0.id == MusicLyricsSources.genius }?.wave == 2)
        #expect(p.first { $0.id == MusicLyricsSources.lrclib }?.variants == 3)
    }

    @Test func aWesternSongDoesNotAskJioSaavnInTheFirstWave() {
        let locale = MusicLyricsLocale.detect(title: "Bohemian Rhapsody", artists: "Queen", album: nil)
        #expect(!locale.indian)
        #expect(plan(all, locale).first { $0.id == MusicLyricsSources.jioSaavn }?.wave == 1)
    }

    @Test func latinTitlesAreRecognisedByLanguageWordsOnly() {
        #expect(MusicLyricsLocale.detect(title: "Mass Raja (Telugu)", artists: "Melodious Mana Telugu", album: nil) == MusicLyricsLocale(language: .telugu, indian: true))
        #expect(!MusicLyricsLocale.detect(title: "Tum Hi Ho", artists: "T-Series", album: nil).indian, "a label or channel name says nothing about the song")
        #expect(MusicLyricsLocale.detect(title: "Hello", artists: "Adele", album: "25") == MusicLyricsLocale(language: nil, indian: false))
    }

    @Test func healthDelaysAndSkipsSources() {
        let now = FastLocked<Double>(1000)
        let stats = MusicLyricsSourceStats(clock: { now.value })
        let locale = MusicLyricsLocale(language: .hindi, indian: true)
        stats.record(MusicLyricsSources.lrclib, seconds: 5, answered: false, hit: false)
        #expect(plan(all, locale, stats).first { $0.id == MusicLyricsSources.lrclib }?.wave == 1)
        stats.record(MusicLyricsSources.lrclib, seconds: 5, answered: false, hit: false)
        stats.record(MusicLyricsSources.lrclib, seconds: 5, answered: false, hit: false)
        #expect(!plan(all, locale, stats).contains { $0.id == MusicLyricsSources.lrclib })
        now.value += 400
        #expect(plan(all, locale, stats).contains { $0.id == MusicLyricsSources.lrclib })
        stats.record(MusicLyricsSources.lrclib, seconds: 0.3, answered: true, hit: true)
        #expect(stats.recentFailures(MusicLyricsSources.lrclib) == 0)
    }

    @Test func aConsistentlySlowSourceMovesToTheSecondWaveAndTimeoutsFollowTheMeasuredP95() {
        let stats = MusicLyricsSourceStats()
        for _ in 0..<6 { stats.record(MusicLyricsSources.lrcRed, seconds: 2.6, answered: true, hit: false) }
        let p = plan(all, MusicLyricsLocale(language: nil, indian: false), stats)
        #expect(p.first { $0.id == MusicLyricsSources.lrcRed }?.wave == 1)
        for _ in 0..<8 { stats.record("x", seconds: 0.4, answered: true, hit: true) }
        #expect(stats.timeout("x", cap: 8) == 2.5)
        for _ in 0..<8 { stats.record("y", seconds: 3, answered: true, hit: true) }
        #expect(abs(stats.timeout("y", cap: 8) - 4.9) < 0.01)
        #expect(stats.timeout("y", cap: 4) == 4)
    }
}

@Suite struct LyricsDiskCacheTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-fast-\(UUID().uuidString)") }
    private func lyrics(_ n: Int, pinned: Bool = false) -> MusicLyrics {
        MusicLyrics(synced: [MusicLyricLine(timeMs: 1000, text: "line \(n)"), MusicLyricLine(timeMs: 5000, text: "more \(n)")], providerID: "lrclib", pinned: pinned)
    }

    @Test func theLeastRecentlyUsedFilesGoFirstAndPinnedOnesStay() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = MusicLyricsDiskStore(directory: dir)
        for i in 0..<30 { await store.write(key: "k\(i)", lyrics: lyrics(i, pinned: i == 0), fetchedAt: Date()); try await Task.sleep(nanoseconds: 5_000_000) }
        // Reading k1 makes it the most recently used.
        _ = await store.read(key: "k1")
        let removed = await store.trim(maxFiles: 20, maxBytes: 10_000_000)
        #expect(removed >= 12)
        #expect(await store.read(key: "k0") != nil)
        #expect(await store.read(key: "k1") != nil)
        #expect(await store.read(key: "k2") == nil)
        #expect(await store.read(key: "k29") != nil)
        #expect(await store.usage().files <= 18)
    }

    @Test func theByteLimitTrimsToo() async {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = MusicLyricsDiskStore(directory: dir)
        for i in 0..<10 { await store.write(key: "k\(i)", lyrics: lyrics(i), fetchedAt: Date()) }
        let before = await store.usage()
        await store.trim(maxFiles: 100, maxBytes: before.bytes / 2)
        let after = await store.usage()
        #expect(after.bytes <= before.bytes / 2 && after.files < before.files)
    }

    @Test func theFolderIsKeptOutOfBackupsAndWipeRemovesEverything() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = MusicLyricsDiskStore(directory: dir)
        await store.write(key: "a", lyrics: lyrics(1), fetchedAt: Date())
        await store.writeAlias(key: "alias|x|y|40", lyrics: lyrics(2, pinned: true))
        let excluded = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
        #expect(await store.readAlias(key: "alias|x|y|40")?.lyrics?.pinned == false)
        await store.clear(keepPinned: false)
        #expect(await store.usage().files == 0)
    }

    @Test func aMissIsNeverSharedThroughAnAliasAndExpiresAfterSixHours() async {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = MusicLyricsDiskStore(directory: dir)
        await store.write(key: "alias|m", lyrics: nil, fetchedAt: Date())
        #expect(await store.readAlias(key: "alias|m") == nil)
        let now = Date()
        #expect(MusicLyricsCachePolicy.missTTL == 6 * 3600)
        #expect(MusicLyricsCachePolicy.isFresh(hit: false, fetchedAt: now.addingTimeInterval(-5 * 3600), now: now))
        #expect(!MusicLyricsCachePolicy.isFresh(hit: false, fetchedAt: now.addingTimeInterval(-7 * 3600), now: now))
        #expect(MusicLyricsCachePolicy.isFresh(hit: true, fetchedAt: now.addingTimeInterval(-90 * 24 * 3600), now: now))
    }

    @Test func theSameSongUnderAnotherIdSharesTheAliasKey() {
        let a = MusicTrack(id: "1", providerID: "audius", title: "Tum Hi Ho (Official Video)", durationMs: 262_000, artists: [MusicArtistRef(id: "a", name: "Arijit Singh")])
        let b = MusicTrack(id: "zzz", providerID: "youtube-music", title: "Tum Hi Ho", durationMs: 263_000, artists: [MusicArtistRef(id: "b", name: "Arijit Singh - Topic")])
        #expect(MusicLyricsService.aliasKey(for: a) == MusicLyricsService.aliasKey(for: b))
        let other = MusicTrack(id: "2", providerID: "audius", title: "Tum Hi Ho", durationMs: 330_000, artists: [MusicArtistRef(id: "a", name: "Arijit Singh")])
        #expect(MusicLyricsService.aliasKey(for: a) != MusicLyricsService.aliasKey(for: other))
    }
}

private struct FastCountingSource: MusicLyricsProvider {
    var info: MusicProviderInfo { MusicProviderInfo(id: MusicLyricsSources.lrclib, name: "fake", summary: "test") }
    var capabilities: MusicCapabilities { .lyrics }
    let asked: FastLocked<[String]>
    let delay: Double
    func lyrics(for track: MusicTrack) async throws -> MusicLyrics? {
        asked.withLock { $0.append(track.id) }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return MusicLyrics(synced: [MusicLyricLine(timeMs: 1000, text: "first line here"), MusicLyricLine(timeMs: 100_000, text: "last line here")], providerID: info.id)
    }
}

@MainActor
@Suite struct LyricsPrefetchTests {
    private func service(delay: Double = 0) -> (MusicLyricsService, FastLocked<[String]>) {
        let reg = MusicRegistry(defaults: UserDefaults(suiteName: "lyr.\(UUID().uuidString)")!)
        let asked = FastLocked<[String]>([])
        let p = FastCountingSource(asked: asked, delay: delay)
        reg.register(p)
        reg.setEnabled(true, id: p.id, reason: .setup)
        let s = MusicLyricsService(registry: reg, cacheDirectory: nil)
        s.warmsConnections = false
        s.timing.overall = 3; s.timing.walkBudget = 2; s.timing.cap = 1
        return (s, asked)
    }
    private func track(_ n: Int) -> MusicTrack {
        MusicTrack(id: "t\(n)", providerID: "audius", title: "Song \(n)", durationMs: 120_000, artists: [MusicArtistRef(id: "a", name: "Artist")])
    }
    private func settle(_ s: MusicLyricsService, _ t: MusicTrack) async {
        let start = Date()
        while !s.loadState(for: t).isTerminal, Date().timeIntervalSince(start) < 4 { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test func theStartedSongIsLookedUpAtOnceAndOnlyTheNextTwoAreLookedAheadOf() async {
        let (s, asked) = service()
        let queue = (1...6).map(track)
        s.trackStarted(queue[0], queue: queue, metered: false)
        await settle(s, queue[0])
        #expect(s.loadState(for: queue[0]).isTerminal)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let ids = Set(asked.value)
        #expect(ids == ["t1", "t2", "t3"])
    }

    @Test func nothingIsLookedAheadOnAMeteredConnection() async {
        let (s, asked) = service()
        let queue = (1...4).map(track)
        s.trackStarted(queue[0], queue: queue, metered: true)
        await settle(s, queue[0])
        try? await Task.sleep(nanoseconds: 800_000_000)
        #expect(Set(asked.value) == ["t1"])
    }

    @Test func aNewSongCancelsTheLookupsAheadOfTheOldOne() async {
        let (s, asked) = service(delay: 0.6)
        let queue = (1...6).map(track)
        s.schedulePrefetch([queue[1], queue[2]], after: nil, metered: false)
        try? await Task.sleep(nanoseconds: 200_000_000)
        s.schedulePrefetch([], after: nil, metered: false)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(Set(asked.value) == ["t2"])
        #expect(s.loadState(for: queue[2]) == .idle)
    }

    @Test func aPrefetchedSongIsFoundInstantlyAndWipeForgetsIt() async {
        let (s, asked) = service()
        let queue = (1...3).map(track)
        s.trackStarted(queue[0], queue: queue, metered: false)
        await settle(s, queue[0])
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let before = asked.value.count
        let found = await s.lyrics(for: queue[1])
        #expect(found != nil && asked.value.count == before)
        s.clearCache()
        let again = await s.lyrics(for: queue[1])
        #expect(again != nil && asked.value.count > before)
    }
}

@Suite struct JioSaavnLyricsTests {
    // Trimmed from real replies.
    private let search = #"""
    {"total":5,"start":1,"results":[
     {"id":"gZsIAUmO","title":"Samajavaragamana - Male","subtitle":"Sid Sriram - Ala Vaikunthapurramuloo","language":"telugu","more_info":{"has_lyrics":"true","duration":"219","lyrics_id":""}},
     {"id":"aNPkTdmJ","title":"Samajavaragamana","subtitle":"Jonnuvittula, S.P.Balasubramanyam, Chitra - Top Hero (Original Motion Picture Soundtrack)","language":"telugu","more_info":{"has_lyrics":"true","duration":"298"}},
     {"id":"sFriQd4g","title":"Samajavaragamana","subtitle":"Sanjith Hegde - Haage Vaikunthapuradalli","language":"kannada","more_info":{"has_lyrics":"false","duration":"215"}},
     {"id":"Bt07_OpM","title":"Tum Hi Ho (From &quot;Aashiqui 2&quot;)","subtitle":"Arijit Singh, Mithoon - Best Of Arijit Singh","language":"hindi","more_info":{"has_lyrics":"false","duration":"261"}},
     {"id":"aRZbUYD7","title":"Tum Hi Ho","subtitle":"Mithoon, Arijit Singh - Aashiqui 2","language":"hindi","more_info":{"has_lyrics":"true","duration":"262"}}]}
    """#
    private let lyricsReply = #"{"lyrics":"Nee Kaallani Pattuku Vadalanannavi<br>Choode Naa Kallu<br><br>Nee Kallaki Kaavaali<br>Kaasthaaye Kaatukala Naa Kalalu","snippet":"","lyrics_copyright":"x"}"#

    private func candidates() -> [JioSaavnLyricsProvider.Candidate] { JioSaavnLyricsProvider.candidates(try! JSONSerialization.jsonObject(with: Data(search.utf8))) }

    @Test func readsCandidatesAndTheCreditLine() {
        let c = candidates()
        #expect(c.count == 5 && c[0].id == "gZsIAUmO" && c[0].hasLyrics && c[0].seconds == 219)
        #expect(c[0].artists == "Sid Sriram" && c[3].title == "Tum Hi Ho (From \"Aashiqui 2\")" && !c[3].hasLyrics)
    }

    @Test func picksTheSongWithLyricsWhoseTitleAndLengthAgree() {
        let c = candidates()
        #expect(JioSaavnLyricsProvider.pick(c, title: "Samajavaragamana", artist: "Sid Sriram", seconds: 230) == nil)
        #expect(JioSaavnLyricsProvider.pick(c, title: "Samajavaragamana", artist: "Sid Sriram", seconds: 221)?.id == "gZsIAUmO")
        #expect(JioSaavnLyricsProvider.pick(c, title: "Tum Hi Ho (From \"Aashiqui 2\")", artist: "Arijit Singh", seconds: 262)?.id == "aRZbUYD7")
        // A cut 30 s off is another version; no length falls back to the artist.
        #expect(JioSaavnLyricsProvider.pick(c, title: "Tum Hi Ho", artist: "", seconds: 300) == nil)
        #expect(JioSaavnLyricsProvider.pick(c, title: "Tum Hi Ho", artist: "Arijit Singh", seconds: nil)?.id == "aRZbUYD7")
        #expect(JioSaavnLyricsProvider.pick(c, title: "Tum Hi Ho", artist: "Someone Else", seconds: nil) == nil)
        #expect(JioSaavnLyricsProvider.pick(c, title: "Tum Hi Ho Remix", artist: "Arijit Singh", seconds: 262) == nil)
    }

    @Test func spellingVariantsOfTheTitleStillMatch() {
        let c = [JioSaavnLyricsProvider.Candidate(id: "d", title: "Daakko Daakko Meka", artists: "Sivam", seconds: 216, hasLyrics: true)]
        #expect(JioSaavnLyricsProvider.pick(c, title: "Dakko Dakko Meka", artist: "Sivam", seconds: 216)?.id == "d")
    }

    @Test func turnsTheReplyIntoPlainLines() {
        let t = JioSaavnLyricsProvider.text(try! JSONSerialization.jsonObject(with: Data(lyricsReply.utf8)))
        #expect(t?.hasPrefix("Nee Kaallani Pattuku Vadalanannavi\nChoode Naa Kallu\n\nNee Kallaki") == true)
        #expect(JioSaavnLyricsProvider.text(["lyrics": "<br>"]) == nil)
    }

    @Test func endToEndWithACannedTransport() async throws {
        struct Canned: MusicHTTPTransport {
            let search: String, lyrics: String
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let call = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "__call" }?.value
                let body = call == "lyrics.getLyrics" ? lyrics : search
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let p = JioSaavnLyricsProvider(http: MusicHTTP(transport: Canned(search: search, lyrics: lyricsReply)))
        let r = MusicLyricsRequest(videoID: nil, title: "Samajavaragamana Full Video Song", artists: "Sid Sriram", album: nil, durationSeconds: 220)
        let l = try await p.lyrics(for: r)
        #expect(l?.providerID == MusicLyricsSources.jioSaavn && l?.isSynced == false && (l?.plain ?? "").contains("Choode Naa Kallu"))
        #expect(p.info.privacyNote.contains("jiosaavn.com") && MusicLyricsSources.defaultEnabled[MusicLyricsSources.jioSaavn] == true)
    }
}

@Suite struct LyricsRegionalQueryTests {
    @Test func theFilmAfterTheBarBecomesAnArtistLessQuestion() {
        let r = MusicLyricsRequest(videoID: nil, title: "Samajavaragamana Full Video Song | Ala Vaikunthapurramuloo", artists: "Sid Sriram", album: nil, durationSeconds: 220)
        let v = MusicLyricsQueryBuilder.variants(for: r)
        #expect(v.first?.title == "Samajavaragamana")
        #expect(v.contains { $0.kind == .withFilm && $0.title == "Samajavaragamana Ala Vaikunthapurramuloo" && $0.artists.isEmpty })
        #expect(v.count <= MusicLyricsQueryBuilder.maxVariants)
    }

    @Test func noiseWordsAndTheLanguageTagGo() {
        #expect(MusicLyricsQueryBuilder.cleanTitle("Mass Raja (Telugu)").title == "Mass Raja")
        let butta = MusicLyricsQueryBuilder.variants(for: MusicLyricsRequest(videoID: nil, title: "Butta Bomma (Full Video) - Ala Vaikunthapurramuloo", artists: "Armaan Malik", album: nil, durationSeconds: 198))
        #expect(butta.first?.title == "Butta Bomma" && butta.first?.artists == "Armaan Malik")
        let c = MusicLyricsQueryBuilder.cleanTitle("Kaavaalaa (From \"Jailer\") Lyrical Video Song")
        #expect(c.title == "Kaavaalaa" && c.film == "Jailer")
    }
}

private final class FastLocked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    var value: T { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    @discardableResult func withLock<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}
