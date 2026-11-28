import Testing
import WebKit
import AppKit
@testable import REDDY

/// Services keep playing when another destination shows and stop only when something else starts: the policy matrix, retention of playing
/// views, the poller's start and stop, the badge, and (opt in) a parked web view that keeps playing audio. No real provider, no owner data.
@MainActor private final class FakeProbe: ServiceMediaProbing {
    var states: [ProviderID: ServiceMediaState] = [:]
    private(set) var calls = 0
    func playbackState(of id: ProviderID) async -> ServiceMediaState { calls += 1; return states[id] ?? .paused }
}

@MainActor private final class ManualScheduler: PollScheduling {
    private(set) var started = 0, cancelled = 0
    var active: Bool { started > cancelled }
    func schedule(every interval: Duration, tick: @escaping @MainActor () async -> Void) -> PollHandle {
        started += 1
        return PollHandle { [weak self] in self?.cancelled += 1 }
    }
}

@MainActor private final class Rig {
    let probe = FakeProbe(), scheduler = ManualScheduler()
    // Changed: the podcast and native players are participants of the registry's AudioOwnership (no more pausePodcast / pauseNativePlayer closures).
    let podcast = FakeAudioParticipant(.podcasts), native = FakeAudioParticipant(.nativePlayer)
    var podcastPaused: Int { podcast.pauseCount }
    var nativePaused: Int { native.pauseCount }
    let hosts: ServiceHostRegistry
    init(budget: MemoryBudget = .standard) {
        var tick = 0
        let p = probe, s = scheduler
        var clock: () -> Date = { Date() }
        hosts = ServiceHostRegistry(registry: .standard, budget: budget, clock: { clock() }, mediaProbe: p, mediaScheduler: s,
                                    makeModel: { ServiceWebModel(definition: $0, dataStore: { .nonPersistent() }) })
        clock = { tick += 1; return Date(timeIntervalSince1970: 2_000_000 + Double(tick)) }          // every read is later than the one before
        hosts.ownership.register(podcast); hosts.ownership.register(native)
    }
    /// A service that shows, and one that has been playing and is then hidden.
    func show(_ id: ProviderID) { hosts.didBecomeVisible(id) }
    func playThenHide(_ id: ProviderID) { hosts.didBecomeVisible(id); hosts.media.apply(.playing, to: id); hosts.didBecomeHidden(id) }
}

@Suite("Background media policy") @MainActor struct ServiceMediaPolicyTests {
    // the matrix of the owner's rules, as plans

    @Test func switchingBetweenServicesOrToNativeTabsPausesNothing() {
        #expect(ServiceMediaPolicy.navigation(from: .youtube, to: .hulu).services == .none)
        #expect(ServiceMediaPolicy.navigation(from: .youtube, to: nil) == .nothing, "back to StreamSetu's tabs")
        #expect(ServiceMediaPolicy.navigation(from: nil, to: nil) == .nothing)
    }

    @Test func enteringAServiceOnlyPausesTheNativeVideoPlayerNeverThePodcastOrServices() {
        let plan = ServiceMediaPolicy.navigation(from: nil, to: .spotify)
        #expect(plan == MediaStopPlan(pausesNativePlayer: true))
        #expect(!plan.pausesPodcast && plan.services == .none)
    }

    // Changed: every claim pauses every other participant (and the native player when a service plays).
    @Test func theNativePlayerStartingPausesEveryServiceAndThePodcast() {
        #expect(ServiceMediaPolicy.otherMediaStarted(from: .nativePlayer) == MediaStopPlan(services: .all, pausesPodcast: true, pausesMusic: true))
    }

    @Test func podcastsStartingPauseEveryOtherParticipant() {
        #expect(ServiceMediaPolicy.otherMediaStarted(from: .podcasts) == MediaStopPlan(services: .all, pausesMusic: true, pausesNativePlayer: true))
    }

    @Test func aServicePlayingPausesEveryOtherParticipantButNotItself() {
        #expect(ServiceMediaPolicy.otherMediaStarted(from: .service(.hulu)) == MediaStopPlan(services: .allExcept(.hulu), pausesPodcast: true, pausesMusic: true, pausesNativePlayer: true))
    }

    @Test func kidsLockBlockedAndSignOutStopEverything() {
        for r: MediaSafetyStop in [.kidsProfile, .locked, .blocked, .signedOut] { #expect(ServiceMediaPolicy.safety(r).services == .all) }
    }

    @Test func typingInSearchPausesNothing() { #expect(ServiceMediaPolicy.searchStarted().isEmpty) }

    // the policy run by the registry

    @Test func aServiceStartingPlayingWhileVisiblePausesTheOthersAndThePodcast() async {
        let r = Rig()
        r.playThenHide(.youtube)
        #expect(r.hosts.media.playingIDs == [.youtube])
        r.show(.hulu)
        r.probe.states = [.youtube: .playing, .hulu: .playing]          // B starts while A still plays
        await r.hosts.media.tick()
        #expect(r.hosts.media.playingIDs == [.hulu], "A was paused by the rule, B plays")
        #expect(r.podcastPaused == 1 && r.nativePaused == 1, "Changed: a service playing now also pauses the native player")
    }

    @Test func switchingAwayFromAPlayingServiceDoesNotStopIt() {
        let r = Rig()
        r.playThenHide(.youtube)
        r.show(.hulu)          // another service
        #expect(r.hosts.media.playingIDs == [.youtube] && r.podcastPaused == 0)
        r.hosts.didBecomeHidden(.hulu)          // back to a native tab
        #expect(r.hosts.media.playingIDs == [.youtube])
        #expect(r.hosts.backgroundPlayingIDs == [.youtube])
    }

    @Test func podcastAndNativePlayerStartsPauseTheServices() {
        let r = Rig()
        r.playThenHide(.youtube)
        r.hosts.otherMediaStarted(from: .podcasts)
        #expect(r.hosts.media.playingIDs.isEmpty && r.podcastPaused == 0, "the podcast is the source: it is not paused")
        r.playThenHide(.hulu)
        r.hosts.otherMediaStarted(from: .nativePlayer)
        #expect(r.hosts.media.playingIDs.isEmpty && r.podcastPaused == 1)
    }

    @Test func safetyStopsPauseEverything() {
        for reason: MediaSafetyStop in [.kidsProfile, .locked, .blocked, .signedOut] {
            let r = Rig()
            r.playThenHide(.youtube); r.playThenHide(.hulu)
            r.hosts.safetyStop(reason)
            #expect(r.hosts.media.playingIDs.isEmpty, "\(reason)")
        }
    }

    @Test func searchTypingLeavesAPlayingServiceAlone() {
        let r = Rig()
        r.playThenHide(.youtube)
        let nav = ServiceNavigation(capabilities: .macOS); nav.select(.hulu)
        ServiceGuardActions.searchStarted(services: nav)
        #expect(nav.navExpanded && r.hosts.media.playingIDs == [.youtube])
    }
}

@Suite("Background media retention") @MainActor struct BackgroundRetentionTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func used(_ pairs: [(ProviderID, Double)]) -> [ProviderID: Date] { Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, t0.addingTimeInterval($0.1)) }) }

    @Test func aPlayingHiddenViewIsExemptFromTheBudgetAndOthersAreEvictedAsBefore() {
        let live: [ProviderID] = [.netflix, .hulu, .youtube, .peacock]
        let u = used([(.netflix, 1), (.hulu, 2), (.youtube, 3), (.peacock, 4)])
        #expect(RetentionPlan.releaseList(live: live, lastUsed: u, visible: .peacock, budget: 2) == [.netflix, .hulu])
        #expect(RetentionPlan.releaseList(live: live, lastUsed: u, visible: .peacock, budget: 2, held: [.netflix]) == [.hulu], "the playing, oldest view stays")
        #expect(RetentionPlan.releaseList(live: live, lastUsed: u, visible: .peacock, budget: 0, held: [.netflix, .hulu]) == [.youtube])
    }

    @Test func theCapPausesTheLeastRecentlyUsedPlayingViewsBeyondIt() {
        let playing: Set<ProviderID> = [.netflix, .hulu, .youtube, .peacock, .spotify]
        let u = used([(.netflix, 5), (.hulu, 1), (.youtube, 2), (.peacock, 3), (.spotify, 4)])
        #expect(RetentionPlan.pauseOverCap(playing: playing, lastUsed: u, visible: nil, cap: 4) == [.hulu])
        #expect(RetentionPlan.pauseOverCap(playing: playing, lastUsed: u, visible: .hulu, cap: 4) == [.youtube], "the visible one is never paused")
        #expect(RetentionPlan.pauseOverCap(playing: playing, lastUsed: u, visible: nil, cap: 2) == [.hulu, .youtube, .peacock])
        #expect(RetentionPlan.pauseOverCap(playing: [.hulu], lastUsed: u, visible: nil, cap: 4).isEmpty)
        #expect(MemoryBudget.standard.maxPlayingViews == 4)
    }

    @Test func underCriticalPressureThePlayingViewThatStartedFirstGoesFirst() {
        let since = used([(.netflix, 30), (.hulu, 10), (.youtube, 20)])
        #expect(RetentionPlan.pressureVictim(playing: [.netflix, .hulu, .youtube], playingSince: since, visible: nil) == .hulu)
        #expect(RetentionPlan.pressureVictim(playing: [.netflix, .hulu, .youtube], playingSince: since, visible: .hulu) == .youtube)
        #expect(RetentionPlan.pressureVictim(playing: [], playingSince: since, visible: nil) == nil)
    }

    // Changed: async; a service just hidden is held until its one probe returns (eviction safety), so the idle ones are evicted after the probes settle.
    @Test func theRegistryKeepsAPlayingHiddenViewAndEvictsTheIdleOnes() async {
        let r = Rig()
        func open(_ id: ProviderID) { _ = r.hosts.model(for: id)?.hostedView(); r.show(id) }          // a web view is made when a service is first shown
        open(.hulu); r.hosts.media.apply(.playing, to: .hulu); r.hosts.didBecomeHidden(.hulu)
        for id: ProviderID in [.netflix, .peacock] { open(id); r.hosts.didBecomeHidden(id) }
        open(.youtube)
        await r.hosts.media.settleProbes()
        #expect(r.hosts.liveIDs.contains(.hulu), "playing: kept although it is the oldest and over the budget")
        #expect(!r.hosts.liveIDs.contains(.netflix), "idle and oldest of the rest: evicted as before")
        #expect(r.hosts.liveIDs.count == 3)
        r.hosts.media.stopped(.hulu)          // it stopped playing: no longer exempt
        r.hosts.applyRetention(budget: r.hosts.budget.maxLiveWebViews)
        #expect(!r.hosts.liveIDs.contains(.hulu))
        r.hosts.releaseHidden(); r.hosts.pauseAll()
    }

    @Test func theRegistryEnforcesTheCapOnPlayingViews() {
        let r = Rig()
        let ids: [ProviderID] = [.netflix, .hulu, .youtube, .peacock, .spotify]
        for id in ids { r.show(id); r.hosts.media.apply(.playing, to: id); r.hosts.didBecomeHidden(id) }
        r.hosts.mediaChanged()
        #expect(r.hosts.media.playingIDs.count == 4)
        #expect(!r.hosts.media.playingIDs.contains(.netflix), "the least recently used one was paused")
    }

    @Test func criticalPressurePausesOnePlayingViewPerEventFirstInFirstOut() {
        let r = Rig()
        for id: ProviderID in [.netflix, .hulu, .youtube] { _ = r.hosts.model(for: id); r.show(id); r.hosts.media.apply(.playing, to: id); r.hosts.didBecomeHidden(id) }
        r.hosts.handleMemoryPressure(critical: false)
        #expect(r.hosts.media.playingIDs.count == 3, "a warning keeps playing views")
        r.hosts.handleMemoryPressure(critical: true)
        #expect(r.hosts.media.playingIDs == [.hulu, .youtube], "the first to start went first")
        r.hosts.handleMemoryPressure(critical: true)
        #expect(r.hosts.media.playingIDs == [.youtube])
    }

    @Test func theRetentionTimeDoesNotReleaseAViewThatIsPlaying() {
        let r = Rig()
        let m = r.hosts.model(for: .hulu)!
        #expect(!m.holdsHiddenView())
        r.playThenHide(.hulu)
        #expect(m.holdsHiddenView())
        r.hosts.media.stopped(.hulu)
        #expect(!m.holdsHiddenView())
    }
}

@Suite("Background media poller") @MainActor struct BackgroundPollerTests {
    @Test func nothingIsPolledWhenNothingShowsOrPlays() {
        let r = Rig()
        #expect(!r.hosts.media.isPolling && r.scheduler.started == 0 && r.probe.calls == 0)
        r.hosts.pauseAll(); r.hosts.handleMemoryPressure(critical: true)
        #expect(!r.hosts.media.isPolling && r.scheduler.started == 0)
    }

    @Test func aVisibleServiceIsWatchedAndWatchingEndsWhenItHidesWithoutPlaying() {
        let r = Rig()
        r.show(.youtube)
        #expect(r.hosts.media.isPolling && r.scheduler.started == 1)
        r.hosts.didBecomeHidden(.youtube)
        #expect(!r.hosts.media.isPolling && !r.scheduler.active, "it was not playing: nothing to poll")
    }

    @Test func aHiddenPlayingServiceIsPolledUntilItStops() async {
        let r = Rig()
        r.playThenHide(.youtube)
        #expect(r.hosts.media.isPolling)
        r.probe.states[.youtube] = .playing
        await r.hosts.media.tick()
        #expect(r.hosts.media.isPolling && r.hosts.media.playingIDs == [.youtube])
        r.probe.states[.youtube] = .paused
        await r.hosts.media.tick()
        #expect(r.hosts.media.isPolling, "one miss is a track change, not a stop")
        await r.hosts.media.tick()
        #expect(!r.hosts.media.isPolling && !r.scheduler.active && r.hosts.media.playingIDs.isEmpty)
    }

    @Test func aReleasedViewEndsItsPollingAtOnce() async {
        let r = Rig()
        r.playThenHide(.youtube)
        r.probe.states[.youtube] = .noView
        await r.hosts.media.tick()
        #expect(!r.hosts.media.isPolling)
    }

    @Test func pausingEverythingStopsThePolling() {
        let r = Rig()
        r.playThenHide(.youtube)
        r.hosts.pauseAll()
        #expect(!r.hosts.media.isPolling)
    }

    @Test func onlyThePublicPlaybackStateIsUsed() throws {
        let src = try String(contentsOf: ServiceSources.root.appendingPathComponent("Services/Streaming/Runtime/ServiceMediaMonitor.swift"), encoding: .utf8)
        #expect(src.contains("requestMediaPlaybackState"))
        for token in ["evaluateJavaScript", "WKUserScript", "WKScriptMessageHandler", "_WK", "value(forKey", "addScriptMessageHandler"] { #expect(!src.contains(token), "\(token)") }
    }
}

@Suite("Background media badge") @MainActor struct BackgroundBadgeTests {
    @Test func theBadgeShowsOnABackgroundServiceOnly() {
        let r = Rig()
        r.playThenHide(.youtube)
        #expect(r.hosts.backgroundPlayingIDs == [.youtube])
        r.show(.youtube)
        #expect(r.hosts.backgroundPlayingIDs.isEmpty, "the one showing carries no badge")
        r.hosts.didBecomeHidden(.youtube)
        r.hosts.pauseAll()
        #expect(r.hosts.backgroundPlayingIDs.isEmpty)
    }

    @Test func theBindingAndTheLabelCarryPlaying() {
        var nav = ServicesNavigationBinding.empty
        #expect(!nav.isPlaying(.spotify))
        nav.playing = [.spotify]
        #expect(nav.isPlaying(.spotify) && !nav.isPlaying(.hulu))
        #expect(ServiceAccessibility.openLabel(.spotify, availability: .unverified, active: false, pinned: true, playing: true) == "Spotify, pinned, Playing")
        #expect(ServiceAccessibility.openLabel(.hulu, availability: .unverified, active: false, pinned: false) == "Hulu", "the old labels are unchanged")
        #expect(ServiceAccessibility.playingLabel == "Playing")
    }

    @Test func chipSizesAreUnchangedAndTheBadgeIsStatic() throws {
        #expect(ServiceChip.iconSize == 22 && ServiceChip.hitWidth == 32)
        let src = try String(contentsOf: ServiceSources.root.appendingPathComponent("Features/Streaming/ServicesDropdown.swift"), encoding: .utf8)
        let start = src.range(of: "struct ServiceGlyph")!.lowerBound, end = src.range(of: "/// The opaque, theme-driven surface")!.lowerBound
        let glyph = String(src[start..<end])
        #expect(glyph.contains("speaker.wave.2.fill") && !glyph.contains(".animation(") && !glyph.contains("withAnimation"), "static: nothing to hold back for Reduce Motion")
    }
}

@Suite("Background media parking", .serialized) @MainActor struct BackgroundParkingTests {
    // Changed: parking is opt-in (services.parking.enabled, default off); this test turns it on with its own defaults.
    @Test func aWebViewIsParkedInTheWindowNotRemovedWhenTheWindowExists() {
        _ = NSApplication.shared
        let d = UserDefaults(suiteName: "parking-\(UUID())")!; d.set(true, forKey: ServiceWebParking.defaultsKey)
        ServiceWebParking.shared.defaults = d
        defer { ServiceWebParking.shared.defaults = .standard }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)); win.contentView = NSView(); win.contentView?.addSubview(host)
        defer { ServiceWebParking.shared.register(nil); win.contentView = nil }
        ServiceWebParking.shared.register(host)
        let web = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        ServiceWebParking.shared.park(web)
        #expect(web.superview === host && web.window === win && !web.isHidden, "still in the window and not hidden")
        #expect(web.frame.size == NSSize(width: 800, height: 600), "it keeps its size")
    }

    @Test func parkingIsOffByDefaultAndDetachesInstead() {
        let d = UserDefaults(suiteName: "parking-\(UUID())")!
        #expect(!ServiceWebParking.isEnabled(d), "experimental: off until the integrator flips the default")
        let host = NSView(), web = NSView(); host.addSubview(web)
        ServiceWebParking.shared.defaults = d; defer { ServiceWebParking.shared.defaults = .standard }
        ServiceWebParking.shared.register(host); defer { ServiceWebParking.shared.register(nil) }
        ServiceWebParking.shared.park(web)
        #expect(web.superview == nil, "detached, not parked (the model still holds the view)")
    }

    @Test func withNoWindowToParkInTheViewIsRemoved() {
        ServiceWebParking.shared.register(nil)
        let holder = NSView(), web = NSView(); holder.addSubview(web)
        ServiceWebParking.shared.park(web)
        #expect(web.superview == nil)
    }

    @Test func theHostViewParksInsteadOfRemoving() throws {
        let src = try String(contentsOf: ServiceSources.root.appendingPathComponent("Features/Streaming/ServiceHostView.swift"), encoding: .utf8)
        #expect(src.contains("ServiceWebParking.shared.park($0)"))
        let root = try String(contentsOf: ServiceSources.root.appendingPathComponent("Application/RootView.swift"), encoding: .utf8)
        #expect(root.contains("ServiceWebParkingAnchor()"))
    }
}

/// Opt in (needs a real window and an audio device): a service's web view moved into the parking view keeps playing, and one removed from the
/// window is measured for comparison. Run with REDDY_BACKGROUND_AUDIO=1.
@Suite("Background audio (opt in)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["REDDY_BACKGROUND_AUDIO"] != nil)) @MainActor struct BackgroundAudioTests {
    private func wav(seconds: Int = 30) -> Data {
        let rate = 8000, n = rate * seconds
        var d = Data("RIFF".utf8); func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }; func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        u32(36 + n * 2); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16); d.append(Data("data".utf8)); u32(n * 2)
        d.append(Data(count: n * 2))          // silent samples: a real audio track, never a sound
        return d
    }
    private func time(_ w: WKWebView) async -> Double { ((try? await w.evaluateJavaScript("document.getElementById('a').currentTime")) as? Double) ?? -1 }          // test-only read of the local fixture

    /// Runs for both modes so the integrator can choose the parking default from evidence: `parked` moves the view into the 1 by 1 parking view;
    /// otherwise it is only detached (what the app does with parking off; the model keeps it). Detached mode reports and does not fail: whether WebKit
    /// keeps a windowless view playing is the question being measured.
    @Test(arguments: [true, false]) func aHiddenWebViewKeepsPlaying(parked: Bool) async throws {
        let server = try ServiceFixtureServer(); server.media = wav(); try await server.start(); defer { server.stop() }
        _ = NSApplication.shared
        let m = ServiceWebModel(definition: ServiceTestSupport.fixture(.spotify, server), dataStore: { .nonPersistent() })
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: win.contentRect(forFrameRect: win.frame)), shown = NSView(frame: root.bounds)
        let parking = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)); parking.wantsLayer = true; parking.layer?.masksToBounds = true
        root.addSubview(shown); root.addSubview(parking); win.contentView = root
        ServiceWebParking.shared.register(parking)
        defer { m.serviceBecameHidden(); m.releaseResources(); ServiceWebParking.shared.register(nil); win.contentView = nil }
        m.serviceBecameVisible(); let web = m.hostedView(); web.frame = shown.bounds; shown.addSubview(web)
        _ = await ServiceTestSupport.until { m.phase == .ready }
        m.load(server.url("/media"))
        #expect(await ServiceTestSupport.until(60) { m.webView?.title == "media" })
        var playing = false
        for _ in 0..<20 where !playing {
            _ = try? await web.evaluateJavaScript("document.getElementById('a').play().catch(function(){})")
            try? await Task.sleep(for: .milliseconds(400))
            playing = await web.requestMediaPlaybackState() == .playing
        }
        #expect(playing, "playing before it is parked")
        let d = UserDefaults(suiteName: "bgaudio-\(UUID())")!; d.set(parked, forKey: ServiceWebParking.defaultsKey)
        ServiceWebParking.shared.defaults = d; defer { ServiceWebParking.shared.defaults = .standard }
        m.serviceBecameHidden(); ServiceWebParking.shared.park(web)          // what leaving the service does (parks when parking is on, detaches otherwise)
        let t0 = await time(web)
        try? await Task.sleep(for: .seconds(3))
        let t1 = await time(web), state = await web.requestMediaPlaybackState()
        print("MEASURE \(parked ? "parked" : "detached"): state=\(state.rawValue) currentTime \(t0) -> \(t1) keptPlaying=\(state == .playing && t1 > t0 + 2)")
        if parked { #expect(state == .playing && t1 > t0 + 2, "the parked page kept playing, in real time") }
        #expect(!m.isMediaSuspended)
    }
}
