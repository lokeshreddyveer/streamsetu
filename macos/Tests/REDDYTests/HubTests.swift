import Testing
import Foundation
@testable import REDDY

// Metadata hub: pure logic against the shared fixtures in artwork/fixtures (Kotlin matches these later). Fake keys only; no network.
@Suite("Metadata hub") struct HubTests {
    static func root() -> URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: root().appendingPathComponent("artwork/fixtures/" + name)) }
    static func obj(_ name: String) throws -> Any { try JSONSerialization.jsonObject(with: data(name)) }

    static func ctx(_ d: [String: Any]) -> ArtContext { ArtContext(preferredLang: d["preferredLang"] as? String ?? "en", originalLang: d["originalLang"] as? String, largeScreen: true) }
    static func cand(_ d: [String: Any], _ kind: ArtKind) -> ArtCandidate {
        ArtCandidate(kind: kind, url: d["url"] as! String, source: HubSource(rawValue: d["source"] as! String)!, lang: d["lang"] as? String, width: d["width"] as! Int, height: d["height"] as! Int, likes: d["likes"] as? Int ?? 0)
    }
    static func ids(_ d: [String: Any]) -> HubIdentity { HubIdentity(tmdb: d["tmdb"] as? Int, tvdb: d["tvdb"] as? Int, imdb: d["imdb"] as? String, tvmaze: d["tvmaze"] as? Int) }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: arbiter fixtures
    func runPicks(_ file: String, _ kind: ArtKind) throws {
        let root = try Self.obj(file) as! [String: Any]
        let picks = root["pick"] as! [[String: Any]]
        #expect(picks.count >= 5)
        for c in picks {
            let cands = (c["candidates"] as! [[String: Any]]).map { Self.cand($0, kind) }
            let got = Arbiter.pick(kind, cands, Self.ctx(c["ctx"] as! [String: Any]))?.candidate.url
            #expect(got == c["expected"] as? String, "\(c["notes"] ?? "")")
        }
    }
    @Test func posterFixtures() throws { try runPicks("arbiter-poster.json", .poster) }
    @Test func logoFixtures() throws { try runPicks("arbiter-logo.json", .logo) }

    @Test func replaceFixtures() throws {
        let root = try Self.obj("arbiter-poster.json") as! [String: Any]
        for c in root["replace"] as! [[String: Any]] {
            var stored: StoredFact?
            if let s = c["stored"] as? [String: Any] {
                let q: Double = (s["quality"] as? String) == "pinned" ? .infinity : (s["quality"] as! NSNumber).doubleValue
                stored = StoredFact(value: "x", source: HubSource(rawValue: s["source"] as! String)!, quality: q, expiresAt: (s["expired"] as! Bool) ? t0.addingTimeInterval(-1) : t0.addingTimeInterval(1000), failCount: s["failCount"] as! Int)
            }
            let pick = Arbiter.Pick(candidate: ArtCandidate(kind: .poster, url: "n", source: .fanart, lang: "en", width: 1000, height: 1500), score: (c["candidateScore"] as! NSNumber).doubleValue)
            #expect(Arbiter.shouldReplace(stored: stored, with: pick, now: t0) == (c["expected"] as! Bool), "\(c["notes"] ?? "")")
        }
    }
    @Test func backdropNeedsTextless16by9AndWidth() {
        let c = ArtContext()
        func b(_ lang: String?, _ w: Int, _ h: Int) -> ArtCandidate { ArtCandidate(kind: .backdrop, url: "u", source: .tmdb, lang: lang, width: w, height: h) }
        #expect(Arbiter.pick(.backdrop, [b("en", 1920, 1080)], c) == nil)
        #expect(Arbiter.pick(.backdrop, [b(nil, 1280, 720)], c) == nil)
        #expect(Arbiter.pick(.backdrop, [b(nil, 1920, 1200)], c) == nil)
        #expect(Arbiter.pick(.backdrop, [b("", 1920, 1080), b(nil, 3840, 2160)], c)?.candidate.width == 3840)
        #expect(Arbiter.pick(.backdrop, [b("", 1920, 1080), b(nil, 3840, 2160)], ArtContext(largeScreen: false))?.candidate.width == 1920)
    }
    @Test func targetQualityStopsFanOut() {
        let c = ArtContext()
        let good = StoredFact(value: "u", source: .tmdb, quality: 1100, expiresAt: t0.addingTimeInterval(100))
        #expect(Arbiter.atTarget(.poster, stored: good, c, now: t0))
        #expect(!Arbiter.atTarget(.poster, stored: nil, c, now: t0))
        var weak = good; weak.quality = 400; #expect(!Arbiter.atTarget(.poster, stored: weak, c, now: t0))
        var old = good; old.expiresAt = t0.addingTimeInterval(-1); #expect(!Arbiter.atTarget(.poster, stored: old, c, now: t0))
    }

    // MARK: identity and text
    @Test func identityFixtures() throws {
        let root = try Self.obj("identity.json") as! [String: Any]
        for c in root["merge"] as! [[String: Any]] {
            let src = HubSource(rawValue: c["incomingSource"] as! String)!
            let got = HubIdentity.merge(Self.ids(c["existing"] as! [String: Any]), Self.ids(c["incoming"] as! [String: Any]), incomingRank: HubIdentity.rank(of: src), existingRank: src == .playlist ? 99 : 0)
            #expect(got == Self.ids(c["expected"] as! [String: Any]), "\(c["notes"] ?? "")")
        }
        for c in root["queryID"] as! [[String: Any]] {
            let got = Self.ids(c["identity"] as! [String: Any]).queryID(for: HubSource(rawValue: c["source"] as! String)!, kind: HubTitleKind(rawValue: c["kind"] as! String)!)
            #expect(got == c["expected"] as? String, "\(c)")
        }
        for c in root["imdb"] as! [[String: Any]] { #expect(HubIdentity.imdbID(c["input"] as? String) == c["expected"] as? String) }
    }
    @Test func episodeTextFixtures() throws {
        for c in try Self.obj("arbiter-episode-text.json") as! [[String: Any]] {
            let cands = (c["candidates"] as! [[String: Any]]).map { EpisodeTextArbiter.Candidate(source: HubSource(rawValue: $0["source"] as! String)!, text: $0["text"] as! String) }
            let got = EpisodeTextArbiter.choose(stored: c["stored"] as? String, storedSource: (c["storedSource"] as? String).flatMap(HubSource.init(rawValue:)), candidates: cands)
            #expect(got?.text == c["expectedText"] as? String, "\(c["notes"] ?? "")")
            #expect(got?.source.rawValue == c["expectedSource"] as? String, "\(c["notes"] ?? "")")
        }
    }
    @Test func ratingNeverBlends() {
        #expect(RatingArbiter.value(tmdbAverage: 8.2, tmdbVotes: 1500, playlist: "5.5", tvmaze: 9.9) == 8.2)
        #expect(RatingArbiter.value(tmdbAverage: 8.2, tmdbVotes: 9, playlist: "5.5", tvmaze: 9.9) == 5.5)
        #expect(RatingArbiter.value(tmdbAverage: nil, tmdbVotes: nil, playlist: nil, tvmaze: 8.9) == 8.9)
        #expect(RatingArbiter.value(tmdbAverage: 10, tmdbVotes: 2, playlist: "0", tvmaze: nil) == nil)
    }

    // MARK: attribution
    @Test func tvdbFooterOnlyForTvdbProvenance() throws {
        for c in try Self.obj("attribution.json") as! [[String: Any]] {
            let prov = Set((c["provenance"] as! [String]).compactMap(HubSource.init(rawValue:)))
            #expect(HubAttribution.footer(provenance: prov, onScreens: c["onScreens"] as! Bool) == c["expected"] as? String)
        }
        #expect(!HubDefaults.tvdbAttributionOnScreens, "no provider name on a content screen: the credit is in Settings")
        #expect(HubAttribution.footer(provenance: [.tmdb, .fanart, .tvmaze]) == nil)
        #expect(HubAttribution.footer(provenance: [.tvdb]) == nil, "with the on-screen credit off, even TheTVDB data adds no footer")
        #expect(HubAttribution.footer(provenance: [.tvdb], onScreens: true) == "Data from TheTVDB.com")
    }

    // MARK: providers
    @Test func fanartParsesAndKeepsKeysOutOfTheURL() throws {
        let movie = FanartProvider.parse(try Self.data("fanart-movie-603.json"), kind: .movie)
        #expect(movie.filter { $0.kind == .logo }.count == 2 && movie.allSatisfy { $0.url.hasPrefix("https://") })
        #expect(QualityScorer.isTextless(movie.first { $0.kind == .backdrop }?.lang))
        let tv = FanartProvider.parse(try Self.data("fanart-tv-121361.json"), kind: .series)
        #expect(tv.filter { $0.kind == .seasonPoster }.count == 1 && tv.first { $0.kind == .seasonPoster }?.season == 1)
        #expect(FanartProvider.parse(try Self.data("fanart-tv-121361.json"), kind: .movie).isEmpty)
        let req = FanartProvider.request(kind: .series, id: "121361", keys: FanartKeys(projectKey: "FAKE-PROJECT-KEY", clientKey: "FAKE-PERSONAL-KEY"))!
        #expect(!req.url!.absoluteString.contains("FAKE") && req.url!.host == "webservice.fanart.tv" && req.url!.path == "/v3.2/tv/121361")
        #expect(req.value(forHTTPHeaderField: "api-key") == "FAKE-PROJECT-KEY" && req.value(forHTTPHeaderField: "client-key") == "FAKE-PERSONAL-KEY")
        #expect(FanartProvider.request(kind: .movie, id: "603", keys: FanartKeys(projectKey: "K", clientKey: nil))!.value(forHTTPHeaderField: "client-key") == nil)
    }
    @Test func tvdbParsesAndMapsLanguages() throws {
        let a = TVDBProvider.parseArtworks(try Self.data("tvdb-artworks.json"), kind: .series)
        #expect(a.count == 3)
        #expect(a.first { $0.kind == .poster }?.lang == "en" && a.first { $0.kind == .backdrop }?.lang == "" && a.first { $0.kind == .logo }?.lang == "hi")
    }
    @Test func tvmazeParsesShowAndSchedule() throws {
        let s = TVmazeProvider.parseShow(try Self.data("tvmaze-show-82.json"))!
        #expect(s.ids.tvmaze == 82 && s.ids.tvdb == 121361 && s.ids.imdb == "tt0944947" && s.status == "Running" && s.rating == 8.9)
        #expect(s.episodes.count == 2 && s.seasons.count == 2 && s.seasons[0].episodeCount == 2)
        #expect(s.episodes[0].summary == "The first episode." && s.episodes[0].imageURL == "https://static.tvmaze.com/o.jpg")
        #expect(s.next?.airstamp == "2026-12-01T02:00:00+00:00" && s.next?.summary == "Back again.")
        let sch = TVmazeProvider.parseSchedule(try Self.data("tvmaze-schedule-web.json"))
        #expect(sch.count == 2 && sch[0].tvdb == 121361 && sch[1].imdb == nil && sch[0].season == 3)
        #expect(TVmazeProvider.showRequest(id: HubIdentity(tvmaze: 82))!.url!.absoluteString.removingPercentEncoding?.contains("embed[]=nextepisode") == true)
        #expect(TVmazeProvider.showRequest(id: HubIdentity(tvdb: 121361))!.url!.absoluteString == "https://api.tvmaze.com/lookup/shows?thetvdb=121361")
        #expect(TVmazeProvider.showRequest(id: HubIdentity(tmdb: 5)) == nil)
    }
    @Test func tmdbImagesBecomeCandidates() throws {
        let c = TMDBProvider.parseImages(try Self.data("tmdb-images.json"))
        #expect(c.count == 3 && c.first { $0.kind == .backdrop }?.lang == nil && c.allSatisfy { $0.source == .tmdb && $0.url.hasPrefix("https://image.tmdb.org/") })
        #expect(Arbiter.pick(.backdrop, c, ArtContext())?.candidate.url.hasSuffix("/b.jpg") == true)
    }

    @Test func tmdbExtrasFeedTheCrosswalk() throws {
        let root = try Self.obj("tmdb-details-extras.json") as! [String: Any]
        func parsed(_ k: String, _ series: Bool) -> TMDBExtras.Parsed? { TMDBExtras.parse(try! JSONSerialization.data(withJSONObject: root[k]!), isSeries: series) }
        let s = parsed("series", true)!, es = root["expectedSeries"] as! [String: Any]
        #expect(s.ids == { var i = Self.ids(es["ids"] as! [String: Any]); i.kind = .series; return i }())
        #expect(s.translations == es["translations"] as! [String: String])
        let m = parsed("movie", false)!
        #expect(m.ids.tvdb == nil && m.ids.imdb == "tt0133093" && m.ids.tmdb == 603)
        let store = HubStore(db: try TestSupport.makeDB())
        store.saveTMDBExtras("s1", s)
        #expect(store.identity("s1")?.ids.tvdb == 121361 && store.fact("s1", "overview:te")?.fact.value == "తెలుగు సారాంశం")
    }

    // MARK: budgets
    @Test func tvmazeNeverExceedsTenCallsPerTenSeconds() {
        var b = TokenBucket(.tvmaze, now: t0)
        var times: [Double] = []
        var t = 0.0
        while t < 120 { if b.take(now: t0.addingTimeInterval(t)) == 0 { times.append(t) }; t += 0.1 }          // asks 10 times a second for two minutes
        for (i, s) in times.enumerated() { #expect(times.filter { $0 >= s && $0 < s + 10 }.count <= 10, "window at \(i)") }
        #expect(times.count > 50)
    }
    @Test func breakerOpensAfterFiveFailuresAndProbesOnce() {
        var b = CircuitBreaker()
        for _ in 0..<4 { b.failure(now: t0) }
        let a1 = b.allow(now: t0)
        b.failure(now: t0)
        let a2 = b.allow(now: t0.addingTimeInterval(899))
        let a3 = b.allow(now: t0.addingTimeInterval(901))                // the one probe
        let a4 = b.allow(now: t0.addingTimeInterval(902))
        b.failure(now: t0.addingTimeInterval(902))                       // the probe failed: open again
        let a5 = b.allow(now: t0.addingTimeInterval(903))
        let a6 = b.allow(now: t0.addingTimeInterval(902 + 901)); b.success()
        let a7 = b.allow(now: t0.addingTimeInterval(2000))
        #expect(a1 && !a2 && a3 && !a4 && !a5 && a6 && a7)
    }
    @Test func negativeCacheDurations() {
        #expect(NegativeCache.missUntil(.notFound, now: t0) == t0.addingTimeInterval(30 * 86400))
        #expect(NegativeCache.missUntil(.serverError, now: t0) == t0.addingTimeInterval(6 * 3600))
        #expect(NegativeCache.missUntil(.offline, now: t0) == nil)
        #expect(NegativeCache.outcome(forStatus: 404, retryAfter: nil) == .notFound)
        #expect(NegativeCache.backoff(retryAfter: nil, previousFailures: 0) == 10 && NegativeCache.backoff(retryAfter: nil, previousFailures: 20) == 900 && NegativeCache.backoff(retryAfter: 30, previousFailures: 3) == 30)
    }
    @Test func queueExpressBeforeBulkDedupedAndCapped() {
        var q = HubQueue(policy: .tvdb, now: t0)
        q.enqueue("a", lane: .bulk); q.enqueue("b", lane: .bulk); q.enqueue("b", lane: .bulk)
        q.enqueue("c", lane: .express)
        let n1 = q.next(now: t0)?.key                                     // express first
        let n2 = q.next(now: t0)?.key                                     // one bulk worker
        let n3 = q.next(now: t0)?.key
        q.enqueue("b", lane: .express)                                    // promoted; one express at a time
        let n4 = q.next(now: t0)?.key
        q.finish("c"); let n5 = q.next(now: t0)?.key
        let dup = q.enqueue("b", lane: .express)                          // in flight: no duplicate
        #expect(n1 == "c" && n2 == "a" && n3 == nil && n4 == nil && n5 == "b" && !dup)
    }
    @Test func fanartRefusesBulkAndHasADailyCap() {
        var q = HubQueue(policy: .fanart, now: t0)
        let bulk = q.enqueue("x", lane: .bulk); let none = q.next(now: t0)
        var served = 0
        for i in 0..<400 { q.enqueue("t\(i)", lane: .express); if let n = q.next(now: t0) { served += 1; q.finish(n.key) } }
        let later = t0.addingTimeInterval(2 * 86400)
        let idle = q.next(now: later)                                     // the cap resets on a new day
        q.enqueue("again", lane: .express); let again = q.next(now: later)?.key
        #expect(!bulk); #expect(none == nil); #expect(served == HubPolicy.fanart.perDayCap); #expect(idle != nil, "a new day resumes the waiting title"); _ = again
        #expect(HubPolicy.fanart.bulkAllowed == false && HubPolicy.fanart.refillPerSecond <= 2 && HubPolicy.tvdb.keep == 7 * 86400 && HubPolicy.tmdb.keep == 180 * 86400)
    }

    // MARK: keys and access
    func access(_ s: HubSource, builtIn: String?, defaults: UserDefaults, secrets: MemorySecretStore = MemorySecretStore(), now: @escaping @Sendable () -> Date) -> HubAccess {
        HubAccess(source: s, secrets: secrets, builtIn: { builtIn }, defaults: defaults, now: now)
    }
    func freshDefaults() -> UserDefaults { let n = "hubtest-\(UUID().uuidString)"; let d = UserDefaults(suiteName: n)!; d.removePersistentDomain(forName: n); return d }

    @Test func resolutionOrderAndDefaults() {
        let d = freshDefaults(); let now = t0
        let fan = access(.fanart, builtIn: "BUILTIN", defaults: d, now: { now })
        #expect(fan.origin == .builtIn && FanartKeys.resolve(fan) == FanartKeys(projectKey: "BUILTIN", clientKey: nil))
        fan.setOwnKey("  MINE  ")
        #expect(fan.origin == .own && FanartKeys.resolve(fan) == FanartKeys(projectKey: "BUILTIN", clientKey: "MINE"))           // personal key is sent IN ADDITION
        #expect(access(.fanart, builtIn: nil, defaults: d, now: { now }).origin == .none)
        let tvdb = access(.tvdb, builtIn: "BUILTIN", defaults: d, now: { now })
        #expect(tvdb.origin == .builtIn && tvdb.enabled && HubDefaults.tvdbBuiltInDefaultOn)              // the owner turned TheTVDB on by default (approval still pending)
        tvdb.enabled = false; #expect(tvdb.origin == .none, "it can still be switched off")
        #expect(access(.tvmaze, builtIn: nil, defaults: d, now: { now }).origin == .builtIn)
        let off = access(.tvmaze, builtIn: nil, defaults: d, now: { now }); off.enabled = false; #expect(off.origin == .none)
    }
    @Test func rejectedBuiltInKeyIsPausedSevenDays() {
        let d = freshDefaults(); let box = NowBox(t0)
        let a = access(.fanart, builtIn: "BUILTIN", defaults: d, now: { box.value })
        a.markBuiltInRejected()
        #expect(a.origin == .none && a.builtInRejected)
        box.value = t0.addingTimeInterval(6 * 86400); #expect(a.origin == .none)
        box.value = t0.addingTimeInterval(7 * 86400 + 1); #expect(a.origin == .builtIn)
        a.markBuiltInRejected(); a.setOwnKey("mine"); #expect(!a.builtInRejected, "editing the key lifts the pause")
    }

    // MARK: TheTVDB session
    final class NowBox: @unchecked Sendable { var value: Date; init(_ v: Date) { value = v } }
    final class Calls: @unchecked Sendable {
        let lock = NSLock(); var requests: [URLRequest] = []; var tokenNo = 0; var failNextGet = false
        func add(_ r: URLRequest) { lock.withLock { requests.append(r) } }
    }
    func stub(_ calls: Calls) -> HubFetch {
        { req in
            calls.add(req)
            if req.url!.path.hasSuffix("/login") { calls.lock.withLock { calls.tokenNo += 1 }; return Data(#"{"data":{"token":"TOKEN-\#(calls.tokenNo)"}}"#.utf8) }
            if calls.lock.withLock({ let f = calls.failNextGet; calls.failNextGet = false; return f }) { throw NetworkError.http(status: 401, retryAfter: nil) }
            return Data(#"{"data":{"artworks":[]}}"#.utf8)
        }
    }
    @Test func tvdbLoginOncePutsKeyOnlyInTheBodyAndRefreshesOn401() async throws {
        let d = freshDefaults(); let calls = Calls(); let secrets = MemorySecretStore(); let box = NowBox(t0)
        let a = access(.tvdb, builtIn: "FAKE-TVDB-KEY", defaults: d, secrets: secrets, now: { box.value }); a.enabled = true
        let s = TVDBSession(access: a, fetch: stub(calls))
        _ = try await s.get("/series/1/artworks"); _ = try await s.get("/series/2/artworks")
        #expect(calls.tokenNo == 1)
        let login = calls.requests[0]
        #expect(login.httpMethod == "POST" && String(data: login.httpBody!, encoding: .utf8)!.contains("FAKE-TVDB-KEY") && !login.url!.absoluteString.contains("FAKE"))
        #expect(calls.requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer TOKEN-") == true && !$0.url!.absoluteString.contains("TOKEN") })
        #expect(secrets.get(TVDBSession.tokenAccount)?.hasSuffix("TOKEN-1") == true)                      // kept for the next launch
        calls.failNextGet = true; _ = try await s.get("/series/3/artworks")
        #expect(calls.tokenNo == 2, "a 401 logs in once more")
        let s2 = TVDBSession(access: a, fetch: stub(calls)); _ = try await s2.get("/x")                    // a new launch reads the saved token
        #expect(calls.tokenNo == 2)
        box.value = t0.addingTimeInterval(31 * 86400); let s3 = TVDBSession(access: a, fetch: stub(calls)); _ = try await s3.get("/x")
        #expect(calls.tokenNo == 3, "a token past its 30 days is not reused")
    }
    @Test func tvdbRejectedBuiltInKeyPausesIt() async {
        let d = freshDefaults(); let a = access(.tvdb, builtIn: "FAKE", defaults: d, now: { self.t0 }); a.enabled = true
        let s = TVDBSession(access: a, fetch: { _ in throw NetworkError.http(status: 401, retryAfter: nil) })
        await #expect(throws: NetworkError.self) { _ = try await s.get("/x") }
        #expect(a.builtInRejected)
    }

    // MARK: store and hub
    @Test func migrationCreatesTheTablesAndCopiesProviderIDs() throws {
        let db = try TestSupport.makeDB()
        #expect(DatabaseMigrator.latestVersion >= 24)
        #expect(try db.read { try $0.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('hub_identity','metadata_facts')") } == 2)
        let store = HubStore(db: db)
        store.saveIdentity("a", HubIdentity(tmdb: 603, kind: .movie), from: .playlist)
        store.saveIdentity("a", HubIdentity(tmdb: 999, tvdb: 5, imdb: "tt0133093"), from: .tmdb, now: t0)
        let got = store.identity("a")!.ids
        #expect(got.tmdb == 603 && got.tvdb == 5 && got.imdb == "tt0133093" && got.kind == .movie)
    }
    @Test func factsNeverDowngradeAndPurge() throws {
        let store = HubStore(db: try TestSupport.makeDB())
        #expect(store.put("a", "poster", value: "u1", source: .tmdb, quality: 1100, now: t0, keep: 1000))
        #expect(!store.put("a", "poster", value: "u2", source: .fanart, quality: 1120, now: t0, keep: 1000), "inside the margin")
        #expect(store.put("a", "poster", value: "u3", source: .fanart, quality: 1200, now: t0, keep: 1000))
        #expect(!store.put("a", "poster", value: "u4", source: .tvdb, quality: 800, now: t0, keep: 1000), "never a downgrade")
        #expect(store.put("a", "poster", value: "u5", source: .tvdb, quality: 800, now: t0.addingTimeInterval(2000), keep: 1000), "an expired value is replaced")
        #expect(store.provenance("a") == [.tvdb])
        store.put("b", "logo", value: "l", source: .fanart, quality: 1, now: t0, keep: 10)
        #expect(store.purgeExpired(now: t0.addingTimeInterval(5000)) == 2)
        store.put("c", "logo", value: "l", source: .fanart, quality: 1, now: t0, keep: 10)
        #expect(store.purge(items: ["c"]) == 1 && store.fact("c", "logo") == nil)
    }

    final class StubArt: ArtworkProvider, @unchecked Sendable {
        let source: HubSource; var calls = 0; var result: [ArtCandidate]; let lock = NSLock()
        init(_ s: HubSource, _ r: [ArtCandidate]) { source = s; result = r }
        func artwork(for id: HubIdentity, kind: HubTitleKind) async throws -> [ArtCandidate] { lock.withLock { calls += 1 }; return result }
    }
    func makeHub(_ art: [StubArt], db: DatabaseManager, sendable: @escaping @Sendable (String) -> Bool = { _ in true }) -> (MetadataHub, HubStore) {
        let d = freshDefaults(); let store = HubStore(db: db)
        let acc: [HubSource: HubAccess] = [.fanart: access(.fanart, builtIn: "FAKE", defaults: d, now: { self.t0 }), .tvdb: access(.tvdb, builtIn: "FAKE", defaults: d, now: { self.t0 }), .tvmaze: access(.tvmaze, builtIn: nil, defaults: d, now: { self.t0 })]
        let t = t0
        return (MetadataHub(store: store, artwork: art, episodes: [], access: acc, isSendable: sendable, now: { t }, sleep: { _ in }), store)
    }
    @Test func hubAsksFanartOncePerTitleAndStoresTheBestLogo() async throws {
        let fan = StubArt(.fanart, [ArtCandidate(kind: .logo, url: "https://x/l.png", source: .fanart, lang: "en", width: 800, height: 310, likes: 5),
                                    ArtCandidate(kind: .backdrop, url: "https://x/b.jpg", source: .fanart, lang: "", width: 1920, height: 1080, likes: 5)])
        let (hub, _) = makeHub([fan], db: try TestSupport.makeDB())
        let id = HubIdentity(tmdb: 603)
        let r1 = await hub.refresh("m1", identity: id, kind: .movie)
        #expect(r1.asked == [.fanart] && Set(r1.stored) == ["logo", "backdrop"])
        #expect(await hub.image("m1", .logo) == "https://x/l.png")
        let r2 = await hub.refresh("m1", identity: id, kind: .movie)
        #expect(fan.calls == 1 && r2.asked.isEmpty, "one request per title until expiry")
        #expect(await hub.attributionFooter("m1") == nil, "fanart.tv art never produces the TheTVDB footer")
    }
    @Test func hubSkipsLockedTitlesMissingIdsAndOffSources() async throws {
        let fan = StubArt(.fanart, []); let tv = StubArt(.tvdb, [])
        let (hub, _) = makeHub([fan, tv], db: try TestSupport.makeDB(), sendable: { $0 != "locked" })
        _ = await hub.refresh("locked", identity: HubIdentity(tmdb: 1), kind: .movie)
        _ = await hub.refresh("noid", identity: HubIdentity(), kind: .series)
        _ = await hub.refresh("ok", identity: HubIdentity(tmdb: 1, tvdb: 2), kind: .movie)
        #expect(fan.calls == 1, "only the title that was allowed and had an id")
        #expect(tv.calls == 1, "TheTVDB is on by default: asked once, for the title that was allowed and had its id")
    }
    @Test func hubFindsNothingAndRemembersTheMiss() async throws {
        let fan = StubArt(.fanart, [])
        let (hub, _) = makeHub([fan], db: try TestSupport.makeDB())
        _ = await hub.refresh("m", identity: HubIdentity(tmdb: 9), kind: .movie); _ = await hub.refresh("m", identity: HubIdentity(tmdb: 9), kind: .movie)
        #expect(fan.calls == 1)
    }
    @Test func hubSkipsFanartWhenTheTitleIsAlreadyGoodEnough() async throws {
        let fan = StubArt(.fanart, [])
        let (hub, store) = makeHub([fan], db: try TestSupport.makeDB())
        for (f, q) in [("poster", 1100.0), ("logo", 1100), ("backdrop", 120)] { store.put("m", f, value: "u", source: .tmdb, quality: q, now: t0, keep: 86400) }
        let r = await hub.refresh("m", identity: HubIdentity(tmdb: 9), kind: .movie)
        #expect(fan.calls == 0 && r.asked.isEmpty)
    }
    @Test func tvdbDataHasNoFooterAndASevenDayKeep() async throws {
        let (hub, store) = makeHub([], db: try TestSupport.makeDB())
        store.put("s", "poster", value: "u", source: .tvdb, quality: 1, now: t0, keep: HubPolicy.tvdb.keep)
        #expect(await hub.attributionFooter("s") == nil)      // the credit moved to Settings
        #expect(store.fact("s", "poster")?.fact.expiresAt == t0.addingTimeInterval(7 * 86400))
    }
}
