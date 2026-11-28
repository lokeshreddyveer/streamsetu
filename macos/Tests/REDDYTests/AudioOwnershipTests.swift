import Testing
import WebKit
import AppKit
import MediaPlayer
@testable import REDDY

// The audio coordinator, the remote command router, eviction safety, termination and eligibility stops, the setting, the badge, and the opt-in
// measurements. No real provider, no owner data. Polling is best effort by design (WebKit offers no event); these tests use fake probes and clocks.

@MainActor final class FakeAudioParticipant: AudioParticipant {
    let audioID: MediaSource
    var isPlaying: Bool
    private(set) var pauseCount = 0
    init(_ id: MediaSource, playing: Bool = false) { audioID = id; isPlaying = playing }
    func pause() { pauseCount += 1; isPlaying = false }
    /// What a native player does after it claimed: it starts.
    func start() { isPlaying = true }
}

@MainActor private final class OwnProbe: ServiceMediaProbing {
    var states: [ProviderID: ServiceMediaState] = [:]
    private var waiting: [ProviderID: CheckedContinuation<ServiceMediaState, Never>] = [:]
    var gated: Set<ProviderID> = []
    func playbackState(of id: ProviderID) async -> ServiceMediaState {
        if gated.contains(id) { return await withCheckedContinuation { waiting[id] = $0 } }
        return states[id] ?? .paused
    }
    func isWaiting(_ id: ProviderID) -> Bool { waiting[id] != nil }
    func answer(_ id: ProviderID, _ s: ServiceMediaState) { gated.remove(id); waiting.removeValue(forKey: id)?.resume(returning: s) }
}

@MainActor private final class OwnScheduler: PollScheduling {
    private(set) var intervals: [Duration] = []
    private(set) var cancelled = 0
    func schedule(every interval: Duration, tick: @escaping @MainActor () async -> Void) -> PollHandle {
        intervals.append(interval)
        return PollHandle { [weak self] in self?.cancelled += 1 }
    }
}

@MainActor private final class OwnRig {
    let probe = OwnProbe(), scheduler = OwnScheduler(), ownership = AudioOwnership()
    let defaults: UserDefaults
    let podcast = FakeAudioParticipant(.podcasts), native = FakeAudioParticipant(.nativePlayer), third = FakeAudioParticipant(.service(.crunchyroll))
    let hosts: ServiceHostRegistry
    init(budget: MemoryBudget = .standard, keepPlaying: Bool = true) {
        defaults = UserDefaults(suiteName: "own-\(UUID())")!
        ServicePreferences.setKeepsPlayingInBackground(keepPlaying, in: defaults)
        ownership.diagnostics = MediaDiagnostics()
        var t = 0
        let clock: () -> Date = { t += 1; return Date(timeIntervalSince1970: 3_000_000 + Double(t)) }          // every read is a second later (the fake clock)
        hosts = ServiceHostRegistry(registry: .standard, budget: budget, clock: clock, mediaProbe: probe, mediaScheduler: scheduler, ownership: ownership, defaults: defaults,
                                    makeModel: { ServiceWebModel(definition: $0, dataStore: { .nonPersistent() }) })
        ownership.register(podcast); ownership.register(native); ownership.register(third)
    }
    func open(_ id: ProviderID) { _ = hosts.model(for: id)?.hostedView(); hosts.didBecomeVisible(id) }
    func finish() { hosts.releaseHidden(); hosts.pauseAll() }
    /// The page obeys a pause: a service the registry no longer holds as playing reads as paused.
    func settlePages(_ ids: [ProviderID]) { for id in ids where !hosts.media.playingIDs.contains(id) { probe.states[id] = .paused } }
    var playingCount: Int { ownership.playing.count }
}

@Suite("Audio ownership") @MainActor struct AudioOwnershipCoreTests {
    @Test func aClaimPausesEveryOtherParticipantBeforeItReturns() {
        let o = AudioOwnership(); o.diagnostics = MediaDiagnostics()
        let all: [FakeAudioParticipant] = [.init(.nativePlayer, playing: true), .init(.podcasts, playing: true), .init(.service(.crunchyroll), playing: true), .init(.service(.hulu), playing: true), .init(.service(.youtube), playing: true)]
        all.forEach { o.register($0) }
        let g = o.claim(.service(.crunchyroll), reason: .servicePlaySeen)
        #expect(g == 1 && o.owner == .service(.crunchyroll))
        for p in all { #expect(p.isPlaying == (p.audioID == .service(.crunchyroll)), "\(p.audioID)") }
        #expect(all.first { $0.audioID == .service(.crunchyroll) }!.pauseCount == 0, "the claimant is never paused")
    }

    @Test func claimingAgainAsTheOwnerIsIdempotentAndNeverPausesIt() {
        let o = AudioOwnership(); o.diagnostics = MediaDiagnostics()
        let third = FakeAudioParticipant(.service(.crunchyroll)), pod = FakeAudioParticipant(.podcasts)
        o.register(third); o.register(pod)
        let g1 = o.claim(.service(.crunchyroll), reason: .servicePlaySeen); third.start()
        let g2 = o.claim(.service(.crunchyroll), reason: .servicePlaySeen)
        #expect(g1 == g2 && o.generation == 1 && third.pauseCount == 0 && third.isPlaying)
        pod.start()          // something started meanwhile: the owner's next claim silences it
        o.claim(.service(.crunchyroll), reason: .servicePlaySeen)
        #expect(!pod.isPlaying && third.isPlaying && o.generation == 1)
    }

    @Test func aLateObservationFromAnOlderGenerationNeverPausesTheNewestOwner() {
        let o = AudioOwnership(); o.diagnostics = MediaDiagnostics()
        let a = FakeAudioParticipant(.service(.hulu)), b = FakeAudioParticipant(.podcasts)
        o.register(a); o.register(b)
        let ga = o.claim(.service(.hulu), reason: .servicePlaySeen)!; a.start()
        let gb = o.claim(.podcasts, reason: .podcastPlay)!; b.start()
        #expect(gb > ga && o.owner == .podcasts)
        let pausesBefore = b.pauseCount          // the first claim (by A) already told B to pause once, as every claim does
        let late = o.claim(.service(.hulu), reason: .servicePlaySeen, observedAt: ga)          // A's late "playing" arrives
        #expect(late == nil && o.owner == .podcasts && b.isPlaying && b.pauseCount == pausesBefore, "B stays the owner and is not paused; A is not re-claimed")
        #expect(o.staleIgnored == 1 && o.diagnostics.counts["ownership.stale"] == 1)
        #expect(!o.release(.service(.hulu), generation: ga), "a late stop from an old owner is ignored too")
        #expect(o.release(.podcasts) && o.owner == nil)
    }

    @Test func aClaimStormAlwaysLeavesExactlyOneOwnerAndOnePlayingParticipant() {
        let o = AudioOwnership(); o.diagnostics = MediaDiagnostics()
        let ids: [MediaSource] = [.nativePlayer, .podcasts, .service(.crunchyroll), .service(.hulu), .service(.youtube), .service(.peacock)]
        let ps = Dictionary(uniqueKeysWithValues: ids.map { ($0, FakeAudioParticipant($0)) })
        ps.values.forEach { o.register($0) }
        var seed: UInt64 = 42
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        var last: UInt64 = 0
        for _ in 0..<500 {
            let id = ids[next() % ids.count]
            if next() % 5 == 0 { if o.release(id) { ps[id]!.isPlaying = false } }          // the owner stopped
            else if o.claim(id, reason: .other) != nil { ps[id]!.start() }          // claim BEFORE it starts
            #expect(o.generation >= last); last = o.generation
            let playing = ps.values.filter(\.isPlaying)
            #expect(playing.count <= 1)
            if let p = playing.first { #expect(o.owner == p.audioID) }
        }
    }

    @Test func unregisteringTheOwnerReleasesIt() {
        let o = AudioOwnership(); o.diagnostics = MediaDiagnostics()
        o.register(FakeAudioParticipant(.service(.crunchyroll))); o.claim(.service(.crunchyroll), reason: .servicePlaySeen)
        o.unregister(.service(.crunchyroll))
        #expect(o.owner == nil && o.participant(.service(.crunchyroll)) == nil)
    }

    @Test func ownershipChangesAreCountedByReasonCodeOnly() {
        let o = AudioOwnership(); let d = MediaDiagnostics(); o.diagnostics = d
        o.claim(.service(.crunchyroll), reason: .servicePlaySeen); o.claim(.podcasts, reason: .podcastPlay); o.release(.podcasts, reason: .terminated)
        #expect(d.counts["ownership.service-play-seen"] == 1 && d.counts["ownership.podcast-play"] == 1 && d.counts["ownership.release.terminated"] == 1)
        d.parked(+1); d.parked(+1); d.parked(-1)
        #expect(d.parkedNow == 1 && d.counts["parked.added"] == 2 && d.counts["parked.removed"] == 1)
        #expect(d.lines.allSatisfy { !$0.contains("http") && !$0.contains("/") })
    }
}

@Suite("Navigation never claims") @MainActor struct NavigationNeverClaimsTests {
    @Test func navigatingWhileAnotherSourcePlaysLeavesTheOwnerAlone() {
        let r = OwnRig()
        r.ownership.claim(.service(.crunchyroll), reason: .servicePlaySeen); r.third.start()
        let g = r.ownership.generation
        r.hosts.didBecomeVisible(.hulu); r.hosts.didBecomeHidden(.hulu); r.hosts.didBecomeVisible(.youtube)
        let nav = ServiceNavigation(capabilities: .macOS); nav.select(.hulu); ServiceGuardActions.searchStarted(services: nav); nav.selectPodcasts(); nav.returnToStreamSetu()
        #expect(r.ownership.owner == .service(.crunchyroll) && r.ownership.generation == g && r.third.isPlaying && r.third.pauseCount == 0)
        #expect(!ServiceMediaPolicy.navigation(from: nil, to: .hulu).pausesPodcast)
        r.finish()
    }

    @Test func openingAServiceWhileAnotherSourcePlaysPausesItOnlyWhenTheServiceReallyReportsPlaying() async {
        let r = OwnRig()
        r.ownership.claim(.service(.crunchyroll), reason: .servicePlaySeen); r.third.start()
        r.hosts.didBecomeVisible(.hulu)
        r.probe.states[.hulu] = .paused
        await r.hosts.media.tick()
        #expect(r.third.isPlaying && r.ownership.owner == .service(.crunchyroll), "an open but silent service pauses nothing")
        r.probe.states[.hulu] = .playing
        await r.hosts.media.tick()
        #expect(!r.third.isPlaying && r.ownership.owner == .service(.hulu), "the service really plays: now it claims")
        #expect(r.hosts.media.playingIDs == [.hulu])
    }

    @Test func aStaleServiceObservationIsDroppedAndTheNextPollClaimsWithACurrentGeneration() async {
        let r = OwnRig()
        r.hosts.didBecomeVisible(.hulu)
        r.probe.gated = [.hulu]
        let poll = Task { await r.hosts.media.tick() }
        while !r.probe.isWaiting(.hulu) { await Task.yield() }
        r.ownership.claim(.service(.crunchyroll), reason: .servicePlaySeen); r.third.start()          // the owner changes while the probe is out
        r.probe.answer(.hulu, .playing)
        await poll.value
        #expect(r.ownership.owner == .service(.crunchyroll) && r.third.isPlaying && r.third.pauseCount == 0, "the late answer did not pause the newest owner")
        #expect(r.hosts.media.playingIDs.isEmpty, "and it is not recorded, so the next poll looks again")
        r.probe.states[.hulu] = .playing
        await r.hosts.media.tick()
        #expect(r.ownership.owner == .service(.hulu) && !r.third.isPlaying)
    }
}

@Suite("Polling speed and hidden pages") @MainActor struct PollingSpeedTests {
    @Test func theVisibleServiceIsPolledFasterOnlyWhileAnotherParticipantPlays() {
        let r = OwnRig()
        r.hosts.didBecomeVisible(.hulu)
        #expect(r.hosts.media.currentInterval == .milliseconds(1500))
        r.podcast.start(); r.ownership.claim(.podcasts, reason: .podcastPlay)          // the ownership change tells the monitor
        #expect(r.hosts.media.currentInterval == .milliseconds(500))
        r.podcast.isPlaying = false; r.ownership.claim(.service(.crunchyroll), reason: .servicePlaySeen)
        #expect(r.hosts.media.currentInterval == .milliseconds(1500))
        r.finish()
    }

    @Test func aHiddenLivePageThatStartsByItselfIsNoticedShownWithTheBadgeAndClaims() async {
        let r = OwnRig()
        r.podcast.start(); r.ownership.claim(.podcasts, reason: .podcastPlay)
        r.open(.hulu); r.hosts.didBecomeHidden(.hulu); await r.hosts.media.settleProbes()
        #expect(r.hosts.media.isScanningHidden, "a live hidden view is scanned slowly")
        #expect(r.scheduler.intervals.contains(.seconds(5)))
        r.probe.states[.hulu] = .playing
        await r.hosts.media.scan()
        #expect(r.hosts.backgroundPlayingIDs == [.hulu] && r.ownership.owner == .service(.hulu) && !r.podcast.isPlaying)
        #expect(r.ownership.diagnostics.counts["ownership.hidden-autoplay"] == 1)
        r.hosts.releaseHidden(); r.hosts.media.refresh()
        #expect(!r.hosts.media.isScanningHidden, "no live views, no scan")
        r.finish()
    }
}

@Suite("Eviction safety") @MainActor struct EvictionSafetyTests {
    private func rig() -> OwnRig { OwnRig(budget: MemoryBudget(maxLiveWebViews: 1)) }

    @Test func aServiceHiddenLessThanOnePollAfterItStartedIsNotEvictedUntilItsProbeReturns() async {
        let r = rig()
        r.open(.netflix)
        r.probe.gated = [.netflix]          // the last poll said paused; the probe taken at hiding is still out
        r.hosts.didBecomeHidden(.netflix)
        r.open(.hulu)          // over the budget: the oldest hidden one would go
        #expect(r.hosts.liveIDs.contains(.netflix), "held while the probe is out")
        r.hosts.applyRetention(budget: 0); r.hosts.mediaChanged()
        #expect(r.hosts.liveIDs.contains(.netflix), "no cleanup race can evict it either")
        while !r.probe.isWaiting(.netflix) { await Task.yield() }
        r.probe.answer(.netflix, .playing)
        await r.hosts.media.settleProbes()
        #expect(r.hosts.liveIDs.contains(.netflix) && r.hosts.media.playingIDs == [.netflix] && r.ownership.owner == .service(.netflix))
        r.finish()
    }

    @Test func whenTheProbeFindsItSilentTheDeferredEvictionRuns() async {
        let r = rig()
        r.open(.netflix)
        r.probe.gated = [.netflix]
        r.hosts.didBecomeHidden(.netflix)
        r.open(.hulu)
        while !r.probe.isWaiting(.netflix) { await Task.yield() }
        r.probe.answer(.netflix, .paused)
        await r.hosts.media.settleProbes()
        #expect(!r.hosts.liveIDs.contains(.netflix) && r.hosts.liveIDs.contains(.hulu), "evicted once the probe said it was silent")
        r.finish()
    }

    @Test func theCurrentOwnerAndARecentlyPlayingServiceAreNotEvicted() async {
        let r = rig()
        r.open(.netflix); r.ownership.claim(.service(.netflix), reason: .servicePlaySeen)
        r.hosts.didBecomeHidden(.netflix); await r.hosts.media.settleProbes()
        r.open(.hulu)
        #expect(r.hosts.liveIDs.contains(.netflix), "the owner is never evicted by timing")
        r.hosts.media.apply(.playing, to: .youtube); r.hosts.media.apply(.paused, to: .youtube)
        #expect(r.hosts.media.isHeld(.youtube), "seen playing within the grace period")
        r.finish()
    }
}

@Suite("Termination and eligibility stops") @MainActor struct StopTests {
    /// `owner: false` leaves a second service playing without a claim (a page that started between two polls), so two can be playing at once.
    private func playingHidden(_ r: OwnRig, _ id: ProviderID, owner: Bool = true) {
        r.open(id); r.hosts.media.apply(.playing, to: id); if owner { r.ownership.claim(.service(id), reason: .servicePlaySeen) }; r.hosts.didBecomeHidden(id)
    }

    @Test func aTerminatedWebProcessClearsTheBadgeReleasesOwnershipAndNeverLeavesAudioActive() {
        let r = OwnRig()
        playingHidden(r, .hulu)
        #expect(r.hosts.backgroundPlayingIDs == [.hulu] && r.ownership.playing == [.service(.hulu)])
        let before = MediaDiagnostics.shared.counts["termination"] ?? 0
        r.hosts.model(for: .hulu)!.processTerminated()          // the registry's onTermination
        #expect(r.hosts.media.playingIDs.isEmpty && r.hosts.backgroundPlayingIDs.isEmpty)
        #expect(r.ownership.owner == nil && r.ownership.playing.isEmpty)
        #expect((MediaDiagnostics.shared.counts["termination"] ?? 0) == before + 1)
        r.finish()
    }

    @Test func eachEligibilityLossStopsOnlyTheServiceItConcernsAndReleasesItsView() {
        for reason: MediaSafetyStop in [.signedOut, .dataCleared, .disabled, .removed, .accessRevoked] {
            let r = OwnRig()
            playingHidden(r, .hulu); playingHidden(r, .youtube, owner: false)          // hulu owns the audio, youtube also plays
            r.hosts.safetyStop(reason, service: .hulu)
            #expect(!r.hosts.media.playingIDs.contains(.hulu) && r.hosts.media.playingIDs.contains(.youtube), "\(reason)")
            #expect(!r.hosts.liveIDs.contains(.hulu), "\(reason): its web view is released")
            #expect(r.hosts.backgroundPlayingIDs == [.youtube] && r.ownership.owner == nil, "\(reason)")
            r.hosts.safetyStop(reason, service: .youtube)
            #expect(r.ownership.owner == nil && r.hosts.backgroundPlayingIDs.isEmpty && r.ownership.playing.isEmpty, "\(reason)")
            r.finish()
        }
    }

    @Test func kidsLockBlockedAndProfileSwitchStopEveryServiceAndReleaseTheirViews() {
        for reason: MediaSafetyStop in [.kidsProfile, .locked, .blocked, .profileSwitched] {
            let r = OwnRig()
            playingHidden(r, .hulu); playingHidden(r, .youtube, owner: false)
            r.hosts.safetyStop(reason)
            #expect(r.hosts.media.playingIDs.isEmpty && r.ownership.owner == nil && r.hosts.liveIDs.isEmpty && r.hosts.backgroundPlayingIDs.isEmpty, "\(reason)")
            r.finish()
        }
    }

    @Test func aShowingServiceIsPausedAtOnceAndReleasedWhenItHides() async {
        let r = OwnRig()
        r.open(.hulu); r.hosts.media.apply(.playing, to: .hulu); r.ownership.claim(.service(.hulu), reason: .servicePlaySeen)
        r.hosts.safetyStop(.kidsProfile)
        #expect(r.hosts.media.playingIDs.isEmpty && r.ownership.owner == nil)
        #expect(r.hosts.liveIDs.contains(.hulu), "it is on screen: its page cannot be released under it")
        r.hosts.didBecomeHidden(.hulu); await r.hosts.media.settleProbes()
        #expect(r.hosts.liveIDs.isEmpty, "released as soon as it hides")
        r.finish()
    }

    @Test func theModelsHooksReachTheRegistry() async {
        let r = OwnRig()
        playingHidden(r, .hulu)
        r.hosts.model(for: .hulu)!.onEligibilityLost?(.hulu, .signedOut)
        #expect(r.hosts.media.playingIDs.isEmpty && r.ownership.owner == nil)
        playingHidden(r, .youtube)
        _ = await r.hosts.model(for: .youtube)!.clearServiceDataReporting()          // clearing website data
        #expect(r.hosts.media.playingIDs.isEmpty && r.ownership.owner == nil && r.hosts.backgroundPlayingIDs.isEmpty)
        r.finish()
    }

    @Test func theModelFiresTheHooksAtTheRightMoments() throws {
        let src = try ServiceSources.runtime()
        #expect(src.contains("onEligibilityLost?(definition.id, .dataCleared)") && src.contains("onEligibilityLost?(definition.id, .signedOut)"))
    }
}

@Suite("Keep services playing setting") @MainActor struct KeepPlayingSettingTests {
    @Test func defaultsOnPersistsAndLeavesTheStoredPinsUnchanged() {
        let d = UserDefaults(suiteName: "kp-\(UUID())")!
        #expect(ServicePreferences.keepsPlayingInBackground(d))
        ServicePreferences.setKeepsPlayingInBackground(false, in: d)
        #expect(!ServicePreferences.keepsPlayingInBackground(d))
        #expect(!String(decoding: ServicePreferences.initial().encoded(), as: UTF8.self).lowercased().contains("keep"))
    }

    @Test func onKeepsAServicePlayingWhenAnotherShows() {
        let r = OwnRig(keepPlaying: true)
        r.open(.hulu); r.hosts.media.apply(.playing, to: .hulu); r.hosts.didBecomeHidden(.hulu)
        r.open(.youtube)
        #expect(r.hosts.media.playingIDs == [.hulu])
        r.finish()
    }

    @Test func offPausesOnEverySwitch() {
        let r = OwnRig(keepPlaying: false)
        r.open(.hulu); r.hosts.media.apply(.playing, to: .hulu); r.ownership.claim(.service(.hulu), reason: .servicePlaySeen)
        r.hosts.didBecomeHidden(.hulu)
        #expect(r.hosts.media.playingIDs.isEmpty && r.ownership.owner == nil, "leaving pauses it")
        r.open(.youtube); r.hosts.media.apply(.playing, to: .youtube)
        r.open(.peacock)
        #expect(!r.hosts.media.playingIDs.contains(.youtube), "showing another service pauses the rest")
        r.finish()
    }

    @Test func theSettingIsInSettingsWithAnHonestCaption() throws {
        let src = try String(contentsOf: ServiceSources.root.appendingPathComponent("Features/Settings/Views/StreamingServicesSettingsSection.swift"), encoding: .utf8)
        #expect(src.contains("Keep services playing in the background") && src.contains("best effort"))
        for lang in ["hi", "te"] {
            let strings = try String(contentsOf: ServiceSources.root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localization/\(lang).lproj/Localizable.strings"), encoding: .utf8)
            #expect(strings.contains("\"Keep services playing in the background\""), Comment(rawValue: lang))
        }
    }
}

@Suite("Badge accuracy") @MainActor struct BadgeAccuracyTests {
    @Test func theBadgeClearsOnStopTerminationSignOutAndHandoff() {
        func hiddenPlaying(_ r: OwnRig, _ id: ProviderID) { r.open(id); r.hosts.media.apply(.playing, to: id); r.ownership.claim(.service(id), reason: .servicePlaySeen); r.hosts.didBecomeHidden(id) }
        let r = OwnRig()
        hiddenPlaying(r, .hulu); #expect(r.hosts.backgroundPlayingIDs == [.hulu])
        r.hosts.pauseService(.hulu); #expect(r.hosts.backgroundPlayingIDs.isEmpty, "stop")
        hiddenPlaying(r, .hulu); r.hosts.model(for: .hulu)!.processTerminated(); #expect(r.hosts.backgroundPlayingIDs.isEmpty, "termination")
        hiddenPlaying(r, .hulu); r.hosts.safetyStop(.signedOut, service: .hulu); #expect(r.hosts.backgroundPlayingIDs.isEmpty, "sign-out")
        hiddenPlaying(r, .hulu); r.ownership.claim(.podcasts, reason: .podcastPlay); #expect(r.hosts.backgroundPlayingIDs.isEmpty, "handoff")
        #expect(r.ownership.owner == .podcasts)
        r.finish()
    }

    @Test func rapidServiceSwitchingAndClaimsLeaveOneOwnerAndOnePlayingParticipantAfterEachSettle() async {
        let r = OwnRig()
        let ids: [ProviderID] = [.hulu, .youtube, .peacock, .netflix]
        var seed: UInt64 = 7
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        var visible: ProviderID?
        func show(_ id: ProviderID) { _ = r.hosts.model(for: id); r.hosts.didBecomeVisible(id) }          // no web views: the registry's logic only
        for _ in 0..<300 {
            switch next() % 6 {
            case 0: let id = ids[next() % ids.count]; if let v = visible { r.hosts.didBecomeHidden(v) }; show(id); visible = id
            case 1: if let v = visible { r.hosts.didBecomeHidden(v); visible = nil }
            case 2: if let v = visible { r.probe.states[v] = .playing }          // the visible page starts by itself
            case 3: r.ownership.claim(.nativePlayer, reason: .nativePlay); r.native.start(); r.settlePages(ids)
            case 4: r.ownership.claim(.podcasts, reason: .podcastPlay); r.podcast.start(); r.settlePages(ids)
            default: r.ownership.claim(.service(.crunchyroll), reason: .servicePlaySeen); r.third.start(); r.settlePages(ids)
            }
            await r.hosts.media.tick(); await r.hosts.media.settleProbes()
            r.settlePages(ids)
            #expect(r.playingCount <= 1, "two participants report playing after settle")
            if let only = r.ownership.playing.first { #expect(r.ownership.owner == only) }
        }
    }
}

// MARK: - the remote command router

@MainActor private final class FakeSurface: CommandCenterSurface {
    private(set) var installs = 0, uninstalls = 0, applies: [RemoteCommandSupport] = [], clears = 0
    private(set) var published: [String: Any]?
    private(set) var installedTargets = 0
    private var handler: (@MainActor (RemoteCommandEvent) -> RemoteCommandResult)?
    func install(_ handler: @escaping @MainActor (RemoteCommandEvent) -> RemoteCommandResult) { guard self.handler == nil else { return }; installs += 1; installedTargets = 8; self.handler = handler }
    func uninstall() { uninstalls += 1; installedTargets = 0; handler = nil; applies.append(.none) }
    func apply(_ support: RemoteCommandSupport) { applies.append(support) }
    func publish(_ info: [String: Any], playing: Bool) { published = info }
    func clearNowPlaying() { clears += 1; published = nil }
    func press(_ kind: RemoteCommandKind, position: TimeInterval? = nil) -> RemoteCommandResult? { handler?(RemoteCommandEvent(kind: kind, position: position, interval: nil)) }
}

@MainActor private final class FakeHandler: RemoteCommandHandling {
    var remoteSupport: RemoteCommandSupport
    private(set) var received: [RemoteCommandKind] = []
    private(set) var ownerFlags: [Bool] = []
    init(_ s: RemoteCommandSupport) { remoteSupport = s }
    func handleRemote(_ event: RemoteCommandEvent) -> RemoteCommandResult { received.append(event.kind); return .success }
    func remoteOwnershipChanged(isOwner: Bool) { ownerFlags.append(isOwner) }
}

@Suite("Media command router") @MainActor struct MediaCommandRouterTests {
    private let video = RemoteCommandSupport(enabled: [.play, .pause, .toggle, .next, .previous], skipForward: 15, skipBackward: 15)
    private let podcast = RemoteCommandSupport(enabled: [.play, .pause, .toggle, .skipForward, .skipBackward, .seek], skipForward: 30, skipBackward: 10)
    private let third = RemoteCommandSupport(enabled: [.play, .pause, .toggle, .next, .previous, .seek])

    private func rig() -> (MediaCommandRouter, FakeSurface, AudioOwnership, FakeHandler, FakeHandler, FakeHandler) {
        let o = AudioOwnership(); o.diagnostics = MediaDiagnostics()
        let s = FakeSurface(); let r = MediaCommandRouter(surface: s, ownership: o)
        let v = FakeHandler(video), p = FakeHandler(podcast), m = FakeHandler(third)
        r.register(v, for: .nativePlayer); r.register(p, for: .podcasts); r.register(m, for: .service(.crunchyroll))
        return (r, s, o, v, p, m)
    }

    @Test func thereIsOneSystemRegistrationNoMatterHowManyOwnersRegister() {
        let (r, s, _, _, _, _) = rig()
        #expect(s.installs == 1 && s.installedTargets == 8)
        r.shutdown()
        #expect(s.uninstalls == 1 && s.installedTargets == 0, "stale targets are removed")
    }

    @Test func commandsReachTheCurrentOwnerOnly() {
        let (r, s, o, v, p, m) = rig()
        #expect(s.press(.play) == .noActionable, "nobody owns the audio")
        o.claim(.podcasts, reason: .podcastPlay)
        #expect(s.press(.toggle) == .success && p.received == [.toggle] && v.received.isEmpty && m.received.isEmpty)
        #expect(s.press(.next) == .noActionable, "the owner does not support Next")
        o.claim(.service(.crunchyroll), reason: .servicePlaySeen)
        _ = s.press(.next); _ = s.press(.seek, position: 3)
        #expect(m.received == [.next, .seek] && p.received == [.toggle])
        o.claim(.service(.hulu), reason: .servicePlaySeen)
        #expect(s.press(.play) == .noActionable, "an embedded service answers for itself")
        _ = r
    }

    @Test func enabledStateFollowsTheOwnerAndChangesOnlyOnEvents() {
        let (r, s, o, v, p, m) = rig()
        o.claim(.nativePlayer, reason: .nativePlay); #expect(s.applies.last == video)
        o.claim(.podcasts, reason: .podcastPlay); #expect(s.applies.last == podcast && s.applies.last?.skipForward == 30)
        o.claim(.service(.crunchyroll), reason: .servicePlaySeen); #expect(s.applies.last == third)
        let count = s.applies.count
        r.supportChanged(for: .service(.crunchyroll)); r.supportChanged(for: .service(.crunchyroll))
        #expect(s.applies.count == count, "no change, no write: nothing is rewritten on a timer")
        r.supportChanged(for: .podcasts)
        m.remoteSupport.enabled.remove(.next); r.supportChanged(for: .service(.crunchyroll))
        #expect(s.applies.count == count + 1 && s.applies.last?.enabled.contains(.next) == false, "an owner's change is applied once; a non-owner's call is ignored")
        o.release(.service(.crunchyroll)); #expect(s.applies.last == RemoteCommandSupport.none, "no owner: every command disabled")
        #expect(v.ownerFlags == [true, false] && p.ownerFlags == [true, false] && m.ownerFlags == [true, false])
    }

    @Test func nowPlayingIsAcceptedFromTheOwnerOnlyAndNeverOutlivesIt() {
        let (r, s, o, _, _, _) = rig()
        #expect(!r.publish(["t": 1], playing: true, from: .podcasts) && s.published == nil)
        o.claim(.podcasts, reason: .podcastPlay)
        #expect(r.publish(["t": 1], playing: true, from: .podcasts) && s.published != nil)
        #expect(!r.publish(["t": 2], playing: true, from: .service(.crunchyroll)) && (s.published?["t"] as? Int) == 1)
        o.claim(.service(.crunchyroll), reason: .servicePlaySeen)
        #expect(s.published == nil && r.publishedBy == nil, "handing the audio over clears the old owner's information")
        #expect(r.publish(["t": 3], playing: true, from: .service(.crunchyroll)))
        r.ownerStopped(.service(.crunchyroll))
        #expect(s.published == nil && o.owner == nil)
    }

    @Test func aLateArtworkForASkippedTrackIsNotStoredAsTheCurrentOne() throws {
        let src = try String(contentsOf: ServiceSources.root.appendingPathComponent("Services/Music/Playback/MusicPlayer.swift"), encoding: .utf8)
        let body = try #require(src.components(separatedBy: "func setNowPlayingArtwork").dropFirst().first?.prefix(400))
        #expect(body.contains("guard uid == current?.uid"), "the arriving artwork must belong to the current track before it is stored")
    }

    @Test func theLibraryAndPodcastRemotesNoLongerRegisterOnTheSystemCentre() throws {
        let np = try String(contentsOf: ServiceSources.root.appendingPathComponent("Playback/NowPlayingService.swift"), encoding: .utf8)
        let pod = try String(contentsOf: ServiceSources.root.appendingPathComponent("Features/Podcasts/PodcastPlayer.swift"), encoding: .utf8)
        let router = try String(contentsOf: ServiceSources.root.appendingPathComponent("Playback/MediaCommandRouter.swift"), encoding: .utf8)
        for src in [np, pod] { #expect(!src.contains("addTarget") && !src.contains("MPRemoteCommandCenter.shared()") && !src.contains("nowPlayingInfo =")) }
        #expect(router.components(separatedBy: "addTarget").count == 2, "exactly one registration site")
        #expect(np.contains("RemoteCommandHandling") && pod.contains("RemoteCommandHandling"))
    }
}

// MARK: - opt-in measurement (BG_MEASURE=1)

/// Opens N = 1...4 local fixture service views parked (parking on), keeps each playing a silent local track, and samples CPU and resident memory over 30 s.
/// App figures are this process; web figures are the sum of every WebContent process on the machine (an upper bound that includes other apps' pages).
@Suite("Park measurement (opt in)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["BG_MEASURE"] == "1")) @MainActor struct ParkMeasurementTests {
    private static func wav(seconds: Int = 60) -> Data {
        let rate = 8000, n = rate * seconds
        var d = Data("RIFF".utf8); func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }; func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        u32(36 + n * 2); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16); d.append(Data("data".utf8)); u32(n * 2)
        d.append(Data(count: n * 2)); return d          // silent samples: a real audio track, never a sound
    }
    private static func appCPU() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6 }
    private static func appRSSMB() -> Double {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
    /// (cpu seconds, resident MB) summed over every WebContent process, from `ps`.
    private static func webProcesses() -> (cpu: Double, mb: Double) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "time=,rss=,comm="]
        let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var cpu = 0.0, kb = 0.0
        for line in text.split(separator: "\n") where line.contains("WebContent") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let rss = Double(f[1]) else { continue }
            kb += rss
            cpu += f[0].split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1.replacingOccurrences(of: ",", with: ".")) ?? 0) }
        }
        return (cpu, kb / 1024)
    }

    @Test func measureParkedViews() async throws {
        let server = try ServiceFixtureServer(); server.media = Self.wav(); try await server.start(); defer { server.stop() }
        _ = NSApplication.shared
        let ids: [ProviderID] = [.spotify, .youtube, .hulu, .peacock]
        let d = UserDefaults(suiteName: "measure-\(UUID())")!; d.set(true, forKey: ServiceWebParking.defaultsKey)
        ServiceWebParking.shared.defaults = d; defer { ServiceWebParking.shared.defaults = .standard; ServiceWebParking.shared.register(nil) }
        var rows: [String] = ["N | app CPU % | web CPU % | app RSS MB | web RSS MB (all WebContent) | parked"]
        for n in 1...4 {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)), shown = NSView(frame: root.bounds)
            let parking = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)); parking.wantsLayer = true; parking.layer?.masksToBounds = true
            root.addSubview(shown); root.addSubview(parking); win.contentView = root
            ServiceWebParking.shared.register(parking)
            MediaDiagnostics.shared.reset()
            var models: [ServiceWebModel] = []
            for id in ids.prefix(n) {
                let m = ServiceWebModel(definition: ServiceTestSupport.fixture(id, server), dataStore: { .nonPersistent() })
                m.serviceBecameVisible(); let web = m.hostedView(); web.frame = shown.bounds; shown.addSubview(web)
                _ = await ServiceTestSupport.until { m.phase == .ready }
                m.load(server.url("/media"))
                _ = await ServiceTestSupport.until(60) { m.webView?.title == "media" }
                for _ in 0..<10 {
                    _ = try? await web.evaluateJavaScript("document.getElementById('a').play().catch(function(){})")          // test-only, local fixture
                    try? await Task.sleep(for: .milliseconds(300))
                    if await web.requestMediaPlaybackState() == .playing { break }
                }
                m.serviceBecameHidden(); ServiceWebParking.shared.park(web)
                models.append(m)
            }
            let c0 = Self.appCPU(), w0 = Self.webProcesses(), t0 = Date()
            try? await Task.sleep(for: .seconds(30))
            let dt = Date().timeIntervalSince(t0), w1 = Self.webProcesses()
            rows.append(String(format: "%ld | %.1f | %.1f | %.0f | %.0f | %ld", n, (Self.appCPU() - c0) / dt * 100, (w1.cpu - w0.cpu) / dt * 100, Self.appRSSMB(), w1.mb, MediaDiagnostics.shared.parkedNow))
            for m in models { m.releaseResources() }
            ServiceWebParking.shared.register(nil); win.contentView = nil
        }
        print("MEASURE parked views (30 s each)\n" + rows.joined(separator: "\n"))
    }
}
