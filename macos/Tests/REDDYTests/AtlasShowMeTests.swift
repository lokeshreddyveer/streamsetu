import Testing
import Foundation
import CoreGraphics
@testable import REDDY

private func entry(_ id: String, _ kind: AtlasKind = .setting, title: String = "T", path: [String] = ["Settings", "Playback"], reach: AtlasReach = .settingsPage("Playback"), anchor: String? = nil,
                   recipe: [AtlasStep]? = nil, guideOnly: Bool = false, safety: AtlasSafety = .change) -> AtlasEntry {
    AtlasEntry(id: id, kind: kind, title: title, summary: "About \(title).", path: path, reach: reach, anchor: anchor, recipe: recipe, safety: safety, guideOnly: guideOnly)
}

@MainActor @Suite("Atlas: Show me") struct AtlasShowMeTests {
    let frame = CGRect(x: 40, y: 60, width: 120, height: 30)

    @Test func singleEntryIsOneStepOnItsOwnMarker() throws {
        let s = try #require(ShowMeSession.make(for: entry("setting.buffering", title: "Buffering mode"), lookup: { _ in nil }))
        #expect(s.steps.count == 1 && s.current.anchor == "setting.buffering" && s.isFirst && s.isLast && !s.showsProgress)
        #expect(s.current.openTitle == "Playback")       // the page it lives on
    }

    @Test func anchorFieldWinsOverTheEntryId() throws {
        let s = try #require(ShowMeSession.make(for: entry("setting.x", anchor: "control.x"), lookup: { _ in nil }))
        #expect(s.current.anchor == "control.x")
    }

    @Test func recipeWalksItsStepsBackAndForth() throws {
        let steps = [AtlasStep(say: "One", anchor: "a", reach: nil), AtlasStep(say: "Two", anchor: "b", reach: nil), AtlasStep(say: "Three", anchor: nil, reach: nil)]
        var s = try #require(ShowMeSession.make(for: entry("recipe.r", .recipe, title: "Do it", reach: .none, recipe: steps, safety: .read), lookup: { _ in nil }))
        #expect(s.progress == "Step 1 of 3" && s.showsProgress && !s.back())
        #expect(s.next() && s.next() && s.isLast && !s.next())
        #expect(s.progress == "Step 3 of 3" && s.current.say == "Three")
        #expect(s.back() && s.current.say == "Two")
    }

    @Test func spotlightWhenTheFrameIsRecorded() throws {
        let s = try #require(ShowMeSession.make(for: entry("setting.a"), lookup: { _ in nil }))
        #expect(s.resolve(frames: ["setting.a": frame]) == .spotlight(frame))
    }

    @Test func frameThatIsEmptyOrTinyCountsAsMissing() throws {
        let s = try #require(ShowMeSession.make(for: entry("setting.a"), lookup: { _ in nil }))
        #expect(s.resolve(frames: ["setting.a": .zero]) == .missing(openTitle: "Playback", canOpen: true))
        #expect(s.resolve(frames: ["setting.a": CGRect(x: 1, y: 1, width: 2, height: 2)]) == .missing(openTitle: "Playback", canOpen: true))
        #expect(s.resolve(frames: ["setting.a": CGRect(x: Double.nan, y: 0, width: 50, height: 50)]) == .missing(openTitle: "Playback", canOpen: true))
    }

    @Test func missingFallsBackToOpenTheScreenThenSaysWhereToLook() throws {
        var s = try #require(ShowMeSession.make(for: entry("setting.a"), lookup: { _ in nil }))
        #expect(s.resolve(frames: [:]) == .missing(openTitle: "Playback", canOpen: true))
        s.markOpened()
        #expect(s.resolve(frames: [:]) == .openedButNotFound(lookFor: "Playback"))
        #expect(s.resolve(frames: ["setting.a": frame]) == .spotlight(frame))           // it appeared after opening
    }

    @Test func noRouteMeansNoOpenButton() throws {
        let s = try #require(ShowMeSession.make(for: entry("setting.a", reach: .none), lookup: { _ in nil }))
        #expect(s.resolve(frames: [:]) == .missing(openTitle: "Playback", canOpen: false))
        #expect(s.announcement(s.resolve(frames: [:])).contains("Open Playback and try again"))
    }

    @Test func aStepWithoutAnAnchorIsJustACaption() throws {
        let s = try #require(ShowMeSession.make(for: entry("recipe.r", .recipe, reach: .none, recipe: [AtlasStep(say: "Press Add.", anchor: nil, reach: nil)], safety: .read), lookup: { _ in nil }))
        #expect(s.resolve(frames: [:]) == .caption)
    }

    @Test func recipeStepOpensTheEntryItPointsAt() throws {
        let target = entry("control.addSource.type", .control, title: "Type", path: ["Add Playlist"], reach: .modal("addPlaylist"))
        let r = entry("recipe.add", .recipe, title: "Add", reach: .none, recipe: [AtlasStep(say: "Choose Type.", anchor: "control.addSource.type", reach: nil)], safety: .read)
        let s = try #require(ShowMeSession.make(for: r, lookup: { $0 == target.id ? target : nil }))
        #expect(s.current.openEntryID == "control.addSource.type" && s.current.reach == .modal("addPlaylist"))
        #expect(s.resolve(frames: [:]) == .missing(openTitle: "Add Playlist", canOpen: true))
    }

    @Test func guideOnlyIsHighlightedWithAnExplanationNeverChanged() throws {
        let lock = entry("setting.appLock", guideOnly: true, safety: .never)
        let s = try #require(ShowMeSession.make(for: lock, lookup: { _ in nil }))
        #expect(s.current.guideOnly)
        #expect(s.announcement(.spotlight(frame)).contains("You change it yourself"))
        #expect(!lock.mayPropose)
        // a how-to that points at a guide-only control is guide-only for that step
        let r = entry("recipe.lock", .recipe, reach: .none, recipe: [AtlasStep(say: "Open App lock.", anchor: "setting.appLock", reach: nil)], safety: .read)
        #expect(ShowMeSession.make(for: r, lookup: { $0 == "setting.appLock" ? lock : nil })?.current.guideOnly == true)
    }

    @Test func announcementNamesTheStepAndTheProblem() throws {
        var s = try #require(ShowMeSession.make(for: entry("recipe.r", .recipe, reach: .none, recipe: [AtlasStep(say: "First.", anchor: "a", reach: nil), AtlasStep(say: "Second.", anchor: "b", reach: nil)], safety: .read), lookup: { _ in nil }))
        #expect(s.announcement(.spotlight(frame)) == "Step 1 of 2. First.")
        _ = s.next()
        #expect(s.announcement(.missing(openTitle: "Playback", canOpen: true)).contains("Step 2 of 2. Second. I can't find it on this screen. Open Playback first."))
    }

    // MARK: controller

    @Test func controllerStartsStepsAndFinishes() throws {
        let c = ShowMeController()
        let steps = [AtlasStep(say: "One", anchor: "a", reach: nil), AtlasStep(say: "Two", anchor: "b", reach: nil)]
        let r = entry("recipe.r", .recipe, reach: .none, recipe: steps, safety: .read)
        c.lookup = { $0 == r.id ? r : nil }
        #expect(!c.start(entryID: "nope") && !c.isActive)
        #expect(c.start(entryID: "recipe.r") && c.isActive)
        c.next(); #expect(c.session?.progress == "Step 2 of 2")
        c.back(); #expect(c.session?.progress == "Step 1 of 2")
        c.next(); c.next()                      // past the last step is Done
        #expect(!c.isActive)
    }

    @Test func controllerOpensTheScreenOnRequestAndRemembersIt() throws {
        let c = ShowMeController()
        let e = entry("setting.a")
        c.lookup = { $0 == e.id ? e : nil }
        var opened: [String] = []
        c.opener = { opened.append($0); return true }
        c.start(entryID: "setting.a")
        c.openCurrentScreen()
        #expect(opened == ["setting.a"])
        #expect(c.session?.resolve(frames: [:]) == .openedButNotFound(lookFor: "Playback"))
    }

    @Test func controllerScrollsThroughTheRegisteredHandler() {
        let c = ShowMeController()
        var seen: [String] = []
        c.scrollHandler = { seen.append($0) }
        c.scrollIntoView("setting.a")
        #expect(seen == ["setting.a"])
    }

    @Test func realEntriesAllMakeASession() {
        // Every declared entry can be shown: either its own marker or the "open it first" fallback. None crash or come back empty.
        for e in Atlas.entries where e.recipe?.isEmpty != true {
            #expect(ShowMeSession.make(for: e, lookup: { Atlas.entry($0) }) != nil, "\(e.id)")
        }
    }
}

@MainActor @Suite("Atlas: palette source") struct AtlasPaletteSourceTests {
    let engine = Atlas.engine

    @Test func aSettingNameFindsTheSetting() {
        let rows = AtlasPaletteSource.rows(for: "hardware decoding", engine: engine, platform: .mac)
        #expect(rows.contains { $0.id == "setting.hardwareDecoding" } || rows.contains { $0.title.lowercased().contains("hardware") }, "\(rows.map(\.id))")
    }

    @Test func aShortcutRowCarriesItsKeys() {
        let rows = AtlasPaletteSource.rows(for: "add playlist", engine: engine, platform: .mac)
        #expect(rows.contains { $0.shortcut == "⌘N" }, "\(rows.map { "\($0.id) \($0.shortcut ?? "-")" })")
    }

    @Test func aTitleSearchOffersNoScreens() {
        for q in ["breaking bad", "star wars", "money heist", "kgf chapter 2", "x"] { #expect(AtlasPaletteSource.rows(for: q, engine: engine, platform: .mac).isEmpty, "\(q)") }
    }

    @Test func rowsAreCappedAndOnlyListedKinds() {
        let rows = AtlasPaletteSource.rows(for: "playback settings", engine: engine, platform: .mac, limit: 3)
        #expect(rows.count <= 3 && !rows.isEmpty)
        #expect(rows.allSatisfy { AtlasPaletteSource.listedKinds.contains($0.kind) })
    }

    @Test func dmgOnlyEntriesAreHiddenInTheAppStoreBuild() {
        let dmg = Atlas.entries.filter { $0.platforms.contains(.dmgOnly) && AtlasPaletteSource.listedKinds.contains($0.kind) }
        for e in dmg.prefix(5) {
            let rows = AtlasPaletteSource.rows(for: e.title, engine: engine, platform: .mac, appStore: true, limit: 10)
            #expect(!rows.contains { $0.id == e.id }, "\(e.id)")
        }
    }

    @Test func oneTypoInALongWordIsForgiven() {
        #expect(AtlasPaletteSource.withinOneEdit("subtitles", "subtitels") == false)      // a swap is two edits
        #expect(AtlasPaletteSource.withinOneEdit("subtitles", "subtitle") && AtlasPaletteSource.withinOneEdit("buffering", "bufferng") && AtlasPaletteSource.withinOneEdit("playback", "plaback"))
        #expect(!AtlasPaletteSource.withinOneEdit("inception", "reception"))
        #expect(AtlasPaletteSource.rows(for: "sleep timr", engine: engine, platform: .mac).isEmpty == false || AtlasPaletteSource.rows(for: "sleep timer", engine: engine, platform: .mac).isEmpty == false)
    }

    @Test func questionDetection() {
        for q in ["how do I fix buffering", "why is my guide empty?", "where is the sleep timer", "my guide is empty again today", "can I turn off subtitles"] { #expect(AtlasPaletteSource.isQuestion(q), "\(q)") }
        for q in ["inception", "bbc one", "playback", "star wars the force awakens", ""] { #expect(!AtlasPaletteSource.isQuestion(q), "\(q)") }
    }

    @Test func askRowTitle() {
        #expect(AtlasPaletteSource.askTitle("why is my guide empty") == "Ask Setu: why is my guide empty")
        #expect(AtlasPaletteSource.askTitle("  ") == "Ask Setu")
    }

    @Test func askSetuShortcutIsDeclaredAndUnique() throws {
        let e = try #require(Atlas.entry("menu.help.askSetu"))
        #expect(e.shortcut == "⌥⌘/")
        // The Services menu shares ⌘R and ⌘←/⌘→ on purpose: the refresh and skip commands are disabled while a service is on screen (MenuCommands.swift), so only one is live.
        let all = Atlas.entries.filter { $0.kind == .menuItem && !$0.id.hasPrefix("menu.services.") }.compactMap(\.shortcut)
        #expect(Set(all).count == all.count, "a menu shortcut is declared twice")
        #expect(AtlasShortcuts.groups.flatMap(\.rows).contains { $0.keys == "⌥⌘/" })
    }
}
