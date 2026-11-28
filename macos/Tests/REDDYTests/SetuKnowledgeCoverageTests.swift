import Foundation
import Testing
@testable import REDDY

/// Setu must know the whole app. These tests keep it that way: every marker in the code has an entry, every entry the audit asked for exists and says what the app does today, stale text is gone, corrections point at
/// real entries, and Hinglish and Telugu in Latin letters reach the right topics.
@MainActor @Suite("Setu knowledge: coverage and truth", .serialized) struct SetuKnowledgeCoverageTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY")
    var entries: [AtlasEntry] { Atlas.entries }
    var byID: [String: AtlasEntry] { Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    // MARK: every control in the code has an entry

    /// Every id a marker names (`.atlas`, `.atlasCovers`, `.atlasScreen`, `atlas:`) anywhere in the Mac sources, Music included, is a declared entry; a new control with no entry fails here.
    @Test func everyMarkerInTheCodeHasADeclaredEntry() throws {
        let ids = Set(entries.map(\.id))
        var missing: [String] = []
        for f in try FileManager.default.subpathsOfDirectory(atPath: Self.sources.path) where f.hasSuffix(".swift") && !f.hasPrefix("Atlas/") {
            let text = try String(contentsOf: Self.sources.appendingPathComponent(f), encoding: .utf8)
            for m in text.matches(of: /(?:\.atlas|\.atlasCovers|\.atlasScreen)\("([^"]+)"\)|atlas: "([^"]+)"/) {
                let id = String(m.output.1 ?? m.output.2 ?? "")
                if !id.isEmpty, !ids.contains(id) { missing.append("\(id)  (\(f))") }
            }
        }
        #expect(missing.isEmpty, "markers with no declared entry: \(missing.sorted())")
    }

    // MARK: the audit's missing entries exist

    static let wanted: [String] = [
        // Setu and the search box
        "control.setu.shareScreen", "control.setu.newChat", "control.setu.modelMenu", "meta.setuCanChange", "meta.setuTools", "shortcut.setu.send", "shortcut.search.askSetu", "control.settings.askSetu",
        "control.addSource.helpMeWithThis", "intent.openSetting", "control.search.topBar", "control.search.askSetuRow", "shortcut.search.forceAsk", "shortcut.search.forceSearch",
        // app
        "setting.viewingLimits", "control.profiles.add", "control.profiles.remove", "diag.viewingBlock", "control.statistics.weeklyDigest", "control.tonight.usualTime", "screen.home.offline", "control.home.clearContinue",
        "meta.smartMix", "control.player.privateBadge", "control.integrations.traktSignIn", "control.guide.removeGuide", "control.settings.openNetworkSettings", "meta.deepLinks", "meta.widgetsAndActivity",
        "shortcut.podcasts.keys", "meta.whatIsStreamSetu", "meta.pricing", "meta.supportedDevices", "meta.supportedFormats", "meta.differencesByPlatform", "meta.compareToOthers", "diag.streamingService", "diag.appLock",
        "diag.backupRestore", "diag.proxyDns", "diag.multiviewLimit", "diag.libraryRebuilt", "meta.whatsNew.2026.11.23", "meta.whatsNew.music",
        // Music screens and controls
        "screen.music.sidebarLibrary", "screen.music.sidebarPlaylists", "control.music.sidebarFold", "control.music.sidebarOpenLink", "control.music.backPill", "control.music.sidePanelButton", "screen.music.sidePanel",
        "screen.music.listenNowPersonal", "screen.music.exploreRegion", "control.music.exploreShuffleChart", "control.music.exploreFeatureCards", "control.music.exploreLanguageTile", "behaviour.music.countryRules",
        "control.music.searchScope", "control.music.searchTypeChips", "control.music.searchRecent", "screen.music.libraryTabs", "control.music.libraryRecentlyAdded", "control.music.playerBarPill", "control.music.playerBarMore",
        "control.music.playerHideShow", "control.music.sleepTimerMusic", "control.music.effectsPopover", "control.music.audioQualityChip", "screen.music.miniPlayerWindow", "screen.music.theatre", "control.music.menuBarItem",
        "behaviour.music.notifications", "screen.music.shortcutsList", "screen.music.settingsMap",
        // Music keys
        "shortcut.music.nextPrev", "shortcut.music.shuffleRepeat", "shortcut.music.like", "shortcut.music.mute", "shortcut.music.volumeKeys", "shortcut.music.refresh", "shortcut.music.toggleNowPlaying", "shortcut.music.zoom",
        "shortcut.music.theatreKey", "shortcut.music.optionSpace", "shortcut.music.forward", "shortcut.music.roomLock", "shortcut.music.queueUndo", "shortcut.music.selectAll", "shortcut.music.globalHotkeys",
        // Music settings
        "setting.music.audioQuality", "setting.music.normalizeVolume", "setting.music.crossfade", "setting.music.autoplay", "setting.music.playOnStart", "setting.music.menuBarItem", "setting.music.globalHotkeys",
        "setting.music.lyricsSources", "setting.music.translateLyricsInto", "setting.music.lyricsOffset", "setting.music.automix", "setting.music.equalizer", "setting.music.outputDevice", "setting.music.animatedArtwork",
        "setting.music.scrobbling", "setting.music.audioCache", "setting.music.localFolders", "setting.music.pluginUpdates", "setting.music.youtubeMusicAccount", "setting.music.devicesAllowControl", "setting.music.textSize",
        // Music how-tos and fixes
        "recipe.music.signInYouTubeMusic", "recipe.music.setSleepTimer", "recipe.music.changeCountry", "recipe.music.addLanguage", "recipe.music.importPlaylist", "recipe.music.downloadSongs", "recipe.music.startListenTogether",
        "recipe.music.pairDevice", "recipe.music.connectLastFm", "recipe.music.turnOnCrossfade", "recipe.music.useEqualizer", "recipe.music.findFavouriteSongs", "recipe.music.blockSong", "diag.music.noLyrics",
        "diag.music.songWontPlay", "diag.music.noChartsForCountry", "diag.music.noSourceOn", "diag.music.devicesNotFound", "diag.music.pairingLocked", "diag.music.playerBarGone", "diag.music.sidebarNamesMissing",
        "diag.music.panelButtonMissing",
    ]

    @Test func everyEntryTheAuditsAskedForExists() {
        let ids = Set(entries.map(\.id))
        #expect(Self.wanted.count >= 130)
        #expect(Self.wanted.filter { !ids.contains($0) }.isEmpty, "missing: \(Self.wanted.filter { !ids.contains($0) })")
    }

    @Test func theNewEntriesAreSpecificFindableAndChecked() {
        for id in Self.wanted {
            guard let e = byID[id] else { continue }
            #expect(e.reviewed, "\(id) is not marked reviewed")
            #expect(e.summary.count >= 30, "\(id) summary is too thin: \(e.summary)")
            #expect(!e.summary.hasPrefix("The button '") && !e.summary.hasPrefix("A button in"), "\(id) is a templated summary")
            if e.kind != .meta, e.kind != .screen { #expect(!e.aliases.isEmpty, "\(id) has no spoken forms") }
        }
    }

    @Test func musicEntriesAreMacOnlyAndTheSearchBoxIsMacOnly() {
        for id in Self.wanted where id.contains("music") || id.hasPrefix("control.search.") || id.hasPrefix("shortcut.search.") {
            #expect(byID[id]?.platforms == .mac, "\(id) must be Mac only")
        }
    }

    // MARK: stale text is gone

    @Test func whatsNewDescribesTheCurrentRelease() {
        let e = byID["meta.whatsNew"]
        #expect(e?.summary.contains("2.18.0") == true && e?.summary.contains("1.4") == true)
        #expect(entries.filter { $0.id.hasPrefix("meta.whatsNew.next") }.isEmpty)
        #expect(!entries.contains { $0.summary.contains("Planned for the next release") })
        #expect(byID["meta.whatsNew.2026.11.23"]?.since == "2.18.0")
    }

    @Test func noMusicEntryStillDescribesAHeaderBarOrWrongTabs() {
        for e in entries where e.id.contains("music") {
            #expect(!e.path.contains("Header"), "\(e.id) still sits in a Music header")
            #expect(!e.summary.lowercased().contains("header bar"), "\(e.id): \(e.summary)")
            #expect(!e.summary.contains("Accounts and Sources"), "\(e.id)")
            #expect(!e.path.contains("Shortcuts") || e.kind == .shortcut, "\(e.id) names a Shortcuts tab that does not exist")
        }
        #expect(byID["screen.music.settings"]?.summary.contains("Plugins & Sources") == true)
        #expect(byID["control.music.sidebar"]?.summary.contains("Library group") == true)
        #expect(byID["screen.destination.music"]?.summary.contains("Listen Now") == true)
        #expect(byID["control.music.openLink"]?.path.contains("More") == true)
    }

    @Test func theGuideHubEntriesPointAtRealPlaces() {
        for id in ["setting.guide.enrichmentEnabled", "setting.guide.reminderLeadMinutes", "setting.storage.guideBannerDismissed"] { #expect(byID[id]?.path.first != "Settings" || byID[id]?.path.contains("Library") == true, "\(id)") }
        for id in ["setting.guide.sources", "setting.guide.addXMLTV", "setting.guide.publicDatabase", "setting.guide.enrichLogos", "setting.guide.enrichmentEnabled", "setting.guide.reminderLeadMinutes"] {
            #expect(byID[id]?.mayPropose == false, "\(id) cannot be changed by Setu, so it must not offer a change button")
        }
    }

    @Test func theCatalogueSendsPeopleToTheLibraryTabForTheFiveSettingsThatMoved() {
        for id in ["profiles", "icloudSync", "lanSync", "keywordAlerts", "subscriptions"] { #expect(AppSettingsCatalog.find(id)?.path.contains("Library") == true, "\(id): \(AppSettingsCatalog.find(id)?.path ?? "none")") }
    }

    @Test func artworkEntriesNoLongerSayAKeyIsRequired() {
        for id in ["screen.person", "recipe.fixWrongArtwork", "diag.artwork"] {
            let t = ((byID[id]?.summary ?? "") + " " + (byID[id]?.detail ?? "")).lowercased()
            #expect(!t.contains("needs a tmdb key") && !t.contains("add your own free tmdb key") && !t.contains("you can use your own free tmdb key"), "\(id): \(t)")
        }
    }

    @Test func entriesForMacOnlyControlsAreNotOfferedOnIPhone() {
        for id in ["setting.toneMapping", "setting.deinterlace", "setting.renderingProfile", "setting.stereoDownmix", "setting.density", "setting.clickBehavior", "setting.sidebarLaunch", "setting.liveRewind", "setting.recordings"] {
            #expect(byID[id]?.platforms.contains(.iPhone) == false, "\(id) has no iPhone control")
        }
    }

    // MARK: titles are words

    @Test func noEntryTitleIsACodeName() {
        let bad = entries.filter { e in
            e.title.contains("%@") || e.title.contains(".circle") || e.title.contains("(s.") || e.title.hasSuffix(" Button") || e.title.hasSuffix(" shortcut") || e.title == "01" || e.title.contains(": )")
        }
        #expect(bad.isEmpty, "titles that are code names: \(bad.map { "\($0.id): \($0.title)" })")
    }

    /// The one-line "The button 'X' in Music, Y." summaries carry no answer. They are being replaced; this ratchet stops the count growing while that goes on.
    @Test func templatedMusicSummariesDoNotGrow() {
        let templated = entries.filter { $0.summary.hasPrefix("The button '") || $0.summary.hasPrefix("The menu '") || $0.summary.hasPrefix("The shortcut '") || $0.summary.hasPrefix("A button in Music") || $0.summary.hasPrefix("A shortcut in Music") }
        #expect(templated.count <= 270, "\(templated.count) templated summaries (limit 270); write a real one for each new control")
    }

    // MARK: corrections and spoken forms point at real entries

    @Test func everyRefinementAndHinglishAliasBelongsToARealEntry() {
        let ids = Set(entries.map(\.id))
        #expect(AtlasRefine.table.keys.filter { !ids.contains($0) }.sorted().isEmpty, "refinements for missing entries: \(AtlasRefine.table.keys.filter { !ids.contains($0) }.sorted())")
        #expect(AtlasTuning.indic.keys.filter { !ids.contains($0) }.sorted().isEmpty, "Hinglish aliases for missing entries: \(AtlasTuning.indic.keys.filter { !ids.contains($0) }.sorted())")
        #expect(AtlasTuning.indic.count >= 30)
    }

    @Test func aRefinedEntryKeepsItsIdAndKind() {
        #expect(byID["control.music.sidePanelButton"]?.kind == .control)
        #expect(byID["control.music.contextToggle"]?.shortcut == "⌃⌘I")
        #expect(byID["control.music.playerAndQueueMusicplayerbartrackinfoButton"]?.title == "Like the playing song (heart)")
    }

    // MARK: Hinglish and Telugu in Latin letters reach the right topics

    @Test func commonAsksInHinglishAndTeluguFindTheirTopic() {
        let cases: [(String, [String])] = [
            ("queue clear kaise", ["control.music.playerAndQueueClearQueue"]),
            ("lyrics kaise dekhe", ["control.music.playerAndQueueLyrics"]),
            ("song play ela", ["screen.music.search", "control.music.songPagePlay", "control.music.songMenusPlay", "control.music.libraryPlay"]),
            ("subtitles kaise on kare", ["recipe.setupSubtitles", "setting.subtitlesByDefault"]),
            ("sound nahi aa raha", ["diag.noSound"]),
            ("guide khali kyun hai", ["recipe.fixEmptyGuide", "diag.guide"]),
            ("equalizer kahan hai", ["recipe.music.useEqualizer", "setting.music.equalizer"]),
            ("crossfade ela on cheyali", ["recipe.music.turnOnCrossfade", "setting.music.crossfade"]),
            ("devices nahi mil rahe", ["diag.music.devicesNotFound"]),
            ("sleep timer ela pettali", ["recipe.sleepTimer", "control.music.sleepTimerMusic"]),
        ]
        for (q, want) in cases {
            let top = Atlas.engine.retrieve(q, platform: .mac, limit: 8).hits.map(\.entry.id)
            #expect(want.contains { top.contains($0) }, "\(q) -> \(top)")
        }
    }

    @Test func englishQuestionsAboutTheSearchBoxAndSetuFindTheirEntries() {
        let cases: [(String, [String])] = [
            ("ask setu from the search bar", ["control.search.topBar", "shortcut.search.askSetu", "control.search.askSetuRow"]),
            ("what does shift return do in search", ["shortcut.search.forceAsk"]),
            ("how do i turn off setu seeing my screen", ["control.setu.shareScreen"]),
            ("can setu change my settings", ["meta.setuCanChange"]),
            ("is streamsetu free", ["meta.pricing"]),
            ("does it play mkv", ["meta.supportedFormats"]),
            ("where is favorite songs in music", ["screen.music.sidebarLibrary", "recipe.music.findFavouriteSongs"]),
            ("why is there no back button in music", ["control.music.backPill"]),
        ]
        for (q, want) in cases {
            let top = Atlas.engine.retrieve(q, platform: .mac, limit: 8).hits.map(\.entry.id)
            #expect(want.contains { top.contains($0) }, "\(q) -> \(top)")
        }
    }

    @Test func theRouterLogLineNeverCrashesOnOddText() {
        SetuRouterLog.decision(text: "", route: .general, intent: .other, decision: .weak, confidence: 0, top: [], outcome: "test")
        SetuRouterLog.searchReturn(query: "a b \u{1F3B5}", mode: "automatic", action: "search", kids: false)
    }
}
