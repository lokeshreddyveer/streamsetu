import Testing
import Foundation
@testable import REDDY

@Suite("Music setup presets") @MainActor struct MusicSetupPresetsTests {
    private func defaults() -> UserDefaults {
        let suite = "music.setup.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite) ?? .standard
        d.removePersistentDomain(forName: suite)
        return d
    }
    private func registry(_ d: UserDefaults? = nil) -> MusicRegistry {
        let r = MusicRegistry(defaults: d ?? defaults())
        MusicBuiltIns.register(into: r)
        return r
    }

    @Test func freshRegistryHasNothingEnabled() {
        let r = registry()
        #expect(r.enabled.isEmpty && r.activeMetadataID == nil && r.changeLog.isEmpty)
    }

    @Test func defaultSetIsEveryKeylessBuiltInExceptLocalFiles() {
        let r = registry()
        let ids = MusicSetupPresets.defaultSet(registry: r)
        #expect(ids == Set(r.all.filter { $0.info.kind == .builtIn }.map(\.id)).subtracting(["local"]).filter { id in r.provider(id: id)?.info.requiresSignIn == false })
        #expect(!ids.contains("local"))
        for id in ["lastfm", "listenbrainz"] { #expect(!ids.contains(id), Comment(rawValue: id)) }      // they need the person's own key, so they stay off until one is added
        for id in ["ytmusic", "youtube-music", "audius", "jiosaavn", "itunes", "spotify", "piped", "invidious", "lrclib", "youtube", "ytcaptions"] {
            #expect(ids.contains(id), Comment(rawValue: id))
        }
    }

    @Test func pluginProvidersAreNeverInTheDefaultSet() {
        let r = registry()
        let plugin = MusicProviderInfo(id: "demo-plugin", name: "Demo", summary: "", kind: .plugin)
        var providers = r.all
        providers.append(PluginStub(info: plugin))
        #expect(!MusicSetupPresets.defaultSet(providers: providers).contains("demo-plugin"))
    }

    @Test func freshModelPreselectsTheDefaultSetAndRerunPreselectsWhatIsOn() {
        let r = registry()
        let fresh = MusicSetupModel(providers: r.all)
        #expect(fresh.enabling == MusicSetupPresets.defaultSet(registry: r) && fresh.canContinue)
        let rerun = MusicSetupModel(providers: r.all, current: ["audius", "itunes", "gone-source"])
        #expect(rerun.enabling == ["audius", "itunes"])
        #expect(MusicSetupModel(providers: r.all, current: ["local"]).enabling == ["local"])
    }

    @Test func modelEditsOnlyChangeTheTicks() {
        let r = registry()
        var m = MusicSetupModel(providers: r.all)
        m.turnOff(group: .metadata); m.turnOff(group: .audio)
        #expect(m.onCount(in: .metadata) == 0 && !m.canContinue)
        m.selectRecommended(in: .metadata)
        #expect(m.canContinue && m.chosen.contains("ytmusic"))
        m.set("local", on: true)
        #expect(m.enabling.contains("local"))
        #expect(r.enabled.isEmpty, "the screen never touches the registry")
    }

    @Test func continueEnablesExactlyTheChosenSetAndLogsIt() {
        let r = registry()
        let ids = MusicSetupPresets.defaultSet(registry: r)
        for p in r.all { r.setEnabled(ids.contains(p.id), id: p.id, reason: .setup) }
        #expect(r.enabled == ids)
        #expect(r.changeLog.count == min(50, ids.count) && r.changeLog.allSatisfy { $0.reason == .setup && $0.on })
    }

    @Test func changeLogKeepsTheLast50AndSurvivesARelaunch() {
        let d = defaults()
        let r = registry(d)
        for i in 0..<60 { r.setEnabled(i % 2 == 0, id: "audius", reason: .switch); r.setEnabled(i % 2 == 0, id: "x\(i)", reason: .switch) }
        #expect(r.changeLog.count == 50)
        let again = MusicRegistry(defaults: d)
        #expect(again.changeLog == r.changeLog)
    }

    @Test func enabledSourcesSurviveAttachGateSettingsAccountRebuildAndRelaunch() {
        let d = defaults()
        let r = registry(d)
        r.setEnabled(true, id: "ytmusic"); r.setEnabled(true, id: "audius"); r.setEnabled(true, id: "lrclib")
        r.setActiveMetadata("ytmusic")
        let before = r.enabled
        // an account rebuild registers the YouTube provider again under the same id
        r.register(YouTubeMusicFullProvider())
        YouTubeMusicBuiltIns.register(into: r)
        // a settings change that is not a switch: lyric and audio order edits
        r.setAudioOrder(r.audioOrder.reversed()); r.setLyricsOrder(r.lyricsOrder.reversed())
        #expect(r.enabled == before)
        // a relaunch builds a new registry on the same defaults, then registers the built-ins again
        let relaunched = registry(d)
        #expect(relaunched.enabled == before && relaunched.activeMetadataID == "ytmusic")
    }

    @Test func removingAProviderIsLoggedAsRemoval() {
        let r = registry()
        r.setEnabled(true, id: "piped")
        r.unregister(id: "piped")
        #expect(r.changeLog.last?.reason == .unregister && r.changeLog.last?.on == false)
    }

    @Test func displayNamesAreUniqueAndDisambiguated() {
        let r = registry()
        let names = r.all.map { MusicSourceDisplay.name(for: $0.info) }
        #expect(Set(names).count == names.count, Comment(rawValue: names.joined(separator: ", ")))
        #expect(MusicSourceDisplay.name(for: r.provider(id: "youtube-music")!.info) == "YouTube Music (basic search)")
        #expect(MusicSourceDisplay.name(for: r.provider(id: "youtube")!.info) == "YouTube Music lyrics")
        #expect(MusicSourceDisplay.name(for: r.provider(id: "ytcaptions")!.info) == "YouTube captions")
        #expect(MusicSourceDisplay.name(for: r.provider(id: "ytmusic")!.info) == "YouTube Music")
    }

    @Test func sharedTextIsDeduplicatedAndEmptyForNothing() {
        let r = registry()
        #expect(MusicSourceDisplay.firstSentence("One thing. Two things.") == "One thing.")
        #expect(MusicSourceDisplay.firstSentence("No stop") == "No stop")
        let all = MusicSourceDisplay.sharedText(ids: MusicSetupPresets.defaultSet(registry: r), providers: r.all)
        #expect(all.contains("Google sees") && !all.localizedCaseInsensitiveContains("sign in"))
        let sentences = all.components(separatedBy: ". ")
        #expect(Set(sentences).count == sentences.count)
        let local = MusicSourceDisplay.sharedText(ids: ["local"], providers: r.all)
        #expect(local.contains("Reads only the folders"))
        #expect(MusicSourceDisplay.sharedText(ids: [], providers: r.all).isEmpty)
    }
}

private struct PluginStub: MusicProvider {
    let info: MusicProviderInfo
    var capabilities: MusicCapabilities { [] }
}
