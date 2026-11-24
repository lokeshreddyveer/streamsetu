import Testing
import WebKit
import AppKit
@testable import REDDY

/// A person leaves a service (to the native screens or to another service) and comes back: playing must work again, while leaving still stops
/// everything. Silent local audio only; playback is started with the page's own play() (no real user click exists in a test process; the
/// test web views are not restricted by the autoplay policy), so this proves WebKit's suspend/lift handling, not a site's own gesture rules.
@Suite("Service resume", .serialized) @MainActor struct ServiceResumeTests {
    private func wav(seconds: Int = 30) -> Data {
        let rate = 8000, n = rate * seconds
        var d = Data("RIFF".utf8); func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }; func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        u32(36 + n * 2); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16); d.append(Data("data".utf8)); u32(n * 2)
        d.append(Data(count: n * 2))
        return d
    }

    private func time(_ w: WKWebView) async -> Double { ((try? await w.evaluateJavaScript("document.getElementById('a').currentTime")) as? Double) ?? -1 }
    private func isPaused(_ w: WKWebView) async -> Bool { ((try? await w.evaluateJavaScript("document.getElementById('a').paused")) as? Bool) ?? true }

    /// Asks the page to play (bounded retries) until currentTime advances. Returns whether it did.
    private func playAndAdvance(_ w: WKWebView) async -> Bool {
        for _ in 0..<20 {
            _ = try? await w.evaluateJavaScript("document.getElementById('a').play().catch(function(){})")
            let t0 = await time(w)
            try? await Task.sleep(for: .milliseconds(500))
            let t1 = await time(w)
            if t1 > t0 + 0.2, !(await isPaused(w)) { return true }
        }
        return false
    }

    @MainActor private final class Rig {
        let server: ServiceFixtureServer, hosts: ServiceHostRegistry, nav = ServiceNavigation(capabilities: .macOS)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        init(server: ServiceFixtureServer, hosts: ServiceHostRegistry) { self.server = server; self.hosts = hosts; nav.hosts = hosts }
    }

    @MainActor private func rig(releaseAfter: Duration? = nil) async throws -> Rig {
        let server = try ServiceFixtureServer(); server.media = wav(); try await server.start()
        _ = NSApplication.shared
        let hosts = ServiceHostRegistry(registry: .standard, budget: .standard, makeModel: { d in
            let m = ServiceWebModel(definition: ServiceTestSupport.fixture(d.id, server), dataStore: { .nonPersistent() }, releaseAfter: releaseAfter ?? MemoryBudget.standard.hiddenTTL)
            m.isAppActive = { true }; return m
        })
        return Rig(server: server, hosts: hosts)
    }

    /// What the app does on a switch: the navigation hides and shows, then the root view's change handler pauses every service except the new one.
    private func go(_ r: Rig, to s: ProviderID?) {
        if let s { r.nav.select(s) } else { r.nav.returnToStreamSetu() }
        r.hosts.pauseAll(except: s)
        attach(r, s)
    }
    private func attach(_ r: Rig, _ s: ProviderID?) {
        if let s, let m = r.hosts.model(for: s) { let v = m.hostedView(); if r.win.contentView !== v { r.win.contentView = v; v.frame = r.win.contentView!.bounds } } else { r.win.contentView = NSView() }
    }

    private func start(_ r: Rig, _ s: ProviderID) async throws -> WKWebView {
        go(r, to: s)
        let m = try #require(r.hosts.model(for: s))
        _ = await ServiceTestSupport.until { m.phase == .ready }
        m.load(r.server.url("/media"))
        #expect(await ServiceTestSupport.until(60) { m.webView?.title == "media" })
        let w = try #require(m.webView)
        #expect(await playAndAdvance(w), "\(s.rawValue): playing before leaving")
        return w
    }

    private func stopped(_ w: WKWebView) async -> Bool {
        for _ in 0..<20 { if await isPaused(w) { return true }; try? await Task.sleep(for: .milliseconds(200)) }
        return false
    }

    @Test func playingWorksAgainAfterNativeScreensAndBack() async throws {
        let r = try await rig(); defer { r.server.stop(); go(r, to: nil); r.hosts.handleMemoryPressure(critical: true) }
        let w = try await start(r, .youtube)
        go(r, to: nil)
        #expect(await stopped(w), "leaving stops the sound")
        try? await Task.sleep(for: .milliseconds(500))
        go(r, to: .youtube)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(await isPaused(w), "nothing resumes by itself")
        #expect(await playAndAdvance(w), "playing works after returning")
    }

    @Test func spotifyStopsWhenLeftAndPlaysAgainAfterReturning() async throws {
        let r = try await rig(); defer { r.server.stop(); go(r, to: nil); r.hosts.handleMemoryPressure(critical: true) }
        let w = try await start(r, .spotify)
        go(r, to: .youtube)
        #expect(await stopped(w), "leaving stops Spotify's sound")
        try? await Task.sleep(for: .milliseconds(500))
        go(r, to: .spotify)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(await isPaused(w), "nothing resumes by itself")
        #expect(await playAndAdvance(w), "playing works after returning")
    }

    @Test func playingWorksAgainAfterAnotherServiceAndBack() async throws {
        let r = try await rig(); defer { r.server.stop(); go(r, to: nil); r.hosts.handleMemoryPressure(critical: true) }
        let w = try await start(r, .youtube)
        go(r, to: .hulu)
        #expect(await stopped(w))
        try? await Task.sleep(for: .milliseconds(500))
        go(r, to: nil)
        go(r, to: .youtube)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(await isPaused(w))
        #expect(await playAndAdvance(w), "playing works after A -> B -> native -> A")
    }

    @Test func playingWorksAgainAfterTheRetentionRelease() async throws {
        let r = try await rig(releaseAfter: .milliseconds(300)); defer { r.server.stop(); go(r, to: nil); r.hosts.handleMemoryPressure(critical: true) }
        let first = try await start(r, .youtube)
        go(r, to: nil)
        let m = try #require(r.hosts.model(for: .youtube))
        #expect(await ServiceTestSupport.until(10) { m.webView == nil }, "released after the retention time")
        _ = first
        go(r, to: .youtube)
        #expect(await ServiceTestSupport.until(60) { m.webView?.title != nil && m.phase == .ready })
        m.load(r.server.url("/media"))
        #expect(await ServiceTestSupport.until(60) { m.webView?.title == "media" })
        let w2 = try #require(m.webView)
        #expect(!m.isMediaSuspended)
        #expect(await playAndAdvance(w2), "a rebuilt page plays")
    }

    /// Pinned WebKit behaviour the fix relies on: suspensions are counted, so the app must request one per hide.
    @Test func eachRepeatedPauseOfAHiddenServiceKeepsOneSuspensionOnly() async throws {
        let r = try await rig(); defer { r.server.stop(); go(r, to: nil); r.hosts.handleMemoryPressure(critical: true) }
        let w = try await start(r, .youtube)
        let m = try #require(r.hosts.model(for: .youtube))
        go(r, to: nil)
        r.hosts.pauseAll(); r.hosts.pauseAll(except: .hulu); m.pauseMedia()
        #expect(m.isMediaSuspended, "still suspended while hidden")
        #expect(await stopped(w))
        go(r, to: .youtube)
        #expect(!m.isMediaSuspended)
        #expect(await playAndAdvance(w), "one lift is enough however often it was paused while hidden")
    }
}
