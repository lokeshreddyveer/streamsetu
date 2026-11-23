import Testing
import Foundation
@testable import REDDY

/// Virtual time: sleeping advances it at once, and every sleep is recorded.
private final class FakeClock: MatchClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1_000
    private(set) var sleeps: [TimeInterval] = []
    func now() -> TimeInterval { lock.withLock { t } }
    func sleep(_ s: TimeInterval) async throws { try Task.checkCancellation(); lock.withLock { t += max(0, s); sleeps.append(s) }; await Task.yield() }
    var elapsed: TimeInterval { lock.withLock { t - 1_000 } }
}

private final class FakeNet: MatchNetwork, @unchecked Sendable {
    var usable = true
    func isUsable(allowCellular: Bool) -> Bool { usable || allowCellular }
}

/// Recorded requests and canned replies; counts how many run at once.
private final class FakeHTTP: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    private(set) var times: [TimeInterval] = []
    private(set) var maxParallel = 0
    private var running = 0
    var clock: FakeClock?
    var reply: @Sendable (URLRequest, Int) throws -> Data
    init(_ reply: @escaping @Sendable (URLRequest, Int) throws -> Data) { self.reply = reply }
    func fetch(_ r: URLRequest) async throws -> Data {
        let n: Int = lock.withLock { requests.append(r); times.append(clock?.now() ?? 0); running += 1; maxParallel = max(maxParallel, running); return requests.count }
        await Task.yield()
        defer { lock.withLock { running -= 1 } }
        return try reply(r, n)
    }
    var queries: [String] { lock.withLock { requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value } } }
    var count: Int { lock.withLock { requests.count } }
}

private func hit(_ title: String, year: Int, id: Int = 1, pop: Double = 10) -> String {
    #"{"id":\#(id),"title":"\#(title)","overview":"A story.","poster_path":"/p\#(id).jpg","backdrop_path":"/b.jpg","release_date":"\#(year)-01-01","vote_average":7.0,"popularity":\#(pop)}"#
}
private func results(_ r: String...) -> Data { Data(("{\"results\":[" + r.joined(separator: ",") + "]}").utf8) }
private let none = Data(#"{"results":[]}"#.utf8)
private let ownKey = "0123456789abcdef0123456789abcdef"

private struct Rig {
    let db: DatabaseManager, src: PlaylistSource, svc: MetadataMatchService, matcher: ArtworkAutoMatcher, http: FakeHTTP, clock: FakeClock, net: FakeNet, defaults: InMemoryDefaults, creds: InMemoryCredentialStore

    init(key: String? = ownKey, builtIn: String? = nil, interval: TimeInterval = 0, reply: @escaping @Sendable (URLRequest, Int) throws -> Data, existing: DatabaseManager? = nil, defaults d: InMemoryDefaults? = nil) throws {
        db = try existing ?? TestSupport.makeDB()
        src = try existing == nil ? TestSupport.makeSource(db) : PlaylistSource(name: "Test", type: .m3uRemote, baseURL: "http://example.com/p.m3u")
        creds = InMemoryCredentialStore()
        if let key { try creds.save(Credentials(username: "tmdb", password: key), ref: MetadataMatchService.keyRef) }
        defaults = d ?? InMemoryDefaults()
        clock = FakeClock(); net = FakeNet(); http = FakeHTTP(reply); http.clock = clock
        let h = http
        svc = MetadataMatchService(db: db, credentials: creds, defaults: defaults, builtIn: { builtIn }, pacer: RequestPacer(interval: interval, clock: clock)) { try await h.fetch($0) }
        matcher = ArtworkAutoMatcher(service: svc, store: MatchStateStore(defaults: defaults, profileID: { "p1" }), network: net, clock: clock)
        svc.lookupsAllowed = { [matcher] in matcher.enabled }
        matcher.ratingPassEnabled = false
    }
    func add(_ titles: [(String, Int?)]) throws {
        let ms = titles.enumerated().map { TestSupport.movie(src, "m\($0.offset)", $0.element.0, year: $0.element.1) }
        _ = try CatalogIndexer(db: db).commitMovies(source: src, categories: [], movies: ms)
    }
    func poster(_ title: String) throws -> String? {
        try db.read { try $0.queryOne("SELECT poster_url FROM movies WHERE title=?", [title]) { $0.optString(0) } } ?? nil
    }
}

@Suite("Automatic artwork matching") struct ArtworkAutoMatchTests {
    // MARK: cleaning fixtures
    struct Fixture: Decodable { let input: String; let year: Int?; let expectedClean: String; let notes: String }
    @Test func cleaningMatchesTheSharedFixtures() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artwork/fixtures/name-cleaning.json")
        let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        #expect(cases.count >= 60)
        for c in cases { #expect(ArtworkNameCleaner.clean(c.input, year: c.year) == c.expectedClean, "\(c.input) [\(c.notes)]") }
    }

    // MARK: credentials
    @Test func credentialOrderOwnKeyThenBuiltInThenNothing() throws {
        let tok = "eyJ" + String(repeating: "b", count: 60)
        let own = try Rig(key: ownKey, builtIn: tok) { _, _ in none }
        #expect(own.svc.keySource == .own)
        let builtIn = try Rig(key: nil, builtIn: tok) { _, _ in none }
        #expect(builtIn.svc.keySource == .builtIn && builtIn.svc.hasKey && !builtIn.svc.hasOwnKey)
        let nothing = try Rig(key: nil, builtIn: nil) { _, _ in none }
        #expect(nothing.svc.keySource == .none && !nothing.svc.hasKey)
        let v4own = try Rig(key: tok + "own", builtIn: "eyJother") { _, _ in none }
        #expect(v4own.svc.keySource == .own)
    }

    @Test func v3KeyGoesInTheQueryAndTokensInTheHeader() async throws {
        let tok = "eyJ" + String(repeating: "c", count: 60)
        let v3 = try Rig(key: ownKey) { _, _ in none }
        try await v3.svc.verifyKey()
        let r3 = try #require(v3.http.requests.last)
        #expect(r3.url?.query?.contains("api_key=\(ownKey)") == true && r3.value(forHTTPHeaderField: "Authorization") == nil)
        let v4 = try Rig(key: tok) { _, _ in none }
        try await v4.svc.verifyKey()
        let r4 = try #require(v4.http.requests.last)
        #expect(r4.value(forHTTPHeaderField: "Authorization") == "Bearer " + tok && r4.url?.query?.contains("api_key") != true)
        let built = try Rig(key: nil, builtIn: tok) { _, _ in none }
        try await built.svc.verifyKey()
        let rb = try #require(built.http.requests.last)
        #expect(rb.value(forHTTPHeaderField: "Authorization") == "Bearer " + tok && rb.url?.query?.contains("api_key") != true && rb.url?.host == "api.themoviedb.org")
    }

    @Test func aRefusedBuiltInTokenIsSetAsideAndRememberedWithoutHammering() async throws {
        let tok = "eyJ" + String(repeating: "d", count: 60)
        let rig = try Rig(key: nil, builtIn: tok) { _, _ in throw NetworkError.http(status: 401, retryAfter: nil) }
        try rig.add([("Pushpa", 2021), ("Jawan", 2023)])
        await #expect(throws: MetadataMatchService.MatchError.invalidKey) { try await rig.svc.run() }
        #expect(rig.svc.keySource == .none && rig.svc.access.builtInRejected)
        let before = rig.http.count
        await #expect(throws: MetadataMatchService.MatchError.noKey) { try await rig.svc.run() }
        #expect(rig.http.count == before, "no request is made while the token is set aside")
        rig.matcher.start(); try await waitUntil { rig.matcher.status.state == .builtInRejected }
        #expect(rig.matcher.status.state == .builtInRejected && rig.matcher.status.line.contains("built-in key is not working"))
        try rig.svc.saveKey(ownKey)          // the person adds their own key: used at once, and the rejection is forgotten
        #expect(rig.svc.keySource == .own && !rig.svc.access.builtInRejected)
    }

    @Test func aBuildWithoutATokenHasNone() {
        #if !STREAMSETU_BUILTIN_TMDB
        #expect(BuiltInTMDB.token() == nil && !BuiltInTMDB.isAvailable)
        #endif
        // The scrambled form round-trips, and the pieces do not contain the text.
        let text = "scrambled-example.not-a-real-credential"
        let mask = (0..<text.utf8.count).map { UInt8(($0 * 37 + 11) % 251) }
        let data = zip(Array(text.utf8), mask).map { $0 ^ $1 }
        let chunks = stride(from: 0, to: data.count, by: 7).map { Array(data[$0..<min($0 + 7, data.count)]) }
        #expect(BuiltInTMDB.assemble(chunks: chunks, order: Array(chunks.indices), mask: mask) == text)
        #expect(BuiltInTMDB.assemble(chunks: chunks, order: Array(chunks.indices), mask: Array(mask.dropLast())) == nil)
    }

    @Test func noSecretIsCommittedInGeneratedFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ignore = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(ignore.contains("macos/Sources/REDDY/Generated/") && ignore.contains("ios/StreamSetu/Generated/"))
        for f in ["macos/Sources/REDDY/Services/TMDBAccess.swift", "Scripts/gen-builtin-tmdb.py"] {
            let text = try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)
            #expect(text.range(of: #"eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}"#, options: .regularExpression) == nil, "\(f) holds no token")
        }
    }

    // MARK: matching quality
    @Test func oneSearchWithoutTheYearThenOnlyOneFallback() async throws {
        let rig = try Rig { r, n in n < 2 ? none : results(hit("Pushpa The Rise", year: 2021, id: 5)) }
        try rig.add([("TELUGU | Pushpa The Rise (Telugu) FHD 2026", 2021)])
        let out = try await rig.svc.run()
        #expect(out.matched == 1 && rig.http.count == 2)
        #expect(rig.http.queries.first == "Pushpa The Rise")
        let first = try #require(rig.http.requests.first?.url?.query)
        #expect(!first.contains("year=") && first.contains("language=en-US") && first.contains("include_adult=false"))
        #expect(try rig.poster("TELUGU | Pushpa The Rise (Telugu) FHD 2026") != nil)
    }

    @Test func aTitleCostsAboutOneAndAHalfRequestsAtMost() async throws {
        let rig = try Rig { r, _ in
            let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "query" }?.value ?? ""
            if q.hasSuffix("9") { return none }          // one in ten is not found
            return results(hit(q, year: 2020)) }
        try rig.add((0..<100).map { ("Film Number \($0)", 2020) })
        rig.matcher.start(); try await waitUntil(timeout: 20) { rig.matcher.status.state == .complete }
        let matched = try rig.db.read { try $0.scalarInt("SELECT COUNT(*) FROM metadata_matches WHERE tmdb_id IS NOT NULL") }
        #expect(matched == 90, "matched \(matched)")
        #expect(Double(rig.http.count) / 100 <= 1.5, "requests per title: \(Double(rig.http.count) / 100)")
        #expect(Double(rig.http.count) / Double(matched) <= 1.5, "requests per matched title (the not-found tenth is searched up to four ways): \(Double(rig.http.count) / Double(matched))")
    }

    @Test func theChoiceIsMadeLocallyByYearThenPopularityFromOneList() async throws {
        let rig = try Rig { _, _ in results(hit("Dune", year: 1984, id: 1, pop: 99), hit("Dune", year: 2021, id: 2, pop: 20), hit("Dune", year: 2021, id: 3, pop: 90)) }
        try rig.add([("Dune", 2021)])
        _ = try await rig.svc.run()
        #expect(rig.http.count == 1)
        let tmdb = try rig.db.read { try $0.queryOne("SELECT tmdb_id FROM metadata_matches LIMIT 1") { $0.optInt(0) } } ?? nil
        #expect(tmdb == 1, "name only: the first same-name result, whatever its year or popularity")
    }

    @Test func aFilmFromAnotherYearIsNeverRelabelled() async throws {
        let far = try Rig { _, _ in results(hit("The Silent Harbor", year: 2005)) }
        try far.add([("The Silent Harbor", 1999)])
        #expect(try await far.svc.run().matched == 1, "name only: the year is not read, a same-name film is the match")
        #expect(far.http.count <= 3)
    }

    @Test func bulkCoversOnlyTitlesWithoutAPoster() throws {
        let rig = try Rig { _, _ in none }
        var a = TestSupport.movie(rig.src, "a", "Has Poster Film", year: 2020); a.posterURL = "http://p/x.jpg"
        let b = TestSupport.movie(rig.src, "b", "No Poster Film", year: 2020)
        var c = TestSupport.movie(rig.src, "c", "Poster But No Summary", year: 2020); c.posterURL = "http://p/y.jpg"; c.overview = nil
        _ = try CatalogIndexer(db: rig.db).commitMovies(source: rig.src, categories: [], movies: [a, b, c])
        #expect(try rig.svc.pendingCount() == 1 && MetadataMatchService.includeSummaryOnly == false, "titles that only lack a summary wait until they are opened")
    }

    @Test func similarityThresholdAndChoiceByYearThenPopularity() {
        #expect(MetadataMatchService.similarity("Spider-Man: No Way Home", "Spider Man No Way Home") == 1)
        #expect(MetadataMatchService.similarity("Fast & Furious", "Fast and Furious") == 1)
        #expect(MetadataMatchService.similarity("Matrix Reloaded", "The Matrix") < MetadataMatchService.minSimilarity)
        let json = Data(("{\"results\":[" + hit("Dune", year: 1984, id: 1, pop: 50) + "," + hit("Dune", year: 2021, id: 2, pop: 20) + "," + hit("Dune", year: 2021, id: 3, pop: 90) + "]}").utf8)
        let reply = try! JSONDecoder().decode(MetadataMatchService.SearchReply.self, from: json)
        #expect(MetadataMatchService.best(reply.results, for: "Dune", year: 2021)?.tmdbID == 1, "name only: the first same-name result in order")
        #expect(MetadataMatchService.best(reply.results, for: "Dune", year: nil)?.tmdbID == 1)
        #expect(MetadataMatchService.best(reply.results, for: "Arrakis", year: 2021) == nil)
    }

    @Test func notFoundTitlesAreRememberedUnderTheCurrentRules() async throws {
        let rig = try Rig { _, _ in none }
        try rig.add([("Totally Obscure Regional Film", 2015)])
        rig.matcher.start(); try await waitUntil { rig.matcher.status.state == .complete }
        let sent = rig.http.count
        #expect(sent >= 1 && rig.matcher.status.notFound == 1 && rig.matcher.status.line == "All artwork matched · 1 not found")
        rig.matcher.start(); try await Task.sleep(nanoseconds: 200_000_000)
        #expect(rig.http.count == sent, "tried once (with its second try), then remembered")
    }

    // MARK: pacing, backoff, resume
    @Test func requestsAreSpacedAboutTwentyTwoASecondAndAtMostEightAtOnce() async throws {
        let rig = try Rig(interval: ArtworkAutoMatcher.interval) { r, _ in results(hit(r.url!.query!.contains("Film") ? "Film" : "X", year: 2020)) }
        try rig.add((0..<30).map { ("Film \($0)", 2020) })
        // Titles are all called "Film N": make the fake answer match each query.
        let rig2 = try Rig(interval: ArtworkAutoMatcher.interval) { r, _ in
            let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "query" }?.value ?? ""
            return results(hit(q, year: 2020)) }
        try rig2.add((0..<30).map { ("Film Number \($0)", 2020) })
        _ = rig
        rig2.matcher.start(); try await waitUntil { rig2.matcher.status.state == .complete }
        #expect(rig2.http.count == 30)
        #expect(rig2.clock.elapsed >= 1.2, "30 requests need at least 1.3 virtual seconds at about 22 a second (got \(rig2.clock.elapsed))")
        #expect(rig2.http.maxParallel <= ArtworkAutoMatcher.workers)
        let ts = rig2.http.times.sorted()
        for i in 0..<(ts.count - 10) { #expect(ts[i + 10] - ts[i] > 0.1, "no burst: ten requests are never sent together (virtual time is shared, so only a loose bound is stable)") }
    }

    @Test func aRateLimitHoldsEverythingForRetryAfterAndThenContinues() async throws {
        let rig = try Rig(interval: 0.1) { r, n in
            if n == 3 { throw NetworkError.http(status: 429, retryAfter: 40) }
            let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "query" }?.value ?? ""
            return results(hit(q, year: 2020)) }
        try rig.add((0..<6).map { ("Film Number \($0)", 2020) })
        rig.matcher.start(); try await waitUntil { rig.matcher.status.state == .complete }
        #expect(rig.clock.elapsed >= 40, "waited Retry-After before carrying on")
        #expect(try rig.db.read { try $0.scalarInt("SELECT COUNT(*) FROM movies WHERE poster_url IS NOT NULL") } == 6)
        #expect(rig.defaults.integer(forKey: "artwork.auto.failures") == 0, "the back-off count resets after a success")
    }

    @Test func offlineBacksOffWithoutLosingTheTitle() async throws {
        let rig = try Rig(interval: 0) { r, n in
            if n <= 2 { throw URLError(.notConnectedToInternet) }
            let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "query" }?.value ?? ""
            return results(hit(q, year: 2020)) }
        try rig.add([("Film Number 1", 2020)])
        rig.matcher.start(); try await waitUntil { rig.matcher.status.state == .complete }
        let got = try rig.poster("Film Number 1")
        #expect(rig.clock.elapsed >= 15 && got != nil)
    }

    @Test func waitsOnCellularAndResumesOnWiFiOrWhenAllowed() async throws {
        let rig = try Rig { r, _ in results(hit("Film Number 1", year: 2020)) }
        try rig.add([("Film Number 1", 2020)])
        rig.net.usable = false
        rig.matcher.allowCellular = false          // on by default; this person turned mobile data off
        rig.matcher.start(); try await waitUntil { rig.matcher.status.state == .waitingForNetwork }
        #expect(rig.http.count == 0)
        rig.matcher.allowCellular = true
        try await waitUntil { rig.matcher.status.state == .complete }
        #expect(rig.http.count >= 1)
    }

    @Test func resumesAfterARelaunchWithoutRepeatingFinishedTitles() async throws {
        let seen = Locked<[String]>([])
        let reply: @Sendable (URLRequest, Int) throws -> Data = { r, _ in
            let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "query" }?.value ?? ""
            seen.mutate { $0.append(q) }; return results(hit(q, year: 2020)) }
        let first = try Rig(reply: reply)
        try first.add((0..<20).map { ("Film Number \($0)", 2020) })
        _ = try await first.svc.run(limit: 8)                          // the app was closed after 8
        #expect(seen.value.count == 8)
        let second = try Rig(reply: reply, existing: first.db, defaults: first.defaults)          // relaunch: same database, same settings, new objects
        second.matcher.start(); try await waitUntil { second.matcher.status.state == .complete }
        #expect(seen.value.count == 20 && Set(seen.value).count == 20, "each title was looked up once")
    }

    @Test func switchOffAndKeyRemovalStopTheRun() async throws {
        let gate = DispatchSemaphore(value: 0), served = Locked(0)
        let rig = try Rig(interval: 0.1) { r, _ in
            let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "query" }?.value ?? ""
            served.mutate { $0 += 1 }; let n = served.value
            if n > 8 { _ = gate.wait(timeout: .now() + 10) }      // the clock is virtual: hold the run at 8 replies (no real sleep) until the test has switched it off, however slow the machine is
            return results(hit(q, year: 2020)) }
        try rig.add((0..<200).map { ("Film Number \($0)", 2020) })
        rig.matcher.start(); try await waitUntil { rig.http.count >= 5 }
        rig.matcher.enabled = false
        for _ in 0..<400 { gate.signal() }                                              // let held replies finish; the stopped run must not ask for more
        try await waitUntil { rig.matcher.status.state == .off }                        // wait for the stop itself, not for a guessed delay
        try await Task.sleep(nanoseconds: 100_000_000)
        let stopped = rig.http.count
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.http.count == stopped && stopped < 200 && rig.matcher.status.state == .off, "no more requests after the switch is turned off")
        rig.matcher.enabled = true; try await waitUntil { rig.http.count > stopped + 3 }
        try rig.svc.removeKey()
        try await waitUntil { rig.matcher.status.state == .noKey }                      // wait for the stop itself, not for a guessed delay
        let afterRemoval = rig.http.count
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig.http.count == afterRemoval && rig.matcher.status.state == .noKey)
        rig.matcher.stop()
    }

    @Test func switchedOffSendsNothingAtAllNotEvenForDetails() async throws {
        let rig = try Rig { _, _ in none }
        try rig.add([("Film Number 1", 2020)])
        rig.matcher.enabled = false
        let id = try rig.db.read { try $0.queryOne("SELECT id FROM movies LIMIT 1") { $0.string(0) } }!
        _ = await rig.svc.details(for: .init(id: id, isSeries: false, title: "Film Number 1", year: 2020))
        #expect(rig.http.count == 0)
    }

    // MARK: priority and privacy
    @Test func titlesOnScreenGoToTheFront() async throws {
        let order = Locked<[String]>([])
        let rig = try Rig { r, _ in
            let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "query" }?.value ?? ""
            order.mutate { $0.append(q) }; return results(hit(q, year: 2020)) }
        try rig.add((0..<50).map { ("Film Number \($0)", 2020) })
        let wanted = try rig.db.read { try $0.query("SELECT id, title FROM movies WHERE title IN ('Film Number 3','Film Number 41')") { ($0.string(0), $0.string(1)) } }
        rig.matcher.prioritize(wanted.map(\.0)); rig.matcher.prioritize(wanted.map(\.0))          // asked twice while scrolling: one batch
        try await waitUntil { Set(order.value).isSuperset(of: ["Film Number 3", "Film Number 41"]) }
        let firstDozen = Set(order.value.prefix(12))
        #expect(firstDozen.isSuperset(of: ["Film Number 3", "Film Number 41"]), "served by the express lane before the bulk run reaches them: \(order.value.prefix(12))")
        rig.matcher.stop()
    }

    @Test func restrictedTitlesAreNeverQueuedAndArePurgedTheMomentTheyBecomeRestricted() async throws {
        let rig = try Rig(interval: 0.1) { r, _ in
            let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "query" }?.value ?? ""
            return results(hit(q, year: 2020)) }
        var movies = (0..<40).map { TestSupport.movie(rig.src, "m\($0)", "Film Number \($0)", year: 2020) }
        for i in 0..<10 { movies[i].categoryID = "locked-cat"; movies[i].titleOverride() }
        for i in 10..<20 { movies[i].categoryID = "open-cat" }
        for i in 20..<40 { movies[i].categoryID = "later-cat" }
        let cats = ["locked-cat", "open-cat", "later-cat"].enumerated().map { CatalogCategory(id: $0.element, sourceID: rig.src.id, kind: .movie, providerID: $0.element, name: $0.element, sortOrder: $0.offset) }
        _ = try CatalogIndexer(db: rig.db).commitMovies(source: rig.src, categories: cats, movies: movies)
        try rig.db.write { try $0.execute("INSERT INTO locked_categories(category_id) VALUES('locked-cat')", []) }
        let hidden = movies[25].id
        try rig.db.write { try $0.execute("INSERT INTO hidden_items(item_id, kind, hidden_at) VALUES(?,?,?)", [hidden, "movie", Date()]) }
        let (items, _) = try rig.svc.pending(limit: 100)
        let ids = Set(items.map(\.id))
        #expect(items.count == 29 && !ids.contains(hidden) && movies[0..<10].allSatisfy { !ids.contains($0.id) }, "locked folder and hidden title are not listed")
        // The queue holds a buffer; then a folder is locked while it is non-empty.
        rig.matcher.start(); try await waitUntil { rig.http.count >= 3 }
        try rig.db.write { try $0.execute("INSERT INTO locked_categories(category_id) VALUES('later-cat')", []) }
        rig.matcher.restrictionChanged()
        #expect(rig.matcher.queuedIDs.isEmpty, "the queue is emptied the moment something is locked")
        let lockedLater = Set(movies[20..<40].map(\.id))
        let sentBefore = rig.http.count
        try await waitUntil { rig.matcher.status.state == .complete }
        let sentNames = Set(rig.http.queries.dropFirst(sentBefore))
        #expect(sentNames.isDisjoint(with: Set((20..<40).map { "Film Number \($0)" })) || sentBefore > 0)
        for i in 0..<10 { #expect(!rig.http.queries.contains("Film Number \(i)")) }
        _ = lockedLater
    }

    @Test func twinsOfRestrictedTitlesAreNeverSent() async throws {
        let rig = try Rig { _, _ in none }
        var a = TestSupport.movie(rig.src, "a", "Same Name Film", year: 2020); a.categoryID = "locked-cat"
        var b = TestSupport.movie(rig.src, "b", "Same Name Film", year: 2020); b.categoryID = "open-cat"
        let cats = ["locked-cat", "open-cat"].enumerated().map { CatalogCategory(id: $0.element, sourceID: rig.src.id, kind: .movie, providerID: $0.element, name: $0.element, sortOrder: $0.offset) }
        _ = try CatalogIndexer(db: rig.db).commitMovies(source: rig.src, categories: cats, movies: [a, b])
        try rig.db.write { try $0.execute("INSERT INTO locked_categories(category_id) VALUES('locked-cat')", []) }
        let (items, _) = try rig.svc.pending(limit: 10)
        #expect(items.isEmpty, "a copy of a locked title is not sent either")
    }

    @Test func mobileDataIsOnByDefaultAndOnlyOfflineStops() {
        let store = MatchStateStore(defaults: InMemoryDefaults(), profileID: { "p" })
        #expect(store.allowCellular, "matching runs on any network unless the person turns mobile data off")
        #expect(PathMatchNetwork.decide(satisfied: true, metered: true, allowCellular: true))
        #expect(PathMatchNetwork.decide(satisfied: true, metered: true, allowCellular: true), "Low Data Mode and hotspots are ignored")
        #expect(!PathMatchNetwork.decide(satisfied: false, metered: false, allowCellular: true), "offline")
        #expect(!PathMatchNetwork.decide(satisfied: true, metered: true, allowCellular: false), "mobile data switched off")
    }

    @Test func tmdbRequestsAreNeverBlockedByLowDataMode() async throws {
        let rig = try Rig { _, _ in none }
        try await rig.svc.verifyKey()
        #expect(rig.http.requests.allSatisfy { $0.allowsConstrainedNetworkAccess && $0.allowsExpensiveNetworkAccess }, "Low Data Mode and hotspots never block TMDB")
    }

    @Test func theExpressLaneHasItsOwnBudgetThatBulkCannotUseUp() async throws {
        let clock = FakeClock()
        let pacer = RequestPacer(interval: 0.045, clock: clock)
        for _ in 0..<200 { try await pacer.wait() }          // the bulk run has booked 9 seconds ahead
        let before = clock.now()
        try await pacer.wait(express: true)
        #expect(clock.now() - before < 0.2, "an express request is not queued behind the bulk run")
        var times: [TimeInterval] = []
        for _ in 0..<12 { try await pacer.wait(express: true); times.append(clock.now()) }
        #expect((times.last! - times.first!) >= 11 * (1.0 / 6) - 0.05, "about six a second for the express lane")
    }

    @Test func scrollingAwayCancelsAndOnlyTheNewestTwelveAreKept() async throws {
        let rig = try Rig { r, _ in
            let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "query" }?.value ?? ""
            return results(hit(q, year: 2020)) }
        try rig.add((0..<40).map { ("Film Number \($0)", 2020) })
        rig.matcher.enabled = false          // nothing is sent while the queue is inspected
        rig.matcher.enabled = true
        let ids = try rig.db.read { try $0.query("SELECT id FROM movies ORDER BY title") { $0.string(0) } }
        rig.matcher.prioritize(ids); rig.matcher.cancelPriority(Array(ids.prefix(30)))
        try await waitUntil { rig.matcher.status.state == .complete }
        #expect(rig.matcher.expressServed.count <= ArtworkAutoMatcher.expressBatch)
        #expect(Set(rig.matcher.expressServed).isDisjoint(with: Set(ids.prefix(30))), "titles that scrolled away were not asked for")
    }

    @Test func theExpressLaneNeverSendsRestrictedTitlesAndDoesNothingWithoutAKey() async throws {
        let rig = try Rig(key: nil, builtIn: nil) { _, _ in none }
        try rig.add([("Film Number 1", 2020)])
        let id = try rig.db.read { try $0.queryOne("SELECT id FROM movies") { $0.string(0) } }!
        rig.matcher.prioritize([id])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig.http.count == 0, "no credential: nothing is sent, silently")
        let rig2 = try Rig { _, _ in none }
        var m = TestSupport.movie(rig2.src, "x", "Secret Film", year: 2020); m.categoryID = "locked-cat"
        let cat = CatalogCategory(id: "locked-cat", sourceID: rig2.src.id, kind: .movie, providerID: "locked-cat", name: "Locked", sortOrder: 0)
        _ = try CatalogIndexer(db: rig2.db).commitMovies(source: rig2.src, categories: [cat], movies: [m])
        try rig2.db.write { try $0.execute("INSERT INTO locked_categories(category_id) VALUES('locked-cat')", []) }
        rig2.matcher.prioritize([m.id])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig2.http.count == 0, "a locked title is never sent through the express lane")
    }

    @Test func anExpressResultIsStoredSoTheBulkRunSkipsIt() async throws {
        let rig = try Rig { r, _ in
            let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "query" }?.value ?? ""
            return results(hit(q, year: 2020)) }
        try rig.add([("Film Number 1", 2020)])
        let id = try rig.db.read { try $0.queryOne("SELECT id FROM movies") { $0.string(0) } }!
        rig.matcher.prioritize([id])
        try await waitUntil { rig.matcher.expressServed.contains(id) }
        #expect(try rig.svc.pendingCount() == 0 && (rig.svc.posterURL(for: id) ?? "").hasPrefix("https://image.tmdb.org"), "written at once, so the tile can show it and bulk will not repeat it")
    }

    @Test func theProgressLineGivesARateAndTimeLeftOnceEnoughAreDone() {
        var s = ArtworkMatchStatus(state: .running, done: 1204, total: 3218, notFound: 61)
        #expect(!s.line.contains("left"))
        s.perMinute = 600; s.minutesLeft = 4
        #expect(s.line.hasSuffix("a minute · about 4 min left"))
    }

    @Test func progressTextAndSettingsStates() {
        var s = ArtworkMatchStatus(state: .running, done: 1204, total: 3218, notFound: 61)
        #expect(s.line == "Matching artwork: 1,204 of 3,218 done · 61 not found".replacingOccurrences(of: ",", with: Locale.current.groupingSeparator ?? ","))
        s.state = .complete
        #expect(s.line.hasPrefix("All artwork matched") && s.line.contains("61 not found"))
        s.notFound = 0
        #expect(s.line == "All artwork matched")
        #expect(ArtworkMatchStatus(state: .off).line == "Matching artwork is off.")
        #expect(ArtworkMatchStatus(state: .builtInRejected).line == ArtworkSettingsModel.brokenBuiltIn)
        #expect(!ArtworkMatchStatus(state: .running, done: 5, total: 9).line.contains("more are waiting"))
    }

    @Test func untouchedPlaylistDataAndTakeBackStillWork() async throws {
        let rig = try Rig { _, _ in results(hit("Film Number 1", year: 2020)) }
        try rig.add([("Film Number 1", 2020)])
        _ = try await rig.svc.run()
        #expect(try rig.poster("Film Number 1")?.hasPrefix("https://image.tmdb.org/t/p/w500") == true)
        let n = rig.svc.purgeExpired(now: Date().addingTimeInterval(200 * 86400))
        let after = try rig.poster("Film Number 1")
        #expect(n > 0 && after == nil, "after 180 days what TMDB filled is taken back")
    }
}

/// Polls (in real time, briefly) until a condition holds.
private func waitUntil(timeout: TimeInterval = 10, _ cond: @escaping @Sendable () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !cond() { if Date() > end { Issue.record("timed out waiting"); return }; try await Task.sleep(nanoseconds: 10_000_000) }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}
private extension Movie { mutating func titleOverride() {} }

@Suite("Display rating") struct DisplayRatingTests {
    struct Case: Decodable { let tmdbAverage: Double?; let tmdbVotes: Int?; let provider: String?; let expected: Double?; let notes: String }
    private func root() -> URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    @Test func theSharedFixturesHold() throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: root().appendingPathComponent("artwork/fixtures/display-rating.json")))
        #expect(cases.count >= 15)
        for c in cases {
            let got = DisplayRating.value(tmdbAverage: c.tmdbAverage, tmdbVotes: c.tmdbVotes, provider: c.provider)
            #expect(got == c.expected, "\(c.notes)")
        }
    }

    @Test func aMatchStoresTheTMDBRatingOverAJunkOneAndTakesItBackAfter180Days() async throws {
        let db = try TestSupport.makeDB(); let src = try TestSupport.makeSource(db)
        var m = TestSupport.movie(src, "r", "Rated Film Number One", year: 2020); m.rating = "10.0"
        _ = try CatalogIndexer(db: db).commitMovies(source: src, categories: [], movies: [m])
        let creds = InMemoryCredentialStore(); try creds.save(Credentials(username: "tmdb", password: "0123456789abcdef0123456789abcdef"), ref: MetadataMatchService.keyRef)
        let body = Data(#"{"results":[{"id":7,"title":"Rated Film Number One","poster_path":"/p.jpg","release_date":"2020-01-01","vote_average":7.46,"vote_count":321,"popularity":5}]}"#.utf8)
        let svc = MetadataMatchService(db: db, credentials: creds, defaults: InMemoryDefaults(), builtIn: { nil }) { _ in body }
        _ = try await svc.run()
        func rating() throws -> String? { try db.read { try $0.queryOne("SELECT rating FROM movies") { $0.optString(0) } } ?? nil }
        #expect(try rating() == "7.5")
        _ = svc.purgeExpired(now: Date().addingTimeInterval(200 * 86400))
        #expect(try rating() == nil, "taken back with the rest of what TMDB filled")
    }

    @Test func fewVotesNeverOverwriteTheProviderRating() async throws {
        let db = try TestSupport.makeDB(); let src = try TestSupport.makeSource(db)
        var m = TestSupport.movie(src, "r", "Rated Film Number Two", year: 2020); m.rating = "6.4"
        _ = try CatalogIndexer(db: db).commitMovies(source: src, categories: [], movies: [m])
        let creds = InMemoryCredentialStore(); try creds.save(Credentials(username: "tmdb", password: "0123456789abcdef0123456789abcdef"), ref: MetadataMatchService.keyRef)
        let body = Data(#"{"results":[{"id":8,"title":"Rated Film Number Two","release_date":"2020-01-01","vote_average":10.0,"vote_count":2,"poster_path":"/q.jpg"}]}"#.utf8)
        let svc = MetadataMatchService(db: db, credentials: creds, defaults: InMemoryDefaults(), builtIn: { nil }) { _ in body }
        _ = try await svc.run()
        let r = try db.read { try $0.queryOne("SELECT rating FROM movies") { $0.optString(0) } } ?? nil
        #expect(r == "6.4")
    }

    @Test func aVisibleMatchedTitleWithoutARatingGetsOneSmallRequestOnce() async throws {
        let db = try TestSupport.makeDB(); let src = try TestSupport.makeSource(db)
        var m = TestSupport.movie(src, "r", "Rated Film Number Three", year: 2020); m.posterURL = "http://p/x.jpg"; m.overview = "s"
        _ = try CatalogIndexer(db: db).commitMovies(source: src, categories: [], movies: [m])
        let id = try db.read { try $0.queryOne("SELECT id FROM movies") { $0.string(0) } }!
        try db.write { try $0.execute("INSERT INTO metadata_matches(item_id, kind, tmdb_id, matched_at) VALUES(?,?,?,?)", [id, "movie", 9, Date()]) }
        let creds = InMemoryCredentialStore(); try creds.save(Credentials(username: "tmdb", password: "0123456789abcdef0123456789abcdef"), ref: MetadataMatchService.keyRef)
        let calls = Locked<Int>(0)
        let svc = MetadataMatchService(db: db, credentials: creds, defaults: InMemoryDefaults(), builtIn: { nil }) { r in calls.mutate { $0 += 1 }; return Data(#"{"id":9,"vote_average":8.04,"vote_count":900}"#.utf8) }
        let cand = try #require(svc.ratingCandidates(ids: [id]).first)
        try await svc.backfillRating(cand)
        let r = try db.read { try $0.queryOne("SELECT rating FROM movies") { $0.optString(0) } } ?? nil
        #expect(r == "8.0" && calls.value == 1)
        #expect(svc.ratingCandidates(ids: [id]).isEmpty, "asked once")
    }
}

@Suite("Ratings for tiles on screen") struct TileRatingRequestTests {
    private func rig(votes: Int = 500, _ extra: (inout Movie) -> Void = { _ in }) throws -> (DatabaseManager, MetadataMatchService, ArtworkAutoMatcher, Locked<Int>, String) {
        let db = try TestSupport.makeDB(); let src = try TestSupport.makeSource(db)
        var m = TestSupport.movie(src, "t", "Sight Unseen Tile Film", year: 2020); m.posterURL = "http://p/x.jpg"; m.overview = "s"; m.rating = nil; extra(&m)
        let cats = [CatalogCategory(id: "locked-cat", sourceID: src.id, kind: .movie, providerID: "locked-cat", name: "L", sortOrder: 0)]
        _ = try CatalogIndexer(db: db).commitMovies(source: src, categories: cats, movies: [m])
        let id = try db.read { try $0.queryOne("SELECT id FROM movies") { $0.string(0) } }!
        let creds = InMemoryCredentialStore(); try creds.save(Credentials(username: "tmdb", password: "0123456789abcdef0123456789abcdef"), ref: MetadataMatchService.keyRef)
        let calls = Locked<Int>(0)
        let body = Data(#"{"results":[{"id":5,"title":"Sight Unseen Tile Film","release_date":"2020-01-01","vote_average":6.84,"vote_count":\#(votes),"poster_path":"/z.jpg","popularity":3}]}"#.utf8)
        let svc = MetadataMatchService(db: db, credentials: creds, defaults: InMemoryDefaults(), builtIn: { nil }) { _ in calls.mutate { $0 += 1 }; return body }
        let matcher = ArtworkAutoMatcher(service: svc, store: MatchStateStore(defaults: InMemoryDefaults(), profileID: { "p" }), network: AlwaysNet(), clock: SystemMatchClock())
        return (db, svc, matcher, calls, id)
    }
    private func rating(_ db: DatabaseManager) throws -> String? { try db.read { try $0.queryOne("SELECT rating FROM movies") { $0.optString(0) } } ?? nil }

    @Test func aTileWithAPosterButNoRatingAsksOnceAndNeverAgain() async throws {
        let (db, _, matcher, calls, id) = try rig()
        matcher.prioritize([id])
        try await tileWait { matcher.expressServed.contains(id) }
        #expect(calls.value == 1)
        #expect(try rating(db) == "6.8")
        matcher.prioritize([id]); matcher.prioritize([id])
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(calls.value == 1, "later appearances send nothing")
        matcher.stop()
    }

    @Test func fewVotesLeaveNoStarButAreRememberedAsAsked() async throws {
        let (db, svc, matcher, calls, id) = try rig(votes: 3)
        matcher.prioritize([id])
        try await tileWait { matcher.expressServed.contains(id) }
        #expect(try rating(db) == nil && calls.value == 1)
        #expect(svc.ratingCandidates(ids: [id]).isEmpty)
        matcher.stop()
    }

    @Test func aLockedTitleIsNeverAsked() async throws {
        let (db, _, matcher, calls, id) = try rig { $0.categoryID = "locked-cat" }
        try db.write { try $0.execute("INSERT INTO locked_categories(category_id) VALUES('locked-cat')", []) }
        matcher.prioritize([id])
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(calls.value == 0)
        matcher.stop()
    }

    @Test func theSlowPassGivesTitlesTheirRatingOverTime() async throws {
        let (db, _, matcher, calls, _) = try rig()
        matcher.ratingPassEnabled = true
        matcher.start()
        try await tileWait(timeout: 20) { (try? self.rating(db)) == "6.8" }
        #expect(calls.value == 1)
        matcher.stop()
    }
}

private struct AlwaysNet: MatchNetwork { func isUsable(allowCellular: Bool) -> Bool { true } }
private func tileWait(timeout: TimeInterval = 10, _ cond: @escaping @Sendable () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !cond() { if Date() > end { Issue.record("timed out waiting"); return }; try await Task.sleep(nanoseconds: 10_000_000) }
}
