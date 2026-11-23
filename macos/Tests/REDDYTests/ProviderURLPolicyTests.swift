import Testing
import Foundation
@testable import REDDY

@Suite("Provider address policy") struct ProviderURLPolicyTests {
    private func d(_ p: ProviderURLPolicy, _ s: String, main: Bool = true, redirect: Bool = false) -> ProviderURLPolicy.Decision { p.decide(URL(string: s), isMainFrame: main, isRedirect: redirect) }
    private func policy(_ id: ProviderID) -> ProviderURLPolicy { ProviderRegistry.standard.definition(for: id)!.urlPolicy }

    @Test func everyServiceKeepsItsOwnHostAndNothingLookalike() {
        for def in ProviderRegistry.standard.definitions {
            let p = def.urlPolicy, host = def.homeURL.host!
            #expect(d(p, def.homeURL.absoluteString) == .allowInApp, Comment(rawValue: host))
            #expect(d(p, "https://\(host):443/x") == .allowInApp)
            #expect(d(p, "https://\(host):8443/") == .block)
            #expect(d(p, "http://\(host)/") == .block)
            #expect(d(p, "https://user:pw@\(host)/") == .block)
            #expect(d(p, "https://\(host).evil.example/") == .openExternally)
            #expect(d(p, "https://evil" + (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + "/") == .openExternally)
            #expect(d(p, "https://\(host)@evil.example/") == .block)
            #expect(d(p, "https://evil.example/\(host)") == .openExternally)
        }
    }

    @Test func schemesAndPopupsAreTheSameForEveryService() {
        for def in ProviderRegistry.standard.definitions {
            let p = def.urlPolicy
            for u in ["javascript:alert(1)", "data:text/html,x", "file:///etc/hosts", "blob:https://x.test/1", "ftp://x.test/", "app-scheme://x"] { #expect(d(p, u) == .block, Comment(rawValue: u)) }
            #expect(d(p, "about:blank") == .allowInApp); #expect(d(p, "about:srcdoc") == .block)
            #expect(d(p, "mailto:a@b.test") == .openExternally); #expect(d(p, "mailto:a@b.test", main: false) == .block)
            #expect(d(p, "https://captcha.example/frame", main: false) == .allowInApp)          // framed pages the site chose
            #expect(d(p, "http://captcha.example/frame", main: false) == .block)
            #expect(p.popups == .sameViewIfAllowed && p.subframes == .anyHTTPS && p.adapterKey == nil)
        }
    }

    @Test func signInStartHostsPassAsMainFrameHTTPSOnly() {
        let starts: [(ProviderID, String)] = [
            (.primevideo, "https://www.amazon.com/ap/signin"), (.primevideo, "https://www.amazon.in/ap/signin"),
            (.disneyplus, "https://www.disneyplus.com/login"), (.disneyplus, "https://www.jiohotstar.com/login"), (.disneyplus, "https://www.hotstar.com/in"),
            (.disneyplus, "https://disneyid.com/login"), (.hulu, "https://auth.hulu.com/web/login"), (.hulu, "https://disneyid.com/login"),
            (.hbomax, "https://auth.max.com/login"), (.hbomax, "https://play.hbomax.com/signIn"), (.peacock, "https://www.peacocktv.com/signin"),
            (.peacock, "https://oauth.id.peacocktv.com/x"), (.paramountplus, "https://www.paramountplus.com/account/signin/"),
            (.appletv, "https://appleid.apple.com/auth"), (.appletv, "https://idmsa.apple.com/"), (.appletv, "https://account.apple.com/sign-in"),
            (.crunchyroll, "https://sso.crunchyroll.com/login")]
        for (id, u) in starts {
            #expect(d(policy(id), u) == .allowInApp, Comment(rawValue: u))
            #expect(d(policy(id), u.replacingOccurrences(of: "https://", with: "http://")) != .allowInApp, Comment(rawValue: u))
            #expect(d(policy(id), u.replacingOccurrences(of: "https://", with: "https://u:p@")) == .block)
            #expect(d(policy(id), "https://" + (URL(string: u)!.host!) + ".evil.test/") == .openExternally, Comment(rawValue: u))
        }
        #expect(d(policy(.primevideo), "https://evilamazon.com/ap/signin") == .openExternally)
        #expect(d(policy(.primevideo), "https://amazon.com.evil.test/ap/signin") == .openExternally)
        #expect(d(policy(.primevideo), "https://www.amazon.com@evil.test/") == .block)
        #expect(d(policy(.primevideo), "http://www.amazon.com/ap/signin") != .allowInApp)
        #expect(d(policy(.primevideo), "https://www.amazon.co.uk/ap/signin") == .openExternally)
        #expect(d(policy(.appletv), "https://www.apple.com/") == .openExternally)
        #expect(d(policy(.hulu), "https://www.disneyplus.com/login") == .openExternally)       // still a guess: blocked, host shown in the notice
        #expect(d(policy(.paramountplus), "https://www.cbs.com/") == .openExternally)
    }

    @Test func youtubeStaysWithoutGoogleSignIn() {
        for h in ["accounts.google.com", "google.com", "accounts.youtube.com.evil.test"] { #expect(d(policy(.youtube), "https://\(h)/signin") == .openExternally) }
    }


    @Test func redirectOnlyHostsAreReachedByRedirectNeverByLink() {
        for (id, host) in [(ProviderID.youtube, "youtu.be"), (.hbomax, "max.com")] {
            #expect(d(policy(id), "https://\(host)/x") == .openExternally)
            #expect(d(policy(id), "https://\(host)/x", redirect: true) == .allowInApp)
            #expect(d(policy(id), "https://evil-\(host)/x", redirect: true) == .openExternally)
        }
    }

    @Test func googleSignInIsNotReachableFromYouTube() {
        for u in ["https://accounts.google.com/ServiceLogin", "https://accounts.youtube.com/SetSID"] where u.contains("google") { #expect(d(policy(.youtube), u, redirect: true) == .openExternally) }
        #expect(d(policy(.youtube), "https://m.youtube.com/") == .allowInApp)
    }

    @Test func oneServiceDoesNotAllowAnotherServicesHost() {
        #expect(d(policy(.netflix), "https://www.hulu.com/") == .openExternally)
        #expect(d(policy(.hulu), "https://www.netflix.com/") == .openExternally)
    }

    @Test func theOldInitialiserAndNamesStillWork() {
        let p = NetflixURLPolicy(hostSuffixes: ["127.0.0.1"], inAppSchemes: ["http"], allowsAnyPort: true)
        #expect(p.hostRules == [HostRule(suffix: "127.0.0.1", role: .site)] && p.allowsAnyPort)
        #expect(p.decide(URL(string: "http://127.0.0.1:5555/"), isMainFrame: true) == .allowInApp)
        #expect(NetflixURLPolicy.production == ProviderCatalog.netflix.urlPolicy)
        #expect(ProviderURLPolicy.loggable(URL(string: "https://u:p@www.hulu.com/a?q=SECRET#f")) == "https://www.hulu.com/a")
        #expect(ProviderURLPolicy.loggable(nil) == "-")
        #expect(NetflixFailure.from(domain: NSURLErrorDomain, code: NSURLErrorTimedOut) == ServiceFailure.timedOut)
    }
}
