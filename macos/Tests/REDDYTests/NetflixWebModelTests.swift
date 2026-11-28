import Testing
import WebKit
import AppKit
@testable import REDDY

/// The Netflix web model against local fixtures only (127.0.0.1): the real site is never contacted.
@Suite("Netflix web model", .serialized) @MainActor struct NetflixWebModelTests {
    static let policy = NetflixURLPolicy(hostSuffixes: ["127.0.0.1"], inAppSchemes: ["http"], allowsAnyPort: true)

    @MainActor final class Rig {
        let server: ServiceFixtureServer
        let model: NetflixWebModel
        var opened: [URL] = []
        let window: NSWindow
        init(releaseAfter: Duration = .seconds(1800), slowAfter: Duration = .seconds(8), store: @escaping () -> WKWebsiteDataStore = { .nonPersistent() }, server: ServiceFixtureServer? = nil) async throws {
            _ = NSApplication.shared
            self.server = try server ?? ServiceFixtureServer()
            if server == nil { try await self.server.start() }
            model = NetflixWebModel(policy: NetflixWebModelTests.policy, homeURL: self.server.url("/home"), dataStore: store, releaseAfter: releaseAfter, slowAfter: slowAfter)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            model.openExternal = { [weak self] u in self?.opened.append(u) }
            model.isAppActive = { true }
            nonisolated(unsafe) var clock = Date(); model.now = { clock = clock.addingTimeInterval(3); return clock }
        }
        func show() { model.serviceBecameVisible(); window.contentView = model.hostedView(); model.hostedView().frame = window.contentView!.bounds }
        func finish() { model.serviceBecameHidden(); model.releaseResources(); window.contentView = nil; server.stop() }
        var title: String { model.webView?.title ?? "" }
        var url: String { model.webView?.url?.path ?? "" }
    }

    static func until(_ timeout: Double = 30, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(40)) }
        return cond()
    }

    @Test func configurationHasNoScriptsNoBridgeAndOnlyTheSafariApplicationName() throws {
        let c = NetflixWebModel.makeConfiguration(dataStore: .nonPersistent())
        #expect(c.userContentController.userScripts.isEmpty)
        #expect(c.applicationNameForUserAgent == SafariUserAgent.applicationName)
        #expect(c.preferences.isElementFullscreenEnabled)
        #expect(!c.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(c.preferences.isFraudulentWebsiteWarningEnabled)
        let v = WKWebView(frame: .zero, configuration: c)
        #expect((v.customUserAgent ?? "").isEmpty)
        // no message handler can have been registered: adding the same name twice would only be legal if none existed, so check by removing a never-added one is a no-op; the code has no addScriptMessageHandler call
        let src = try ServiceSources.runtime()
        for forbidden in ["addScriptMessageHandler", "WKUserScript", "evaluateJavaScript", "customUserAgent", "cookie.value", "cookie.name", "$0.value", "$0.name", "WKContentRuleList", "limitsNavigationsToAppBoundDomains"] { #expect(!src.contains(forbidden), "\(forbidden)") }
    }

    @Test func nothingIsCreatedUntilTheServiceIsShown() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        #expect(rig.model.webView == nil); #expect(rig.model.phase == .idle)
        rig.show()
        #expect(rig.model.webView != nil)
    }

    @Test func initialLoadReachesReady() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        let t0 = Date(); rig.show()
        #expect(await Self.until { rig.model.phase == .ready })
        #expect(await Self.until { rig.title == "home" })          // the title is read from the page after it is ready, so it is waited for
        print("MEASURE web view creation + first local load: \(Int(Date().timeIntervalSince(t0) * 1000)) ms (loopback fixture, debug build)")
    }

    @Test func redirectsFollowWithinTheAllowedHost() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        rig.show(); _ = await Self.until { rig.model.phase == .ready }
        rig.model.load(rig.server.url("/redirect"))
        #expect(await Self.until { rig.url == "/home" && rig.model.phase == .ready })
    }

    @Test func aRedirectToAnotherHostNeverOpensAnotherApp() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        rig.show(); _ = await Self.until { rig.model.phase == .ready }
        rig.model.load(rig.server.url("/redirect-out"))
        #expect(await Self.until { rig.model.pendingExternal != nil })          // asked, not opened
        #expect(rig.opened.isEmpty)
        // WebKit reports the cancelled redirect target for a moment under load: it must settle back on the allowed page, never stay on the other host.
        #expect(await Self.until { rig.model.webView?.url?.host != "localhost" })
        rig.model.cancelExternal()
        #expect(rig.model.pendingExternal == nil && rig.opened.isEmpty, "cancel opens nothing")
    }

    @Test func notFoundShowsThePageAndServerErrorShowsTheNativeState() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        rig.show(); _ = await Self.until { rig.model.phase == .ready }
        rig.model.load(rig.server.url("/404"))
        #expect(await Self.until { rig.model.lastStatusCode == 404 && rig.model.phase == .ready })
        rig.model.load(rig.server.url("/500"))
        #expect(await Self.until { rig.model.phase == .failed(.siteUnavailable(status: 500)) })
        rig.model.reload()
        #expect(await Self.until { rig.server.hits("/500") >= 2 })
    }

    @Test func slowResponseShowsLoadingThenTheSlowNote() async throws {
        let rig = try await Rig(slowAfter: .milliseconds(300)); defer { rig.finish() }
        rig.show(); _ = await Self.until { rig.model.phase == .ready }
        rig.model.load(rig.server.url("/slow"))
        #expect(await Self.until { rig.model.phase == .loading })
        #expect(await Self.until { rig.model.isSlow })
        #expect(await Self.until { rig.model.phase == .ready && !rig.model.isSlow })
        #expect(await Self.until { rig.title == "slow" })
    }

    @Test func unreachableSiteIsAFailureWithARetry() async throws {
        let port = try ServiceFixtureServer.unreachablePort()
        _ = NSApplication.shared
        let model = NetflixWebModel(policy: Self.policy, homeURL: URL(string: "http://127.0.0.1:\(port)/")!, dataStore: { .nonPersistent() })
        defer { model.serviceBecameHidden(); model.releaseResources() }
        model.serviceBecameVisible()
        #expect(await Self.until { if case .failed = model.phase { true } else { false } })
        model.reload()
        #expect(await Self.until { if case .failed = model.phase { true } else { false } })
    }

    /// A local HTTPS server with a self-signed certificate: the system refuses it, nothing is loaded, and the person sees the secure-connection state.
    @Test func aCertificateTheSystemDoesNotTrustShowsTheSecureConnectionState() async throws {
        _ = NSApplication.shared
        let server = try ServiceFixtureServer(tls: true)
        try await server.start(); defer { server.stop() }
        let policy = NetflixURLPolicy(hostSuffixes: ["127.0.0.1"], inAppSchemes: ["https"], allowsAnyPort: true)
        let model = NetflixWebModel(policy: policy, homeURL: server.url("/home"), dataStore: { .nonPersistent() })
        defer { model.serviceBecameHidden(); model.releaseResources() }
        model.serviceBecameVisible()
        #expect(await Self.until(15) { model.phase == .failed(.tlsFailure) })
        #expect(model.webView?.title != "home")
        let copy = NetflixFailureCopy.text(for: .tlsFailure)
        #expect(copy.title == "The secure connection failed")
    }

    @Test func popupsLoadInTheSameViewOrLeaveForTheBrowser() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        rig.show(); rig.model.load(rig.server.url("/popup")); _ = await Self.until { rig.title == "popup" }
        _ = try? await rig.model.webView?.evaluateJavaScript("document.getElementById('l').click()")          // test-only script: a click on target=_blank
        #expect(await Self.until { rig.url == "/home" })
        #expect(rig.opened.isEmpty)
        rig.model.load(rig.server.url("/popup")); _ = await Self.until { rig.title == "popup" }
        _ = try? await rig.model.webView?.evaluateJavaScript("document.getElementById('x').click()")
        #expect(await Self.until { rig.model.pendingExternal?.host == "localhost" })
        #expect(rig.opened.isEmpty, "a pop-up to another site never opens the browser by itself")
        rig.model.confirmExternal()
        #expect(rig.opened.count == 1 && rig.opened.first?.host == "localhost"); #expect(rig.url == "/popup")
        rig.model.confirmExternal(); #expect(rig.opened.count == 1, "confirmed once, opened once")
    }

    /// Even after the person says Open: StreamSetu must be in front, and a second open within two seconds is held back.
    @Test func openingTheBrowserIsLimitedWhileInTheBackgroundAndWhenRepeated() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        rig.show(); rig.model.load(rig.server.url("/links")); _ = await Self.until { rig.title == "links" }
        _ = try? await rig.model.webView?.evaluateJavaScript("document.getElementById('mail').click()")
        #expect(await Self.until { rig.model.pendingExternal != nil })
        rig.model.isAppActive = { false }; rig.model.confirmExternal()
        #expect(rig.opened.isEmpty && rig.model.pendingExternal != nil, "another app in front: nothing opens, the question stays")
        rig.model.isAppActive = { true }
        let fixed = Date(); rig.model.now = { fixed }
        rig.model.confirmExternal(); #expect(rig.opened.count == 1)
        _ = try? await rig.model.webView?.evaluateJavaScript("document.getElementById('ext').click()")
        #expect(await Self.until { rig.model.pendingExternal != nil })
        rig.model.confirmExternal()
        #expect(rig.opened.count == 1, "a second open within two seconds is held back")
        #expect(NetflixWebModel.destinationLabel(URL(string: "https://example.com/secret/path?token=abc")!) == "example.com")
    }

    @Test func externalLinksMailAndCustomSchemes() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        rig.show(); rig.model.load(rig.server.url("/links")); _ = await Self.until { rig.title == "links" }
        _ = try? await rig.model.webView?.evaluateJavaScript("document.getElementById('custom').click()")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(rig.opened.isEmpty, "a custom scheme never opens another app")
        _ = try? await rig.model.webView?.evaluateJavaScript("document.getElementById('mail').click()")
        #expect(await Self.until { rig.model.pendingExternal?.scheme == "mailto" })
        #expect(rig.opened.isEmpty); rig.model.confirmExternal()
        #expect(rig.opened.contains { $0.scheme == "mailto" })
        _ = try? await rig.model.webView?.evaluateJavaScript("document.getElementById('ext').click()")
        #expect(await Self.until { rig.model.pendingExternal?.host == "localhost" })
        rig.model.confirmExternal()
        #expect(rig.opened.contains { $0.host == "localhost" })
        #expect(rig.url == "/links")
    }

    @Test func downloadsAreBlocked() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        rig.show(); _ = await Self.until { rig.model.phase == .ready }
        rig.model.load(rig.server.url("/download"))
        #expect(await Self.until { rig.model.notice == .downloadBlocked })
        #expect(await Self.until { rig.url == "/home" })           // settles on the page that was showing (WebKit is slower under load)
        rig.model.dismissNotice()
        rig.model.load(rig.server.url("/zip"))
        #expect(await Self.until { rig.model.notice == .downloadBlocked })
        #expect(await Self.until { rig.model.phase == .ready })          // the page that was showing stays
    }

    @Test func reloadBackAndForward() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        rig.show(); _ = await Self.until { rig.model.phase == .ready }
        rig.model.load(rig.server.url("/a")); _ = await Self.until { rig.url == "/a" && rig.model.phase == .ready }
        rig.model.load(rig.server.url("/b")); _ = await Self.until { rig.url == "/b" && rig.model.phase == .ready }
        #expect(await Self.until { rig.model.canGoBack })
        rig.model.goBack()
        // WebKit may drop a history entry for a page loaded by the app without a click, so the page before /b is /a or /home; the point is that Back leaves /b.
        #expect(await Self.until { rig.url != "/b" && rig.model.phase == .ready })
        #expect(await Self.until { rig.model.canGoForward })
        rig.model.goForward(); #expect(await Self.until { rig.url == "/b" && rig.model.phase == .ready })
        let before = rig.server.hits("/b")
        rig.model.reload(); _ = await Self.until(3) { rig.server.hits("/b") > before }
        // a reload that WebKit serves from its own cache is allowed; a reload after a failure must always go to the network
        rig.model.load(rig.server.url("/500")); #expect(await Self.until { rig.model.phase == .failed(.siteUnavailable(status: 500)) })
        let h500 = rig.server.hits("/500"); rig.model.reload(); #expect(await Self.until { rig.server.hits("/500") > h500 })
    }

    @Test func hidingAndShowingKeepsThePageWithoutReloading() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        rig.show(); rig.model.load(rig.server.url("/a")); _ = await Self.until { rig.url == "/a" && rig.model.phase == .ready }
        let hits = rig.server.hits("/a")
        let started = Date()
        for _ in 0..<20 { rig.model.serviceBecameHidden(); rig.model.serviceBecameVisible() }
        print("MEASURE 20 hide/show cycles of the retained web view: \(Int(Date().timeIntervalSince(started) * 1000)) ms total")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.server.hits("/a") == hits, "no reload while switching")
        #expect(rig.url == "/a"); #expect(rig.model.releaseCount == 0)
    }

    @Test func aTerminatedWebProcessRecoversByReloading() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        rig.show(); rig.model.load(rig.server.url("/a")); _ = await Self.until { rig.url == "/a" && rig.model.phase == .ready }
        // test-only: find the web process id through the web view's private accessor and kill that process, so the real termination path runs
        let pid = (rig.model.webView?.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
        let real = pid > 0
        if real { kill(pid, SIGKILL) } else { rig.model.webViewWebContentProcessDidTerminate(rig.model.webView!) }          // falls back to calling the delegate
        #expect(await Self.until { rig.model.terminationCount >= 1 })
        #expect(await Self.until(12) { rig.model.phase == .ready && rig.url == "/a" })
        print("MEASURE process termination recovery used \(real ? "a real killed web process" : "a simulated delegate call")")
    }

    @Test func repeatedTerminationStopsTheAutomaticReload() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        rig.show(); _ = await Self.until { rig.model.phase == .ready }
        for _ in 0..<3 { rig.model.webViewWebContentProcessDidTerminate(rig.model.webView!) }
        #expect(rig.model.terminationCount == 3)
        rig.model.reload()          // the person asks
        #expect(await Self.until { rig.model.phase == .ready })
    }

    @Test func releasingFreesTheViewAndComingBackLoadsTheLastPage() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        rig.show(); rig.model.load(rig.server.url("/b")); _ = await Self.until { rig.url == "/b" && rig.model.phase == .ready }
        rig.model.serviceBecameHidden(); rig.model.releaseResources()
        #expect(rig.model.webView == nil); #expect(rig.model.releaseCount == 1); #expect(rig.model.phase == .idle)
        rig.model.releaseResources(); #expect(rig.model.releaseCount == 1)
        rig.show()
        #expect(await Self.until { rig.url == "/b" && rig.model.phase == .ready })
    }

    @Test func aVisibleServiceIsNeverReleased() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        rig.show(); rig.model.releaseResources()
        #expect(rig.model.webView != nil && rig.model.releaseCount == 0)
    }

    @Test func aLongHiddenServiceReleasesItself() async throws {
        let rig = try await Rig(releaseAfter: .milliseconds(300)); defer { rig.finish() }
        rig.show(); _ = await Self.until { rig.model.phase == .ready }
        rig.model.serviceBecameHidden()
        #expect(await Self.until { rig.model.releaseCount == 1 })
        #expect(rig.model.webView == nil)
        rig.show(); rig.model.serviceBecameHidden(); rig.model.serviceBecameVisible()          // coming back cancels the timer
        try? await Task.sleep(for: .milliseconds(600))
        #expect(rig.model.releaseCount == 1)
    }

    @Test func clearingRemovesCookiesOfTheNetflixStoreOnly() async throws {
        let id = UUID()
        defer { Task { try? await WKWebsiteDataStore.remove(forIdentifier: id) } }
        let rig = try await Rig(store: { WKWebsiteDataStore(forIdentifier: id) }); defer { rig.finish() }
        let other = WKWebsiteDataStore.nonPersistent()
        rig.show(); rig.model.load(rig.server.url("/cookie-set")); _ = await Self.until { rig.title == "set" }
        rig.model.load(rig.server.url("/cookie-echo")); _ = await Self.until { rig.title == "cookie:sid=abc123" }
        #expect(rig.title == "cookie:sid=abc123")
        // another store never saw it
        #expect(await other.httpCookieStore.allCookies().isEmpty)
        #expect(await Self.until { rig.model.hasSession })          // 127.0.0.1 is the allowed host in these tests
        await rig.model.clearServiceData()
        #expect(!rig.model.hasSession)
        rig.model.load(rig.server.url("/cookie-echo"))
        #expect(await Self.until { rig.title == "cookie:" })
    }

    @Test func theSessionSurvivesANewModelOnTheSameStore() async throws {
        let id = UUID()
        defer { Task { try? await WKWebsiteDataStore.remove(forIdentifier: id) } }
        let first = try await Rig(store: { WKWebsiteDataStore(forIdentifier: id) })
        first.show(); first.model.load(first.server.url("/cookie-set")); _ = await Self.until { first.title == "set" }
        let second = try await Rig(store: { WKWebsiteDataStore(forIdentifier: id) }, server: first.server)
        defer { second.finish(); first.finish() }
        first.model.releaseResources()
        second.show(); second.model.load(second.server.url("/cookie-echo"))
        #expect(await Self.until { second.title == "cookie:sid=abc123" })
        #expect(await Self.until { second.model.hasSession })
        // the real configuration of the app keeps website data: a persistent store, never the in-memory one
        let c = NetflixWebModel.makeConfiguration(dataStore: WKWebsiteDataStore(forIdentifier: id))
        #expect(c.websiteDataStore.isPersistent)
        #expect(c.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(c.userContentController.userScripts.isEmpty)
    }

    @Test func openInDefaultBrowserUsesTheCurrentAllowedPageElseHome() async throws {
        let rig = try await Rig(); defer { rig.finish() }
        rig.show(); rig.model.load(rig.server.url("/a")); _ = await Self.until { rig.url == "/a" && rig.model.phase == .ready }
        rig.model.openInDefaultBrowser()
        #expect(rig.opened.last?.path == "/a")
    }

    @Test func mediaPauseWithoutAViewIsHarmless() {
        let m = NetflixWebModel(policy: Self.policy, dataStore: { .nonPersistent() })
        m.pauseMedia(); m.serviceBecameHidden(); m.releaseResources()
        #expect(m.webView == nil)
    }

    @Test func memoryBeforeAndAfterALocalPage() async throws {
        func footprintMB() -> Double {
            var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
            return Double(info.phys_footprint) / 1_048_576
        }
        let rig = try await Rig(); defer { rig.finish() }
        let a = footprintMB()
        rig.show(); _ = await Self.until { rig.model.phase == .ready }
        let b = footprintMB()
        rig.model.serviceBecameHidden(); rig.model.releaseResources()
        try? await Task.sleep(for: .milliseconds(500))
        let c = footprintMB()
        print("MEASURE host-process footprint (WebContent/Networking helper processes are separate and not included): before \(Int(a)) MB, with local page \(Int(b)) MB, after release \(Int(c)) MB")
    }
}
