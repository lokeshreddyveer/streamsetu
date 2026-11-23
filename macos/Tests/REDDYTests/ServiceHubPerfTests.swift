import Testing
import WebKit
import AppKit
@testable import REDDY

/// Measurements of the hub on the local fixture server (Debug build, in-memory stores, loopback). They say nothing about any real service.
/// Every line starting MEASURE is recorded with its conditions in the integration report; the assertions are generous bounds, not targets.
@Suite("Service hub performance", .serialized) @MainActor struct ServiceHubPerfTests {
    private func rssKB(_ pid: Int32) -> Int {
        guard pid > 0 else { return 0 }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "rss=", "-p", "\(pid)"]
        let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
        return Int(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }
    private func webPID(_ v: WKWebView?) -> Int32 { (v?.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0 }          // test-only
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return Double(info.phys_footprint) / 1_048_576
    }
    private func cpuSeconds() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
    private func pct(_ v: [Double], _ p: Double) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
    private func f(_ x: Double) -> String { String(format: "%.3f", x) }

    @Test func startingTheHubCreatesNothingAndCostsLittle() {
        let t = Date()
        var made = 0
        let r = ServiceHostRegistry(makeModel: { d in made += 1; return ServiceWebModel(definition: d, dataStore: { .nonPersistent() }) })
        let ms = Date().timeIntervalSince(t) * 1000
        #expect(made == 0 && r.createdIDs.isEmpty && r.liveIDs.isEmpty)
        let t2 = Date(); _ = ProviderRegistry.standard.definitions.map(\.displayName); let reg = Date().timeIntervalSince(t2) * 1000
        let t3 = Date(); let m = r.model(for: .hulu); let model = Date().timeIntervalSince(t3) * 1000
        #expect(m != nil && made == 1 && m?.webView == nil, "a model makes no web view until it is shown")
        print("MEASURE lazy init: registry construction \(f(ms)) ms, catalog read \(f(reg)) ms, first model (no web view) \(f(model)) ms, models made at start \(0), after one open \(made)")
        #expect(ms < 100)
    }

    @Test func pinningPlanningAndPersistenceStayInstant() {
        let iso = IsolatedDefaults.make("hubperf"); let defaults = iso.defaults; defer { IsolatedDefaults.remove(iso.name, defaults) }
        var p = ServicePreferences.initial()
        let ids = ProviderCatalog.all.map(\.id)
        let t = Date()
        for i in 0..<1000 {
            let id = ids[i % ids.count]
            if p.isPinned(id) { p.unpin(id) } else { p.pin(id) }
            p.noteOpened(id); p.save(to: defaults)
        }
        let pinMs = Date().timeIntervalSince(t) * 1000 / 1000
        let widths = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGFloat(110)) })
        let t2 = Date()
        for w in stride(from: 300, through: 1900, by: 1) { _ = ServiceBarPlanner.plan(pinned: ids, active: .hulu, itemWidths: widths, servicesButtonWidth: 90, budget: CGFloat(w), spacing: 8) }
        let planMs = Date().timeIntervalSince(t2) * 1000 / 1601
        print("MEASURE 1000 pin/unpin + save: \(f(pinMs)) ms each; 1601 overflow plans (widths 300 to 1900) \(f(planMs)) ms each")
        #expect(pinMs < 5 && planMs < 1)
    }

    @Test func aHundredNavigationCyclesBetweenServicesStayBoundedInMemoryAndCPU() async throws {
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        _ = NSApplication.shared
        let r = ServiceWebLifecycleTests.registry(server)
        let nav = ServiceNavigation(capabilities: .macOS); nav.hosts = r
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let order: [ProviderID] = [.netflix, .primevideo, .hulu, .youtube, .peacock]
        func show(_ id: ProviderID) async {
            nav.select(id)
            if let m = r.model(for: id) { window.contentView = m.hostedView(); m.hostedView().frame = window.contentView!.bounds }
            _ = await ServiceTestSupport.until(10) { r.model(for: id)?.phase == .ready }
        }
        // warm up: one visit to each, so the one-off costs are not counted as growth
        let t0 = Date(); await show(order[0]); let firstLoadMs = Date().timeIntervalSince(t0) * 1000
        for id in order.dropFirst() { await show(id) }
        try? await Task.sleep(for: .milliseconds(300))
        let base = footprintMB(); var worstLive = 0
        var lat: [Double] = [], trend = ["0:\(Int(base))"], webRSS = 0
        let cpu0 = cpuSeconds(), wall0 = Date()
        for i in 1...100 {
            let id = order[i % order.count]
            let t = Date(); await show(id); lat.append(Date().timeIntervalSince(t) * 1000)
            worstLive = max(worstLive, r.liveIDs.count)
            if i % 20 == 0 { trend.append("\(i):\(Int(footprintMB()))"); webRSS = max(webRSS, rssKB(webPID(r.model(for: id)?.webView)) / 1024) }
        }
        let wall = Date().timeIntervalSince(wall0), cpu = (cpuSeconds() - cpu0) / max(0.001, wall) * 100
        try? await Task.sleep(for: .milliseconds(300))
        let growth = footprintMB() - base
        print("MEASURE 100 navigation cycles over \(order.count) services: first service load \(Int(firstLoadMs)) ms; per switch to ready ms median \(f(pct(lat, 0.5))) p95 \(f(pct(lat, 0.95))) max \(f(lat.max() ?? 0)); most live web views \(worstLive); host footprint MB 'cycle:MB' \(trend.joined(separator: " ")); growth after the run \(Int(growth)) MB; largest web process rss seen \(webRSS) MB; host CPU \(Int(cpu))% of one core over \(f(wall)) s; reloads of the start page \(server.hits("/home"))")
        #expect(worstLive <= 2, "never more than two live web views")
        #expect(growth < 150, "memory growth over 100 cycles stays bounded")
        window.contentView = nil
        nav.returnToStreamSetu(); r.handleMemoryPressure(critical: true)
        #expect(r.liveIDs.isEmpty)
        try? await Task.sleep(for: .milliseconds(300))
        print("MEASURE after releasing every hidden web view: host footprint \(Int(footprintMB())) MB (baseline before cycles \(Int(base)) MB)")
    }

    @Test func eachDebugBlockedHostIsRecordedWithTheHostOnly() async throws {
        #if DEBUG

        let rig = try await ServiceWebModelTests.Rig(.hulu); defer { rig.finish() }
        rig.show(); _ = await ServiceTestSupport.until { rig.model.phase == .ready }
        rig.model.load(rig.server.url("/redirect-out?token=secret#frag"))
        #expect(await ServiceTestSupport.until { DebugHostLog.entries.contains { $0.host == "localhost" && $0.service == "hulu" } })
        let all = DebugHostLog.entries.filter { $0.service == "hulu" }          // other suites may run beside this one
        #expect(all.allSatisfy { !$0.host.contains("secret") && !$0.host.contains("/") && !$0.host.contains("?") })
        #expect(!all.isEmpty)
        #endif
    }
}
