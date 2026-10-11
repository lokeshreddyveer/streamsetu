import Testing
import Foundation
@testable import REDDY

@Suite("Per-playlist User-Agent and headers") struct SourceHeadersTests {
    @Test func linesAreParsedAndUnsafeOnesRefused() {
        let r = SourceHeaders.parse("""
        Referer: https://example.com/
        # a comment
        X-Token_1:  abc123
        Authorization: Bearer secret
        Cookie: a=b
        no colon here
        Bad Name: x
        User-Agent: ignored-here
        Empty:
        """)
        #expect(r.headers == ["Referer": "https://example.com/", "X-Token_1": "abc123"])
        #expect(r.problems.count == 5, "Authorization, Cookie, no colon, bad name, empty value: \(r.problems)")
        #expect(!r.problems.joined().contains("secret"), "a refused value is never echoed")
    }

    @Test func headersApplyToRequestsAndOnlyOverrideTheUserAgentWhenChosen() {
        var req = URLRequest(url: URL(string: "http://p.example/get.php")!)
        req.setValue("default-agent", forHTTPHeaderField: "User-Agent")
        SourceHeaders(userAgent: nil, extra: ["Referer": "http://r.example/"]).apply(to: &req)
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "default-agent" && req.value(forHTTPHeaderField: "Referer") == "http://r.example/")
        SourceHeaders(userAgent: "Kodi/21", extra: [:]).apply(to: &req)
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "Kodi/21")
        #expect(SourceHeaders().isEmpty && SourceHeaders().fields.isEmpty)
        #expect(SourceHeaders(userAgent: "X", extra: ["A": "b"]).fields == ["User-Agent": "X", "A": "b"])
    }

    @Test func eachPlaylistKeepsItsOwnAndOthersAreUntouched() {
        let s = SourceHeadersStore(defaults: UserDefaults(suiteName: "hdr-\(UUID().uuidString)")!)
        let a = UUID(), b = UUID()
        s.set(userAgent: "IPTVSmartersPro", extraText: "Referer: http://x/\nAuthorization: nope", for: a)
        #expect(s.headers(for: a).userAgent == "IPTVSmartersPro" && s.headers(for: a).extra == ["Referer": "http://x/"], "Authorization was dropped")
        #expect(s.headers(for: b).isEmpty)
        s.clear(for: a)
        #expect(s.headers(for: a).isEmpty)
        s.set(userAgent: "  ", extraText: "", for: b)
        #expect(s.headers(for: b).isEmpty, "blank means the default")
    }

    @Test func mpvAndPlaybackRequestsCarryTheHeaders() {
        var c = MPVConfiguration()
        func opts() -> [String: String] { Dictionary(c.options.map { ($0.0, $0.1) }, uniquingKeysWith: { _, b in b }) }
        #expect(opts()["user-agent"] == "VLC/3.0.20 LibVLC/3.0.20" && opts()["http-header-fields"] == nil)
        c.requestHeaders = ["User-Agent": "Kodi/21", "Referer": "http://r.example/", "X-A": "1,2"]
        #expect(opts()["user-agent"] == "Kodi/21")
        #expect(opts()["http-header-fields"] == "Referer: http://r.example/,X-A: 1%2C2", "a comma inside a value can't split the list")
    }
}
