import Testing
import Foundation
@testable import REDDY

@Suite("App DNS") struct AppDNSTests {
    @Test func offByDefaultWithCloudflareRemembered() {
        let c = AppDNSConfiguration()
        #expect(!c.enabled && c.provider == .cloudflare && c.localUsesSystem)
        #expect(c.resolver == nil, "the provider is remembered but inactive until App DNS is on")
        var on = c; on.enabled = true
        #expect(on.resolver?.name == "Cloudflare" && on.resolver?.url.absoluteString == "https://cloudflare-dns.com/dns-query")
    }

    @Test func everyBuiltInProviderIsHTTPSWithBootstrapAddresses() throws {
        for p in AppDNSProvider.allCases where p != .custom {
            let b = try #require(p.builtIn)
            #expect(b.url.scheme == "https" && !b.bootstrap.isEmpty && b.bootstrap.allSatisfy(AppDNSValidator.isIPAddress), "\(p)")
        }
        #expect(AppDNSProvider.custom.builtIn == nil)
    }

    @Test func customAddressesAreValidated() {
        func problem(_ s: String) -> AppDNSValidator.Problem? { if case .failure(let p) = AppDNSValidator.validate(s) { p } else { nil } }
        #expect(problem("") == .empty)
        #expect(problem("http://dns.example/dns-query") == .notHTTPS)
        #expect(problem("dns.example/dns-query") == .notHTTPS)
        #expect(problem("https://user:pw@dns.example/dns-query") == .hasCredentials)
        #expect(problem("https://dns.example/dns-query#x") == .hasFragment)
        #expect(problem("https://dns.example/dns-query") == nil)
        var c = AppDNSConfiguration(); c.enabled = true; c.provider = .custom; c.customURL = "http://dns.example/q"
        #expect(c.resolver == nil, "an invalid custom address never becomes a resolver")
        c.customURL = " https://dns.example/dns-query "; c.customBootstrap = ["9.9.9.9", "not-an-ip"]
        #expect(c.resolver?.bootstrap == ["9.9.9.9"] && c.resolver?.name == "Custom DNS")
    }

    @Test func localNamesAreOnlyLocalNames() {
        for h in ["nas", "plex.local", "NAS.LOCAL.", "router.lan", "192.168.1.20", "10.0.0.5", "172.16.3.1", "169.254.1.1", "127.0.0.1", "fd00::1", "fe80::1", "[::1]", "localhost"] { #expect(AppDNSLocality.isLocalName(h), "\(h)") }
        for h in ["example.com", "cdn.provider.tv", "8.8.8.8", "172.32.0.1", "2606:4700:4700::1111", "local.example.com"] { #expect(!AppDNSLocality.isLocalName(h), "\(h)") }
    }

    @Test func aPublicNameCannotResolveToAPrivateAddress() {
        #expect(!AppDNSLocality.acceptsAnswer(for: "cdn.provider.tv", address: "192.168.1.1", sourceIsLocal: false), "DNS rebinding")
        #expect(!AppDNSLocality.acceptsAnswer(for: "cdn.provider.tv", address: "127.0.0.1", sourceIsLocal: false))
        #expect(AppDNSLocality.acceptsAnswer(for: "cdn.provider.tv", address: "203.0.113.5", sourceIsLocal: false))
        #expect(AppDNSLocality.acceptsAnswer(for: "cdn.provider.tv", address: "192.168.1.1", sourceIsLocal: true), "a source marked local may")
        #expect(AppDNSLocality.acceptsAnswer(for: "nas.local", address: "192.168.1.9", sourceIsLocal: false))
    }

    @Test func dnsMessagesRoundTrip() throws {
        let q = try #require(DNSWire.query("example.com", type: .a))
        #expect([UInt8](q) == [0,0,1,0,0,1,0,0,0,0,0,0, 7,101,120,97,109,112,108,101, 3,99,111,109, 0, 0,1,0,1])
        #expect(DNSWire.query("a..b", type: .a) != nil, "empty labels are skipped")
        #expect(DNSWire.query(String(repeating: "a", count: 64) + ".com", type: .a) == nil, "a label over 63 bytes")
        // a response with one A record (compressed name) and one AAAA record
        var r: [UInt8] = [0,0,0x81,0x80,0,1,0,2,0,0,0,0, 7,101,120,97,109,112,108,101,3,99,111,109,0, 0,1,0,1]
        r += [0xC0,0x0C, 0,1, 0,1, 0,0,0,60, 0,4, 93,184,216,34]
        r += [0xC0,0x0C, 0,28, 0,1, 0,0,0,60, 0,16, 0x26,0x06,0x28,0,0x02,0x20,0,1,0x02,0x48,0x18,0x93,0x25,0xc8,0x19,0x46]
        let a = try #require(DNSWire.parse(Data(r)))
        #expect(a.rcode == 0 && a.addresses.count == 2 && a.addresses[0] == "93.184.216.34" && a.addresses[1].hasPrefix("2606:2800:220:1"))
        r[3] = 0x83
        #expect(DNSWire.parse(Data(r))?.rcode == 3, "NXDOMAIN is reported as such")
        #expect(DNSWire.parse(Data([1, 2, 3])) == nil)
        #expect(DNSWire.parse(Data(r.prefix(30))) == nil, "a truncated answer is refused, not guessed at")
    }

    @Test func theTestAsksForHostNamesOnly() {
        #expect(AppDNSProbe.hostOnly("https://user:pw@provider.tv:8080/live/u/p/1.ts?token=abc") == "provider.tv")
        #expect(AppDNSProbe.hostOnly("cdn.example.com") == "cdn.example.com")
        #expect(AppDNSProbe.hostOnly("Some Playlist Name") == nil)
        #expect(AppDNSProbe.hostOnly("") == nil)
    }

    @Test func statusNeverClaimsMoreThanIsVerified() {
        var c = AppDNSConfiguration()
        #expect(AppDNSStatus.line(c, mpvInUse: false) == "Not active")
        c.enabled = true
        #expect(AppDNSStatus.line(c, mpvInUse: true).contains("MPV playback still uses system DNS"))
        c.provider = .custom; c.customURL = "nonsense"
        #expect(AppDNSStatus.line(c, mpvInUse: false) == "Custom resolver is not valid")
        #expect(AppDNSStatus.privacyNotice.contains("can see the domain names"))
    }

    @Test func applyingTurnsOnAndOffWithoutCrashing() {
        var c = AppDNSConfiguration(); c.enabled = true
        AppDNSController.apply(c)
        AppDNSController.apply(AppDNSConfiguration())
        AppDNSController.clearCache()
    }
}

@Suite("App DNS test") struct AppDNSTestRunTests {
    final class FakeDoH: URLProtocol {
        nonisolated(unsafe) static var answers: [String: [UInt8]] = [:]       // host -> A record bytes (empty = NXDOMAIN)
        nonisolated(unsafe) static var seenQueries: [String] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var b64 = items.first { $0.name == "dns" }?.value ?? ""
            b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); while b64.count % 4 != 0 { b64 += "=" }
            let q = [UInt8](Data(base64Encoded: b64) ?? Data())
            var labels: [String] = [], i = 12
            while i < q.count, q[i] != 0 { labels.append(String(decoding: q[(i + 1)...(i + Int(q[i]))], as: UTF8.self)); i += Int(q[i]) + 1 }
            let host = labels.joined(separator: "."), isA = q.count > i + 2 && q[i + 2] == 1
            Self.seenQueries.append(request.url!.absoluteString)
            let ip = Self.answers[host] ?? []
            var r: [UInt8] = [0, 0, 0x81, ip.isEmpty ? 0x83 : 0x80, 0, 1, 0, (isA && !ip.isEmpty) ? 1 : 0, 0, 0, 0, 0] + Array(q[12..<(i + 5)])
            if isA && !ip.isEmpty { r += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4] + ip }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: Data(r)); client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func probe() -> AppDNSProbe {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [FakeDoH.self]
        return AppDNSProbe(session: URLSession(configuration: c))
    }

    @Test func reportsWhatTheResolverAnswersAndComparesWithTheDevice() async {
        FakeDoH.answers = ["example.com": [93, 184, 216, 34], "provider.tv": [203, 0, 113, 7], "guide.tv": [192, 168, 1, 1]]
        FakeDoH.seenQueries = []
        let r = await AppDNSTest.run(AppDNSConfiguration(), hosts: [("Playlist", "http://u:p@provider.tv:8080/get.php?username=u&password=p"), ("Guide", "https://guide.tv/x.xml"), ("Local", "http://nas.local/list.m3u")],
                                     probe: probe(), systemResolves: { $0 != "provider.tv" })
        #expect(r.reachable && r.resolverName == "Cloudflare")
        #expect(r.rows.map(\.host) == ["example.com", "provider.tv", "guide.tv"], "the local name is not sent to a public resolver")
        #expect(r.rows[1].resolved && r.rows[2].resolved == false && r.rows[2].detail.contains("private address"), "DNS rebinding is refused")
        #expect(r.comparison?.contains("Playlist") == true, "the device could not resolve the playlist host but App DNS could")
        let sent = FakeDoH.seenQueries.joined()
        #expect(!sent.contains("password") && !sent.contains("username") && !sent.contains("get.php"), "only host names reach the resolver")
    }

    @Test func anUnreachableResolverIsSaidSo() async {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [FailingDoH.self]
        let r = await AppDNSTest.run(AppDNSConfiguration(), hosts: [], probe: AppDNSProbe(session: URLSession(configuration: c)), systemResolves: { _ in true })
        #expect(!r.reachable && r.headline == "Cloudflare is unavailable" && !r.advice.isEmpty)
    }

    final class FailingDoH: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
        override func stopLoading() {}
    }
}
