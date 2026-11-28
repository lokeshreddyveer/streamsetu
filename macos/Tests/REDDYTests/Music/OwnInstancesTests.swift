import Testing
import Foundation
@testable import REDDY

private final class OwnTransport: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []
    private let route: @Sendable (URLRequest) throws -> (Int, String)
    init(_ route: @escaping @Sendable (URLRequest) throws -> (Int, String)) { self.route = route }
    var requestedHosts: [String] { lock.withLock { hosts } }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { hosts.append(request.url?.host ?? "") }
        let (status, body) = try route(request)
        guard let url = request.url, let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { throw MusicError.network("stub") }
        return (Data(body.utf8), resp)
    }
}

private final class OwnClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    var value: Date { get { lock.withLock { t } } set { lock.withLock { t = newValue } } }
    func advance(_ s: TimeInterval) { lock.withLock { t.addTimeInterval(s) } }
}

private let pipedAudio = #"{"audioStreams":[{"url":"https://media.test/a","mimeType":"audio/webm; codecs=\"opus\"","bitrate":128000}]}"#
private let pipedNoAudio = #"{"audioStreams":[]}"#
private let invidiousAudio = #"{"adaptiveFormats":[{"url":"/videoplayback?id=1","type":"audio/webm; codecs=\"opus\"","bitrate":"128000"}]}"#

@Suite struct OwnInstanceValidationTests {
    private func ok(_ s: String, tick: Bool = false) -> String? {
        if case .success(let u) = MusicOwnInstances.validate(s, ownNetwork: tick) { return u.absoluteString }
        return nil
    }
    private func problem(_ s: String, tick: Bool = false) -> MusicOwnInstances.Problem? {
        if case .failure(let p) = MusicOwnInstances.validate(s, ownNetwork: tick) { return p }
        return nil
    }

    @Test func goodAddressesAreCleaned() {
        #expect(ok("https://piped-api.example.org") == "https://piped-api.example.org")
        #expect(ok("  https://piped-api.example.org/  ") == "https://piped-api.example.org")
        #expect(ok("https://example.org:8443/piped/") == "https://example.org:8443/piped")
        #expect(ok("HTTPS://Example.org") == "https://Example.org" || ok("HTTPS://Example.org") == "https://example.org")
    }

    @Test func lanAddressesNeedTheTickAndMayUseHTTP() {
        #expect(problem("http://192.168.1.20:3000") == .needsOwnNetworkTick)
        #expect(ok("http://192.168.1.20:3000", tick: true) == "http://192.168.1.20:3000")
        #expect(ok("http://localhost:3000/", tick: true) == "http://localhost:3000")
        #expect(ok("https://192.168.1.20", tick: true) == "https://192.168.1.20")
        #expect(problem("https://192.168.1.20") == .needsOwnNetworkTick)
    }

    @Test func plainHTTPToTheInternetIsRefused() {
        #expect(problem("http://example.org") == .needsHTTPS)
        #expect(problem("http://example.org", tick: true) == .needsHTTPS)
    }

    @Test func badSchemesCredentialsAndPathsAreRefused() {
        #expect(problem("") == .empty)
        #expect(problem("   ") == .empty)
        #expect(problem("ftp://example.org") == .wrongScheme)
        #expect(problem("file:///etc/passwd") == .wrongScheme)
        #expect(problem("javascript:alert(1)") == .wrongScheme)
        #expect(problem("example.org") != nil)
        #expect(problem("https://") != nil)
        #expect(problem("https://user:pw@example.org") == .credentials)
        #expect(problem("https://user@example.org") == .credentials)
        #expect(problem("https://example.org/a/../b") == .badPath)
        #expect(problem("https://example.org/%2e%2e/b") == .badPath)
        #expect(problem("https://example.org/?x=1") == .badPath)
        #expect(problem("https://example.org/#top") == .badPath)
        #expect(problem("https://exa mple.org") == .notAnAddress)
        #expect(problem("https://example.org:99999") != nil)
    }

    @Test func atMostTwoAddressesPerKindAndDuplicatesCollapse() {
        let s = MusicOwnInstances(piped: ["https://a.example.org", "https://a.example.org/", "https://b.example.org", "https://c.example.org"], invidious: [], ownNetwork: false)
        #expect(s.urls(.piped).map(\.host) == ["a.example.org", "b.example.org"])
        #expect(MusicOwnInstances.split("https://a.org, https://b.org https://c.org").count == 2)
    }

    @Test func savedAndLoadedThroughDefaults() throws {
        let d = try #require(UserDefaults(suiteName: "own-instances-test-\(UUID().uuidString)"))
        MusicOwnInstances(piped: ["https://a.example.org"], invidious: ["http://10.0.0.5:3000"], ownNetwork: true).save(d)
        let back = MusicOwnInstances.load(d)
        #expect(back.piped == ["https://a.example.org"] && back.invidious == ["http://10.0.0.5:3000"] && back.ownNetwork)
        MusicOwnInstances.removeAll(d)
        #expect(MusicOwnInstances.load(d) == MusicOwnInstances())
    }

    @Test func defaultsKeysAreDeviceSettingsAndNeverPortable() {
        for key in [MusicOwnInstances.pipedKey, MusicOwnInstances.invidiousKey, MusicOwnInstances.ownNetworkKey] {
            #expect(MusicDefaultsKeys.deviceSettings.contains(key))
            #expect(!MusicDefaultsKeys.portable.contains(key))
            #expect(!MusicDefaultsKeys.sourceChoices.contains(key) && !MusicDefaultsKeys.activity.contains(key))
            #expect(MusicDefaultsKeys.typedValue(key, "https://a.example.org") == nil)
        }
        let d = UserDefaults(suiteName: "own-instances-snap-\(UUID().uuidString)")
        if let d { MusicOwnInstances(piped: ["https://a.example.org"], invidious: [], ownNetwork: false).save(d); #expect(MusicDefaultsKeys.snapshot(d).isEmpty) }
    }
}

@Suite(.serialized) struct OwnInstanceAllowListTests {
    @Test func onlyTheConfiguredPrivateHostPasses() throws {
        defer { MusicOwnHosts.set([]) }
        let s = MusicOwnInstances(piped: ["http://192.168.1.20:3000"], invidious: [], ownNetwork: true)
        MusicOwnHosts.set(s.allowedPrivateHosts)
        #expect(MusicTransfer.isAllowed(try #require(URL(string: "http://192.168.1.20:3000/videoplayback?x=1"))))
        #expect(MusicTransfer.isAllowed(try #require(URL(string: "http://192.168.1.20:8080/proxy"))))
        #expect(!MusicTransfer.isAllowed(try #require(URL(string: "http://192.168.1.21:3000/videoplayback"))))
        #expect(!MusicTransfer.isAllowed(try #require(URL(string: "http://127.0.0.1:3000/x"))))
        #expect(!MusicTransfer.isAllowed(try #require(URL(string: "http://localhost/x"))))
        #expect(MusicTransfer.isAllowed(try #require(URL(string: "https://rr1.googlevideo.com/videoplayback"))))
    }

    @Test func withoutTheTickNothingPrivateIsAllowed() throws {
        defer { MusicOwnHosts.set([]) }
        let s = MusicOwnInstances(piped: ["http://192.168.1.20:3000"], invidious: [], ownNetwork: false)
        #expect(s.allowedPrivateHosts.isEmpty && s.urls(.piped).isEmpty)
        MusicOwnHosts.set(s.allowedPrivateHosts)
        #expect(!MusicTransfer.isAllowed(try #require(URL(string: "http://192.168.1.20:3000/x"))))
    }

    @Test func aPublicOwnHostAddsNothingToTheList() {
        let s = MusicOwnInstances(piped: ["https://piped-api.example.org"], invidious: [], ownNetwork: true)
        #expect(s.allowedPrivateHosts.isEmpty)
    }
}

@Suite struct OwnInstanceOrderingTests {
    private let t0 = Date(timeIntervalSince1970: 1_900_000_000)
    private func urls(_ hosts: String...) -> [URL] { hosts.compactMap { URL(string: "https://\($0)") } }

    @Test func ownServersAreProbedFirstAndKeptInTheirOwnOrder() async {
        let transport = OwnTransport { req in
            let host = req.url?.host ?? ""
            if req.url?.path.contains("/streams/") == true { return (200, host == "mine2.test" ? pipedAudio : pipedAudio) }
            return (500, "")
        }
        let http = MusicHTTP(transport: transport)
        let tracker = MusicOwnInstanceTracker(http: http, now: { Date() }, urls: { [$0 == .piped ? "mine1.test" : "x", "mine2.test"].compactMap { URL(string: "https://\($0)") } })
        let ready = await tracker.ready(.piped)
        #expect(ready.map(\.host) == ["mine1.test", "mine2.test"])
        #expect(Set(transport.requestedHosts) == ["mine1.test", "mine2.test"])
    }

    @Test func ownServerIsTriedBeforeAnyPublicOne() async throws {
        let transport = OwnTransport { req in
            let host = req.url?.host ?? ""
            if host == "mine.test" { return (200, pipedAudio) }
            if req.url?.path.contains("/streams/") == true { return (200, pipedAudio) }
            return (500, "")
        }
        let http = MusicHTTP(transport: transport)
        let own = MusicOwnInstanceTracker(http: http, urls: { _ in [URL(string: "https://mine.test")].compactMap { $0 } })
        let instances = YouTubeInstances(http: http, own: own)
        let first: String? = try await instances.perform(.piped) { base in base.host }
        #expect(first == "mine.test")
        // The public directories were never contacted because the own server answered.
        #expect(!transport.requestedHosts.contains("piped-instances.kavin.rocks"))
        #expect(await instances.ranked(.piped).first?.host == "mine.test")
    }

    @Test func aSlowButWorkingServerStaysFirst() async {
        let clock = OwnClock(t0)
        var book = MusicOwnBook()
        let a = URL(string: "https://slow.test")!, b = URL(string: "https://fast.test")!
        book.sync([a, b])
        book.recordProbe(a, .working(latencyMs: 5800), now: clock.value)
        book.recordProbe(b, .working(latencyMs: 40), now: clock.value)
        #expect(book.usable(now: clock.value) == [a, b])
    }

    @Test func repeatedHardFailuresSetAServerAsideForFiveMinutes() {
        let clock = OwnClock(t0)
        var book = MusicOwnBook()
        let a = URL(string: "https://mine.test")!, b = URL(string: "https://other.test")!
        book.sync([a, b])
        book.recordFailure(a, now: clock.value)
        book.recordFailure(a, now: clock.value)
        #expect(book.usable(now: clock.value) == [a, b])
        book.recordFailure(a, now: clock.value)
        #expect(book.usable(now: clock.value) == [b])
        clock.advance(MusicOwnBook.retryAfter - 1)
        #expect(book.usable(now: clock.value) == [b])
        clock.advance(2)
        #expect(book.usable(now: clock.value) == [a, b])
        // One more failure after the retry sets it aside again at once.
        book.recordFailure(a, now: clock.value)
        #expect(book.usable(now: clock.value) == [b])
        book.recordSuccess(a, now: clock.value)
        clock.advance(MusicOwnBook.retryAfter + 1)
        #expect(book.usable(now: clock.value) == [a, b])
    }

    @Test func probeResultsAreReusedUntilTheCacheTimeEnds() async {
        let clock = OwnClock(t0)
        let transport = OwnTransport { _ in (200, pipedAudio) }
        let tracker = MusicOwnInstanceTracker(http: MusicHTTP(transport: transport), now: { clock.value }, urls: { _ in [URL(string: "https://mine.test")].compactMap { $0 } })
        _ = await tracker.ready(.piped)
        clock.advance(29 * 60)
        _ = await tracker.ready(.piped)
        #expect(transport.requestedHosts.count == 1)
        clock.advance(2 * 60)
        _ = await tracker.ready(.piped)
        #expect(transport.requestedHosts.count == 2)
    }

    @Test func performFailuresSetTheOwnServerAsideAndFallBack() async throws {
        let clock = OwnClock(t0)
        let transport = OwnTransport { req in
            if req.url?.host == "mine.test" { return (200, pipedAudio) }
            return (500, "")
        }
        let http = MusicHTTP(transport: transport)
        let own = MusicOwnInstanceTracker(http: http, now: { clock.value }, urls: { _ in [URL(string: "https://mine.test")].compactMap { $0 } })
        let instances = YouTubeInstances(http: http, now: { clock.value }, own: own)
        for _ in 0..<3 {
            do { let _: Int = try await instances.perform(.piped) { base in if base.host == "mine.test" { throw MusicError.network("HTTP 500") }; return 1 } } catch {}
        }
        #expect(await own.ready(.piped).isEmpty)
        clock.advance(MusicOwnBook.retryAfter + 1)
        #expect(await own.ready(.piped).map(\.host) == ["mine.test"])
    }
}

@Suite struct OwnInstanceStatusTests {
    private func run(_ kind: YouTubeInstances.Kind, _ route: @escaping @Sendable (URLRequest) throws -> (Int, String)) async -> MusicOwnStatus {
        await MusicOwnProbe.run(kind, base: URL(string: "http://192.168.1.20:3000")!, http: MusicHTTP(transport: OwnTransport(route)))
    }

    @Test func workingReportsLatency() async {
        let s = await run(.piped) { _ in (200, pipedAudio) }
        guard case .working(let ms) = s else { Issue.record("expected working, got \(s)"); return }
        #expect(ms >= 0)
        #expect(s.line.contains("ms"))
        #expect(await run(.invidious) { _ in (200, invidiousAudio) } != .notReachable)
    }

    @Test func connectionFailureIsNotReachable() async {
        #expect(await run(.piped) { _ in throw MusicError.network("The request timed out.") } == .notReachable)
    }

    @Test func answersWithoutAudioMeanBlocked() async {
        #expect(await run(.piped) { _ in (200, pipedNoAudio) } == .blocked)
        #expect(await run(.piped) { _ in (500, "") } == .blocked)
        #expect(await run(.invidious) { _ in (403, "") } == .blocked)
        #expect(await run(.piped) { _ in (200, "not json") } == .blocked)
    }

    @Test func linesAreThePlainSentences() {
        #expect(MusicOwnStatus.working(latencyMs: 120).line == "Working (120 ms)")
        #expect(MusicOwnStatus.notReachable.line == "Not reachable")
        #expect(MusicOwnStatus.blocked.line == "Reached but cannot provide audio (blocked by YouTube?)")
    }

    @Test func providersReportTheStatusPerOwnServer() async {
        let http = MusicHTTP(transport: OwnTransport { req in req.url?.host == "a.test" ? (200, pipedAudio) : (200, pipedNoAudio) })
        let own = MusicOwnInstanceTracker(http: http, urls: { _ in ["a.test", "b.test"].compactMap { URL(string: "https://\($0)") } })
        let p = PipedProvider(http: http, instances: YouTubeInstances(http: http, own: own))
        let list = await p.ownInstanceStatuses()
        #expect(list.map(\.url.host) == ["a.test", "b.test"])
        #expect(list[1].status == .blocked)
        if case .working? = list[0].status {} else { Issue.record("a.test should be working") }
    }
}
