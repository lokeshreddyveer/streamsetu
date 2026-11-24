import Testing
import WebKit
import AppKit
@testable import REDDY

/// The provider's OWN regional redirect (an exact host the definition names, reached by a redirect from the service's own site) is told apart
/// from StreamSetu's own address policy ("Link blocked") and from load failures. Local fixtures only: the site is 127.0.0.1, the provider's
/// regional page is the loopback name "localhost", and "unexpected.test" is an external host nothing serves. No real site is contacted.
@Suite("Provider regional restriction", .serialized) @MainActor struct ServiceRegionRestrictionTests {
    static let countryNotice = [RegionNoticeHost(host: "127.0.0.1", pathPattern: RegionNoticeHost.countryPathExceptIn)]

    @MainActor final class Rig {
        let server: ServiceFixtureServer
        let model: ServiceWebModel
        let diagnostics = ServiceDiagnostics()
        let window: NSWindow
        var launches = 0
        /// The fixture site: host 127.0.0.1 whose own pages are the whole path segment /in; the same host's other two-letter paths are the provider's regional pages.
        init(notice: [RegionNoticeHost] = ServiceRegionRestrictionTests.countryNotice, id: ProviderID = .jiohotstar) async throws {
            _ = NSApplication.shared
            server = try ServiceFixtureServer(); try await server.start()
            let d = ProviderCatalog.all.first { $0.id == id }!
            let policy = ProviderURLPolicy(hostRules: [HostRule(suffix: "127.0.0.1", role: .site, exactHost: true, pathPrefixSegments: ["in"])], inAppSchemes: ["http"], allowsAnyPort: true, regionNoticeHosts: notice)
            model = ServiceWebModel(definition: d.replacing(urlPolicy: policy, homeURL: server.url("/in/home"), availability: .unverified), dataStore: { .nonPersistent() })
            model.diagnostics = diagnostics
            model.isAppActive = { true }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            model.openExternal = { [unowned self] _ in launches += 1 }
        }
        func show() { model.serviceBecameVisible(); window.contentView = model.hostedView(); model.hostedView().frame = window.contentView!.bounds }
        func finish() { model.serviceBecameHidden(); model.releaseResources(); window.contentView = nil; server.stop() }
        var title: String { model.webView?.title ?? "" }
        var path: String { model.webView?.url?.path ?? "" }
        var isRegion: Bool { if case .failed(.regionRestricted) = model.phase { true } else { false } }
        var isReady: Bool { model.phase == .ready }
        func start() async { show(); _ = await ServiceTestSupport.until { isReady } }
    }

    // MARK: (a) the service's own pages and redirects are ordinary

    @Test func theOfficialPathLoadsAndASameSiteRedirectChainIsAllowed() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        await rig.start()
        #expect(rig.path == "/in/home" && !rig.isRegion, "the start page is under /in and is not a regional page")
        rig.model.load(rig.server.url("/in/chain-a"))
        #expect(await ServiceTestSupport.until { rig.path == "/in/home" && rig.title == "/in/home" && rig.isReady && rig.server.hits("/in/chain-b") == 1 })
        #expect(!rig.isRegion && rig.model.blockedLinkHost == nil && rig.model.failureScreen == nil)
        #expect(rig.diagnostics.lastRedirectChain(for: .jiohotstar).isEmpty, "same-host redirects add no host hop")
    }

    @Test func theCountryRouterRootRedirectingToTheOfficialPathLoadsEndToEnd() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        await rig.start()
        rig.model.load(rig.server.url("/in/chain-a")); _ = await ServiceTestSupport.until { rig.isReady }
        // a load that begins on the site and is routed through the root: not loadable by itself, admitted as a redirect hop
        rig.model.load(rig.server.url("/in/to-root-in"))
        #expect(await ServiceTestSupport.until { rig.path == "/in/home" && rig.isReady && rig.server.hits("/") >= 1 })
        #expect(!rig.isRegion && rig.model.blockedLinkHost == nil)
    }

    // MARK: (b) the provider's regional redirect, path-aware

    @Test func aRedirectToACountryPathOnTheSameHostIsARegionRestrictionAndThatPageIsNeverLoaded() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        await rig.start()
        rig.model.load(rig.server.url("/in/to-us-chain"))
        #expect(await ServiceTestSupport.until { rig.isRegion })
        #expect(rig.model.phase == .failed(.regionRestricted(host: "127.0.0.1", label: "US")), "the label is shown because the path was actually seen")
        try? await Task.sleep(for: .milliseconds(600))
        #expect(rig.isRegion, "the cancelled load's own failure callback does not replace the state")
        #expect(rig.server.hits("/us") == 0 && rig.server.hits("/us/next") == 0, "the regional page was never requested")
        #expect(rig.model.blockedLinkHost == nil && rig.model.pendingExternal == nil && rig.launches == 0)
        #expect(rig.model.webView?.url?.path != "/us")
        let entries = rig.diagnostics.entries(for: .jiohotstar)
        #expect(entries.contains(.init(host: "127.0.0.1", kind: .providerRegionalPage)) && !entries.contains { $0.kind == .blocked })
        let screen = try #require(rig.model.failureScreen)
        #expect(screen.actions == [.retry, .returnToStreamSetu])
        let text = String(describing: entries)
        for leak in ["/us", "to-us", "next"] { #expect(!text.contains(leak), Comment(rawValue: leak)) }
    }

    @Test func theRootRoutedToACountryPathIsARegionRestrictionAndToAnotherCountryToo() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        await rig.start()
        rig.model.load(rig.server.url("/in/to-root-us"))
        #expect(await ServiceTestSupport.until { rig.isRegion })
        #expect(rig.model.phase == .failed(.regionRestricted(host: "127.0.0.1", label: "US")) && rig.server.hits("/us") == 0)
        rig.model.retry(); _ = await ServiceTestSupport.until { rig.server.hits("/in/to-root-us") >= 2 }
        #expect(await ServiceTestSupport.until { rig.isRegion })
    }

    @Test func aStableRootThatIsServedAsAPageIsShownNotCancelledSilently() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        await rig.start()
        rig.model.load(rig.server.url("/in/to-root-stable"))
        #expect(await ServiceTestSupport.until { rig.path == "/" && rig.title == "root" && rig.isReady })
        #expect(!rig.isRegion && rig.model.blockedLinkHost == nil, "the provider chose to serve it: shown as the provider's page")
        // but the root can never be reached by a link or typed address
        rig.model.load(rig.server.url("/"))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.server.hits("/") == 1, "load(_:) refuses an address the policy would block")
    }

    @Test func aCountryPathShapeNarrowsWhatCountsAsTheRegionalPage() async throws {
        let rig = try await Rig(notice: [RegionNoticeHost(host: "127.0.0.1", pathPattern: "^/uk(/|$)")]); defer { rig.finish() }
        await rig.start()
        rig.model.load(rig.server.url("/in/to-us"))
        #expect(await ServiceTestSupport.until { rig.model.blockedLinkHost == "127.0.0.1" })
        #expect(!rig.isRegion && rig.server.hits("/us") == 0)
        rig.model.dismissBlockedLink()
        rig.model.load(rig.server.url("/in/to-root-uk"))
        #expect(await ServiceTestSupport.until { rig.isRegion })
        #expect(rig.model.phase == .failed(.regionRestricted(host: "127.0.0.1", label: "UK")))
    }

    // MARK: path tricks are the app's own policy

    @Test(arguments: ["/in/to-india", "/in/to-inevil", "/in/to-encoded", "/in/to-encoded-us", "/in/to-doubleslash", "/in/to-other-path"])
    func lookalikePathsAndOtherPathsOnTheSameHostAreLinkBlocked(_ route: String) async throws {
        let rig = try await Rig(); defer { rig.finish() }
        await rig.start()
        rig.model.load(rig.server.url(route))
        #expect(await ServiceTestSupport.until { rig.model.blockedLinkHost == "127.0.0.1" }, Comment(rawValue: route))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!rig.isRegion && rig.server.hits("/india") == 0 && rig.server.hits("/in.evil") == 0 && rig.server.hits("/sports/shows") == 0)
    }

    @Test func aTraversalIsResolvedBeforeMatching() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        await rig.start()
        rig.model.load(rig.server.url("/in/to-traversal"))
        #expect(await ServiceTestSupport.until { rig.isRegion || rig.model.blockedLinkHost != nil })
        #expect(rig.isRegion && rig.model.phase == .failed(.regionRestricted(host: "127.0.0.1", label: "US")), "/in/../us is /us, a country page, never the official path")
        #expect(rig.server.hits("/us") == 0)
    }

    // MARK: (c) an unexpected host is the app's own policy

    @Test func aRedirectToAnUnexpectedHostIsALinkBlockedNoticeNotARegionRestriction() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        await rig.start()
        rig.model.load(rig.server.url("/in/to-unexpected"))
        #expect(await ServiceTestSupport.until { rig.model.blockedLinkHost == "unexpected.test" })
        try? await Task.sleep(for: .milliseconds(400))
        #expect(!rig.isRegion && rig.model.blockedLinkHost == "unexpected.test")
        #expect(!rig.diagnostics.entries(for: .jiohotstar).contains { $0.kind == .providerRegionalPage })
        #expect(rig.diagnostics.entries(for: .jiohotstar).contains(.init(host: "unexpected.test", kind: .blocked)))
        #expect(rig.diagnostics.lastRedirectChain(for: .jiohotstar) == ["127.0.0.1", "unexpected.test"])
    }

    // MARK: (d) the same host reached while the page is idle is not a redirect

    @Test func aScriptedOrClickedNavigationToACountryPathWhileIdleIsLinkBlocked() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        await rig.start()
        rig.model.load(rig.server.url("/in/idle-to-us"))
        #expect(await ServiceTestSupport.until { rig.model.blockedLinkHost == "127.0.0.1" })
        #expect(!rig.isRegion && rig.server.hits("/us") == 0)
        rig.model.dismissBlockedLink()
        for page in ["idle-link-us", "idle-link-other"] {
            rig.model.load(rig.server.url("/in/" + page)); _ = await ServiceTestSupport.until { rig.title == page && rig.isReady }
            _ = try? await rig.model.webView?.evaluateJavaScript("document.getElementById('r').click()")          // test-only click on a fixture
            #expect(await ServiceTestSupport.until { rig.model.blockedLinkHost == "127.0.0.1" }, Comment(rawValue: page))
            #expect(!rig.isRegion && rig.server.hits("/us") == 0 && rig.server.hits("/sports/shows") == 0)
            rig.model.dismissBlockedLink()
        }
    }

    // MARK: (e) lookalikes and subdomains

    @Test(arguments: ["localhost", "sub.localhost", "127.0.0.1.evil.test", "evil-127.0.0.1.test", "127.0.0.2"])          // (a name ending in a number, such as "evil-127.0.0.1", is not a valid URL host, so WebKit never forms the address)
    func anotherHostOrLookalikeWithTheSameCountryPathIsLinkBlocked(_ host: String) async throws {
        let rig = try await Rig(); defer { rig.finish() }
        await rig.start()
        rig.model.load(rig.server.url("/in/to-lookalike?h=\(host)"))
        #expect(await ServiceTestSupport.until { rig.model.blockedLinkHost == host })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!rig.isRegion && rig.server.hits("/us") == 0)
    }

    // MARK: (f) failures are failures

    @Test func aServerErrorAndAnUnreachableSiteAreLoadFailuresNotRegionRestrictions() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        await rig.start()
        rig.model.load(rig.server.url("/in/500"))
        #expect(await ServiceTestSupport.until { rig.model.phase == .failed(.siteUnavailable(status: 500)) })
        let dead = try ServiceFixtureServer.unreachablePort()
        rig.model.load(URL(string: "http://127.0.0.1:\(dead)/in/x")!)
        #expect(await ServiceTestSupport.until { if case .failed(let f) = rig.model.phase, f != .siteUnavailable(status: 500) { true } else { false } })
        if case .failed(let f) = rig.model.phase { #expect(f != .regionRestricted(host: "127.0.0.1", label: nil)); if case .regionRestricted = f { Issue.record("a connection failure is not a region restriction") } }
        #expect(rig.model.blockedLinkHost == nil)
    }

    // MARK: (g) the state machine

    @Test func retryReloadsTheStartAddressOnceAndLeavesTheRestrictionAndNothingIsLaunched() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        await rig.start()
        rig.model.load(rig.server.url("/in/to-region-once"))
        #expect(await ServiceTestSupport.until { rig.isRegion })
        #expect(rig.server.hits("/in/to-region-once") == 1)
        rig.model.retry()
        #expect(await ServiceTestSupport.until { rig.isReady && rig.path == "/in/home" })
        #expect(rig.server.hits("/in/to-region-once") == 2, "one reload, no loop")
        #expect(!rig.isRegion && rig.model.failureScreen == nil)
        #expect(rig.launches == 0 && rig.model.openExternal == nil)
    }

    @Test func theRestrictionScreenOffersRetryAndReturnOnlyForEveryDefinition() {
        for d in ProviderCatalog.all {
            let s = ServiceFailureScreen(phase: .failed(.regionRestricted(host: "regional.example.test", label: nil)), definition: d)
            #expect(s?.actions == [.retry, .returnToStreamSetu], "\(d.id)")
            #expect(s?.actions.contains(.openInDefaultBrowser) == false)
        }
        // a different failure of a service that confirms links first keeps its browser button
        #expect(ServiceFailureScreen(phase: .failed(.offline), definition: ProviderCatalog.netflix)?.actions == [.retry, .openInDefaultBrowser])
    }

    @Test func theRestrictionStateIsDistinctFromEveryOtherFailureAndReloadsFromTheModel() {
        let m = ServiceWebModel(definition: ProviderCatalog.jiohotstar, dataStore: { .nonPersistent() })
        m.regionRestricted(host: "www.hotstar.com", label: nil)
        #expect(m.phase == .failed(.regionRestricted(host: "www.hotstar.com", label: nil)) && m.blockedLinkHost == nil)
        #expect(ServiceFailure.regionRestricted(host: "a", label: nil) != .other && ServiceFailure.regionRestricted(host: "a", label: nil) != .siteUnavailable(status: nil))
        #expect(ServiceFailure.regionRestricted(host: "a", label: nil) != .regionRestricted(host: "a", label: "US"))
        // a cancelled-by-policy callback after the state was set leaves it; a real error would not be one
        m.loadFailed(NSError(domain: "WebKitErrorDomain", code: 102))
        #expect(m.phase == .failed(.regionRestricted(host: "www.hotstar.com", label: nil)))
        m.loadFailed(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        #expect(m.phase == .failed(.regionRestricted(host: "www.hotstar.com", label: nil)))
        m.loadFailed(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        #expect(m.phase == .failed(.timedOut))
    }

    // MARK: (h) every other definition is unchanged

    private static func describe(_ r: HostRule) -> String {
        "\(r.role):\(r.suffix):\(r.active)" + (r.exactHost ? ":exact" : "") + (r.pathPrefixSegments.isEmpty ? "" : ":/" + r.pathPrefixSegments.joined(separator: "/"))
    }
    /// The host rules of each service, frozen. Only JioHotstar declares site exact hosts, a path prefix or regional-notice hosts; every service also carries the shared Google sign-in group (exact auth hosts).
    static let frozenRules: [String: [String]] = [
        "netflix": ["site:netflix.com:true", "auth:accounts.google.com:true:exact", "auth:accounts.youtube.com:true:exact"],
        "primevideo": ["site:primevideo.com:true", "auth:amazon.com:true", "auth:amazon.in:true", "auth:accounts.google.com:true:exact", "auth:accounts.youtube.com:true:exact"],
        "disneyplus": ["site:disneyplus.com:true", "auth:disneyid.com:true", "auth:jiohotstar.com:true", "auth:hotstar.com:true", "auth:accounts.google.com:true:exact", "auth:accounts.youtube.com:true:exact"],
        "hulu": ["site:hulu.com:true", "auth:disneyid.com:true", "auth:disneyplus.com:false", "auth:accounts.google.com:true:exact", "auth:accounts.youtube.com:true:exact"],
        "hbomax": ["site:hbomax.com:true", "site:max.com:true", "auth:auth.max.com:true", "auth:accounts.google.com:true:exact", "auth:accounts.youtube.com:true:exact"],
        "peacock": ["site:peacocktv.com:true", "auth:accounts.google.com:true:exact", "auth:accounts.youtube.com:true:exact"],
        "paramountplus": ["site:paramountplus.com:true", "auth:cbs.com:false", "auth:accounts.google.com:true:exact", "auth:accounts.youtube.com:true:exact"],
        "appletv": ["site:tv.apple.com:true", "auth:appleid.apple.com:true", "auth:idmsa.apple.com:true", "auth:account.apple.com:true", "auth:accounts.google.com:true:exact", "auth:accounts.youtube.com:true:exact"],
        "youtube": ["site:youtube.com:true", "redirectOnly:youtu.be:true", "redirectOnly:consent.google.com:true", "auth:accounts.google.com:true:exact", "auth:accounts.youtube.com:true:exact"],
        "crunchyroll": ["site:crunchyroll.com:true", "auth:accounts.google.com:true:exact", "auth:accounts.youtube.com:true:exact"],
        "spotify": ["site:spotify.com:true", "redirectOnly:spotify.link:true", "auth:accounts.google.com:true:exact", "auth:accounts.youtube.com:true:exact"],
        "jiohotstar": ["site:jiohotstar.com:true", "site:www.hotstar.com:true:exact:/in", "site:hotstar.com:true:exact:/in", "auth:accounts.google.com:true:exact", "auth:accounts.youtube.com:true:exact"],
    ]

    @Test func everyOtherDefinitionHasNoRegionalHostsNoPathRulesAndItsRulesAreFrozen() {
        for d in ProviderCatalog.all {
            #expect(Self.frozenRules[d.id.rawValue] == d.urlPolicy.hostRules.map(Self.describe), "\(d.id)")
            #expect(d.urlPolicy.inAppSchemes == ["https"] && !d.urlPolicy.allowsAnyPort, "\(d.id)")
            if d.id == .jiohotstar { continue }
            #expect(d.regionNoticeHosts.isEmpty && d.urlPolicy.regionNoticeHosts.isEmpty, "\(d.id)")
            #expect(d.urlPolicy.hostRules.allSatisfy { ($0.exactHost ? HostRule.googleSignIn.contains($0) : true) && $0.pathPrefixSegments.isEmpty }, "\(d.id)")
        }
        #expect(Set(Self.frozenRules.keys) == Set(ProviderCatalog.all.map(\.id.rawValue)))
        #expect(ProviderURLPolicy(hostSuffixes: ["a.test"], inAppSchemes: ["https"]).regionNoticeHosts.isEmpty)
    }

    @Test func jioHotstarKeepsItsPreferenceAndOnlyTheIndiaPathOfTheExactHostsLoads() {
        let j = ProviderCatalog.jiohotstar
        #expect(j.regionProfile == .india && j.regionProfile?.preferredCountry == "IN" && j.regionProfile?.preferredLocaleIdentifier == "en_IN")
        #expect(j.homeURL.absoluteString == "https://www.hotstar.com/in")
        #expect(j.regionNoticeHosts.map(\.host) == ["www.hotstar.com", "hotstar.com"] && j.regionNoticeHosts.allSatisfy { $0.pathPattern == RegionNoticeHost.countryPathExceptIn && $0.isWellFormed })
        #expect(ProviderRegistry.validate(ProviderRegistry.standard.definitions).isEmpty, "the notice shape does not overlap the /in site path")
        #expect(ServiceFailureCopy.officialSite(j.homeURL) == "hotstar.com/in")
    }

    // MARK: (i) the decision table

    private let jio = ProviderCatalog.jiohotstar.urlPolicy
    private func d(_ p: ProviderURLPolicy, _ s: String, main: Bool = true, redirect: Bool = false, origin: String? = nil) -> ProviderURLPolicy.Decision {
        p.decide(URL(string: s), isMainFrame: main, isRedirect: redirect, originHost: origin)
    }
    private func region(_ h: String, _ l: String?) -> ProviderURLPolicy.Decision { .providerRegionRestriction(host: h, label: l) }

    @Test func theOfficialIndiaPathLoadsAndNothingElseOnTheseHostsDoes() {
        for u in ["https://www.hotstar.com/in", "https://hotstar.com/in", "https://www.hotstar.com/in/", "https://www.hotstar.com/in/tv/shows?x=1#y", "https://www.hotstar.com:443/in/home",
                  "https://WWW.HOTSTAR.COM/in/home", "https://www.jiohotstar.com/", "https://jiohotstar.com/in", "https://www.hotstar.com/in/%E0%A4%85"] {
            #expect(d(jio, u) == .allowInApp, Comment(rawValue: u))
        }
        for u in ["https://www.hotstar.com/", "https://www.hotstar.com/us", "https://www.hotstar.com/india", "https://www.hotstar.com/inx", "https://www.hotstar.com/in.evil", "https://www.hotstar.com/IN",
                  "https://www.hotstar.com/%69n", "https://www.hotstar.com/%69n/home", "https://www.hotstar.com//in", "https://www.hotstar.com/in/../us", "https://www.hotstar.com/./us", "https://www.hotstar.com/tv",
                  "https://www.hotstar.com/sports/in", "https://www.hotstar.com/in%2f..%2fus", "https://www.hotstar.com/%2e%2e/in", "https://www.hotstar.com:8443/in"] {
            #expect(d(jio, u) == (u.hasSuffix(":8443/in") ? .block : .openExternally), Comment(rawValue: u))          // a non-default port on the service's own host is refused outright
        }
        #expect(d(jio, "https://www.hotstar.com/in/../in/x") == .allowInApp, "a traversal that stays under /in is resolved first")
        #expect(d(jio, "http://www.hotstar.com/in") == .block && d(jio, "http://hotstar.com/in/x") == .block, "never plain http: refused, not downgraded")
        for u in ["https://sub.hotstar.com/in", "https://api.hotstar.com/in", "https://help.hotstar.com/in", "https://evil-hotstar.com/in", "https://evilhotstar.com/in", "https://hotstar.com.evil.test/in",
                  "https://www.hotstar.com.evil.test/in", "https://nothotstar.com/in", "https://example.com/hotstar.com/in"] {
            #expect(d(jio, u) == .openExternally, Comment(rawValue: u))
        }
        for u in ["https://user@www.hotstar.com/in", "https://www.hotstar.com@evil.test/in", "https://user:pw@hotstar.com/in"] { #expect(d(jio, u) == .block, Comment(rawValue: u)) }
    }

    @Test func aRedirectToACountryPathFromTheSitesOwnLoadIsTheProvidersRegionalPage() {
        let o = "www.jiohotstar.com"
        #expect(d(jio, "https://www.hotstar.com/us", redirect: true, origin: o) == region("www.hotstar.com", "US"))
        #expect(d(jio, "https://hotstar.com/uk/home", redirect: true, origin: o) == region("hotstar.com", "UK"))
        #expect(d(jio, "https://www.hotstar.com/ca", redirect: true, origin: "www.hotstar.com") == region("www.hotstar.com", "CA"), "a load that began on the official path")
        #expect(d(jio, "https://www.hotstar.com/sg/", redirect: true, origin: o) == region("www.hotstar.com", "SG"))
        #expect(d(jio, "https://www.hotstar.com/in/../us", redirect: true, origin: o) == region("www.hotstar.com", "US"), "resolved before matching")
        #expect(d(jio, "https://www.hotstar.com:443/us?x=1#y", redirect: true, origin: o) == region("www.hotstar.com", "US"))
        // the country router's root is admitted only as a redirect hop
        #expect(d(jio, "https://www.hotstar.com/", redirect: true, origin: o) == .allowInApp)
        #expect(d(jio, "https://www.hotstar.com/", redirect: false, origin: o) == .openExternally)
        #expect(d(jio, "https://www.hotstar.com/", redirect: true, origin: nil) == .openExternally && d(jio, "https://www.hotstar.com/", redirect: true, origin: "evil.test") == .openExternally)
        // the Indian path reached by redirect simply loads
        #expect(d(jio, "https://www.hotstar.com/in", redirect: true, origin: o) == .allowInApp)
    }

    @Test func everyOtherRedirectOrCircumstanceStaysTheAppsOwnPolicy() {
        let o = "www.jiohotstar.com"
        for u in ["https://www.hotstar.com/india", "https://www.hotstar.com/in.evil", "https://www.hotstar.com/%69n", "https://www.hotstar.com/%75s", "https://www.hotstar.com//us", "https://www.hotstar.com/usa",
                  "https://www.hotstar.com/u", "https://www.hotstar.com/US", "https://www.hotstar.com/sports/shows", "https://www.hotstar.com/us%2fx", "https://sub.hotstar.com/us", "https://api.hotstar.com/us",
                  "https://evil-hotstar.com/us", "https://hotstar.com.evil.test/us", "https://www.hotstar.com.evil.test/us", "https://www.hotstar.com:8443/us", "http://www.hotstar.com/us"] {
            #expect(d(jio, u, redirect: true, origin: o) == .openExternally, Comment(rawValue: u))
        }
        // documented limit: a redirect to ANY other two-letter first segment is classed as a country page, so "/tv/..." (a valid code, Tuvalu) is shown as one
        #expect(d(jio, "https://www.hotstar.com/tv/shows", redirect: true, origin: o) == .providerRegionRestriction(host: "www.hotstar.com", label: "TV"))
        for u in ["https://user@www.hotstar.com/us", "https://www.hotstar.com@evil.test/us"] { #expect(d(jio, u, redirect: true, origin: o) == .block, Comment(rawValue: u)) }
        // not a redirect (a link, a script, a typed address while idle)
        #expect(d(jio, "https://www.hotstar.com/us", redirect: false, origin: o) == .openExternally)
        #expect(d(jio, "https://hotstar.com/uk", redirect: false) == .openExternally)
        // a redirect, but the load did not begin on a site host
        for origin in [nil, "evil.test", "jiohotstar.com.evil.test", "sub.hotstar.com"] { #expect(d(jio, "https://www.hotstar.com/us", redirect: true, origin: origin) == .openExternally, Comment(rawValue: origin ?? "nil")) }
        // an embedded frame is never a main-frame restriction
        #expect(d(jio, "https://www.hotstar.com/us", main: false, redirect: true, origin: o) == .allowInApp)
        // the other services never classify it
        for def in ProviderCatalog.all where def.id != .jiohotstar && !def.urlPolicy.isAllowedHost("www.hotstar.com") {
            #expect(def.urlPolicy.decide(URL(string: "https://www.hotstar.com/us"), isMainFrame: true, isRedirect: true, originHost: def.homeURL.host) == .openExternally, "\(def.id)")
        }
    }

    @Test func aRedirectOnlyOrSignInHostIsNotASiteOriginAndAnyPathShapeIsHonoured() {
        let p = ProviderURLPolicy(hostRules: [HostRule(suffix: "site.example", role: .site), HostRule(suffix: "go.example", role: .redirectOnly), HostRule(suffix: "login.example", role: .auth)],
                                  inAppSchemes: ["https"], regionNoticeHosts: [RegionNoticeHost(host: "regional.example", pathPattern: "^/[a-z]{2}(/|$)")])
        #expect(d(p, "https://regional.example/us", redirect: true, origin: "site.example") == region("regional.example", "US"))
        #expect(d(p, "https://regional.example/us/", redirect: true, origin: "www.site.example") == region("regional.example", "US"))
        for path in ["/", "/u", "/usa", "/US", "/watch/x", "/1a"] { #expect(d(p, "https://regional.example" + path, redirect: true, origin: "site.example") == .openExternally, Comment(rawValue: path)) }
        for o in ["go.example", "login.example"] { #expect(d(p, "https://regional.example/us", redirect: true, origin: o) == .openExternally, Comment(rawValue: o)) }
        let none = ProviderURLPolicy(hostRules: [HostRule(suffix: "site.example", role: .site)], inAppSchemes: ["https"])
        #expect(none.regionNoticeHosts.isEmpty && d(none, "https://regional.example/us", redirect: true, origin: "site.example") == .openExternally)
        #expect(!RegionNoticeHost(host: "x.example", pathPattern: "([").isWellFormed)
        // a policy with no path rule is untouched by the path logic: any path of the host loads, a trailing-dot or odd path included
        #expect(d(none, "https://site.example//a/../b") == .allowInApp)
    }

    @Test func theRegistryRejectsRegionalHostsThatAreNotExactOrOverlapTheSiteOrAreNotHTTPS() {
        let base = ProviderCatalog.jiohotstar
        let ok = RegionNoticeHost(host: "hotstar.com", pathPattern: RegionNoticeHost.countryPathExceptIn)
        func issues(_ notice: [RegionNoticeHost], schemes: Set<String> = ["https"], anyPort: Bool = false) -> [RegistryIssue] {
            let p = ProviderURLPolicy(hostRules: base.urlPolicy.hostRules, inAppSchemes: schemes, allowsAnyPort: anyPort, regionNoticeHosts: notice)
            return ProviderRegistry.validate([base.replacing(urlPolicy: p, homeURL: base.homeURL)])
        }
        #expect(issues([ok]).isEmpty)
        for bad in ["*.hotstar.com", ".hotstar.com", "hotstar.com/us", "hotstar.com:443", "", "jiohotstar.com", "www.jiohotstar.com", "a b.com"] {
            #expect(issues([RegionNoticeHost(host: bad, pathPattern: RegionNoticeHost.countryPathExceptIn)]) == [.invalidRegionNoticeHost(.jiohotstar)], Comment(rawValue: bad))
        }
        // path-aware overlap: a notice with no shape, or a shape that can match "/in", would classify the official path as regional
        #expect(issues([RegionNoticeHost(host: "hotstar.com")]) == [.invalidRegionNoticeHost(.jiohotstar)])
        #expect(issues([RegionNoticeHost(host: "hotstar.com", pathPattern: "^/[a-z]{2}(/|$)")]) == [.invalidRegionNoticeHost(.jiohotstar)])
        #expect(issues([RegionNoticeHost(host: "hotstar.com", pathPattern: "([")]) == [.invalidRegionNoticeHost(.jiohotstar)])
        #expect(issues([ok], schemes: ["http"]).contains(.invalidRegionNoticeHost(.jiohotstar)), "https only (the home address is then refused too, which is also reported)")
        #expect(issues([ok], anyPort: true) == [.invalidRegionNoticeHost(.jiohotstar)], "default port only")
        // a home address outside the official path is refused by the registry
        let p = ProviderURLPolicy(hostRules: base.urlPolicy.hostRules, inAppSchemes: ["https"], regionNoticeHosts: [ok])
        #expect(ProviderRegistry.validate([base.replacing(urlPolicy: p, homeURL: URL(string: "https://www.hotstar.com/us")!)]).contains(.homeHostNotAllowed(.jiohotstar)))
    }

    // MARK: (j) wording

    private func table(_ code: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localization/\(code).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String], "\(code) did not parse")
    }

    @Test func theRestrictionWordingNamesTheServiceTheHostAndKeepsTheFourThingsApart() {
        let c = ServiceFailureCopy.text(for: .regionRestricted(host: "www.hotstar.com", label: nil), name: "JioHotstar", offersBrowser: false)
        #expect(c.title == "JioHotstar sent this connection to another region")
        #expect(c.message == "JioHotstar chooses which regional site to show from the network location it sees.\nRegional page: www.hotstar.com\nStreamSetu does not change or hide your location, and this app opens only JioHotstar.")
        let us = ServiceFailureCopy.text(for: .regionRestricted(host: "www.hotstar.com", label: "US"), name: "JioHotstar", offersBrowser: false, officialSite: "hotstar.com/in").message
        #expect(us.contains("Regional page: www.hotstar.com (US)") && us.contains("This is JioHotstar's old United States page.") && us.hasSuffix("opens only hotstar.com/in."))
        let uk = ServiceFailureCopy.text(for: .regionRestricted(host: "www.hotstar.com", label: "UK"), name: "JioHotstar", offersBrowser: false).message
        #expect(uk.contains("(UK)") && !uk.contains("old United States"))
        for claim in ["policy", "bundle", "Disney", "not available", "unavailable"] { #expect(!c.message.contains(claim), Comment(rawValue: claim)) }
        let lines = ServiceFailureCopy.regionSeparation(name: "JioHotstar", profile: ProviderCatalog.jiohotstar.regionProfile)
        #expect(lines == ["Preferred region: India (en_IN)", "Network location: decided by your connection, not checked by StreamSetu",
                          "Service region: decided by JioHotstar", "Playback: decided by JioHotstar"])
        #expect(ServiceFailureCopy.regionSeparation(name: "X", profile: nil).count == 3, "a service with no preference shows no preference line")
        for text in [c.title, c.message] + lines { for word in ["verified", "eligible", "unlock", "bypass", "vpn"] { #expect(!text.lowercased().contains(word), Comment(rawValue: text)) } }
    }

    @Test func theNewWordingHasHindiAndTeluguWithOnePlaceholderEach() throws {
        let hi = try table("hi"), te = try table("te")
        let keys = ["%@ sent this connection to another region", "%@ chooses which regional site to show from the network location it sees.", "This is %@'s old United States page.",
                    "Regional page: %@", "StreamSetu does not change or hide your location, and this app opens only %@.", "Network location: decided by your connection, not checked by StreamSetu",
                    "Service region: decided by %@", "Playback: decided by %@", "Redirect chain: %@", "redirect hop %lld", "provider regional page reached",
                    RegionProfile.india.noteKey]
        for k in keys {
            #expect(hi[k] != nil && te[k] != nil, "no Hindi/Telugu for: \(k)")
            #expect(hi[k] != k && te[k] != k, "not translated: \(k)")
            for t in [hi, te] { #expect((t[k] ?? "").components(separatedBy: "%@").count <= 2, "one placeholder: \(k)") }
        }
        #expect(hi["Available in India; from outside India the service may redirect to a page this app does not open. StreamSetu does not change your location."] == nil, "the old note is replaced")
        #expect(Set(hi.keys) == Set(te.keys))
    }

    @Test func theSettingsDiagnosticsShowTheChainAndTheRegionalPageAsHostsOnly() {
        let diag = ServiceDiagnostics()
        diag.recordRedirectHop(.jiohotstar, host: "www.jiohotstar.com", index: 0)
        diag.recordRedirectHop(.jiohotstar, host: "WWW.Hotstar.com", index: 1)
        diag.recordRegionalPage(.jiohotstar, host: "www.hotstar.com")
        let suite = UserDefaults(suiteName: "reddy-region-restriction-\(UUID().uuidString)")!
        let m = StreamingServicesSettingsModel(defaults: suite, diagnostics: diag)
        #expect(m.redirectChainLine(.jiohotstar) == "Redirect chain: www.jiohotstar.com -> www.hotstar.com")
        #expect(m.diagnosticLines(.jiohotstar) == ["www.jiohotstar.com: redirect hop 1", "www.hotstar.com: redirect hop 2", "www.hotstar.com: provider regional page reached"])
        #expect(m.redirectChainLine(.hulu) == nil)
        // a later chain replaces the earlier one in the summary
        diag.recordRedirectHop(.jiohotstar, host: "a.example", index: 0); diag.recordRedirectHop(.jiohotstar, host: "b.example", index: 1)
        #expect(diag.lastRedirectChain(for: .jiohotstar) == ["a.example", "b.example"])
    }

    @Test func noRegionSignalOrWorkspaceCallWasAddedAndTheRuntimeNamesNoProvider() throws {
        let src = try ServiceSources.text(["Services/Streaming/Runtime", "Services/Streaming/Policy"])
        for banned in ["Accept-Language", "setValue(", "CLLocation", "navigator.language", "NSWorkspace.shared.open(url)"] { #expect(!src.contains(banned), Comment(rawValue: banned)) }
        #expect(src.contains("didReceiveServerRedirectForProvisionalNavigation"), "the supported redirect callback is used")
        let runtime = try ServiceSources.text(["Services/Streaming/Runtime"])
        for id in ProviderCatalog.all.map(\.id.rawValue) { #expect(!runtime.lowercased().contains("\"\(id)\""), Comment(rawValue: id)) }
    }
}
