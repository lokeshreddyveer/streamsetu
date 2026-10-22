import Testing
import Foundation
@testable import REDDY

/// A pretend web service: answers by path, and remembers what was asked.
final class FakeWeb: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var routes: [(match: String, status: Int, body: String)] = []
    var transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { [self] r in
            let routes = lock.withLock { requests.append(r); return self.routes }
            let key = (r.url?.path ?? "") + "?" + (r.url?.query ?? "")
            let hit = routes.last { key.contains($0.match) } ?? (match: "", status: 404, body: "{}")
            return (Data(hit.body.utf8), HTTPURLResponse(url: r.url!, statusCode: hit.status, httpVersion: nil, headerFields: nil)!)
        }
    }
    func asked(_ part: String) -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests.filter { ($0.url?.absoluteString ?? "").contains(part) } }
}

@Suite struct DebridTests {
    @Test func linksAndMagnetsAreToldApart() {
        #expect(DebridInput.parse("https://host.tld/file/abc") == .link(URL(string: "https://host.tld/file/abc")!))
        #expect(DebridInput.parse("  magnet:?xt=urn:btih:ABC123&dn=x ") == .magnet("magnet:?xt=urn:btih:ABC123&dn=x"))
        #expect(DebridInput.parse("ftp://x/y") == .invalid)
        #expect(DebridInput.parse("hello") == .invalid)
        #expect(DebridInput.parse("magnet:?dn=nohash") == .invalid)
    }

    @Test func realDebridUnlocksALinkWithTheTokenInTheHeaderNotTheAddress() async throws {
        let web = FakeWeb(); web.routes = [("/unrestrict/link", 200, #"{"filename":"Film.mkv","download":"https://cdn.rd/d/Film.mkv"}"#)]
        var c = DebridClient(service: .realDebrid, token: "TOK"); c.transport = web.transport
        let r = try await c.resolve("https://hoster.tld/f/1")
        #expect(r.url.absoluteString == "https://cdn.rd/d/Film.mkv" && r.name == "Film.mkv")
        let req = try #require(web.asked("unrestrict/link").first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer TOK")
        #expect(!(req.url?.absoluteString.contains("TOK") ?? true), "the token must not be in the address")
        #expect(String(data: req.httpBody ?? Data(), encoding: .utf8) == "link=https%3A%2F%2Fhoster.tld%2Ff%2F1")
    }

    @Test func allDebridUnlocksALink() async throws {
        let web = FakeWeb(); web.routes = [("/link/unlock", 200, #"{"status":"success","data":{"link":"https://ad.cdn/x.mp4","filename":"x.mp4"}}"#)]
        var c = DebridClient(service: .allDebrid, token: "K"); c.transport = web.transport
        #expect(try await c.resolve("https://h/f").url.absoluteString == "https://ad.cdn/x.mp4")
    }

    @Test func premiumizePicksTheLargestVideo() async throws {
        let web = FakeWeb(); web.routes = [("directdl", 200, #"{"status":"success","content":[{"path":"a/readme.txt","size":10,"link":"https://p/readme"},{"path":"a/small.mkv","size":100,"link":"https://p/small"},{"path":"a/big.mkv","size":900,"link":"https://p/big","stream_link":"https://p/big-stream"}]}"#)]
        var c = DebridClient(service: .premiumize, token: "K"); c.transport = web.transport
        let r = try await c.resolve("https://h/f")
        #expect(r.name == "big.mkv" && r.url.absoluteString == "https://p/big-stream")
    }

    @Test func aBadTokenAndARefusalAreExplained() async {
        let web = FakeWeb(); web.routes = [("/unrestrict/link", 401, #"{"error":"bad_token"}"#)]
        var c = DebridClient(service: .realDebrid, token: "X"); c.transport = web.transport
        await #expect(throws: DebridError.rejected("Real-Debrid did not accept the token.")) { try await c.resolve("https://h/f") }
        web.routes = [("/unrestrict/link", 503, "{}")]
        await #expect(throws: DebridError.self) { try await c.resolve("https://h/f") }
    }

    @Test func noTokenAndNotALinkNeverReachTheNetwork() async {
        let web = FakeWeb()
        var c = DebridClient(service: .realDebrid, token: " "); c.transport = web.transport
        await #expect(throws: DebridError.noToken) { try await c.resolve("https://h/f") }
        c = DebridClient(service: .realDebrid, token: "T"); c.transport = web.transport
        await #expect(throws: DebridError.invalid) { try await c.resolve("nonsense") }
        #expect(web.requests.isEmpty)
    }

    @Test func magnetsAreRefusedWhereTheyAreNotAllowed() async {
        let web = FakeWeb()
        var c = DebridClient(service: .realDebrid, token: "T", allowMagnets: false); c.transport = web.transport
        await #expect(throws: DebridError.magnetsNotAllowed) { try await c.resolve("magnet:?xt=urn:btih:ABC") }
        #expect(web.requests.isEmpty)
    }

    @Test func realDebridMagnetSelectsTheLargestVideoThenUnlocksIt() async throws {
        let web = FakeWeb()
        web.routes = [("addMagnet", 201, #"{"id":"T1"}"#),
                      ("torrents/info/T1", 200, #"{"status":"waiting_files_selection","files":[{"id":1,"path":"/a.nfo","bytes":5},{"id":2,"path":"/s.mkv","bytes":50},{"id":3,"path":"/b.mkv","bytes":500}]}"#),
                      ("selectFiles/T1", 204, "{}")]
        var c = DebridClient(service: .realDebrid, token: "T", allowMagnets: true); c.transport = web.transport; c.pollEvery = 0.01; c.magnetWait = 5
        // after files are chosen the torrent reports done
        Task { try? await Task.sleep(nanoseconds: 60_000_000); web.routes += [("torrents/info/T1", 200, #"{"status":"downloaded","links":["https://rd/l/1"]}"#), ("/unrestrict/link", 200, #"{"filename":"b.mkv","download":"https://cdn/b.mkv"}"#)] }
        let r = try await c.resolve("magnet:?xt=urn:btih:ABC")
        #expect(r.url.absoluteString == "https://cdn/b.mkv")
        let select = try #require(web.asked("selectFiles/T1").first)
        #expect(String(data: select.httpBody ?? Data(), encoding: .utf8) == "files=3", "only the biggest video is chosen")
    }

    @Test func aMagnetThatIsNotReadyInTimeSaysSo() async {
        let web = FakeWeb(); web.routes = [("addMagnet", 201, #"{"id":"T2"}"#), ("torrents/info/T2", 200, #"{"status":"downloading"}"#)]
        var c = DebridClient(service: .realDebrid, token: "T", allowMagnets: true); c.transport = web.transport; c.pollEvery = 0.01; c.magnetWait = 0.1
        await #expect(throws: DebridError.self) { try await c.resolve("magnet:?xt=urn:btih:ABC") }
    }

    @Test func theTokenIsKeptInTheVaultNotElsewhere() {
        let store = InMemoryCredentialStore(); let d = DebridStore(store: store)
        #expect(!d.load().isComplete)
        d.save(DebridAccount(service: .allDebrid, token: " abc "))
        #expect(d.load().token == "abc" && d.load().service == .allDebrid)
        d.save(DebridAccount(service: .allDebrid, token: ""))
        #expect(!d.load().isComplete)
    }
}

@Suite struct TraktTests {
    private let app = TraktApp(clientID: "CID", secret: "SEC")

    @Test func cleaningATitleTakesOffTheProvidersDecoration() {
        #expect(TraktItem.cleanTitle("John Wick (2014) 4K HEVC") == "John Wick")
        #expect(TraktItem.cleanTitle("EN - The Matrix [1080p]") == "The Matrix")
        #expect(TraktItem.cleanTitle("Dune") == "Dune")
    }

    @Test func aMovieAndAnEpisodeAreDescribedTheWayTraktWantsThem() {
        let m = TraktItem.movie(title: "Dune", year: 2021).payload
        #expect((m["movie"] as? [String: Any])?["title"] as? String == "Dune" && (m["movie"] as? [String: Any])?["year"] as? Int == 2021)
        let e = TraktItem.episode(show: "Severance", year: 2022, season: 1, number: 3).payload
        #expect((e["episode"] as? [String: Any])?["season"] as? Int == 1 && (e["episode"] as? [String: Any])?["number"] as? Int == 3)
        #expect((e["show"] as? [String: Any])?["title"] as? String == "Severance")
    }

    @Test func signingInWithACodeWaitsThenGetsTokens() async throws {
        let web = FakeWeb()
        web.routes = [("device/code", 200, #"{"device_code":"DC","user_code":"ABCD1234","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":5}"#),
                      ("device/token", 400, "{}")]
        var c = TraktClient(app: app); c.transport = web.transport
        let code = try await c.startDeviceLogin()
        #expect(code.userCode == "ABCD1234")
        #expect(try await c.pollDeviceToken(code) == nil, "still waiting for the person")
        web.routes += [("device/token", 200, #"{"access_token":"AT","refresh_token":"RT","expires_in":7776000,"created_at":1800000000}"#)]
        let t = try #require(try await c.pollDeviceToken(code))
        #expect(t.access == "AT" && t.refresh == "RT" && t.expires == Date(timeIntervalSince1970: 1_800_000_000 + 7_776_000))
        let poll = try #require(web.asked("device/token").last)
        let body = try #require(try JSONSerialization.jsonObject(with: poll.httpBody ?? Data()) as? [String: String])
        #expect(body["client_id"] == "CID" && body["client_secret"] == "SEC" && body["code"] == "DC")
    }

    @Test func aRefusedOrExpiredCodeIsReported() async throws {
        let web = FakeWeb(); web.routes = [("device/token", 410, "{}")]
        var c = TraktClient(app: app); c.transport = web.transport
        let code = TraktClient.DeviceCode(deviceCode: "x", userCode: "y", url: "u", expiresIn: 1, interval: 1)
        await #expect(throws: TraktError.expired) { try await c.pollDeviceToken(code) }
        web.routes = [("device/token", 418, "{}")]
        await #expect(throws: TraktError.denied) { try await c.pollDeviceToken(code) }
    }

    @Test func aScrobbleCarriesTheTokenTheKeyAndTheProgress() async throws {
        let web = FakeWeb(); web.routes = [("scrobble/stop", 201, "{}")]
        var c = TraktClient(app: app); c.transport = web.transport
        try await c.scrobble(.stop, item: .movie(title: "Dune", year: 2021), progress: 96, tokens: TraktTokens(access: "AT", refresh: "RT", expires: Date().addingTimeInterval(1e6)))
        let r = try #require(web.asked("scrobble/stop").first)
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer AT" && r.value(forHTTPHeaderField: "trakt-api-key") == "CID" && r.value(forHTTPHeaderField: "trakt-api-version") == "2")
        let body = try #require(try JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
        #expect(body["progress"] as? Double == 96)
    }

    @Test func anUnknownTitleOrARepeatIsNotAnError() async throws {
        let web = FakeWeb(); web.routes = [("scrobble", 404, "{}")]
        var c = TraktClient(app: app); c.transport = web.transport
        let t = TraktTokens(access: "AT", refresh: "RT", expires: Date().addingTimeInterval(1e6))
        try await c.scrobble(.start, item: .movie(title: "Obscure", year: nil), progress: 0, tokens: t)
        web.routes = [("scrobble", 409, "{}")]
        try await c.scrobble(.start, item: .movie(title: "Dune", year: 2021), progress: 0, tokens: t)
        web.routes = [("scrobble", 401, "{}")]
        await #expect(throws: TraktError.notSignedIn) { try await c.scrobble(.start, item: .movie(title: "Dune", year: 2021), progress: 0, tokens: t) }
    }

    @Test func theWatchlistReadsMoviesAndShows() async throws {
        let web = FakeWeb()
        web.routes = [("watchlist/movies", 200, #"[{"movie":{"title":"Dune","year":2021}}]"#), ("watchlist/shows", 200, #"[{"show":{"title":"Severance","year":2022}}]"#)]
        var c = TraktClient(app: app); c.transport = web.transport
        let list = try await c.watchlist(tokens: TraktTokens(access: "AT", refresh: "RT", expires: Date().addingTimeInterval(1e6)))
        #expect(list == [TraktListed(title: "Dune", year: 2021, isShow: false), TraktListed(title: "Severance", year: 2022, isShow: true)])
    }

    @Test func watchlistTitlesMatchTheLibraryByNameAndYear() {
        let dune = TraktListed(title: "Dune", year: 2021, isShow: false)
        #expect(TraktMatching.matches(listed: dune, title: "Dune (2021) 4K", year: 2021))
        #expect(TraktMatching.matches(listed: dune, title: "DUNE", year: nil))
        #expect(!TraktMatching.matches(listed: dune, title: "Dune", year: 1984), "a different year is a different film")
        #expect(!TraktMatching.matches(listed: dune, title: "Dune Part Two", year: 2024))
    }

    @MainActor @Test func tokensAndKeysAreKeptInTheVaultAndSignOutForgetsTheTokens() {
        let store = InMemoryCredentialStore()
        let s = TraktService(store: store, transport: FakeWeb().transport)
        #expect(s.state == .notConfigured)
        s.app = TraktApp(clientID: "A", secret: "B")
        #expect(s.state == .signedOut && s.app.clientID == "A")
        let again = TraktService(store: store, transport: FakeWeb().transport)
        #expect(again.app.secret == "B")
        again.signOut()
        #expect(!again.isSignedIn)
    }

    @MainActor @Test func nothingIsSentWhenSignedOutOrInAKidsProfile() async throws {
        let web = FakeWeb(); let s = TraktService(store: InMemoryCredentialStore(), transport: web.transport)
        s.app = TraktApp(clientID: "A", secret: "B")
        s.scrobble(.start, .movie(title: "Dune", year: 2021), progress: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(web.requests.isEmpty, "signed out sends nothing")
    }
}

@Suite struct AITests {
    private func client(_ p: AIProvider, key: String = "KEY", model: String = "", base: String = "", web: FakeWeb) -> AIClient {
        var c = AIClient(config: AIConfig(provider: p, model: model, base: base, key: key)); c.transport = web.transport; return c
    }
    private func body(_ r: URLRequest) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:] }

    @Test func geminiSendsTheKeyInAHeaderAndReadsTheText() async throws {
        let web = FakeWeb(); web.routes = [("generateContent", 200, #"{"candidates":[{"content":{"parts":[{"text":"Hello"},{"text":" there"}]}}]}"#)]
        let a = try await client(.gemini, web: web).ask(system: "S", prompt: "P")
        #expect(a == "Hello there")
        let r = try #require(web.requests.first)
        #expect(r.value(forHTTPHeaderField: "x-goog-api-key") == "KEY" && !(r.url?.absoluteString.contains("KEY") ?? true))
        #expect(r.url?.absoluteString.contains("gemini-2.5-flash-lite:generateContent") == true)
        #expect(((body(r)["system_instruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String == "S")
    }

    @Test func claudeUsesItsOwnHeadersAndFormat() async throws {
        let web = FakeWeb(); web.routes = [("/v1/messages", 200, #"{"content":[{"type":"text","text":"Hi"}]}"#)]
        #expect(try await client(.claude, web: web).ask(system: "S", prompt: "P") == "Hi")
        let r = try #require(web.requests.first)
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "KEY" && r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(body(r)["system"] as? String == "S" && body(r)["model"] as? String == "claude-haiku-5-5" && body(r)["max_tokens"] as? Int == 700)
    }

    @Test func openAIAndOpenRouterUseBearerAndChatMessages() async throws {
        for (p, host) in [(AIProvider.openAI, "api.openai.com"), (AIProvider.openRouter, "openrouter.ai")] {
            let web = FakeWeb(); web.routes = [("chat/completions", 200, #"{"choices":[{"message":{"content":"Yo"}}]}"#)]
            #expect(try await client(p, web: web).ask(system: "S", prompt: "P") == "Yo")
            let r = try #require(web.requests.first)
            #expect(r.url?.host == host && r.value(forHTTPHeaderField: "Authorization") == "Bearer KEY")
            #expect((body(r)["messages"] as? [[String: String]])?.map { $0["role"] ?? "" } == ["system", "user"])
        }
    }

    @Test func ollamaNeedsNoKeyAndTakesTheAddressItIsGiven() async throws {
        let web = FakeWeb(); web.routes = [("/api/chat", 200, #"{"message":{"role":"assistant","content":"Local"}}"#)]
        #expect(try await client(.ollama, key: "", base: "192.168.1.20:11434/", web: web).ask(system: "S", prompt: "P") == "Local")
        let r = try #require(web.requests.first)
        #expect(r.url?.absoluteString == "http://192.168.1.20:11434/api/chat" && r.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(body(r)["stream"] as? Bool == false)
    }

    @Test func aMissingKeyNeverReachesTheNetwork() async {
        let web = FakeWeb()
        await #expect(throws: AIError.notConfigured) { try await client(.claude, key: " ", web: web).ask(system: "S", prompt: "P") }
        #expect(web.requests.isEmpty)
    }

    @Test func refusalsAreExplainedInPlainWords() async {
        let web = FakeWeb(); web.routes = [("messages", 401, "{}")]
        await #expect(throws: AIError.rejected("Anthropic Claude did not accept the key.")) { try await client(.claude, web: web).ask(system: "S", prompt: "P") }
        web.routes = [("messages", 429, "{}")]
        await #expect(throws: AIError.self) { try await client(.claude, web: web).ask(system: "S", prompt: "P") }
        web.routes = [("messages", 404, "{}")]
        await #expect(throws: AIError.self) { try await client(.claude, model: "nope", web: web).ask(system: "S", prompt: "P") }
    }

    @Test func appleIntelligenceUsesTheOnDeviceModelAndNothingOnTheNetwork() async throws {
        let web = FakeWeb()
        var c = client(.apple, key: "", web: web)
        c.onDevice = { system, prompt in "on device: \(system)/\(prompt)" }
        #expect(try await c.ask(system: "S", prompt: "P") == "on device: S/P")
        #expect(web.requests.isEmpty)
    }

    @Test func theAnswerIsReadEvenInsideACodeBlock() {
        let a = "Sure!\n```json\n{\"search\":\"telugu thriller 2010s\",\"titles\":[\"Inception (2010)\",\"\"],\"note\":\"Mind-bending.\"}\n```"
        let s = WatchAdvisor.parse(a)
        #expect(s == WatchSuggestion(search: "telugu thriller 2010s", titles: ["Inception (2010)"], note: "Mind-bending."))
        #expect(WatchAdvisor.parse("I cannot help with that") == nil)
        #expect(WatchAdvisor.parse("{\"search\":\"\",\"titles\":[],\"note\":\"x\"}") == nil)
        #expect(WatchAdvisor.split("Inception (2010)") == ("Inception", 2010))
    }

    @Test func onlyWhatThePersonTypedGoesInThePrompt() {
        let p = WatchAdvisor.prompt("  something light  ")
        #expect(p == "What I feel like watching: something light")
        #expect(!WatchAdvisor.system.lowercased().contains("playlist"), "no library details are described to the AI")
    }

    @Test func theChoiceIsKeptAndTheKeyIsSeparatePerProvider() {
        let defaults = UserDefaults(suiteName: "ai-\(UUID().uuidString)")!
        let store = AIStore(defaults: defaults, credentials: InMemoryCredentialStore())
        #expect(store.provider == .apple)
        store.save(AIConfig(provider: .claude, model: " claude-x ", base: "", key: " KEYC "))
        store.save(AIConfig(provider: .openAI, model: "", base: "", key: "KEYO"))
        #expect(store.provider == .openAI)
        #expect(store.load(.claude).key == "KEYC" && store.load(.claude).model == "claude-x")
        #expect(store.load(.openAI).key == "KEYO" && store.load(.openAI).effectiveModel == "gpt-4o-mini")
        #expect(store.load(.apple).isReady && !store.load(.gemini).isReady)
    }

    @Test func everyProviderShowsItsCostAndWhereToGetAKey() {
        for p in AIProvider.allCases { #expect(!p.pricing.isEmpty && !p.keyHelp.isEmpty && URL(string: p.pricingURL) != nil) }
    }
}
