import Testing
import WebKit
import AppKit
@testable import REDDY

/// Media on a switch, with a local audio fixture and the supported WebKit calls only. Playback may not start in a test process (autoplay
/// policy); then the run says so and only the call-level assertions apply.
@Suite("Service media", .serialized) @MainActor struct ServiceMediaTests {
    private func wav(seconds: Int = 20) -> Data {
        let rate = 8000, n = rate * seconds
        var d = Data("RIFF".utf8); func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }; func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        u32(36 + n * 2); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16); d.append(Data("data".utf8)); u32(n * 2)
        var s = Data(capacity: n * 2)
        for i in 0..<n { var x = Int16(0).littleEndian; _ = i; s.append(Data(bytes: &x, count: 2)) }          // silent: a real audio track of all-zero samples, never a sound
        return d + s
    }

    private func paused(_ web: WKWebView) async -> Bool { ((try? await web.evaluateJavaScript("document.getElementById('a').paused")) as? Bool) ?? true }          // test-only read of the local fixture

    // Changed from "switching pauses the first": a service now keeps playing while another destination shows (owner request). It stops only when
    // something else starts playing (ServiceMediaPolicy), and still never resumes by itself.
    @Test func switchingToAnotherServiceKeepsTheFirstPlayingUntilSomethingElseStarts() async throws {
        let server = try ServiceFixtureServer(); server.media = wav(); try await server.start(); defer { server.stop() }
        _ = NSApplication.shared
        let r = ServiceWebLifecycleTests.registry(server)
        let nav = ServiceNavigation(capabilities: .macOS); nav.hosts = r
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        defer { nav.returnToStreamSetu(); r.pauseAll(); r.handleMemoryPressure(critical: true); win.contentView = nil }
        nav.select(.youtube)
        let first = try #require(r.model(for: .youtube))
        win.contentView = first.hostedView(); first.hostedView().frame = win.contentView!.bounds
        _ = await ServiceTestSupport.until { first.phase == .ready }          // the start page first, so it cannot finish after the media page
        first.load(server.url("/media"))
        #expect(await ServiceTestSupport.until(60) { first.webView?.title == "media" }, "the local media page loaded")
        let web = try #require(first.webView)
        // Playing is waited for, not assumed: ask again until the page reports it is playing (bounded), so a slow moment cannot skip the checks below.
        var playing = false
        for _ in 0..<20 where !playing {
            _ = try? await web.evaluateJavaScript("document.getElementById('a').play()")
            try? await Task.sleep(for: .milliseconds(300))
            playing = await web.requestMediaPlaybackState() == .playing
        }
        #expect(playing, "the silent local audio started playing before the switch")
        nav.select(.hulu)          // service to service: the first keeps playing, in the background
        try? await Task.sleep(for: .milliseconds(800))
        let during = await web.requestMediaPlaybackState()
        print("MEASURE media switch: playing before=\(playing), state while another service shows=\(during.rawValue)")
        let stillPaused = await paused(web)
        #expect(during == .playing && !stillPaused, "switching does not stop the sound")
        #expect(!first.isMediaSuspended, "a background service is not suspended")
        r.otherMediaStarted(from: .service(.hulu))          // the other service starts playing: only now the first stops
        var after = await web.requestMediaPlaybackState(), isPaused = await paused(web)
        for _ in 0..<20 where after == .playing || !isPaused { try? await Task.sleep(for: .milliseconds(250)); after = await web.requestMediaPlaybackState(); isPaused = await paused(web) }
        #expect(after != .playing && isPaused, "another service starting stops it")
        nav.select(.youtube)
        try? await Task.sleep(for: .milliseconds(800))
        let back = await web.requestMediaPlaybackState()
        let backPaused = await paused(web)
        #expect(back != .playing && backPaused, "coming back never resumes by itself")
        #expect(r.liveIDs.count <= 2)
    }

    @Test func pauseAllReachesEveryLiveWebViewExceptTheOneShowing() async throws {
        let server = try ServiceFixtureServer(); server.media = wav(); try await server.start(); defer { server.stop() }
        _ = NSApplication.shared
        var counts: [ProviderID: Int] = [:]
        let r = ServiceHostRegistry(makeModel: { d in
            let m = ServiceWebModel(definition: ServiceTestSupport.fixture(d.id, server), dataStore: { .nonPersistent() })
            return m
        })
        let a = try #require(r.model(for: .hulu)), b = try #require(r.model(for: .peacock))
        a.serviceBecameVisible(); b.serviceBecameVisible()
        #expect(await ServiceTestSupport.until { a.phase == .ready && b.phase == .ready })
        r.pauseAll(except: .peacock); counts[.hulu] = 1
        await r.pauseAllAndWait()          // completion is awaited: returns only after every page has paused
        #expect(a.webView != nil && b.webView != nil, "pausing never releases or reloads")
        #expect(a.phase == .ready && b.phase == .ready)
        a.serviceBecameHidden(); b.serviceBecameHidden()
        r.pauseAll()          // Changed: the pages' paused state is also recorded (critical pressure keeps a view that is still recorded as playing)
        r.handleMemoryPressure(critical: true)
        #expect(r.liveIDs.isEmpty)
    }

    // Changed: `ServiceGuardActions.playerStarted` is gone; the coordinator does it (see AudioOwnershipTests for the full matrix).
    @Test func theAppsOwnPlayerStartingStopsServiceMedia() {
        let o = AudioOwnership(); let service = FakeAudioParticipant(.service(.hulu), playing: true)
        o.register(service)
        o.claim(.nativePlayer, reason: .nativePlay)
        #expect(!service.isPlaying)
    }

    @Test func noMediaCallResumesOrUsesPrivateWays() throws {
        let src = try ServiceSources.runtime()
        #expect(src.contains("pauseAllMediaPlayback") && src.contains("closeAllMediaPresentations"))
        #expect(!src.contains("_WK") && !src.contains("value(forKey") && !src.contains("resumeAllMediaPlayback"))
        // The only public suspension calls: suspend on hide, lift on show (which never starts playback).
        #expect(src.components(separatedBy: "setAllMediaPlaybackSuspended(").count - 1 == 2)
        #expect(!src.contains("evaluateJavaScript") && !src.contains(".play()"), "the app never plays or reads the page")
    }

    @Test func aHiddenServiceCannotBePlayedByItsPage() async throws {
        let server = try ServiceFixtureServer(); server.media = wav(); try await server.start(); defer { server.stop() }
        _ = NSApplication.shared
        let m = ServiceWebModel(definition: ServiceTestSupport.fixture(.hulu, server), dataStore: { .nonPersistent() })
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        defer { m.serviceBecameHidden(); m.releaseResources(); win.contentView = nil }
        m.serviceBecameVisible(); win.contentView = m.hostedView(); m.hostedView().frame = win.contentView!.bounds
        _ = await ServiceTestSupport.until { m.phase == .ready }
        m.load(server.url("/media-replay"))
        #expect(await ServiceTestSupport.until(60) { m.webView?.title == "media-replay" })
        let web = try #require(m.webView)
        var playing = false
        for _ in 0..<30 where !playing { try? await Task.sleep(for: .milliseconds(300)); playing = await web.requestMediaPlaybackState() == .playing }
        #expect(!m.isMediaSuspended, "a showing service is not suspended")
        // Changed: hiding alone no longer suspends (a hidden service keeps playing); a stop rule (another service or the player starts) does.
        m.serviceBecameHidden()
        #expect(!m.isMediaSuspended, "hiding alone does not suspend playback")
        m.pauseMedia()
        #expect(m.isMediaSuspended, "a stop rule suspends playback, not only a one-off pause")
        // the page asks to play every 150 ms: for two seconds it must never be playing
        var everPlaying = false
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(200)); if await web.requestMediaPlaybackState() == .playing { everPlaying = true } }
        print("MEASURE hidden replay: playing before hide=\(playing), playing while hidden=\(everPlaying)")
        #expect(!everPlaying, "a retained, hidden page cannot make sound again")
        m.serviceBecameVisible()
        #expect(!m.isMediaSuspended, "showing lifts the suspension")
    }

    @Test func returningToAPausedServiceNeverStartsItAndLiftsTheSuspension() async throws {
        let server = try ServiceFixtureServer(); server.media = wav(); try await server.start(); defer { server.stop() }
        _ = NSApplication.shared
        let m = ServiceWebModel(definition: ServiceTestSupport.fixture(.hulu, server), dataStore: { .nonPersistent() })
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        defer { m.serviceBecameHidden(); m.releaseResources(); win.contentView = nil }
        m.serviceBecameVisible(); win.contentView = m.hostedView(); m.hostedView().frame = win.contentView!.bounds
        _ = await ServiceTestSupport.until { m.phase == .ready }
        m.load(server.url("/media"))
        #expect(await ServiceTestSupport.until(60) { m.webView?.title == "media" })
        let web = try #require(m.webView)
        var playing = false
        for _ in 0..<20 where !playing {
            _ = try? await web.evaluateJavaScript("document.getElementById('a').play()")
            try? await Task.sleep(for: .milliseconds(300))
            playing = await web.requestMediaPlaybackState() == .playing
        }
        #expect(playing)
        m.serviceBecameHidden()          // changed: hiding keeps playing; the stop rule is what pauses and suspends
        m.pauseMedia()
        #expect(await ServiceTestSupport.until(10) { m.isMediaSuspended })
        try? await Task.sleep(for: .milliseconds(600))
        m.serviceBecameVisible()
        #expect(!m.isMediaSuspended)
        try? await Task.sleep(for: .milliseconds(1000))
        let stateBack = await web.requestMediaPlaybackState(), pausedBack = await paused(web)
        #expect(stateBack != .playing && pausedBack, "returning shows the page with playback still paused")
        #expect(m.webView === web, "the page was kept, not reloaded")
    }
}
