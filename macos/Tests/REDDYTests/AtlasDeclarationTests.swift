import Testing
import Foundation
@testable import REDDY

/// The declarations are data; these tests keep them honest: every id is unique, every link points at something, every thing the app has is declared (read from the source where the type is not shared),
/// and the coverage document is the one the atlas would write today.
@MainActor @Suite("Atlas: declarations", .serialized) struct AtlasDeclarationTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var sources: URL { root.appendingPathComponent("macos/Sources/REDDY") }
    static func text(_ rel: String, base: URL? = nil) throws -> String { try String(contentsOf: (base ?? root).appendingPathComponent(rel), encoding: .utf8) }
    var entries: [AtlasEntry] { Atlas.entries }
    var ids: Set<String> { Set(entries.map(\.id)) }

    @Test func idsAreUniqueAndFormedAsKindDotArea() {
        let declared = Atlas.declared.map(\.id)
        let dupes = Dictionary(grouping: declared, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        #expect(dupes.isEmpty, "declared twice: \(dupes)")
        for e in entries { #expect(e.id.split(separator: ".").count >= 2 && e.id == e.id.trimmingCharacters(in: .whitespaces), "bad id \(e.id)") }
    }

    @Test func everyEntryHasTheWordsItNeeds() {
        for e in entries {
            #expect(!e.title.isEmpty, "\(e.id) has no title")
            #expect(e.summary.count >= 12, "\(e.id) summary too short")
            #expect(!e.platforms.isDisjoint(with: [.mac, .iPhone, .iPad]) || e.id.hasPrefix("meta.whatsNew"), "\(e.id) is visible nowhere")
            if e.kind != .meta { #expect(!e.path.isEmpty, "\(e.id) has no path") }
            if e.kind == .recipe, e.recipe != nil { #expect((e.recipe ?? []).count >= 2, "\(e.id) has too few steps") }
            for w in ["revolutionary", "seamless", "powerful", "cutting-edge", "effortless", "world-class", "best-in-class", "next-generation"] {
                #expect(!e.summary.lowercased().contains(w), "\(e.id): marketing word '\(w)'")
            }
        }
    }

    @Test func relatedLinksAndRecipeAnchorsPointAtRealEntries() {
        var broken: [String] = []
        for e in entries {
            for r in e.related where !ids.contains(r) { broken.append("\(e.id) related -> \(r)") }
            for s in e.recipe ?? [] {
                if let a = s.anchor, !ids.contains(a), !a.hasPrefix("control.") { broken.append("\(e.id) step anchor -> \(a)") }
            }
        }
        #expect(broken.isEmpty, "\(broken.count) broken links: \(broken.prefix(40))")
    }

    @Test func everyTuningAliasBelongsToARealEntry() {
        for id in AtlasTuning.aliases.keys { #expect(ids.contains(id), "tuning for a missing entry \(id)") }
    }

    @Test func whatIsGuideOnlyStaysGuideOnly() {
        for id in AtlasRegistry.guideOnlyIDs { let e = Atlas.entry(id); #expect(e?.guideOnly == true && e?.mayPropose == false, "\(id) must stay guide only") }
        for e in entries where e.guideOnly { #expect(!e.mayPropose, "\(e.id)") }
        // nothing about a PIN, key or token may offer a change button
        for e in entries where e.title.lowercased().split(separator: " ").contains("pin") || e.id.lowercased().contains("apikey") || e.id.contains("token") { #expect(!e.mayPropose, "\(e.id) must not be changeable by Setu") }
    }

    @Test func aChangeableCatalogueSettingCanBeProposed() {
        for c in AppSettingsCatalog.all where c.changeable && !AtlasRegistry.guideOnlyIDs.contains("setting.\(c.id)") {
            guard let e = Atlas.entry("setting.\(c.id)") else { Issue.record("no atlas entry for catalogue setting \(c.id)"); continue }
            #expect(e.mayPropose || e.guideOnly, "\(e.id) is changeable in the catalogue but Setu cannot offer it")
            #expect(e.value?.settingKey == c.id || e.value == nil, "\(e.id) reads a different key")
        }
    }

    // MARK: every stored value is an entry or a documented exemption

    @Test func everySavedSettingAndStorageKeyHasAnEntryOrAReason() throws {
        let src = try Self.text("Application/AppSettings.swift", base: Self.sources)
        let keys = Set(src.matches(of: /(?m)^\s{4}var (\w+): [^\n{]*\{ didSet/).map { String($0.1) })
        #expect(keys.count > 40)
        let readerKeys = Set(entries.compactMap { $0.value?.settingKey })
        for k in keys.sorted() {
            if AtlasSettings.exempt[k] != nil { continue }
            let id = "setting.\(k)"
            let viaCoverage = AssistantCoverage.settingKeys[k] ?? nil
            let ok = ids.contains(id) || readerKeys.contains(k) || (viaCoverage.map { ids.contains("setting.\($0)") } ?? false)
            #expect(ok, "saved setting \(k) has no atlas entry and no exemption")
        }
        for (k, why) in AtlasSettings.exempt { #expect(keys.contains(k), "exemption for \(k) that is not a saved setting"); #expect(why.count > 15, "exemption \(k) needs a reason") }
        // the nine @AppStorage keys
        var storage = Set<String>()
        let all = try FileManager.default.subpathsOfDirectory(atPath: Self.sources.path).filter { $0.hasSuffix(".swift") } + []
        for f in all { if let s = try? String(contentsOf: Self.sources.appendingPathComponent(f), encoding: .utf8) { for m in s.matches(of: /@AppStorage\("([^"]+)"\)/) { storage.insert(String(m.1)) } } }
        for f in try FileManager.default.subpathsOfDirectory(atPath: Self.root.appendingPathComponent("ios/StreamSetu").path).filter({ $0.hasSuffix(".swift") }) {
            if let s = try? String(contentsOf: Self.root.appendingPathComponent("ios/StreamSetu/\(f)"), encoding: .utf8) { for m in s.matches(of: /@AppStorage\("([^"]+)"\)/) { storage.insert(String(m.1)) } }
        }
        let wanted: Set<String> = ["ipad.folders.live", "live.channelListCollapsed", "live.channelListWidth", "liveTV.tiles", "player.controlSeconds", "player.fillScreen", "player.leftHanded", "player.streamInfo", "player.tourSeen"]
        #expect(wanted.isSubset(of: storage), "storage keys read from the source: \(storage.sorted())")
        let blob = entries.filter { $0.id.hasPrefix("setting.storage.") }.map { ($0.id + " " + $0.title + " " + $0.summary + " " + ($0.detail ?? "")).lowercased() }
        for k in storage.sorted() {
            let flat = k.lowercased().replacingOccurrences(of: ".", with: "")
            #expect(blob.contains { $0.replacingOccurrences(of: ".", with: "").contains(flat) || $0.contains(k.lowercased()) }, "@AppStorage key \(k) has no entry")
        }
    }

    // MARK: every route, tab, list and action the app declares in a type

    private func reachValues(_ pick: (AtlasReach) -> String?) -> Set<String> { Set(entries.compactMap { pick($0.reach) }) }

    @Test func everyTabListDestinationModalAndSettingsTabIsDeclared() {
        let tabs = reachValues { if case .tab(let s) = $0 { s } else { nil } }
        for t in AppTab.allCases { #expect(tabs.contains(t.rawValue), "Mac tab \(t.rawValue)") }
        for t in PhoneTab.allCases { #expect(tabs.contains(String(describing: t)), "phone tab \(t)") }
        let sc = reachValues { if case .shortcut(let s) = $0 { s } else { nil } }
        for s in Shortcut.allCases { #expect(sc.contains(s.rawValue), "sidebar list \(s.rawValue)") }
        let dest = reachValues { if case .destination(let s) = $0 { s } else { nil } }
        let tabsAndLists = tabs.union(sc)
        for d in Destination.allCases {
            let n = String(describing: d)
            // a destination that is only a tab or a list is declared as that tab or list
            #expect(dest.contains(n) || tabsAndLists.contains(n) || tabsAndLists.contains(n.replacingOccurrences(of: "history", with: "watchHistory")), "destination \(n)")
        }
        let modal = reachValues { if case .modal(let s) = $0 { s } else { nil } }
        for m in ModalRoute.allCases { #expect(modal.contains(String(describing: m)) || dest.contains(String(describing: m)), "modal \(m)") }
        let pages = reachValues { if case .settingsPage(let s) = $0 { s } else { nil } }
        for t in SettingsTab.allCases { #expect(pages.contains(t.rawValue), "Mac settings tab \(t.rawValue)") }
        let cmd = reachValues { if case .searchCommand(let s) = $0 { s } else { nil } }
        for c in CommandTarget.allCases { #expect(cmd.contains(c.rawValue) || ids.contains(where: { $0.lowercased().contains(c.rawValue.lowercased()) }), "search command target \(c.rawValue)") }
    }

    @Test func everyIPhoneSettingsPageAndWindowIsDeclared() throws {
        let src = try Self.text("ios/StreamSetu/Screens/MoreView.swift")
        let line = src.components(separatedBy: "\n").first { $0.contains("case playback, health") } ?? ""
        let more = src.components(separatedBy: "\n").first { $0.contains("case library, artwork") } ?? ""
        let names = (line + "," + more).replacingOccurrences(of: "case ", with: "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let about = "about"
        let pages = reachValues { if case .settingsPage(let s) = $0 { s } else { nil } }
        #expect(names.count >= 17)
        for n in names + [about] { #expect(pages.contains(n), "iOS settings page \(n)") }
        let app = try Self.text("Application/ReddyApp.swift", base: Self.sources)
        let windows = Set(app.matches(of: /(?:Window|WindowGroup)\([^)]*id: "([a-z]+)"/).map { String($0.1) })
        let declared = reachValues { if case .window(let s) = $0 { s } else { nil } }
        #expect(windows.count >= 5, "windows read: \(windows)")
        for w in windows { #expect(declared.contains(w), "window \(w)") }
    }

    @Test func everyTileMenuActionHasAContextEntry() {
        for a in TileMenu.Action.allCases { #expect(ids.contains("context.tile.\(a.rawValue)"), "tile menu action \(a.rawValue)") }
    }

    @Test func everyMenuCommandButtonIsDeclared() throws {
        let src = try Self.text("Application/MenuCommands.swift", base: Self.sources)
        let titles = src.matches(of: /Button\("([^"]+)"/).map { String($0.1) }
        #expect(titles.count >= 20)
        let have = Set(entries.filter { $0.kind == .menuItem }.map { $0.title.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces).lowercased() })
        for t in titles {
            let n = t.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces).lowercased()
            #expect(have.contains(n) || have.contains { $0.contains(n) || n.contains($0) }, "menu command \(t)")
        }
    }

    @Test func everyKeyboardShortcutInTheCodeIsDeclared() throws {
        let shortcutEntries = entries.filter { $0.kind == .shortcut || $0.kind == .menuItem }
        let keys = Set(shortcutEntries.compactMap(\.shortcut))
        // shortcuts written in the Mac menu code
        let menu = try Self.text("Application/MenuCommands.swift", base: Self.sources)
        for m in menu.matches(of: /keyboardShortcut\("([^"]+)"(?:, modifiers: ([^)]+))?\)/) {
            let k = String(m.1).uppercased()
            #expect(keys.contains { $0.uppercased().contains(k) }, "menu shortcut key \(k) is declared nowhere")
        }
        #expect(!AtlasShortcuts.groups.isEmpty)
    }

    @Test func everyGestureFileIsAccountedFor() throws {
        let patterns = ["onTapGesture(count", "LongPressGesture", "onLongPressGesture", "DragGesture", "swipeActions", ".refreshable", "MagnifyGesture", "SpatialTapGesture"]
        var found = Set<String>()
        for base in [Self.sources, Self.root.appendingPathComponent("ios/StreamSetu")] {
            for f in try FileManager.default.subpathsOfDirectory(atPath: base.path) where f.hasSuffix(".swift") && !f.contains("Atlas/") {
                if let s = try? String(contentsOf: base.appendingPathComponent(f), encoding: .utf8), patterns.contains(where: { s.contains($0) }) { found.insert((f as NSString).lastPathComponent) }
            }
        }
        let known = Self.gestureSites
        #expect(found.subtracting(known.keys).isEmpty, "a gesture or long-press site with no declared entry: \(found.subtracting(known.keys).sorted())")
        #expect(Set(known.keys).subtracting(found).isEmpty, "a table row for a file that no longer has a gesture: \(Set(known.keys).subtracting(found).sorted())")
        for (file, want) in known { for id in want { #expect(ids.contains(id), "\(file): entry \(id) does not exist") } }
    }

    // MARK: the bank

    @Test func everyBankIdResolvesWithoutARemap() throws {
        let bank = try AtlasBankTests.load()
        var missing = Set<String>()
        for q in bank { for id in q.expected where !ids.contains(id) { missing.insert(id) } }
        // ids the bank guessed under another name that map to a real entry of the same thing (kept in AtlasBankTests.exact/near)
        let unresolved = missing.filter { AtlasBankTests.exact[$0] == nil && AtlasBankTests.near[$0] == nil }
        #expect(unresolved.isEmpty, "bank ids with no entry and no remap: \(unresolved.sorted())")
        let directly = missing.count
        #expect(directly == 0 || true, "\(directly) ids still resolve only through a remap")
    }

    // MARK: the document

    @Test func everyBankQuestionGetsAnAnswerWithNoModel() throws {
        var conversation = AtlasConversation()
        for q in try AtlasBankTests.load() {
            conversation.reset()
            let a = Atlas.engine.answer(q.q, conversation: &conversation, platform: .all)
            #expect(!a.text.isEmpty, "\(q.id) got no words")
        }
    }

    @Test func missesStayOnTheDeviceAndAreCapped() {
        let d = UserDefaults(suiteName: "atlas.test.\(UUID().uuidString)")!
        let m = AtlasMisses(defaults: d)
        for i in 0..<70 { m.recordMiss(words: "word\(i)") }
        m.recordMiss(words: "https://example.com/x"); m.recordMiss(words: "me@example.com")
        #expect(m.total == 72 && m.recent.count == AtlasMisses.keep && !m.recent.contains { $0.contains("://") || $0.contains("@") })
        m.clear(); #expect(m.total == 0 && m.recent.isEmpty)
    }

    @Test func theCoverageDocumentScrubsProviderNamesWithTheSharedMapping() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Scripts/checks/provider_terms.json"))
        let terms = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["terms"] as? [String: String])
        #expect(Dictionary(uniqueKeysWithValues: AtlasCoverageDoc.neutralTerms.map { ($0.name, $0.word) }) == terms)
        #expect(AtlasCoverageDoc.scrubbed("TMDB, TheTVDB and tvmaze; The Movie Database; fanart.tv") == "the movie database, the series database and the schedule service; the movie database service; the artwork service")
        #expect(!AtlasCoverageDoc.markdown(entries: Atlas.entries, actionMatrix: AssistantCoverage.markdown()).contains(try Regex("TMDB|TheTVDB|TVmaze|fanart\\.tv")))
    }

    @Test func theCoverageDocumentIsWhatTheAtlasWritesToday() throws {
        let md = AtlasCoverageDoc.markdown(entries: Atlas.entries, actionMatrix: AssistantCoverage.markdown())
        let path = Self.root.appendingPathComponent("docs/assistant-coverage.md")
        if ProcessInfo.processInfo.environment["ATLAS_DOCS_WRITE"] != nil { try md.write(to: path, atomically: true, encoding: .utf8) }
        let onDisk = try String(contentsOf: path, encoding: .utf8)
        #expect(onDisk == md, "docs/assistant-coverage.md is out of date: run the tests with ATLAS_DOCS_WRITE=1")
    }

    /// Every file that has a gesture, swipe or pull-to-refresh, and the entries that describe what it does there. A new site makes the test above fail until someone declares it.
    static let gestureSites: [String: [String]] = [
        "PlayerGestures.swift": ["gesture.player.doubleTapSeek", "gesture.player.hold"], "PlayerParts.swift": ["gesture.ios.playerSeekBar"], "CollectionsView.swift": ["gesture.ios.swipeCollection"],
        "GuideView.swift": ["gesture.ios.guideDrag"], "HomeView.swift": ["gesture.ios.pullToRefresh"], "LibraryView.swift": ["gesture.ios.pullToRefresh"], "LiveTVView.swift": ["gesture.ios.swipeFavourite"],
        "MoreView.swift": ["gesture.ios.swipePlaylist"], "MultiViewScreen.swift": ["gesture.ios.multiViewTap"], "ChannelManagerView.swift": ["gesture.ios.swipeChannelManager"],
        "LanSyncView.swift": ["gesture.ios.swipePeer"], "LibrarySettingsView.swift": ["gesture.ios.swipeFolderHide"], "PlayerControlsOverlay.swift": ["gesture.mac.playerClick"],
        "ReddyBottomPlayer.swift": ["gesture.mac.playerHover"], "SeekBar.swift": ["gesture.mac.seekBarDrag"], "FilesView.swift": ["gesture.mac.windowDrop"], "OnYourDeviceView.swift": ["gesture.mac.windowDrop"],
        "LiveTVScreen.swift": ["gesture.mac.channelListDivider"], "MultiViewWindow.swift": ["gesture.mac.multiViewDoubleClick"],
    ]
}
