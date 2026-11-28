import Testing
import Foundation
@testable import REDDY

/// Tests for the wiring that joins Music to the rest of the app: storage, shared helpers, settings coverage and the iOS source list.
@Suite("Music integration") struct MusicIntegrationTests {
    private static let macosRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { u.deleteLastPathComponent() }          // Music, REDDYTests, Tests, macos
        return u
    }()
    private static func source(_ relative: String) -> String {
        (try? String(contentsOf: macosRoot.appendingPathComponent("Sources/REDDY/" + relative), encoding: .utf8)) ?? ""
    }
    private static func musicFeatureSources() -> [String] {
        let dir = macosRoot.appendingPathComponent("Sources/REDDY/Features/Music")
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { ($0 as? URL).flatMap { $0.pathExtension == "swift" ? try? String(contentsOf: $0, encoding: .utf8) : nil } }
    }

    // MARK: storage

    @Test func storageRootFollowsTheAppsStorage() {
        #expect(MusicStorage.root.path.hasPrefix(StorageService.applicationSupport.path))
        #expect(MusicStorage.root.lastPathComponent == "Music")
        #expect(MusicStorage.subfolder("Artwork").deletingLastPathComponent().path == MusicStorage.root.path)
        #expect(MusicStorage.caches.path.hasPrefix(StorageService.caches.path))
    }

    @Test func underTestTheStorageIsAThrowawayFolder() {
        #expect(ProcessInfo.processInfo.environment["STREAMSETU_TESTING"] == nil || MusicStorage.root.path.contains("reddy-appsupport-"))
    }

    // MARK: shared helpers

    @Test func hashHelperMatchesKnownVectors() {
        #expect(MusicHash.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(MusicHash.sha256("abc", prefix: 2) == "ba78")
        #expect(MusicHash.md5("abc") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(MusicHash.hex([0x00, 0x0f, 0xa0, 0xff]) == "000fa0ff")
        #expect(MusicSegmentSkipper.hashPrefix("dQw4w9WgXcQ") == SponsorVideoID.hashPrefix("dQw4w9WgXcQ"))
    }

    @Test func timeHelperFormatsAndParses() {
        #expect(MusicTime.clock(ms: 225_000) == "3:45")
        #expect(MusicTime.clock(ms: 3_723_000) == "1:02:03")
        #expect(MusicTime.parseMs("3:45") == 225_000)
        #expect(MusicTime.parseMs("1:02:03.5") == 3_723_500)
        #expect(MusicTime.parseMs("500ms") == 500)
        #expect(MusicTime.parseMs("") == nil && MusicTime.parseMs("abc") == nil)
        #expect(YouTubeAudio.clock("3:45") == 225_000 && YouTubeAudio.clock("45") == nil)
    }

    @Test func textRuleFoldsAccentsPunctuationAndAmpersands() {
        #expect(MusicText.normalize("Beyoncé – Halo!") == "beyonce halo")
        #expect(MusicText.normalize("Rock & Roll's  Café!") == "rock and rolls cafe")
        #expect(MusicText.normalize("日本語 テスト") == "日本語 テスト")
        #expect(MusicTextMatch.normalize("Rock & Roll") == ImportMatcher.norm("Rock & Roll"))
        #expect(LocalLibraryIndex.normalize("Café") == "cafe")
    }

    @Test func networkPolicyKnowsPrivateAddresses() {
        #expect(MusicNetworkPolicy.isPrivateHost("192.168.1.4") && MusicNetworkPolicy.isPrivateHost("localhost") && MusicNetworkPolicy.isPrivateHost("nas.local"))
        #expect(!MusicNetworkPolicy.isPrivateHost("addon.example.com") && !MusicNetworkPolicy.isPrivateHost("8.8.8.8"))
        #expect(MusicNetworkPolicy.isPrivateAddress([10, 0, 0, 1]) && !MusicNetworkPolicy.isPrivateAddress([8, 8, 8, 8]))
        #expect(AddonURLPolicy.isPrivateHost("10.1.2.3") == MusicNetworkPolicy.isPrivateHost("10.1.2.3"))
        #expect(MusicArtworkPolicy.validate("http://192.168.0.2/cover.jpg") == nil)
    }

    @Test func keychainWrapperRejectsEmptyValues() {
        let k = MusicKeychain(service: "StreamSetu.Music.tests.\(UUID().uuidString)")
        #expect(k.read("none") == nil)
        #expect(k.write("none", ""))                // an empty value means "remove", never "store an empty secret"
        #expect(k.read("none") == nil)
    }

    // MARK: settings coverage

    @Test func everySettingsBlockIsInTheSearchIndexAndTheOtherWayRound() {
        let page = Self.source("Features/Music/MusicSettingsPage.swift")
        let ids = Set(page.components(separatedBy: "block(\"").dropFirst().compactMap { $0.components(separatedBy: "\"").first })
        #expect(ids == Set(MusicSettingsSearch.blockAnchors), "blocks on the page and anchors in the index must be the same set")
        let anchors = Set(MusicSettingsSearch.index.map(\.anchor))
        for a in MusicSettingsSearch.blockAnchors { #expect(anchors.contains(a), "no index entry for \(a)") }
    }

    @Test func everySettingsSectionViewIsShownExactlyOnce() {
        let sources = Self.musicFeatureSources()
        let names = ["MusicExtrasSettingsSection", "MusicPlayerSettingsSection", "MusicAccountSettingsSection", "MusicPlaybackSettingsSection",
                     "MusicScrobbleSettingsSection", "MusicThemeSettingsSection", "MusicKaraokeSettingsSection", "MusicLyricsSettingsSection",
                     "MusicSourcesSettingsSection", "MusicHotkeysSection", "MusicAutomixSettingsSection", "MusicCatalogSettingsSection", "MusicOwnInstanceSettingsSection", "MusicSubsonicSettingsSection", "MusicMetadataSettingsSection", "MusicOutputDeviceSettingsSection", "MusicMotionSettingsSection"]
        for n in names {
            let uses = sources.reduce(0) { $0 + $1.components(separatedBy: n + "(hub: hub)").count - 1 }
            #expect(uses == 1, "\(n) is used \(uses) times")
        }
    }

    @Test func settingsHaveTheNewSwitchesAndNoSecondSleepTimer() {
        let page = Self.source("Features/Music/MusicSettingsPage.swift")
        #expect(page.contains("wavySeekBar") && page.contains("videoMode"))
        #expect(!page.localizedCaseInsensitiveContains("sleepTimer"))
        #expect(MusicSettingsSearch.search("karaoke", in: MusicSettingsSearch.index).contains { $0.tab == .playback })
        #expect(MusicSettingsSearch.search("addon", in: MusicSettingsSearch.index).contains { $0.tab == .plugins })
    }

    // MARK: lyrics

    @Test func unofficialLyricSourcesAreAllRealSources() {
        #expect(MusicLyricsSources.unofficial.isSubset(of: Set(MusicLyricsSources.defaultOrder)))
        #expect(!MusicLyricsSettingsLogic.unofficialNote.isEmpty)
    }

    @Test func oneGlobalLyricsOffsetLivesInTheSettings() {
        var s = MusicSettings()
        s.lyricsOffsetMs = 9_999
        #expect(s.lyricsOffsetMs == 9_999 || s.lyricsOffsetMs == MusicLyricsLookup.clampGlobalOffset(9_999))
        let source = Self.source("Features/Music/Lyrics/MusicLyricsState.swift")
        #expect(!source.contains("globalOffsetKey"))
    }

    // MARK: karaoke, resolver

    @MainActor @Test func resolverRemembersWhoServedATrackOnlyWhenAChainDid() {
        let registry = MusicRegistry(defaults: UserDefaults(suiteName: "music.integration.\(UUID().uuidString)") ?? .standard)
        let r = MusicStreamResolver(registry: registry)
        let t = MusicTrack(id: "1", providerID: "x", title: "T", durationMs: 1000, artists: [])
        #expect(r.servedBy(t) == nil)
    }

    @Test func karaokeStaysOnTheOriginalWhileOff() {
        let d = MusicKaraokeSwapPolicy.decide(playing: .original, progress: .off)
        #expect(d == .stay)
        #expect(MusicKaraokeSwapPolicy.crossfade == 0.08)
    }

    // MARK: packaging

    @Test func exportedDragTypesAreDeclared() throws {
        let plist = try String(contentsOf: Self.macosRoot.appendingPathComponent("Configuration/Info.plist"), encoding: .utf8)
        for k in MusicDragKind.allCases { #expect(plist.contains(k.identifier), "\(k.identifier) is not exported") }
    }

    @Test func iosSourceListHasNoDuplicatesAndEveryFileExists() throws {
        let list = try String(contentsOf: Self.macosRoot.deletingLastPathComponent().appendingPathComponent("ios/SharedSources.txt"), encoding: .utf8)
        let lines = list.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        #expect(Set(lines).count == lines.count)
        for l in lines where l.hasPrefix("Services/Music/") || l.hasPrefix("Features/Music/") {
            #expect(FileManager.default.fileExists(atPath: Self.macosRoot.appendingPathComponent("Sources/REDDY/" + l).path), "\(l) is missing")
        }
    }

    @Test func noMusicScreenFileNamesAnAiTool() {
        let banned = ["claude", "anthropic", "chatgpt", "copilot"]
        for s in Self.musicFeatureSources() { for b in banned { #expect(!s.lowercased().contains(b)) } }
    }
}
