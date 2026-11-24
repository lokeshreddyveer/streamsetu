import Testing
import WebKit
import AppKit
@testable import REDDY

/// Fixes from the independent review of the streaming hub: honest clearing results, the browser command only where it works, no cookie reads,
/// no web view made during a clear, one open route, and in-memory stores for every test run.
@Suite("Service review fixes", .serialized) @MainActor struct ServiceReviewFixesTests {
    @Test func aClearThatLeavesRecordsIsReportedAsFailedNeverAsCleared() {
        #expect(ServiceDataClearing.outcome(of: .init(remainingRecordCount: 0)) == .cleared)
        #expect(ServiceDataClearing.outcome(of: .init(remainingRecordCount: 2)) == .failed)
    }

    @Test func clearingAModelReturnsTheStoresRealReport() async {
        let m = ServiceWebModel(definition: ProviderCatalog.all.first { $0.id == .hulu }!, dataStore: { .nonPersistent() })
        let r = await m.clearServiceDataReporting()
        #expect(r.remainingRecordCount == 0)
        let src = (try? String(contentsOf: ServiceSources.root.appendingPathComponent("Services/Streaming/Runtime/ServiceWebModel.swift"), encoding: .utf8)) ?? ""
        #expect(src.contains("let report = await SessionClearing.clear(dataStore)") && src.contains("return report"), "the report is no longer thrown away")
    }

    @Test func theBrowserCommandExistsForNetflixOnly() {
        for d in ProviderCatalog.all {
            let m = ServiceWebModel(definition: d, dataStore: { .nonPersistent() })
            #expect(m.canOpenInBrowser == (d.id == .netflix), Comment(rawValue: d.id.rawValue))
        }
        let menu = try? String(contentsOf: ServiceSources.root.appendingPathComponent("Application/MenuCommands.swift"), encoding: .utf8)
        #expect(menu?.contains("host?.canOpenInBrowser != true).atlas(\"menu.services.openInBrowser\")") == true)
        #expect(menu?.contains("netflix: NetflixWebModel") == false, "the legacy parameter is gone")
    }

    @Test func atlasSaysTheBrowserCommandIsNetflixOnly() throws {
        let t = try String(contentsOf: ServiceSources.root.appendingPathComponent("Atlas/Declarations/Menus.swift"), encoding: .utf8)
        let line = try #require(t.components(separatedBy: "\n").first { $0.contains("\"services.openInBrowser\"") })
        #expect(line.contains("Netflix only") && line.contains("greyed out"))
    }

    /// Cookies are never read: no cookie object, name or value is fetched anywhere in the streaming code. Only website-data records (a site name
    /// and the kinds of data) are looked at, and the cookie observer only learns that something changed.
    @Test func noStreamingCodeReadsCookieObjectsNamesOrValues() throws {
        let src = try ServiceSources.text(["Services/Streaming/Runtime", "Services/Streaming/Session", "Services/Streaming/Policy", "Services/Streaming/Domain",
                                           "Features/Streaming", "Features/Netflix", "Features/Settings/Views"], excluding: ["TestIsolatedDataStoreProvider.swift"])
        for banned in ["allCookies", "getAllCookies", "[HTTPCookie]", ": HTTPCookie", "HTTPCookie(", "HTTPCookie.", ".cookies(", "document.cookie", "cookie.value", "cookie.name", "evaluateJavaScript"] {
            #expect(!src.contains(banned), Comment(rawValue: "found \(banned)"))
        }
        #expect(src.contains("dataRecords(ofTypes: [WKWebsiteDataTypeCookies])"))
    }

    @Test func theSessionFlagUsesTheRecordsSiteNameAndTheSessionDomains() {
        let apple = ProviderCatalog.all.first { $0.id == .appletv }!
        #expect(ServiceWebModel.recordBelongs("apple.com", to: apple), "the session domain of Apple TV is apple.com")
        #expect(ServiceWebModel.recordBelongs(".apple.com", to: apple))
        #expect(!ServiceWebModel.recordBelongs("evilapple.com", to: apple))
        #expect(!ServiceWebModel.recordBelongs("example.com", to: apple))
        let nf = ProviderCatalog.netflix
        #expect(ServiceWebModel.recordBelongs("netflix.com", to: nf) && !ServiceWebModel.recordBelongs("netflix.com.evil.com", to: nf))
    }

    @Test func everyProviderOffersASessionDomainThatItsRecordsCanMatch() {
        for d in ProviderCatalog.all {
            #expect(!d.sessionCookieDomains.isEmpty, Comment(rawValue: d.id.rawValue))
            #expect(d.sessionCookieDomains.contains { ServiceWebModel.recordBelongs($0, to: d) }, Comment(rawValue: d.id.rawValue))
        }
    }

    @Test func theHostViewOnlyAttachesAnExistingWebView() throws {
        let src = try String(contentsOf: ServiceSources.root.appendingPathComponent("Features/Streaming/ServiceHostView.swift"), encoding: .utf8)
        #expect(!src.contains("model.hostedView()"), "a view update never makes a web view")
        #expect(src.contains("model.webView"))
    }

    @Test func noWebViewIsMadeWhileTheDataIsBeingCleared() async throws {
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        _ = NSApplication.shared
        let m = ServiceWebModel(definition: ServiceTestSupport.fixture(.hulu, server), dataStore: { .nonPersistent() })
        m.serviceBecameVisible()
        #expect(await ServiceTestSupport.until { m.phase == .ready })
        let before = m.state.webViewGeneration
        let clearing = Task { await m.clearServiceData() }
        m.serviceBecameVisible()          // shown again mid-clear (a route back into the service)
        #expect(m.webView == nil || m.state.webViewGeneration == before, "no web process starts on a store that is being cleared")
        await clearing.value
        #expect(await ServiceTestSupport.until { m.webView != nil }, "after the clear the page is made once")
        m.serviceBecameHidden(); m.releaseResources()
    }

    @Test func pinnedBarAndDropdownShareOneOpenRoute() throws {
        let root = try String(contentsOf: ServiceSources.root.appendingPathComponent("Application/RootView.swift"), encoding: .utf8)
        #expect(root.contains("onSelectService: { servicesNav.select($0) }"))
        #expect(!root.contains("onSelectService: { services.select($0)"))
    }

    @Test func pinnedItemsDragAsAPrivateTypeNotText() throws {
        let src = try String(contentsOf: ServiceSources.root.appendingPathComponent("Features/Streaming/PinnedServicesBar.swift"), encoding: .utf8)
        #expect(!src.contains(".draggable(id.rawValue)") && !src.contains("dropDestination(for: String.self)"))
        #expect(src.contains("PinnedServiceDrag"))
    }

    @Test func aTestRunNeverGivesAServiceItsRealStore() {
        for d in ProviderCatalog.all {
            let m = ServiceWebModel.forApp(d, environment: ["STREAMSETU_TESTING": "1"])
            #expect(!m.dataStore.isPersistent, Comment(rawValue: d.id.rawValue))
        }
    }

    @Test func memoryPressureReachesTheRegistryPlan() throws {
        let r = ServiceHostRegistry(makeModel: { ServiceWebModel(definition: $0, dataStore: { .nonPersistent() }) })
        let m = try #require(r.model(for: .hulu))
        #expect(m.onMemoryPressure != nil, "the shipped path goes through the registry's retention plan")
        #expect(ServiceWebModel(definition: ProviderCatalog.netflix, dataStore: { .nonPersistent() }).onMemoryPressure == nil)
        #expect(MemoryBudget.standard.hiddenTTL == .seconds(30 * 60))
    }

    /// Redirect-only hosts: the policy lets them through only when the load is a redirect (WebKit has no public redirect flag; see the delegate).
    @Test func everyRedirectOnlyHostIsReachedByRedirectNeverByLink() {
        var seen = 0
        for d in ProviderCatalog.all {
            for rule in d.urlPolicy.hostRules where rule.role == .redirectOnly && rule.active {
                seen += 1
                let u = URL(string: "https://www.\(rule.suffix)/x")!
                #expect(d.urlPolicy.decide(u, isMainFrame: true) != .allowInApp, Comment(rawValue: "\(rule.suffix) by link"))
                #expect(d.urlPolicy.decide(u, isMainFrame: true, isRedirect: true) == .allowInApp, Comment(rawValue: "\(rule.suffix) by redirect"))
            }
        }
        #expect(seen == 3)          // youtu.be, consent.google.com (consent.youtube.com is already a youtube.com host), spotify.link
        let src = try? String(contentsOf: ServiceSources.root.appendingPathComponent("Services/Streaming/Runtime/ServiceWebDelegates.swift"), encoding: .utf8)
        #expect(src?.contains("Known limit") == true, "the limit of the redirect signal stays written down next to the code")
    }
}
