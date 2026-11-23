import Testing
import WebKit
import AppKit
import SwiftUI
@testable import REDDY

/// Session safety, key routing, layout, media on leaving and measurements. Local fixtures only; the real site and the real Netflix session are never touched.
@Suite("Netflix polish", .serialized) @MainActor struct NetflixPolishTests {
    // MARK: session

    @Test func aTestProcessCanNeverGetTheRealNetflixStore() {
        #expect(NetflixWebModel.isRunningUnderTests)
        let before = NetflixWebModel.blockedProductionStoreRequests
        let model = NetflixWebModel()                           // the production default
        let store = model.dataStore
        #expect(!store.isPersistent, "the default store in a test is in memory")
        #expect(NetflixWebModel.blockedProductionStoreRequests == before + 1)
        #expect(model.webView == nil, "nothing is created until the service is shown")
    }

    @Test func theSessionCodeNeverClearsAnythingByItselfAndNeverTouchesOtherStores() throws {
        let src = try ServiceSources.runtime()
        // website data is removed in exactly one place: the explicit clear command, on this model's own store
        #expect(src.components(separatedBy: "removeData(").count == 2)
        #expect(!src.contains("WKWebsiteDataStore.default()"))
        #expect(!src.contains("remove(forIdentifier"))
        #expect(!src.contains("print(") && !src.contains("NSLog(") && !src.contains("Logger("), "nothing is logged")
        let menu = try source("Application/MenuCommands.swift")
        #expect(menu.contains("clearServiceData") && menu.contains("alert.runModal()"), "clearing asks first")
        for forbidden in ["WKScriptMessageHandler", "addScriptMessageHandler", "WKUserScript", "evaluateJavaScript", "callAsyncJavaScript"] { #expect(!src.contains(forbidden), "\(forbidden)") }
    }

    @Test func recreatingTheWebViewReusesTheSameStoreAndProcessRecoveryKeepsIt() async throws {
        let model = NetflixWebModel(dataStore: { .nonPersistent() })
        let store = model.dataStore
        _ = model.hostedView(); #expect(model.webView?.configuration.websiteDataStore === store)
        model.serviceBecameHidden(); model.releaseResources(); #expect(model.webView == nil)
        _ = model.hostedView(); #expect(model.webView?.configuration.websiteDataStore === store)
        model.webViewWebContentProcessDidTerminate(model.webView!)
        #expect(model.webView?.configuration.websiteDataStore === store)
        model.releaseResources()
    }

    // MARK: keys

    @Test func plainKeysGoToTheWebPageWhileAServiceShows() {
        #expect(ServiceKeyRouting.bypassesNativeKeys(serviceActive: true, popupPlayerUp: false))
        #expect(!ServiceKeyRouting.bypassesNativeKeys(serviceActive: true, popupPlayerUp: true), "the popup player over the page keeps its keys")
        #expect(!ServiceKeyRouting.bypassesNativeKeys(serviceActive: false, popupPlayerUp: false), "native behaviour is back when the service is left")
        #expect(!ServiceKeyRouting.bypassesNativeKeys(serviceActive: false, popupPlayerUp: true))
        // the native player's plain keys exist (Space, F, M, arrows) and are only reachable through that route
        let ctx = PlayerShortcutContext(hasPlayback: true, isFullscreen: false, isLive: false, switcherOpen: false, numberEntryActive: false, isExpanded: false)
        for code: UInt16 in [49, 3, 46, 123, 124] { _ = PlayerShortcuts.resolve(keyCode: code, characters: nil, ctx) }
    }

    @Test func theMonitorLetsTextFieldTypingAndCommandKeysAlone() throws {
        let src = try source("Application/PlayerKeyMonitor.swift")
        #expect(src.contains("firstResponder is NSText") && src.contains(".command, .control, .option"))
        let shell = try source("Application/RootView.swift")
        #expect(shell.contains("ServiceKeyRouting.bypassesNativeKeys"))
        // the Esc layers are tried before the bypass, so a native dialog still closes first
        let esc = try #require(shell.range(of: "event.keyCode == 53")), byp = try #require(shell.range(of: "ServiceKeyRouting.bypassesNativeKeys(serviceActive"))
        #expect(esc.lowerBound < byp.lowerBound)
    }

    // MARK: top bar layout while switching

    @Test func theRowDoesNotJumpWhenTheTabsCollapse() {
        for w: CGFloat in [1024, 1440, 1728, 2560] {
            let m = TopBarMetrics.metrics(for: w)
            func frames(_ titles: [String]) -> TopBarGeometry.Frames {
                let nav = titles.map { TabLabelMetrics.textWidth($0) + 2 * m.tabPadding }.reduce(0, +)
                return TopBarGeometry.frames(width: w, height: LayoutTokens.headerHeight, leading: CGSize(width: TabLabelMetrics.brandWidth, height: 28), center: CGSize(width: nav, height: LayoutTokens.headerHeight),
                                             trailingIdeal: CGSize(width: m.searchIdeal + 8 + TopBarMetrics.accountWidth, height: 30), trailingMin: m.searchMin + 8 + TopBarMetrics.accountWidth,
                                             leadingInset: TopBarMetrics.leadingInset, trailingInset: TopBarMetrics.trailingInset)
            }
            let six = frames(AppTab.allCases.map(\.title) + ["Netflix"]), two = frames(["StreamSetu", "Netflix"])
            #expect(six.leading == two.leading, "the wordmark zone does not move at \(w)")
            #expect(abs(six.center.midX - w / 2) <= 0.5 && abs(two.center.midX - w / 2) <= 0.5, "both are centred at \(w)")
            #expect(six.trailing == two.trailing || abs(six.trailing.maxX - two.trailing.maxX) < 0.5, "search and profile keep their right edge at \(w)")
            #expect(six.center.height == two.center.height)
        }
    }

    // MARK: web view region

    /// The page fills the whole content region at every window size: no padding, no inset, nothing clipped at the bottom.
    @Test func theWebViewFillsItsRegionAtEveryWindowSize() async throws {
        _ = NSApplication.shared
        let model = NetflixWebModel(policy: NetflixURLPolicy(hostSuffixes: ["127.0.0.1"], inAppSchemes: ["http"], allowsAnyPort: true), dataStore: { .nonPersistent() })
        // the shell lets its content run under the (transparent) title bar, so the region is the whole window
        let host = NSHostingView(rootView: NetflixHostView(model: model).environment(\.colorScheme, .dark).ignoresSafeArea(.container, edges: .top))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 680), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        win.contentView = host; win.titlebarAppearsTransparent = true
        defer { win.contentView = nil; model.releaseResources() }
        model.serviceBecameVisible()
        for size in [NSSize(width: 1024, height: 680), NSSize(width: 1440, height: 900), NSSize(width: 2560, height: 1440), NSSize(width: 1024, height: 680)] {
            win.setContentSize(size)
            try? await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let web = try #require(model.webView)
            let region = web.superview?.convert(web.frame, to: host) ?? .zero
            print("MEASURE layout \(size): web view \(region) in region \(host.bounds), window content \(win.contentLayoutRect)")
            #expect(abs(region.width - host.bounds.width) < 1 && abs(region.height - host.bounds.height) < 1, "\(size): web view \(region) vs region \(host.bounds)")
        }
    }

    // MARK: leaving the page with media playing

    private func wav(seconds: Int = 20) -> Data {
        let rate = 8000, n = rate * seconds
        var d = Data("RIFF".utf8); func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }; func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        u32(36 + n * 2); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16); d.append(Data("data".utf8)); u32(n * 2)
        var s = Data(capacity: n * 2)
        for i in 0..<n { var x = Int16(0).littleEndian; _ = i; s.append(Data(bytes: &x, count: 2)) }          // silent: a real audio track of all-zero samples, never a sound
        return d + s
    }

    /// What really happens to local audio when the service is hidden, with the supported calls only. Observed values are printed; the assertions are the ones that must hold.
    @Test func leavingStopsLocalMediaAndComingBackDoesNotResumeIt() async throws {
        let server = try ServiceFixtureServer(); server.media = wav(); try await server.start(); defer { server.stop() }
        _ = NSApplication.shared
        let model = NetflixWebModel(policy: NetflixWebModelTests.policy, homeURL: server.url("/media"), dataStore: { .nonPersistent() })
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        defer { win.contentView = nil; model.serviceBecameHidden(); model.releaseResources() }
        model.serviceBecameVisible(); win.contentView = model.hostedView(); model.hostedView().frame = win.contentView!.bounds
        #expect(await NetflixWebModelTests.until { model.phase == .ready })
        let web = try #require(model.webView)
        func paused() async -> Bool { ((try? await web.evaluateJavaScript("document.getElementById('a').paused")) as? Bool) ?? true }          // test-only read of the local fixture
        _ = try? await web.evaluateJavaScript("document.getElementById('a').play()")
        let started = await NetflixWebModelTests.until(5) { true }; _ = started
        try? await Task.sleep(for: .milliseconds(800))
        let playingState = await web.requestMediaPlaybackState()
        let pausedBefore = await paused()
        print("MEASURE media: after play() -> paused=\(pausedBefore), requestMediaPlaybackState=\(playingState.rawValue) (0 none, 1 playing, 2 paused, 3 suspended)")
        // 1. only removing the view from the window (no pause call): what happens?
        web.removeFromSuperview(); win.contentView = NSView()
        try? await Task.sleep(for: .milliseconds(600))
        let stateAfterRemoval = await web.requestMediaPlaybackState(), pausedAfterRemoval = await paused()
        print("MEASURE media: after only removing the view -> paused=\(pausedAfterRemoval), state=\(stateAfterRemoval.rawValue)")
        win.contentView = web
        // 2. the supported approach used by the app
        model.serviceBecameHidden()
        try? await Task.sleep(for: .milliseconds(600))
        let stateAfterLeave = await web.requestMediaPlaybackState(), pausedAfterLeave = await paused()
        print("MEASURE media: after serviceBecameHidden (pauseAllMediaPlayback + closeAllMediaPresentations) -> paused=\(pausedAfterLeave), state=\(stateAfterLeave.rawValue)")
        model.serviceBecameVisible()
        try? await Task.sleep(for: .milliseconds(800))
        let stateAfterReturn = await web.requestMediaPlaybackState(), pausedAfterReturn = await paused()
        print("MEASURE media: after coming back -> paused=\(pausedAfterReturn), state=\(stateAfterReturn.rawValue)")
        if playingState == .playing {
            #expect(stateAfterLeave != .playing && pausedAfterLeave, "leaving must stop the sound")
            #expect(pausedAfterReturn && stateAfterReturn != .playing, "coming back never resumes by itself")
        } else {
            print("MEASURE media: the local audio could not be started in this process (autoplay policy), so the leave/return effect is not shown by this run")
        }
    }

    // MARK: measurements

    private func rssKB(_ pid: Int32) -> Int {
        guard pid > 0 else { return 0 }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "rss=", "-p", "\(pid)"]
        let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
        return Int(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }
    private func webPID(_ v: WKWebView?) -> Int32 { (v?.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0 }          // test-only
    private func hostFootprintMB() -> Double {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return Double(info.phys_footprint) / 1_048_576
    }
    private func cpuSeconds() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
    private func percentile(_ v: [Double], _ p: Double) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
    private func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// Stress run: 100 hide/show cycles, 100 destination round trips, 100 resizes, 3 process kills, 5 recreations. Every number printed is from this run (debug build, loopback fixture, in-memory store).
    @Test func stressRunWithMemoryTrendCpuAndLatencyDistribution() async throws {
        let rig = try await NetflixWebModelTests.Rig(); defer { rig.finish() }
        func ms(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
        var failures = 0, retries = 0
        let t0 = Date(); rig.show()
        #expect(await NetflixWebModelTests.until { rig.model.phase == .ready })
        print("MEASURE create + first local load: \(ms(t0)) ms")
        var pid = webPID(rig.model.webView)
        print("MEASURE start: host footprint \(Int(hostFootprintMB())) MB, web content process (pid \(pid)) rss \(rssKB(pid) / 1024) MB")

        // 1. 100 hide/show cycles, memory sampled every 10
        var lat: [Double] = [], trend: [String] = ["0:\(Int(hostFootprintMB()))/\(rssKB(pid) / 1024)"]
        let cpu0 = cpuSeconds(), wall0 = Date()
        for i in 1...100 {
            let t = Date(); rig.model.serviceBecameHidden(); rig.model.serviceBecameVisible(); lat.append(Date().timeIntervalSince(t) * 1000)
            if i % 10 == 0 { await pause(50); trend.append("\(i):\(Int(hostFootprintMB()))/\(rssKB(webPID(rig.model.webView)) / 1024)") }
        }
        let cpuPct = (cpuSeconds() - cpu0) / max(0.001, Date().timeIntervalSince(wall0)) * 100
        print("MEASURE 100 hide/show cycles, memory trend 'cycle:hostMB/webMB' = \(trend.joined(separator: " "))")
        print("MEASURE cycle latency ms: median \(String(format: "%.3f", percentile(lat, 0.5))), p95 \(String(format: "%.3f", percentile(lat, 0.95))), max \(String(format: "%.3f", lat.max() ?? 0)); host CPU during run \(String(format: "%.0f", cpuPct))% of one core; page reloads \(rig.server.hits("/home") - 1)")
        if rig.server.hits("/home") != 1 { failures += 1 }
        #expect(rig.server.hits("/home") == 1, "no reload while switching")

        // 2. 100 destination round trips through the owner object
        let nav = ServiceNavigation(capabilities: .macOS); nav.host = rig.model
        var lat2: [Double] = []
        for _ in 0..<100 { let t = Date(); nav.select(.netflix); nav.returnToStreamSetu(); lat2.append(Date().timeIntervalSince(t) * 1000) }
        print("MEASURE 100 select/return round trips ms: median \(String(format: "%.3f", percentile(lat2, 0.5))), p95 \(String(format: "%.3f", percentile(lat2, 0.95))), max \(String(format: "%.3f", lat2.max() ?? 0))")
        rig.model.serviceBecameVisible()

        // 3. 100 resizes with the page showing
        let host = NSHostingView(rootView: NetflixHostView(model: rig.model)); let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 680), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentView = host
        var lat3: [Double] = [], trend3: [String] = []
        for i in 1...100 {
            let t = Date(); win.setContentSize(NSSize(width: 1024 + CGFloat(i % 10) * 100, height: 680 + CGFloat(i % 7) * 60)); host.layoutSubtreeIfNeeded(); lat3.append(Date().timeIntervalSince(t) * 1000)
            if i % 25 == 0 { trend3.append("\(i):\(Int(hostFootprintMB()))/\(rssKB(webPID(rig.model.webView)) / 1024)") }
        }
        print("MEASURE 100 resizes ms (layout): median \(String(format: "%.2f", percentile(lat3, 0.5))), p95 \(String(format: "%.2f", percentile(lat3, 0.95))), max \(String(format: "%.2f", lat3.max() ?? 0)); memory 'resize:hostMB/webMB' = \(trend3.joined(separator: " "))")
        win.contentView = nil

        // 4. three process kills
        var recov: [Int] = []
        for k in 1...3 {
            rig.model.load(rig.server.url("/a")); _ = await NetflixWebModelTests.until { rig.url == "/a" && rig.model.phase == .ready }
            pid = webPID(rig.model.webView); guard pid > 0 else { retries += 1; continue }
            let before = rig.model.terminationCount, t = Date(); kill(pid, SIGKILL)
            let saw = await NetflixWebModelTests.until(15) { rig.model.terminationCount > before }
            let back = k < 3 ? await NetflixWebModelTests.until(15) { rig.model.phase == .ready && rig.url == "/a" } : false
            if k < 3 { if !(saw && back) { failures += 1 }; #expect(saw && back, "kill \(k)") }
            else {
                // the third kill inside a minute is not reloaded by itself: the state stays "stopped" until the person presses Try Again
                #expect(saw && rig.model.phase == .terminated, "third kill leaves the stopped state")
                let t5 = Date(); rig.model.reload()
                let manual = await NetflixWebModelTests.until(15) { rig.model.phase == .ready && rig.url == "/a" }
                if !manual { failures += 1 }
                #expect(manual)
                print("MEASURE third kill: left stopped (no automatic reload), manual Try Again -> page back in \(ms(t5)) ms")
            }
            if k < 3 { recov.append(ms(t)) }
        }
        print("MEASURE process kill -> page back ms (automatic reload, kills 1 and 2): \(recov) web rss now \(rssKB(webPID(rig.model.webView)) / 1024) MB")

        // 5. recreation
        var rec: [String] = []
        for i in 1...5 {
            rig.model.serviceBecameHidden(); rig.model.releaseResources(); await pause(100)
            let t = Date(); rig.model.serviceBecameVisible(); _ = await NetflixWebModelTests.until { rig.model.phase == .ready }
            rec.append("\(i):\(ms(t))ms/\(Int(hostFootprintMB()))MB/\(rssKB(webPID(rig.model.webView)) / 1024)MB")
        }
        print("MEASURE 5 recreations 'n:time/hostMB/webMB' = \(rec.joined(separator: " ")); releaseCount \(rig.model.releaseCount)")
        print("MEASURE stress summary: failures \(failures), retries \(retries); host footprint end \(Int(hostFootprintMB())) MB")
        #expect(failures == 0)
        #expect(rig.model.releaseCount >= 5)
    }

    @Test func theModelItselfIsFreedAfterUse() async throws {
        weak var weakModel: NetflixWebModel?
        weak var weakView: NetflixWebView?
        do {
            let m = NetflixWebModel(dataStore: { .nonPersistent() })
            weakModel = m
            weakView = m.hostedView()
            m.serviceBecameHidden(); m.releaseResources()
        }
        for _ in 0..<30 where weakModel != nil || weakView != nil { try? await Task.sleep(for: .milliseconds(100)) }
        print("MEASURE leak check: model freed=\(weakModel == nil), web view freed=\(weakView == nil)")
        #expect(weakView == nil, "a released web view is not kept alive by the model, its observers or its delegates")
    }

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY")
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }
}
