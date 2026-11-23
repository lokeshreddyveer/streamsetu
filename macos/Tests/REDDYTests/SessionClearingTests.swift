import Testing
import WebKit
@testable import REDDY

/// Clearing one service's website data touches that store only. Persistent fixture stores under random identifiers; never a real session.
@Suite("Session clearing", .serialized) @MainActor struct SessionClearingTests {
    private func cookie(_ name: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: "v", .domain: "127.0.0.1", .path: "/", .expires: Date().addingTimeInterval(3600)])!
    }

    @Test func clearingOneStoreLeavesTheOtherAlone() async {
        let idA = UUID(), idB = UUID()
        let a = WKWebsiteDataStore(forIdentifier: idA), b = WKWebsiteDataStore(forIdentifier: idB)
        await a.httpCookieStore.setCookie(cookie("a")); await b.httpCookieStore.setCookie(cookie("b"))
        let na = await a.httpCookieStore.allCookies().count, nb = await b.httpCookieStore.allCookies().count
        #expect(na == 1 && nb == 1)
        let report = await SessionClearing.clear(a)
        #expect(report.remainingRecordCount == 0)
        let aLeft = await a.httpCookieStore.allCookies().count, bLeft = await b.httpCookieStore.allCookies().count
        #expect(aLeft == 0)
        #expect(bLeft == 1, "the other service stays signed in")
        _ = await SessionClearing.clear(b)
        await TestIsolatedDataStoreProvider.removeFixture(idA); await TestIsolatedDataStoreProvider.removeFixture(idB)
    }

    @Test func clearingAModelReleasesItsWebViewAndKeepsOtherModelsSignedIn() async throws {
        _ = NSApplication.shared
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        let idA = UUID(), idB = UUID()
        defer { Task { await TestIsolatedDataStoreProvider.removeFixture(idA); await TestIsolatedDataStoreProvider.removeFixture(idB) } }
        let a = ServiceWebModel(definition: ServiceTestSupport.fixture(.primevideo, server), dataStoreProvider: TestIsolatedDataStoreProvider(persistentFixture: idA))
        let b = ServiceWebModel(definition: ServiceTestSupport.fixture(.hulu, server), dataStoreProvider: TestIsolatedDataStoreProvider(persistentFixture: idB))
        await b.dataStore.httpCookieStore.setCookie(cookie("keep"))
        a.serviceBecameVisible(); a.load(server.url("/cookie-set"))
        #expect(await ServiceTestSupport.until { a.webView?.title == "set" })
        #expect(await ServiceTestSupport.until { a.hasSession })
        let generation = a.state.webViewGeneration
        await a.clearServiceData()
        #expect(!a.hasSession)
        #expect(a.releaseCount >= 1, "the web view was released before the data was cleared")
        #expect(await ServiceTestSupport.until { a.webView != nil && a.state.webViewGeneration > generation }, "it shows the home page again")
        let bLeft = await b.dataStore.httpCookieStore.allCookies().count
        #expect(bLeft == 1, "no other service is touched")
        a.serviceBecameHidden(); a.releaseResources(); b.releaseResources()
        _ = await SessionClearing.clear(b.dataStore)
    }

    @Test func releasingAWebViewKeepsTheSessionOfAPersistentStore() async throws {
        _ = NSApplication.shared
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        let id = UUID(); defer { Task { await TestIsolatedDataStoreProvider.removeFixture(id) } }
        let first = ServiceWebModel(definition: ServiceTestSupport.fixture(.disneyplus, server), dataStoreProvider: TestIsolatedDataStoreProvider(persistentFixture: id))
        first.serviceBecameVisible(); first.load(server.url("/cookie-set"))
        #expect(await ServiceTestSupport.until { first.webView?.title == "set" })
        first.serviceBecameHidden(); first.releaseResources()
        #expect(first.webView == nil)
        let second = ServiceWebModel(definition: ServiceTestSupport.fixture(.disneyplus, server), dataStoreProvider: TestIsolatedDataStoreProvider(persistentFixture: id))
        second.serviceBecameVisible(); second.load(server.url("/cookie-echo"))
        #expect(await ServiceTestSupport.until { second.webView?.title == "cookie:sid=abc123" }, "a new model on the same store is still signed in")
        second.serviceBecameHidden(); second.releaseResources()
        _ = await SessionClearing.clear(second.dataStore)
    }
}
