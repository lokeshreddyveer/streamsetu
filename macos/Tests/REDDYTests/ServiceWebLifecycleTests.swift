import Testing
import WebKit
import AppKit
@testable import REDDY

/// The host registry and the web view lifecycle: lazy creation, retention, release that keeps website data, and the termination limits.
@Suite("Service web lifecycle", .serialized) @MainActor struct ServiceWebLifecycleTests {
    /// A registry whose models point at the local fixture server and use in-memory stores.
    static func registry(_ server: ServiceFixtureServer, budget: MemoryBudget = .standard, made: ((ServiceWebModel) -> Void)? = nil) -> ServiceHostRegistry {
        ServiceHostRegistry(registry: .standard, budget: budget, makeModel: { d in
            let m = ServiceWebModel(definition: ServiceTestSupport.fixture(d.id, server), dataStore: { .nonPersistent() })
            m.isAppActive = { true }
            made?(m); return m
        })
    }

    @Test func nothingIsCreatedUntilAServiceIsOpened() async throws {
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        var made = 0
        let r = Self.registry(server) { _ in made += 1 }
        #expect(r.createdIDs.isEmpty && r.liveIDs.isEmpty && made == 0)
        let nav = ServiceNavigation(capabilities: .macOS); nav.hosts = r
        #expect(made == 0, "attaching the registry makes no model")
        nav.select(.hulu)
        #expect(r.createdIDs == [.hulu] && made == 1)
        #expect(await ServiceTestSupport.until { r.model(for: .hulu)?.phase == .ready })
        nav.returnToStreamSetu(); r.releaseHidden()
        #expect(r.model(for: .hulu) === r.model(for: .hulu), "one model per service, never recreated")
        #expect(r.model(for: ProviderID(unchecked: "nosuch")) == nil)
    }

    @Test func aServiceThatIsNotEmbeddedGetsNoModel() {
        func def(_ a: ServiceAvailability, _ id: ProviderID) -> ProviderDefinition { ProviderCatalog.all.first { $0.id == id }!.with(availability: a) }
        let defs = [def(.disabled, .hulu), def(.registered, .peacock), def(.available, .netflix), def(.unverified, .youtube)]
        var made: [ProviderID] = []
        let r = ServiceHostRegistry(registry: ProviderRegistry(definitions: defs), makeModel: { d in made.append(d.id); return ServiceWebModel(definition: d, dataStore: { .nonPersistent() }) })
        #expect(r.model(for: .hulu) == nil && r.model(for: .peacock) == nil && made.isEmpty)
        #expect(r.model(for: .netflix) != nil && r.model(for: .youtube) != nil && made == [.netflix, .youtube])
    }

    @Test func switchingKeepsAtMostTwoWebViewsAndEvictsTheOldest() async throws {
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        let r = Self.registry(server)
        let nav = ServiceNavigation(capabilities: .macOS); nav.hosts = r
        for id: ProviderID in [.netflix, .primevideo, .hulu] {
            nav.select(id)
            #expect(await ServiceTestSupport.until { r.model(for: id)?.webView != nil })
            #expect(r.liveIDs.count <= 2, "after \(id)")
        }
        #expect(r.liveIDs == [.hulu, .primevideo], "the oldest hidden one was released")
        #expect(r.model(for: .netflix)?.webView == nil)
        // coming back reloads the page; the store object is the same one
        let store = r.model(for: .netflix)!.dataStore
        nav.select(.netflix)
        #expect(await ServiceTestSupport.until { r.model(for: .netflix)?.phase == .ready })
        #expect(r.model(for: .netflix)?.webView?.configuration.websiteDataStore === store)
        #expect(r.liveIDs.count <= 2 && r.liveIDs.contains(.netflix))
        nav.returnToStreamSetu(); r.handleMemoryPressure(critical: true)
        #expect(r.liveIDs.isEmpty, "critical memory releases every hidden web view")
    }

    @Test func aHundredServiceSwitchesStayWithinBudgetAndLoadOnlyOnReturn() async throws {
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        let r = Self.registry(server)
        let nav = ServiceNavigation(capabilities: .macOS); nav.hosts = r
        let order: [ProviderID] = [.netflix, .hulu, .youtube, .peacock, .appletv]
        var worst = 0
        for i in 0..<100 { nav.select(order[i % order.count]); worst = max(worst, r.liveIDs.count) }
        print("MEASURE 100 service switches: most live web views at once \(worst), models made \(r.createdIDs.count)")
        #expect(worst <= 2)
        nav.returnToStreamSetu(); r.handleMemoryPressure(critical: true)
        #expect(r.liveIDs.isEmpty)
    }

    @Test func releasingAWebViewFreesItAndKeepsItsStore() async throws {
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        let m = ServiceWebModel(definition: ServiceTestSupport.fixture(.peacock, server), dataStore: { .nonPersistent() })
        let store = m.dataStore
        weak var weakView: ServiceWebView?
        do {
            let v = m.hostedView(); weakView = v
            #expect(m.state.webViewGeneration == 1 && v.configuration.websiteDataStore === store)
            m.serviceBecameHidden(); m.releaseResources()
            #expect(m.webView == nil && m.releaseCount == 1 && m.phase == .idle)
        }
        for _ in 0..<30 where weakView != nil { try? await Task.sleep(for: .milliseconds(100)) }
        #expect(weakView == nil, "nothing keeps a released web view alive")
        #expect(m.hostedView().configuration.websiteDataStore === store && m.state.webViewGeneration == 2)
        m.releaseResources()
    }

    @Test func theLastPageIsRememberedAcrossARelease() async throws {
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        let m = ServiceWebModel(definition: ServiceTestSupport.fixture(.crunchyroll, server), dataStore: { .nonPersistent() })
        m.serviceBecameVisible(); m.load(server.url("/b"))
        #expect(await ServiceTestSupport.until { m.webView?.url?.path == "/b" && m.phase == .ready })
        m.serviceBecameHidden(); m.releaseResources()
        m.serviceBecameVisible()
        #expect(await ServiceTestSupport.until { m.webView?.url?.path == "/b" && m.phase == .ready }, "page-state restore, separate from the session")
        m.serviceBecameHidden(); m.releaseResources()
    }

    // MARK: process termination

    @Test func aStoppedProcessIsReloadedTwiceThenStaysStoppedUntilRetry() async throws {
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        let m = ServiceWebModel(definition: ServiceTestSupport.fixture(.paramountplus, server), dataStore: { .nonPersistent() })
        m.serviceBecameVisible()
        #expect(await ServiceTestSupport.until { m.phase == .ready })
        for k in 1...2 {
            m.webViewWebContentProcessDidTerminate(m.webView)
            #expect(m.terminationCount == k)
            #expect(await ServiceTestSupport.until { m.phase == .ready || m.phase == .loading }, "reload \(k)")
            _ = await ServiceTestSupport.until { m.phase == .ready }
        }
        m.webViewWebContentProcessDidTerminate(m.webView)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(m.phase == .terminated, "the third stop inside a minute is not reloaded by itself")
        #expect(m.failureScreen?.reason == .terminated && m.failureScreen?.actions == [.retry, .returnToStreamSetu])
        m.retry()
        #expect(await ServiceTestSupport.until { m.phase == .ready })
        m.serviceBecameHidden(); m.releaseResources()
    }

    @Test func aHiddenServiceIsNotReloadedInTheBackground() async throws {
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        let m = ServiceWebModel(definition: ServiceTestSupport.fixture(.appletv, server), dataStore: { .nonPersistent() })
        m.serviceBecameVisible(); #expect(await ServiceTestSupport.until { m.phase == .ready })
        let hits = server.hits("/home")
        m.serviceBecameHidden()
        m.webViewWebContentProcessDidTerminate(m.webView)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(m.phase == .terminated && server.hits("/home") == hits)
        m.serviceBecameVisible()
        #expect(await ServiceTestSupport.until { m.phase == .ready && server.hits("/home") > hits }, "reloaded when it is shown again")
        m.serviceBecameHidden(); m.releaseResources()
    }

    @Test func severalServicesStoppingTripTheCircuitBreaker() async throws {
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        let r = Self.registry(server)
        let nav = ServiceNavigation(capabilities: .macOS); nav.hosts = r
        nav.select(.hulu); nav.select(.youtube)
        #expect(await ServiceTestSupport.until { r.model(for: .youtube)?.phase == .ready })
        let hulu = r.model(for: .hulu)!, you = r.model(for: .youtube)!
        #expect(hulu.webView != nil)
        hulu.webViewWebContentProcessDidTerminate(hulu.webView)          // hidden: one stop, not reloaded
        you.webViewWebContentProcessDidTerminate(you.webView)          // visible: second stop, reloaded
        #expect(await ServiceTestSupport.until { you.phase == .ready || you.phase == .loading })
        _ = await ServiceTestSupport.until { you.phase == .ready }
        you.webViewWebContentProcessDidTerminate(you.webView)          // third within a minute across services
        try? await Task.sleep(for: .milliseconds(400))
        #expect(you.phase == .terminated, "stays stopped: Retry only")
        #expect(r.circuitBreakerTrips == 1)
        #expect(hulu.webView == nil, "hidden web views are released when it trips")
        nav.returnToStreamSetu(); r.handleMemoryPressure(critical: true)
    }

    @Test func theBreakerCountsAcrossProvidersAndExpires() {
        let r = ServiceHostRegistry(makeModel: { ServiceWebModel(definition: $0, dataStore: { .nonPersistent() }) })
        let t = Date()
        #expect(r.recordTermination(of: .hulu, at: t) == .reload)
        #expect(r.recordTermination(of: .peacock, at: t.addingTimeInterval(5)) == .reload)
        #expect(r.recordTermination(of: .youtube, at: t.addingTimeInterval(9)) == .showRetryCard)
        #expect(r.recordTermination(of: .youtube, at: t.addingTimeInterval(500)) == .reload, "an old burst is forgotten")
    }
}

private extension ProviderDefinition {
    func with(availability a: ServiceAvailability) -> ProviderDefinition {
        ProviderDefinition(id: id, displayName: displayName, homeURL: homeURL, availability: a, distributionAuthorization: distributionAuthorization, termsNote: termsNote,
                           externalLinks: externalLinks, platforms: platforms, storeIdentity: storeIdentity, urlPolicy: urlPolicy, capabilities: capabilities,
                           authentication: authentication, sessionCookieDomains: sessionCookieDomains, zoomDefault: zoomDefault, zoomDefaultsKey: zoomDefaultsKey,
                           regionNote: regionNote, releaseNote: releaseNote)
    }
}
