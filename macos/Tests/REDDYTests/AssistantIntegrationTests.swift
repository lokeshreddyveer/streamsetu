import Testing
import Foundation
@testable import REDDY

/// Checks that the assistant reaches the same operations as the screens, with real objects: the player, the settings effects, the guide refresh, and real profile and parental state. Storage is isolated and always removed.
@MainActor @Suite("Assistant: same operations as the screens, real state") struct AssistantIntegrationTests {
    private func rig() throws -> (c: AppContainer, src: PlaylistSource) {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-int-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        return (c, try c.sources.addM3U(name: "Local", url: "http://127.0.0.1:9/list.m3u"))
    }
    private func channel(_ c: AppContainer, _ src: PlaylistSource, _ pid: String, _ name: String, category: CatalogCategory? = nil) throws -> Channel {
        var ch = TestSupport.channel(src, pid, name, cat: nil); ch.streamRef = "http://127.0.0.1:9/live/\(pid).ts"
        if let category { ch.categoryID = category.id; ch.categoryName = category.name }
        try c.indexer.commitChannels(source: src, categories: category.map { [$0] } ?? [], channels: [ch])
        return try #require(try c.catalog.channels(ChannelQuery(collapseVariants: false)).first { $0.name == name })
    }
    private func settle() async { for _ in 0..<3 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) } }

    // MARK: setting effects reach what is playing, once

    @Test func aSubtitleChangeReachesTheStreamThatIsPlayingExactlyOnce() async throws {
        let (c, src) = try rig(); let p = c.playback
        let original = c.settings.subtitleSize; defer { c.settings.subtitleSize = original }
        p.play(channel: try channel(c, src, "a", "Channel A")); await settle()
        let before = p.subtitleStyleApplications
        let r = try #require(c.applySetting(id: "subtitleSize", value: "150%"))
        #expect(c.settings.subtitleSize == 150); #expect(r.reachedPlayback); #expect(p.subtitleStyleApplications == before + 1)
        // the Settings screen's own change handler runs for the same value: no second application
        #expect(c.settingChanged("subtitleSize")?.reachedPlayback == false)
        #expect(p.subtitleStyleApplications == before + 1, "an effect is neither missed nor applied twice")
        // a change made on the screen goes through the same function
        c.settings.subtitleSize = 120
        #expect(c.settingChanged("subtitleSize")?.reachedPlayback == true); #expect(p.subtitleStyleApplications == before + 2)
    }

    @Test func volumeNormalizationReachesThePlayerToo() async throws {
        let (c, src) = try rig(); let p = c.playback
        let original = c.settings.audioProcessing; defer { c.settings.audioProcessing = original }
        p.play(channel: try channel(c, src, "a", "Channel A")); await settle()
        #expect(c.applySetting(id: "audioProcessing", value: "Night Mode")?.reachedPlayback == true)
        #expect(p.audioProcessing == .nightMode)
    }

    @Test func aSettingForTheNextStreamSaysSoAndNothingIsPushed() async throws {
        let (c, src) = try rig(); let p = c.playback
        let original = c.settings.hardwareDecoding; defer { c.settings.hardwareDecoding = original }
        p.play(channel: try channel(c, src, "a", "Channel A")); await settle()
        let before = p.subtitleStyleApplications
        let r = try #require(c.applySetting(id: "hardwareDecoding", value: "Software decoding"))
        #expect(c.settings.hardwareDecoding == .software); #expect(!r.reachedPlayback); #expect(r.note?.contains("next stream") == true); #expect(p.subtitleStyleApplications == before)
    }

    @Test func nothingPlayingMeansNothingToReach() throws {
        let (c, _) = try rig()
        let original = c.settings.subtitleSize; defer { c.settings.subtitleSize = original }
        #expect(c.applySetting(id: "subtitleSize", value: "110%")?.reachedPlayback == false)
        #expect(c.settings.subtitleSize == 110, "the value is still stored")
    }

    @Test func aValueTheCatalogueRefusesStoresNothing() throws {
        let (c, _) = try rig()
        let before = c.settings.theme
        #expect(c.applySetting(id: "theme", value: "Rainbow") == nil); #expect(c.settings.theme == before)
        #expect(c.applySetting(id: "appLock", value: "off") == nil, "app lock is never changed from here")
    }

    @Test func checkingAValueCreatesNoPreferencesDomain() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let e = try #require(AppSettingsCatalog.find("theme"))
        for _ in 0..<50 { _ = e.accepts("Onyx Gloss"); _ = e.accepts("nope") }
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        #expect(after.subtracting(before).filter { $0.hasPrefix("assistant-") }.isEmpty, "validation leaves nothing behind")
    }

    @Test func acceptsAgreesWithWriteForEveryChangeableSetting() {
        IsolatedDefaults.with("accepts") { d in
            for e in AppSettingsCatalog.all where e.changeable {
                let s = AppSettings(defaults: d)
                for v in e.options + ["definitely-not-a-value", "", "   "] { #expect(e.accepts(v) == (e.write?(s, v) == true), "\(e.id) “\(v)”") }
            }
        }
    }

    // MARK: the guide is refreshed the way the button does it

    @Test func theAssistantRefreshesTheGuideLikeTheSettingsButton() async throws {
        let (c, src) = try rig()
        let other = try c.sources.addM3U(name: "Off", url: "http://127.0.0.1:9/other.m3u")
        try await IsolatedDefaults.with("state") { d in
            let state = AppState(container: c, defaults: d)
            var off = other; off.enabled = false
            state.sources = [src, off]
            var asked: [(UUID, Bool)] = []
            state.syncHook = { asked.append(($0, $1)) }
            state.refreshGuides()
            #expect(asked.count == 1 && asked[0].0 == src.id && asked[0].1 == true, "forced, and only for playlists that are on")
            asked = []
            let outcome = await c.perform(AssistantProposal(kind: .syncGuide, origin: c.assistantOrigin()), state: state)
            #expect(outcome.isDone && outcome.message?.contains("guide") == true)
            #expect(asked.count == 1 && asked[0].1 == true, "the assistant's action is the same operation")
            asked = []
            state.syncAll()
            #expect(asked.count == 1 && asked[0].1 == false, "a plain playlist refresh does not force the guide")
        }
    }

    // MARK: Automatic is a saved preference; restarting is a separate action

    @Test func automaticIsSavedAndDoesNotRestartTheStream() async throws {
        let (c, src) = try rig(); let p = c.playback
        let original = c.settings.enginePreference; defer { c.settings.enginePreference = original }
        c.settings.enginePreference = .avPlayer
        p.play(channel: try channel(c, src, "a", "Channel A")); await settle()
        let loads = p.loadCount, item = p.current
        let said = await c.perform(AssistantProposal(kind: .engine("auto"), origin: c.assistantOrigin()), state: AppState(container: c, defaults: .standard)).message
        await settle()
        #expect(c.settings.enginePreference == .automatic); #expect(said?.contains("next stream") == true)
        #expect(p.loadCount == loads && p.current == item, "the stream was not restarted")
        // a failure that needs both offers them as two separate actions
        var e = PlaybackEvidence(); e.playing = false; e.failure = PlaybackError(.engineUnavailable); e.failureIsRecent = true
        #expect(AssistantDiagnostics.playback(e).actions == ["engine:auto", "retry"])
    }

    // MARK: a channel offered is the channel played

    @Test func aChannelProposalCarriesItsOwnIdAndFolder() async throws {
        let (c, src) = try rig()
        let kids = CatalogCategory(id: CatalogCategory.makeID(source: src.id, kind: .channel, provider: "k"), sourceID: src.id, kind: .channel, providerID: "k", name: "Kids", sortOrder: 0)
        let ch = try channel(c, src, "a", "Cartoon Time", category: kids)
        let t = AssistantToolbox(container: c)
        _ = await t.run("play_title", ["title": .string("Cartoon Time")])
        let p = try #require(t.proposals.first)
        guard case .playItem(let id, let isChannel, _) = p.kind else { Issue.record("expected a play-by-id offer"); return }
        #expect(id == ch.id && isChannel); #expect(p.origin.targetItemID == ch.id); #expect(p.origin.categoryID == kids.id)
    }

    @Test func runningARemovedItemIsRefusedAndAnExistingChannelPlays() async throws {
        let (c, src) = try rig()
        let ch = try channel(c, src, "a", "Channel A")
        let state = AppState(container: c, defaults: .standard)
        let gone = await SearchCommandRunner.execute(.playItem(id: "gone", isChannel: true, title: "Gone"), container: c, router: AppRouter(), state: state)
        #expect(!gone.isDone && gone.message?.contains("no longer") == true)
        AssistantPlaybackWatch.timeout = 1
        defer { AssistantPlaybackWatch.timeout = 20 }
        _ = await SearchCommandRunner.execute(.playItem(id: ch.id, isChannel: true, title: "Channel A"), container: c, router: AppRouter(), state: state)
        #expect(c.playback.current != nil, "the channel was asked for")
    }
}

/// Real profile, parental and player objects, each on storage of its own that is removed afterwards.
@MainActor @Suite("Assistant: authorization against real profile and parental state") struct AssistantRealStateTests {
    private struct World {
        let c: AppContainer, profiles: ProfileService, parental: ParentalControls
        let kidsFolder: CatalogCategory, adultFolder: CatalogCategory, kidsChannel: Channel, adultChannel: Channel
    }
    private func world(_ d: UserDefaults) throws -> World {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-rs-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let src = try c.sources.addM3U(name: "Local", url: "http://127.0.0.1:9/list.m3u")      // a playlist whose channels can be played
        let cats = ["Kids", "Adults"].enumerated().map { i, n in CatalogCategory(id: CatalogCategory.makeID(source: src.id, kind: .channel, provider: "\(i)"), sourceID: src.id, kind: .channel, providerID: "\(i)", name: n, sortOrder: i) }
        var chans: [Channel] = []
        for (i, cat) in cats.enumerated() { var ch = TestSupport.channel(src, "\(i)", "\(cat.name) One", cat: nil, order: i); ch.categoryID = cat.id; ch.categoryName = cat.name; ch.streamRef = "http://127.0.0.1:9/live/\(i).ts"; chans.append(ch) }
        try c.indexer.commitChannels(source: src, categories: cats, channels: chans)
        let stored = try c.catalog.channels(ChannelQuery(collapseVariants: false))
        return World(c: c, profiles: ProfileService(db: c.db, defaults: d), parental: ParentalControls(catalog: c.catalog, defaults: d), kidsFolder: cats[0], adultFolder: cats[1],
                     kidsChannel: try #require(stored.first { $0.name == "Kids One" }), adultChannel: try #require(stored.first { $0.name == "Adults One" }))
    }
    private func situation(_ w: World) -> AssistantSituation { AssistantAuthorizer.situation(profiles: w.profiles, parental: w.parental, playback: w.c.playback, catalog: w.c.catalog) }
    private func play(_ w: World, _ ch: Channel, profile: String) -> AssistantProposal {
        AssistantProposal(kind: .playItem(id: ch.id, isChannel: true, title: ch.name), origin: AssistantProposal.Origin(profileID: profile, createdAt: Date(), playbackKey: nil, targetItemID: ch.id, categoryID: ch.categoryID))
    }

    @Test func aLockedFolderIsRefusedWhileLockedAndRefusedAgainAfterItRelocks() throws {
        try IsolatedDefaults.with("par") { d in
            let w = try world(d)
            #expect(w.parental.setPIN("2468")); #expect(w.parental.setFolder(w.adultFolder.id, locked: true))
            let main = w.profiles.activeID
            if case .deny(let why) = AssistantAuthorizer.decide(play(w, w.adultChannel, profile: main), situation(w)) { #expect(why.contains("locked folder")) } else { Issue.record("a locked folder must be refused") }
            #expect(AssistantAuthorizer.decide(play(w, w.kidsChannel, profile: main), situation(w)) == .allow, "a folder that is not locked")
            _ = w.parental.unlock(pin: "2468")
            #expect(AssistantAuthorizer.decide(play(w, w.adultChannel, profile: main), situation(w)) == .allow, "while the person has unlocked restricted content")
            w.parental.lockNow()
            if case .deny = AssistantAuthorizer.decide(play(w, w.adultChannel, profile: main), situation(w)) {} else { Issue.record("after it relocks, an earlier offer must be refused") }
            #expect(!AssistantAuthorizer.accessAllowed(categoryID: w.adultFolder.id, restricting: w.parental.isRestricting, isLocked: { w.parental.isLocked($0) }))
        }
    }

    @Test func aKidsProfileIsRefusedEverythingAndASwitchCancelsOffers() throws {
        try IsolatedDefaults.with("prof") { d in
            let w = try world(d)
            let main = w.profiles.activeID
            let offer = play(w, w.kidsChannel, profile: main)
            #expect(AssistantAuthorizer.decide(offer, situation(w)) == .allow)
            let other = try #require(w.profiles.add(name: "B", kind: .adult, pin: nil))
            _ = w.profiles.switchTo(other.id)
            if case .deny(let why) = AssistantAuthorizer.decide(offer, situation(w)) { #expect(why.contains("profile changed")) } else { Issue.record("an offer made for another profile must be refused") }
            let kid = try #require(w.profiles.add(name: "Kid", kind: .kids, pin: "1357"))  // a kids profile has a PIN, asked when leaving it
            _ = w.profiles.switchTo(kid.id)
            #expect(situation(w).isKids)
            for k in AssistantCoverage.sampleKinds() {
                let o = AssistantProposal.Origin(profileID: kid.id, createdAt: Date(), playbackKey: nil, targetItemID: nil, categoryID: nil)
                if case .deny = AssistantAuthorizer.decide(AssistantProposal(kind: k, origin: o), situation(w)) {} else { Issue.record("\(k) must be refused in a kids profile") }
            }
            #expect(w.profiles.switchTo(main) == .needsPIN, "leaving a kids profile asks for its PIN")
            #expect(w.profiles.switchTo(main, pin: "1357") == .switched)
            #expect(AssistantAuthorizer.decide(offer, situation(w)) == .allow, "back as the person it was offered to")
        }
    }

    @Test func thePlayerStateIsReadForReal() async throws {
        try await IsolatedDefaults.with("play") { d in
            let w = try world(d), p = w.c.playback
            let main = w.profiles.activeID
            @MainActor func retry(_ key: String?) -> AssistantProposal { AssistantProposal(kind: .retry, origin: AssistantProposal.Origin(profileID: main, createdAt: Date(), playbackKey: key, targetItemID: nil, categoryID: nil)) }
            if case .deny = AssistantAuthorizer.decide(retry(nil), situation(w)) {} else { Issue.record("nothing playing must be refused") }
            p.play(channel: w.kidsChannel); for _ in 0..<3 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
            let key = try #require(p.current?.itemID)
            #expect(situation(w).hasPlayback && situation(w).playbackKey == key)
            #expect(AssistantAuthorizer.decide(retry(key), situation(w)) == .allow)
            p.play(channel: w.adultChannel); for _ in 0..<3 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
            if case .deny(let why) = AssistantAuthorizer.decide(retry(key), situation(w)) { #expect(why.contains("changed")) } else { Issue.record("a different stream must be refused") }
            p.stop()
            if case .deny = AssistantAuthorizer.decide(retry(key), situation(w)) {} else { Issue.record("stopped playback must be refused") }
        }
    }

    @Test func isolatedDefaultsNeverTouchThePreferencesFolder() async throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        IsolatedDefaults.with("mem") { d in
            d.set("x", forKey: "k"); d.set(3, forKey: "n"); d.set(true, forKey: "b"); d.set(2.5, forKey: "d"); d.set(["a"], forKey: "l")
            #expect(d.string(forKey: "k") == "x"); #expect(d.integer(forKey: "n") == 3); #expect(d.bool(forKey: "b")); #expect(d.double(forKey: "d") == 2.5); #expect(d.stringArray(forKey: "l") == ["a"])
            d.removeObject(forKey: "k"); #expect(d.object(forKey: "k") == nil)
            _ = d.synchronize()
            // the real settings and profile classes work on it
            let s = AppSettings(defaults: d); s.subtitleSize = 130; #expect(AppSettings(defaults: d).subtitleSize == 130)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)           // long enough for the daemon to have written anything it was going to write
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        // other suites running at the same time make their own files; only what this helper (or the assistant) could make is counted
        let mine = after.subtracting(before).filter { $0.hasPrefix("mem-") || $0.hasPrefix("tmp-") || $0.hasPrefix("assistant-") }
        #expect(mine.isEmpty, "no file was created: \(mine.sorted())")
    }
}
