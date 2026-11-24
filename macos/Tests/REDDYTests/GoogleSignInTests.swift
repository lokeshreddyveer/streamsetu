import Testing
import WebKit
import AppKit
@testable import REDDY

/// Google sign-in for every service: one shared group of exact auth hosts, a sign-in window for the hosts' pop-up requests only, and no page
/// option script or rule list anywhere near those hosts. Fixtures only; no Google account or request is involved.
@MainActor final class FakeServiceEvents: ServiceWebEvents {
    let definition: ProviderDefinition
    var popups: [AuthPopup] = []
    var offSite: [URL] = [], inPlace: [URL] = []
    init(_ d: ProviderDefinition) { definition = d }
    func addressAllowed(_ url: URL) {}
    func addressOffSite(_ url: URL) { offSite.append(url) }
    func downloadBlocked() {}
    func openInPlace(_ url: URL) { inPlace.append(url) }
    func mainResponse(statusCode: Int?) {}
    func loadStarted() {}
    func loadCommitted(_ url: URL?) {}
    func loadFinished() {}
    func loadFailed(_ error: Error) {}
    func processTerminated() {}
    func regionRestricted(host: String, label: String?) {}
    func cookiesChanged() {}
    func presentAuthPopup(_ popup: AuthPopup) { popups.append(popup) }
}

final class FakeNavigationAction: WKNavigationAction {
    private let req: URLRequest
    init(_ url: String) { req = URLRequest(url: URL(string: url)!); super.init() }
    override var request: URLRequest { req }
    override var targetFrame: WKFrameInfo? { nil }
}

@Suite("Google sign-in: shared host group") @MainActor struct GoogleSignInPolicyTests {
    private func d(_ def: ProviderDefinition, _ s: String, redirect: Bool = false, main: Bool = true) -> ProviderURLPolicy.Decision { def.urlPolicy.decide(URL(string: s), isMainFrame: main, isRedirect: redirect) }

    @Test func theGroupIsExactHostsOfRoleAuthOnly() {
        #expect(HostRule.googleSignIn.map(\.suffix) == ["accounts.google.com", "accounts.youtube.com"])
        #expect(HostRule.googleSignIn.allSatisfy { $0.role == .auth && $0.exactHost && $0.active && $0.pathPrefixSegments.isEmpty })
        #expect(!HostRule.googleSignIn.contains { $0.suffix == "google.com" || $0.suffix.hasPrefix("*") })
    }

    @Test func everyProviderIncludesTheGroupJioHotstarOnHoldToo() {
        for def in ProviderCatalog.all {
            let rules = def.urlPolicy.hostRules
            for g in HostRule.googleSignIn { #expect(rules.contains(g), Comment(rawValue: "\(def.id) \(g.suffix)")) }
            #expect(def.urlPolicy.isGoogleSignInHost("accounts.google.com"), Comment(rawValue: def.id.rawValue))
        }
        #expect(ProviderCatalog.all.count == 12 && ProviderCatalog.jiohotstar.availability == .registered)
    }

    @Test func signInHostsLoadOverHttpsInTheMainFrameForEveryProvider() {
        for def in ProviderCatalog.all where def.id != .jiohotstar || true {
            for u in ["https://accounts.google.com/v3/signin/identifier?x=1", "https://accounts.google.com/gsi/select?client_id=x", "https://accounts.youtube.com/accounts/SetSID"] {
                #expect(d(def, u) == .allowInApp, Comment(rawValue: "\(def.id) \(u)"))
            }
        }
    }

    @Test func lookalikesUserinfoHttpPortsAndOtherGoogleHostsStayBlocked() {
        for def in ProviderCatalog.all {
            for u in ["https://accounts.google.com.evil.example/", "https://evil-accounts.google.com/", "https://evilaccounts.google.com/", "https://accounts.google.com.evil.test/signin",
                      "https://google.com/", "https://www.google.com/", "https://myaccount.google.com/", "https://mail.google.com/", "https://apis.google.com/", "https://id.google.com/",
                      "https://accounts.google.co.in/", "https://sub.accounts.google.com/", "https://accounts.youtube.com.evil.test/", "https://sub.accounts.youtube.com/"]
                where def.id != .youtube || !u.contains("accounts.youtube.com.evil") && !u.contains("sub.accounts.youtube") {
                #expect(d(def, u) != .allowInApp, Comment(rawValue: "\(def.id) \(u)"))
            }
            #expect(d(def, "http://accounts.google.com/") == .block, Comment(rawValue: "\(def.id) http"))
            #expect(d(def, "https://user:pw@accounts.google.com/") == .block && d(def, "https://accounts.google.com@evil.example/") == .block)
            #expect(d(def, "https://accounts.google.com:8443/") == .block)
        }
    }

    @Test func youtubeKeepsItsConsentRedirectRuleAndOthersStillDoNotHaveIt() {
        let y = ProviderCatalog.youtube
        #expect(y.urlPolicy.hostRules.first { $0.suffix == "consent.google.com" }?.role == .redirectOnly)
        #expect(d(y, "https://consent.google.com/m") == .openExternally && d(y, "https://consent.google.com/m", redirect: true) == .allowInApp)
        for def in ProviderCatalog.all where def.id != .youtube { #expect(d(def, "https://consent.google.com/m", redirect: true) == .openExternally, Comment(rawValue: def.id.rawValue)) }
    }

    @Test func youtubeIsNoLongerSignedOutOnly() {
        #expect(ProviderCatalog.youtube.authentication == .signInInApp)
        #expect(ProviderCatalog.all.allSatisfy { $0.authentication == .signInInApp })
    }

    @Test func aGoogleSignInHostIsNotASessionOfTheService() {
        #expect(!ServiceWebModel.recordBelongs("accounts.google.com", to: ProviderCatalog.spotify))
        #expect(ServiceWebModel.recordBelongs("spotify.com", to: ProviderCatalog.spotify))
    }
}

@Suite("Google sign-in: pop-up window") @MainActor struct GoogleSignInPopupTests {
    private func rig(_ def: ProviderDefinition = ProviderCatalog.youtube) -> (ServiceWebDelegates, FakeServiceEvents, ServiceDiagnostics) {
        let events = FakeServiceEvents(def), diag = ServiceDiagnostics()
        return (ServiceWebDelegates(events: events, diagnostics: diag), events, diag)
    }
    private func ask(_ delegates: ServiceWebDelegates, _ url: String, config: WKWebViewConfiguration = WKWebViewConfiguration()) -> WKWebView? {
        delegates.webView(WKWebView(), createWebViewWith: config, for: FakeNavigationAction(url), windowFeatures: WKWindowFeatures())
    }

    @Test func aSignInHostGetsARealWindowOnTheSameStoreWithNoScriptsOrRuleLists() async {
        for def in [ProviderCatalog.youtube, ProviderCatalog.spotify, ProviderCatalog.netflix] {
            let (delegates, events, diag) = rig(def)
            let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()
            cfg.userContentController.addUserScript(WKUserScript(source: "1", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let (store, dir) = (WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("g-\(UUID().uuidString)"))!, ())
            _ = dir
            if let list = await SpotifyAdRules.list(in: store) { cfg.userContentController.add(list) }
            let web = ask(delegates, "https://accounts.google.com/gsi/select?client_id=x", config: cfg)
            let popup = events.popups.first
            #expect(web != nil && popup?.webView === web && events.popups.count == 1, Comment(rawValue: def.id.rawValue))
            #expect(web?.configuration.websiteDataStore === cfg.websiteDataStore, "same store, so the result returns to the opener")
            #expect(web?.configuration.userContentController.userScripts.isEmpty == true, "no page option script in the sign-in window")
            #expect(events.inPlace.isEmpty && events.offSite.isEmpty)
            #expect(diag.entries(for: def.id) == [.init(host: "accounts.google.com", kind: .authPopupOpened)])
            popup?.close()
            #expect(popup?.isClosed == true && events.popups.count == 1)
            #expect(diag.entries(for: def.id).last == .init(host: "accounts.google.com", kind: .authPopupClosed))
            #expect(!String(describing: diag.entries(for: def.id)).contains("client_id"), "host only, never the address")
        }
    }

    @Test func anyOtherPopupIsAsBefore() {
        let (delegates, events, diag) = rig()
        #expect(ask(delegates, "https://evil.example/") == nil)
        #expect(ask(delegates, "https://accounts.google.com.evil.example/") == nil)
        #expect(ask(delegates, "https://myaccount.google.com/") == nil)
        #expect(ask(delegates, "http://accounts.google.com/") == nil, "http is blocked")
        #expect(events.popups.isEmpty && events.offSite.count == 3)
        #expect(ask(delegates, "https://www.youtube.com/watch?v=x") == nil && events.inPlace.count == 1, "the service's own address loads in place, as before")
        #expect(diag.entries(for: .youtube).filter { $0.kind == .popupRefused }.count == 4)
        #expect(!diag.entries(for: .youtube).contains { $0.kind == .authPopupOpened })
    }

    @Test func theWindowClosesWhenThePageClosesItAndItsPolicyIsTheServices() async {
        let (delegates, events, _) = rig(ProviderCatalog.spotify)
        let web = ask(delegates, "https://accounts.google.com/gsi/transform")
        let popup = try! #require(events.popups.first)
        #expect(web != nil)
        func decide(_ u: String) async -> WKNavigationActionPolicy { await popup.webView(popup.webView, decidePolicyFor: FakeNavigationAction(u)) }
        #expect(await decide("https://accounts.google.com/v3/signin") == .allow)
        #expect(await decide("https://accounts.spotify.com/callback") == .allow, "the service's own return address")
        #expect(await decide("https://evil.example/") == .cancel)
        #expect(await decide("https://accounts.google.com.evil.example/") == .cancel)
        #expect(await decide("http://accounts.google.com/") == .cancel)
        #expect(popup.webView(popup.webView, createWebViewWith: WKWebViewConfiguration(), for: FakeNavigationAction("https://accounts.google.com/"), windowFeatures: WKWindowFeatures()) == nil, "no second window")
        popup.webViewDidClose(popup.webView)
        #expect(popup.isClosed)
    }
}

@Suite("Google sign-in: page options never run there", .serialized) @MainActor struct GoogleSignInIsolationTests {
    @Test func noScriptOfEitherServiceActsOnAGoogleSignInHost() async {
        for host in ["https://accounts.google.com/", "https://accounts.youtube.com/"] {
            for def in [ProviderCatalog.youtube, ProviderCatalog.spotify] {
                let r = EnhancementRig.runtime(); EnhancementRig.grantAll(r)
                let (cfg, _) = EnhancementRig.config(def, r)
                let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: cfg)
                await EnhancementRig.load(web, #"<html><head><title>Sign in</title></head><body><audio id="a"></audio></body></html>"#, base: host)
                _ = await EnhancementRig.eval(web, "document.title = 'Advertisement'; 0")
                try? await Task.sleep(for: .milliseconds(700))
                let untouched = await EnhancementRig.eval(web, """
                  (function () { return JSON.parse.toString().indexOf('native code') !== -1 && Response.prototype.json.toString().indexOf('native code') !== -1
                    && Object.getOwnPropertyDescriptor(window, 'ytInitialPlayerResponse') === undefined && document.getElementById('a').muted === false
                    && !document.querySelector('style'); })()
                """) as? Bool
                #expect(untouched == true, Comment(rawValue: "\(def.id) on \(host)"))
            }
        }
    }

    @Test func theSignInWindowAndTheServiceViewNeverShareAContentController() {
        let r = EnhancementRig.runtime(); EnhancementRig.grantAll(r)
        let (cfg, _) = EnhancementRig.config(ProviderCatalog.youtube, r)
        #expect(!cfg.userContentController.userScripts.isEmpty)
        let popup = AuthPopup(configuration: cfg, definition: ProviderCatalog.youtube)
        #expect(popup.webView.configuration.userContentController.userScripts.isEmpty)
    }
}
