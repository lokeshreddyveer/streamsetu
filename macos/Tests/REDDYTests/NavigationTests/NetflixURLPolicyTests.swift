import Testing
import Foundation
@testable import REDDY

@Suite("Netflix address policy") struct NetflixURLPolicyTests {
    let p = NetflixURLPolicy.production
    private func d(_ s: String, main: Bool = true) -> NetflixURLPolicy.Decision { p.decide(URL(string: s), isMainFrame: main) }

    @Test func theSiteAndItsSubdomainsStayInTheApp() {
        for u in ["https://www.netflix.com/", "https://netflix.com/browse", "https://www.netflix.com/title/80100172?trackId=1", "https://help.netflix.com/en", "https://WWW.NETFLIX.COM/login", "https://a.b.netflix.com/x"] {
            #expect(d(u) == .allowInApp, "\(u)")
        }
    }

    /// Whole labels only: look-alike names and substrings never match.
    @Test func lookAlikeHostsGoToTheBrowser() {
        for u in ["https://netflix.com.evil.example/", "https://evilnetflix.com/", "https://netflix.co/", "https://www.netflix.com.attacker.net/", "https://notnetflix.com/", "https://example.com/?u=netflix.com", "https://example.com/netflix.com"] {
            #expect(d(u) == .openExternally, "\(u)")
        }
    }

    @Test func onlyHTTPSLoadsInTheApp() {
        #expect(d("http://www.netflix.com/") == .block)          // never downgrade the site itself
        #expect(d("https://example.com/") == .openExternally)
        #expect(d("http://example.com/") == .openExternally)
    }

    @Test func mailAndPhoneLinksGoOutAndEverythingElseIsBlocked() {
        #expect(d("mailto:help@example.com") == .openExternally)
        #expect(d("tel:+10000000") == .openExternally)
        for u in ["javascript:alert(1)", "data:text/html,hi", "file:///etc/hosts", "blob:https://www.netflix.com/abc", "ftp://example.com/x", "nflx://title/1", "myapp://open", "x-apple.systempreferences:", "sms:123", "facetime:a@b.c", "itms-apps://apps.apple.com/x"] {
            #expect(d(u) == .block, "\(u)")
        }
        #expect(d("mailto:a@b.c", main: false) == .block)
    }

    @Test func noCredentialsInAddresses() {
        #expect(d("https://user:pw@www.netflix.com/") == .block)
        #expect(d("https://user@www.netflix.com/") == .block)
        #expect(d("https://user:pw@example.com/") == .block)
    }

    @Test func missingOrOddAddressesAreBlocked() {
        #expect(p.decide(nil, isMainFrame: true) == .block)
        #expect(d("https:///path") == .block)
        #expect(d("about:blank") == .allowInApp)
        #expect(d("about:srcdoc") == .block)
    }

    /// A page the site embeds (a captcha, a payment frame) loads over https from any host; it can never replace the page.
    @Test func embeddedFramesMayBeHTTPSFromAnyHost() {
        #expect(d("https://captcha.example.net/frame", main: false) == .allowInApp)
        #expect(d("http://captcha.example.net/frame", main: false) == .block)
        #expect(d("javascript:void(0)", main: false) == .block)
        #expect(d("https://captcha.example.net/frame", main: true) == .openExternally)
    }

    @Test func logsNeverCarryQueriesFragmentsOrCredentials() {
        let u = URL(string: "https://user:secret@www.netflix.com/title/1?token=abc123&x=y#frag")!
        let s = NetflixURLPolicy.loggable(u)
        #expect(s == "https://www.netflix.com/title/1")
        for bad in ["secret", "token", "abc123", "frag", "user"] { #expect(!s.contains(bad)) }
        #expect(NetflixURLPolicy.loggable(nil) == "-")
    }

    @Test func errorsMapToTheRightStates() {
        func f(_ c: Int) -> NetflixFailure? { NetflixFailure.from(domain: NSURLErrorDomain, code: c) }
        #expect(f(NSURLErrorNotConnectedToInternet) == .offline); #expect(f(NSURLErrorNetworkConnectionLost) == .offline)
        #expect(f(NSURLErrorCannotFindHost) == .dnsFailure); #expect(f(NSURLErrorDNSLookupFailed) == .dnsFailure)
        #expect(f(NSURLErrorTimedOut) == .timedOut)
        for c in [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot] { #expect(f(c) == .tlsFailure) }
        #expect(f(NSURLErrorCannotConnectToHost) == .siteUnavailable(status: nil))
        #expect(f(NSURLErrorCancelled) == nil)
        #expect(NetflixFailure.from(domain: "WebKitErrorDomain", code: 102) == nil)
        #expect(NetflixFailure.from(domain: "Other", code: 1) == .other)
    }

    @Test func everyFailureHasPlainWordsAndNoJargon() {
        for f: NetflixFailure in [.offline, .dnsFailure, .tlsFailure, .timedOut, .siteUnavailable(status: 503), .other] {
            let t = NetflixFailureCopy.text(for: f)
            #expect(!t.title.isEmpty && !t.message.isEmpty && !t.symbol.isEmpty)
            for jargon in ["NSURL", "WebKit", "error code", "-1009", "domain"] { #expect(!t.message.contains(jargon) && !t.title.contains(jargon)) }
        }
    }

    @Test func theHomeAddressIsOnThePolicy() {
        #expect(p.decide(NetflixURLPolicy.homeURL, isMainFrame: true) == .allowInApp)
    }
}
