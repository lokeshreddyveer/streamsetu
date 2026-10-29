import Testing
import Foundation
@testable import REDDY

@Suite("A redirect never hands our logins to another host") struct RedirectPolicyTests {
    private func request(_ url: String, headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }
    private let ours = ["X-Plex-Token": "plex-secret", "Authorization": "Bearer abc", "Cookie": "sid=1", "User-Agent": "StreamSetu/2", "Referer": "https://home.example/"]

    @Test func aRedirectToAnotherHostLosesTheLoginHeadersButKeepsTheRest() {
        let original = request("https://media.example/library", headers: ours)
        let next = RedirectPolicy.sanitized(request("https://cdn.other.example/file", headers: ours), after: original)
        #expect(next.value(forHTTPHeaderField: "X-Plex-Token") == nil)
        #expect(next.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(next.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(next.value(forHTTPHeaderField: "User-Agent") == "StreamSetu/2", "ordinary headers still travel")
        #expect(next.value(forHTTPHeaderField: "Referer") != nil)
    }

    @Test func aRedirectOnTheSameServerChangesNothing() {
        let original = request("https://media.example/a", headers: ours)
        let next = request("https://MEDIA.example/b", headers: ours)
        #expect(RedirectPolicy.sanitized(next, after: original).allHTTPHeaderFields == next.allHTTPHeaderFields)
    }

    @Test func droppingFromHTTPSToPlainHTTPOnTheSameHostIsNotTheSameOrigin() {
        let original = request("https://media.example/a", headers: ours)
        let next = RedirectPolicy.sanitized(request("http://media.example/a", headers: ours), after: original)
        #expect(next.value(forHTTPHeaderField: "X-Plex-Token") == nil && next.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!RedirectPolicy.sameOrigin(URL(string: "https://a.example"), URL(string: "http://a.example")))
        #expect(!RedirectPolicy.sameOrigin(URL(string: "https://a.example"), URL(string: "https://a.example:8443")), "another port is another origin")
    }

    @Test func aLoginInTheAddressCopiedToAnotherHostIsRemoved() {
        let original = request("http://provider.example/get.php?username=me&password=pw&type=m3u")
        let next = RedirectPolicy.sanitized(request("http://elsewhere.example/get.php?username=me&password=pw&type=m3u"), after: original)
        let items = URLComponents(url: next.url!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        #expect(items == ["type"], "the playlist type stays; the login does not")
    }

    @Test func aTokenTheServerPutInItsOwnRedirectIsKept() {
        // Providers send streams to a CDN with a signed token of their own. That must keep working.
        let original = request("http://provider.example/live/me/pw/1.ts", headers: ["User-Agent": "VLC"])
        let next = RedirectPolicy.sanitized(request("http://cdn.example/1.ts?token=signed-by-the-server&expires=99", headers: ["User-Agent": "VLC"]), after: original)
        #expect(next.url?.absoluteString == "http://cdn.example/1.ts?token=signed-by-the-server&expires=99")
    }

    @Test func aHeaderTheRedirectAddedItselfIsNotOurs() {
        let original = request("https://a.example/x", headers: ["X-Api-Key": "mine"])
        let next = RedirectPolicy.sanitized(request("https://b.example/x", headers: ["X-Api-Key": "theirs"]), after: original)
        #expect(next.value(forHTTPHeaderField: "X-Api-Key") == "theirs")
    }
}
