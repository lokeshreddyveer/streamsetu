import Testing
import Foundation
@testable import REDDY

// One-click Last.fm sign-in. Canned replies, a fake sleep and a fake browser: no network, no real clock, no built-in key.

private final class AuthStub: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private let handler: @Sendable (URLRequest, Int) -> (Int, String)
    init(_ handler: @escaping @Sendable (URLRequest, Int) -> (Int, String)) { self.handler = handler }
    var requests: [URLRequest] { lock.withLock { seen } }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let n = lock.withLock { seen.append(request); return seen.count }
        let (code, body) = handler(request, n)
        if code == 0 { throw URLError(.notConnectedToInternet) }
        guard let url = request.url, let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil) else { throw MusicError.network("stub") }
        return (Data(body.utf8), resp)
    }
}

private final class AuthStore: ScrobbleSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    init(_ initial: [String: String] = [:]) { values = initial }
    func read(_ account: String) -> String? { lock.withLock { values[account] } }
    func write(_ value: String, account: String) { lock.withLock { values[account] = value } }
    func remove(_ account: String) { lock.withLock { values[account] = nil } }
}

private final class FakeBrowser: LastFMBrowserOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var opened: [URL] { lock.withLock { urls } }
    @MainActor func open(_ url: URL) -> Bool { lock.withLock { urls.append(url) }; return true }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var total: TimeInterval = 0
    private var cancelAt: Int?
    private var calls = 0
    var elapsed: TimeInterval { lock.withLock { total } }
    init(cancelAfter: Int? = nil) { cancelAt = cancelAfter }
    func sleep(_ s: TimeInterval) async throws {
        let stop = lock.withLock { () -> Bool in total += s; calls += 1; return calls == cancelAt }
        if stop { throw CancellationError() }
    }
}

private let tokenReply = #"{"token":"TOK123"}"#
private let notYet = #"{"error":14,"message":"Unauthorized Token - This token has not been authorized"}"#
private let sessionReply = #"{"session":{"name":"someone","key":"SESSIONKEY","subscriber":0}}"#
private let fixtureKeys: LastFMKeys.Pair = (key: "fixturekey", secret: "fixturesecret")

private func auth(_ stub: AuthStub, store: AuthStore, clock: FakeClock, browser: FakeBrowser = FakeBrowser(), builtIn: Bool = true) -> LastFMAuth {
    LastFMAuth(http: MusicHTTP(transport: stub), store: store, keys: { fixtureKeys }, usesBuiltInApp: builtIn, opener: browser,
               sleep: { try await clock.sleep($0) })
}

private func query(_ r: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

@Suite struct LastFMAuthTests {
    @Test func signatureMatchesTheDocumentedConstruction() {
        // Parameters sorted by name, name+value concatenated, secret appended, MD5; format and callback are left out.
        let sig = LastFMProvider.signature(["method": "auth.getSession", "api_key": "xxxxxxxx", "token": "yyyyyy", "format": "json"], secret: "mysecret")
        #expect(sig == MusicHash.md5("api_keyxxxxxxxxmethodauth.getSessiontokenyyyyyymysecret"))
        #expect(sig.count == 32)
    }

    @Test func getTokenRequestIsSignedJSONAndHidesTheSecret() async throws {
        let stub = AuthStub { _, n in n == 1 ? (200, tokenReply) : (200, sessionReply) }
        let browser = FakeBrowser()
        _ = try await auth(stub, store: AuthStore(), clock: FakeClock(), browser: browser).connect()
        let first = stub.requests[0], q = query(first)
        #expect(first.httpMethod == "GET" && first.url?.host == "ws.audioscrobbler.com")
        #expect(q["method"] == "auth.getToken" && q["api_key"] == "fixturekey" && q["format"] == "json")
        #expect(q["api_sig"] == MusicHash.md5("api_keyfixturekeymethodauth.getTokenfixturesecret"))
        #expect(first.url?.absoluteString.contains("fixturesecret") == false)
        let url = await browser.opened.first
        #expect(url?.absoluteString == "https://www.last.fm/api/auth/?api_key=fixturekey&token=TOK123")
    }

    @Test func pollsUntilApprovedThenStoresOnlyTheSession() async throws {
        let stub = AuthStub { r, n in
            if n == 1 { return (200, tokenReply) }
            return n <= 4 ? (403, notYet) : (200, sessionReply)
        }
        let store = AuthStore(), clock = FakeClock()
        let name = try await auth(stub, store: store, clock: clock).connect()
        #expect(name == "someone")
        #expect(stub.requests.count == 5)                       // token, three "not yet", then the session
        #expect(clock.elapsed == 8)                             // four polls, two seconds apart
        let q = query(stub.requests[4])
        #expect(q["method"] == "auth.getSession" && q["token"] == "TOK123")
        let stored = try #require(store.read(LastFMProvider.credentialsAccount))
        #expect(!stored.contains("fixturekey") && !stored.contains("fixturesecret"))
        let c = try JSONDecoder().decode(LastFMProvider.Credentials.self, from: Data(stored.utf8))
        #expect(c.sessionKey == "SESSIONKEY" && c.usesBuiltInApp && c.username == "someone")
        #expect(store.read(LastFMClient.usernameAccount) == "someone")
    }

    @Test func networkErrorsDuringPollingAreRetried() async throws {
        let stub = AuthStub { _, n in n == 1 ? (200, tokenReply) : (n == 2 || n == 3 ? (0, "") : (200, sessionReply)) }
        #expect(try await auth(stub, store: AuthStore(), clock: FakeClock()).connect() == "someone")
    }

    @Test func neverApprovedTimesOutAfterThreeMinutes() async {
        let stub = AuthStub { _, n in n == 1 ? (200, tokenReply) : (403, notYet) }
        let clock = FakeClock(), store = AuthStore()
        await #expect(throws: LastFMAuthError.timedOut) { try await auth(stub, store: store, clock: clock).connect() }
        #expect(clock.elapsed == 180)
        #expect(store.read(LastFMProvider.credentialsAccount) == nil)
    }

    @Test func cancellingStopsPollingAndStoresNothing() async {
        let stub = AuthStub { _, n in n == 1 ? (200, tokenReply) : (403, notYet) }
        let store = AuthStore()
        await #expect(throws: LastFMAuthError.cancelled) { try await auth(stub, store: store, clock: FakeClock(cancelAfter: 3)).connect() }
        #expect(stub.requests.count == 3)
        #expect(store.read(LastFMProvider.credentialsAccount) == nil)
    }

    @Test func errorsMapToPlainMessages() async {
        for (code, text) in [(15, "expired"), (4, "expired"), (10, "key"), (26, "suspended")] {
            let stub = AuthStub { _, n in n == 1 ? (200, tokenReply) : (403, #"{"error":\#(code),"message":"x"}"#) }
            do { _ = try await auth(stub, store: AuthStore(), clock: FakeClock()).connect(); Issue.record("expected a failure") }
            catch let e as LastFMAuthError { #expect(e.message.contains(text), "code \(code): \(e.message)"); #expect(stub.requests.count == 2) }
            catch { Issue.record("wrong error") }
        }
        let bad = AuthStub { _, _ in (200, #"{"error":10,"message":"Invalid API key"}"#) }
        await #expect(throws: LastFMAuthError.failed("Last.fm did not accept this app's key.")) { try await auth(bad, store: AuthStore(), clock: FakeClock()).connect() }
        let down = AuthStub { _, _ in (0, "") }
        await #expect(throws: LastFMAuthError.failed("Could not reach Last.fm.")) { try await auth(down, store: AuthStore(), clock: FakeClock()).connect() }
    }

    @Test func oldCredentialsStillDecode() throws {
        let old = #"{"apiKey":"k","secret":"s","sessionKey":"sk"}"#
        let c = try JSONDecoder().decode(LastFMProvider.Credentials.self, from: Data(old.utf8))
        #expect(c == LastFMProvider.Credentials(apiKey: "k", secret: "s", sessionKey: "sk"))
        #expect(c.usesBuiltInApp == false && c.username == "")
        let round = try JSONDecoder().decode(LastFMProvider.Credentials.self, from: JSONEncoder().encode(LastFMProvider.Credentials(apiKey: "", secret: "", sessionKey: "z", username: "u", usesBuiltInApp: true)))
        #expect(round.usesBuiltInApp && round.username == "u")
    }

    @Test func keysAreResolvedAtRequestTime() {
        let own = LastFMProvider.Credentials(apiKey: "ownk", secret: "owns", sessionKey: "sk")
        let marked = LastFMProvider.Credentials(apiKey: "", secret: "", sessionKey: "sk", usesBuiltInApp: true)
        let built: () -> LastFMKeys.Pair? = { ("bk", "bs") }
        #expect(own.resolvedKeys(builtIn: built)?.key == "ownk")           // the person's own key wins and is untouched
        #expect(marked.resolvedKeys(builtIn: built)?.secret == "bs")       // the marker pulls the built-in application
        #expect(marked.resolvedKeys(builtIn: { nil }) == nil)              // marker but no built-in key: not connected
        #expect(LastFMProvider.Credentials(apiKey: "", secret: "", sessionKey: "sk").resolvedKeys(builtIn: built) == nil)
    }

    @Test func currentKeysPreferTheOwnKeyThenBuiltIn() {
        let built: () -> LastFMKeys.Pair? = { ("bk", "bs") }
        #expect(LastFMKeys.current(store: AuthStore(), builtIn: built)?.apiKey == "bk")
        #expect(LastFMKeys.current(store: AuthStore(), builtIn: { nil }) == nil)
        let own = AuthStore([LastFMClient.appKeyAccount: "ownk", LastFMClient.appSecretAccount: "owns"])
        let k = LastFMKeys.current(store: own, builtIn: built)
        #expect(k?.apiKey == "ownk" && k?.secret == "owns")
        // A built-in sign-in holds no key of its own, so it does not hide the built-in application.
        let marked = AuthStore([LastFMProvider.credentialsAccount: #"{"apiKey":"","secret":"","sessionKey":"s","usesBuiltInApp":true}"#])
        #expect(LastFMKeys.current(store: marked, builtIn: built)?.apiKey == "bk")
    }

    @Test func signOutClearsTheSession() async throws {
        let store = AuthStore()
        _ = try await auth(AuthStub { _, n in n == 1 ? (200, tokenReply) : (200, sessionReply) }, store: store, clock: FakeClock()).connect()
        let provider = LastFMProvider(http: MusicHTTP(), store: store)
        await provider.signOut()
        #expect(store.read(LastFMProvider.credentialsAccount) == nil)
        #expect(await provider.isSignedIn == false)
    }
}
