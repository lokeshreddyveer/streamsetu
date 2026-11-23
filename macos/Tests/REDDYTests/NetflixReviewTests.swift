import Testing
import Foundation
@testable import REDDY

/// Independent adversarial checks of the Netflix address policy and the destination state machine.
@Suite("Netflix independent review") @MainActor struct NetflixReviewTests {
    let p = NetflixURLPolicy.production

    // MARK: address policy

    /// Every address here must NOT stay in the app as the main frame.
    @Test func hostBypassAttemptsNeverLoadInApp() {
        let bad = [
            "https://netflix.com.evil.test/", "https://evilnetflix.com/", "https://netflix.com@evil.test/", "https://www.netflix.com@evil.test/",
            "https://evil.test/netflix.com", "https://evil.test#@www.netflix.com/", "https://evil.test?@www.netflix.com/",
            "https://netflix.com.:443@evil.test/", "https://xn--netflx-9ta.com/", "https://netfl\u{0131}x.com/", "https://netflix\u{FF0E}com.evil.test/",
            "https://netflix.com%2eevil.test/", "https://netflix.com%00.evil.test/", "https://evil.test\\@www.netflix.com/", "https://www.netflix.com\\@evil.test/",
            "https://evil.test:443\\www.netflix.com/", "https://NETFLIX.COM.EVIL.TEST/", "https://xn--netflix-4g.com/", "https://netflix.com.evil/",
            "https://\u{FF4E}etflix.com.evil.test/", "https://www-netflix.com/", "https://netflix_com.evil.test/",
        ]
        for s in bad {
            guard let u = URL(string: s) else { continue }          // an address Foundation cannot parse is never loaded
            let d = p.decide(u, isMainFrame: true)
            #expect(d != .allowInApp, "\(s) host=\(u.host ?? "nil") decided \(d)")
        }
    }

    @Test func schemesAreNeverLoadedInApp() {
        for s in ["javascript:alert(1)", "JAVASCRIPT:alert(1)", "data:text/html,x", "file:///etc/passwd", "blob:https://www.netflix.com/x", "about:srcdoc", "about:blank#x", "about:blank?x",
                  "view-source:https://www.netflix.com/", "ws://www.netflix.com/", "wss://www.netflix.com/", "ftp://www.netflix.com/", "http://www.netflix.com/", "HTTP://WWW.NETFLIX.COM/"] {
            let d = p.decide(URL(string: s), isMainFrame: true)
            #expect(d != .allowInApp, "\(s) decided \(d)")
        }
        #expect(p.decide(nil, isMainFrame: true) == .block)
    }

    @Test func allowedShapesStayAllowed() {
        for s in ["https://www.netflix.com/", "https://WWW.Netflix.COM/browse", "https://www.netflix.com:443/", "https://help.netflix.com/en/node/1#x"] {
            #expect(p.decide(URL(string: s), isMainFrame: true) == .allowInApp, "\(s)")
        }
    }

    /// Documented (low) gaps, asserted so a change shows up: a non-default port on the site's own domain, and a trailing dot.
    @Test func knownEdgeBehaviour() {
        #expect(p.decide(URL(string: "https://www.netflix.com:8443/"), isMainFrame: true) == .block)          // only the default port
        #expect(p.decide(URL(string: "https://www.netflix.com:443/"), isMainFrame: true) == .allowInApp)
        #expect(p.decide(URL(string: "https://www.netflix.com./"), isMainFrame: true) != .allowInApp)               // trailing dot fails closed
        #expect(p.decide(URL(string: "https://netflix.com./"), isMainFrame: true) != .allowInApp)
    }

    @Test func subframesAreHttpsOnly() {
        #expect(p.decide(URL(string: "https://evil.test/x"), isMainFrame: false) == .allowInApp)          // by design: sites embed captcha and payment frames
        #expect(p.decide(URL(string: "http://evil.test/x"), isMainFrame: false) == .block)
        #expect(p.decide(URL(string: "javascript:1"), isMainFrame: false) == .block)
        #expect(p.decide(URL(string: "data:text/html,x"), isMainFrame: false) == .block)
        #expect(p.decide(URL(string: "file:///x"), isMainFrame: false) == .block)
        #expect(p.decide(URL(string: "https://u:p@evil.test/"), isMainFrame: false) == .block)
    }

    @Test func loggableNeverHasQueryFragmentOrCredentials() {
        for s in ["https://www.netflix.com/watch/1?token=SECRET#frag", "https://u:SECRET@www.netflix.com/a?b=SECRET", "https://www.netflix.com/x;jsessionid=1?q=SECRET"] {
            let out = NetflixURLPolicy.loggable(URL(string: s))
            #expect(!out.contains("SECRET") && !out.contains("frag") && !out.contains("?"), "\(out)")
        }
    }

    // MARK: state machine

    @Test func randomSequencesKeepIndicatorAndContentInAgreement() {
        var rng = SeededRNG(seed: 0xC0FFEE)
        for run in 0..<200 {
            let router = AppRouter(), nav = ServiceNavigation(capabilities: .macOS)
            nav.attach(to: router)
            var blocked = false
            nav.gate = { blocked }
            var modelTab = router.tab
            for _ in 0..<60 {
                switch Int.random(in: 0..<9, using: &rng) {
                case 0: nav.select(.netflix)
                case 1: nav.returnToStreamSetu()
                case 2: let t = AppTab.allCases.randomElement(using: &rng)!; router.navigate(t); modelTab = t
                case 3: router.go([.home, .liveTV, .movies, .series, .guide].randomElement(using: &rng)!); modelTab = router.tab
                case 4: blocked.toggle()
                case 5: nav.restore(["service.netflix", "x", nil, "streamSetu"].randomElement(using: &rng)!)
                case 6: router.open(movie: Movie(id: "m", sourceID: UUID(), providerID: "m", title: "T", normalizedTitle: "t", streamRef: "x"))
                case 7: nav.attach(to: router)
                default: router.closeDetail()
                }
                #expect(nav.navExpanded == (nav.active == .streamSetu), "run \(run)")
                #expect(nav.navExpanded == (nav.activeService == nil), "run \(run)")
                if !nav.navExpanded { #expect(router.tab == modelTab, "native tab must not move while a service shows (run \(run))") }
                modelTab = router.tab
            }
        }
    }

    @Test func aBlockedPlatformStateRefusesEverySelectionRoute() {
        let nav = ServiceNavigation(capabilities: .macOS)
        nav.gate = { true }
        #expect(!nav.select(.netflix)); #expect(!nav.restore("service.netflix")); #expect(nav.navExpanded)
    }

    @Test func platformWithoutServicesCannotReachThemByAnyRoute() {
        let nav = ServiceNavigation(capabilities: .none), router = AppRouter()
        nav.attach(to: router)
        #expect(!nav.select(.netflix)); #expect(!nav.restore("service.netflix")); #expect(nav.navExpanded); #expect(nav.services.isEmpty)
        #expect(DestinationState(rawValue: "service.netflix", capabilities: .none).active == .streamSetu)
        for s in ["streamsetu://open?tab=netflix", "streamsetu://open?tab=Netflix", "streamsetu:///open?tab=netflix", "streamsetu://open?tab=net%66lix"] {
            let link = DeepLink.parse(URL(string: s)!, capabilities: .none)
            if case .openService? = link { Issue.record("\(s) reached a service on a platform without services") }
        }
        if case .openService(.netflix)? = DeepLink.parse(URL(string: "streamsetu://open?tab=netflix")!, capabilities: .macOS) {} else { Issue.record("macOS link must parse") }
        #expect(ServiceCapabilities.none.profile(for: .netflix).websiteLoading == .unavailable)
    }
}

private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
}
