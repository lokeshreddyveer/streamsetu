import Testing
import WebKit
import AppKit
@testable import REDDY

/// The one web model, run through different definitions: the first service (links confirmed first) and every service that never leaves the
/// app. Local fixtures only; no real site, no real session.
@Suite("Service web model", .serialized) @MainActor struct ServiceWebModelTests {
    @MainActor final class Rig {
        let server: ServiceFixtureServer
        let model: ServiceWebModel
        var opened: [URL] = []
        let window: NSWindow
        init(_ id: ProviderID, server: ServiceFixtureServer? = nil, slowAfter: Duration = .seconds(8)) async throws {
            _ = NSApplication.shared
            self.server = try server ?? ServiceFixtureServer()
            if server == nil { try await self.server.start() }
            model = ServiceWebModel(definition: ServiceTestSupport.fixture(id, self.server), dataStore: { .nonPersistent() }, slowAfter: slowAfter)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            model.isAppActive = { true }
        }
        func show() { model.serviceBecameVisible(); window.contentView = model.hostedView(); model.hostedView().frame = window.contentView!.bounds }
        func finish() { model.serviceBecameHidden(); model.releaseResources(); window.contentView = nil; server.stop() }
        var title: String { model.webView?.title ?? "" }
        var url: String { model.webView?.url?.path ?? "" }
    }

    nonisolated static let services: [ProviderID] = [.netflix, .primevideo, .youtube]

    @Test(arguments: services) func loadsRedirectsAndNamesItselfFromTheDefinition(_ id: ProviderID) async throws {
        let rig = try await Rig(id); defer { rig.finish() }
        #expect(rig.model.webView == nil && rig.model.phase == .idle, "nothing is created until the service is shown")
        rig.show()
        #expect(await ServiceTestSupport.until { rig.model.phase == .ready })
        #expect(await ServiceTestSupport.until { rig.title == "home" })          // the title follows the page being ready
        #expect(rig.model.webView?.accessibilityLabel() == rig.model.definition.displayName)
        rig.model.load(rig.server.url("/redirect"))
        #expect(await ServiceTestSupport.until { rig.url == "/home" && rig.model.phase == .ready })
    }

    @Test(arguments: services) func aServerErrorIsAFailureWithARetry(_ id: ProviderID) async throws {
        let rig = try await Rig(id); defer { rig.finish() }
        rig.show(); _ = await ServiceTestSupport.until { rig.model.phase == .ready }
        rig.model.load(rig.server.url("/500"))
        #expect(await ServiceTestSupport.until { rig.model.phase == .failed(.siteUnavailable(status: 500)) })
        let screen = try #require(rig.model.failureScreen)
        #expect(screen.serviceName == rig.model.definition.displayName)
        rig.model.retry()
        #expect(await ServiceTestSupport.until { rig.server.hits("/500") >= 2 })
    }

    // MARK: external links, by configuration

    @Test func theFirstServiceStillAsksBeforeLeaving() async throws {
        let rig = try await Rig(.netflix); defer { rig.finish() }
        rig.model.openExternal = { rig.opened.append($0) }
        rig.show(); _ = await ServiceTestSupport.until { rig.model.phase == .ready }
        rig.model.load(rig.server.url("/redirect-out"))
        #expect(await ServiceTestSupport.until { rig.model.pendingExternal != nil })
        #expect(rig.opened.isEmpty && rig.model.blockedLinkHost == nil)
        #expect(rig.model.failureScreen == nil)
        #expect(ServiceFailureScreen(phase: .terminated, definition: rig.model.definition)?.actions == [.retry, .openInDefaultBrowser])
    }

    @Test(arguments: [ProviderID.primevideo, .hulu, .crunchyroll]) func aServiceThatNeverLeavesTheAppCancelsOffSiteLinksWithANotice(_ id: ProviderID) async throws {
        let rig = try await Rig(id); defer { rig.finish() }
        var launches = 0
        #expect(rig.model.openExternal == nil, "no opener exists")
        rig.model.openExternal = { _ in launches += 1 }          // even a counting opener put in by a test is never reached
        rig.show(); _ = await ServiceTestSupport.until { rig.model.phase == .ready }
        rig.model.load(rig.server.url("/redirect-out"))
        #expect(await ServiceTestSupport.until { rig.model.blockedLinkHost == "localhost" })
        #expect(rig.model.pendingExternal == nil)
        #expect(await ServiceTestSupport.until { rig.model.webView?.url?.host != "localhost" })
        rig.model.dismissBlockedLink(); #expect(rig.model.blockedLinkHost == nil)
        // a pop-up to another host and a mailto link
        rig.model.load(rig.server.url("/popup")); _ = await ServiceTestSupport.until { rig.title == "popup" }
        _ = try? await rig.model.webView?.evaluateJavaScript("document.getElementById('x').click()")          // test-only click on a fixture
        #expect(await ServiceTestSupport.until { rig.model.blockedLinkHost == "localhost" })
        rig.model.dismissBlockedLink()
        rig.model.load(rig.server.url("/links")); _ = await ServiceTestSupport.until { rig.title == "links" }
        _ = try? await rig.model.webView?.evaluateJavaScript("document.getElementById('mail').click()")
        #expect(await ServiceTestSupport.until { rig.model.blockedLinkHost != nil })
        rig.model.openInDefaultBrowser(); rig.model.confirmExternal()
        #expect(launches == 0 && rig.opened.isEmpty, "nothing was launched")
        #expect(ServiceFailureScreen(phase: .terminated, definition: rig.model.definition)?.actions == [.retry, .returnToStreamSetu])
    }

    @Test func everyServiceThatNeverLeavesTheAppHoldsNoOpener() {
        let blocking = ServiceTestSupport.blocking
        #expect(blocking.count == 9)
        for d in blocking {
            let m = ServiceWebModel(definition: d, dataStore: { .nonPersistent() }, openExternal: { _ in Issue.record("launched") })
            #expect(m.openExternal == nil, "\(d.id)")
        }
        #expect(ServiceWebModel(definition: ProviderCatalog.netflix, dataStore: { .nonPersistent() }).openExternal != nil)
    }

    @Test func theRuntimeNamesNoServiceAndNoWorkspaceCallOutsideTheOpenerLine() throws {
        let src = try ServiceSources.text(["Services/Streaming/Runtime", "Services/Streaming/Session"])
        for id in ProviderCatalog.all.map(\.id.rawValue) { #expect(!src.lowercased().contains("\"\(id)\""), "provider id \(id) named in the generic runtime") }
        #expect(src.components(separatedBy: "NSWorkspace").count == 2, "one place, the default opener of a service that confirms first")
        for forbidden in ["WKScriptMessageHandler", "addScriptMessageHandler", "WKUserScript", "evaluateJavaScript", "callAsyncJavaScript"] { #expect(!src.contains(forbidden), "\(forbidden)") }
    }

    // MARK: configuration and compatibility

    @Test func theUITestOverridePointsAnyServiceAtALocalPage() throws {
        let env = ["STREAMSETU_TESTING": "1", "STREAMSETU_SERVICE_TEST_URL": "http://127.0.0.1:9/x"]
        let m = ServiceWebModel.forApp(ProviderCatalog.hulu, environment: env)
        #expect(m.homeURL.absoluteString == "http://127.0.0.1:9/x" && !m.dataStore.isPersistent)
        let legacy = ServiceWebModel.forApp(ProviderCatalog.netflix, environment: ["STREAMSETU_TESTING": "1", "STREAMSETU_NETFLIX_TEST_URL": "http://127.0.0.1:9/n"])
        #expect(legacy.homeURL.absoluteString == "http://127.0.0.1:9/n")
        let other = ServiceWebModel.forApp(ProviderCatalog.hulu, environment: ["STREAMSETU_TESTING": "1", "STREAMSETU_NETFLIX_TEST_URL": "http://127.0.0.1:9/n"])
        #expect(other.homeURL == ProviderCatalog.hulu.homeURL, "one service's override never applies to another")
        let remote = ServiceWebModel.forApp(ProviderCatalog.hulu, environment: ["STREAMSETU_TESTING": "1", "STREAMSETU_SERVICE_TEST_URL": "https://example.com/"])
        #expect(remote.homeURL == ProviderCatalog.hulu.homeURL, "only a loopback address is accepted")
        let noFlag = ServiceWebModel.forApp(ProviderCatalog.hulu, environment: ["STREAMSETU_SERVICE_TEST_URL": "http://127.0.0.1:9/x"])
        #expect(noFlag.homeURL == ProviderCatalog.hulu.homeURL)
    }

    @Test func eachServiceKeepsItsOwnZoomKeyAndDefault() {
        let d = UserDefaults(suiteName: "zoom-" + UUID().uuidString)!
        let a = ServiceWebModel(definition: ProviderCatalog.netflix, dataStore: { .nonPersistent() }, defaults: d)
        let b = ServiceWebModel(definition: ProviderCatalog.hulu, dataStore: { .nonPersistent() }, defaults: d)
        #expect(a.zoom.percent == 85 && b.zoom.percent == 100)
        b.zoomIn()
        #expect(d.object(forKey: "netflix.pageZoom") == nil && d.double(forKey: ProviderCatalog.hulu.zoomDefaultsKey) == 1.05)
        b.resetZoom(); #expect(b.zoom.isDefault)
    }

    @Test func netflixKeepsItsExactStoreAndNames() {
        #expect(NetflixWebModel.storeIdentifier.uuidString.lowercased() == "afdfb6b8-2671-42a0-bd87-6973dcd90758")
        #expect(NetflixWebModel.self == ServiceWebModel.self)
        let m = NetflixWebModel.forApp()
        #expect(m.definition.id == .netflix && m.definition.externalLinks == .confirmThenOpen)
    }
}
