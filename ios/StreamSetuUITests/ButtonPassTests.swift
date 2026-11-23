import XCTest

/// "Press every button": opens every screen the walk reaches (AtlasWalkTests.openScreen) and taps each enabled button on it that does not change or remove anything.
/// The app must not stop, hang over 5 s, go blank or stack a second sheet, and whatever opened must close again (Back, or a sheet's own Close). Controls that are not tapped are listed with the reason.
/// The log goes to the QA folder (see `qa`), one file per device kind. Run through `-only-testing:StreamSetuUITests/AtlasWalkTests/testPressEveryButton`.
extension AtlasWalkTests {
    /// Not tapped by the pass: they change, remove or spend something. The word that matched is written next to the control in the log.
    static let notTapped = try! NSRegularExpression(pattern: "delete|remove|reset|clear|erase|sign out|log out|logout|lock|purchase|buy|subscribe|restore|forget|disconnect|cancel reminder|start fresh|repair|quit|stop|wipe|empty", options: .caseInsensitive)
    static let qa = "/private/tmp/claude-501/-Users-lokeshreddyveerabhadra-Desktop/15e886d1-784e-4b4a-ac5f-1b6e16917e13/scratchpad/qa"

    private var kind: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    func testPressEveryButton() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STREAMSETU_WALK"] != nil, "slow harness pass, not a confirmed app bug: run it with TEST_RUNNER_STREAMSETU_WALK=1; see qa/ios-buttons-iphone.md")
        let plan = try readPlan()
        try? FileManager.default.createDirectory(atPath: Self.qa, withIntermediateDirectories: true)
        var log = ["## \(kind) (\(plan.platform))", "", "| screen | control | result | note |", "|---|---|---|---|"]
        var problems: [String] = []
        func row(_ screen: String, _ control: String, _ result: String, _ note: String = "") {
            log.append("| \(screen) | \(control.replacingOccurrences(of: "|", with: "/")) | \(result) | \(note) |")
        }

        for s in plan.screens {
            var app: XCUIApplication
            switch openScreen(s) {
            case .notWalkable(let why): row(s.id, "-", "not reached", why); continue
            case .missing(let why): row(s.id, "-", "not reached", why); continue
            case .opened(let a): app = a
            }
            guard waitFor(app, "atlas.screen:\(s.id)", 10) else { row(s.id, "-", "not reached", "screen marker never appeared"); continue }
            var offscreen = 0
            var targets: [String] = []
            for b in buttonNames(app) where !targets.contains(b) { targets.append(b) }
            // Buttons that leave the screen (Back, named after the page before it, Close, Done, Cancel) go last: tapping them ends the visit.
            let leaving: Set<String> = ["Back", "Settings", "Library", "Playlists", "More", "Close", "Done", "Cancel", "Home", "Search"]
            targets = targets.filter { !leaving.contains($0) } + targets.filter { leaving.contains($0) }
            for name in targets.prefix(30) {
                if let why = Self.reasonNotTapped(name) { row(s.id, name, "not tapped", why); continue }
                let b = app.buttons[name].firstMatch
                guard canTap(b, app) else { offscreen += 1; continue }          // another tab's content, or scrolled out of sight
                let t0 = Date()
                b.tap()
                let took = Date().timeIntervalSince(t0)
                var note = ""
                if app.state != .runningForeground { problems.append("\(s.id): \(name): the app is no longer running"); row(s.id, name, "CRASH", ""); break }
                if took > 5 { note += "tap took \(String(format: "%.1f", took)) s; "; problems.append("\(s.id): \(name): hang \(String(format: "%.1f", took)) s") }
                settle(app)
                if app.sheets.count + app.popovers.count > 1 { note += "more than one sheet; "; problems.append("\(s.id): \(name): duplicate sheets") }
                if probes(app).isEmpty && app.buttons.count < 2 { note += "blank screen; "; problems.append("\(s.id): \(name): blank screen") }
                let opened = !probes(app).contains("atlas.screen:\(s.id)")
                if opened, leaving.contains(name) { row(s.id, name, "ok (leaves the screen, as it should)"); break }
                var closed = true
                if opened { closed = dismissTop(app, returningTo: s.id) }
                if !closed { note += "could not get back; "; problems.append("\(s.id): \(name): could not get back") }
                row(s.id, name, note.isEmpty ? (opened ? "ok (opened, closed again)" : "ok") : "PROBLEM", note)
                if !closed {          // start this screen again and carry on with the next control
                    switch openScreen(s) { case .opened(let a): app = a; if !waitFor(app, "atlas.screen:\(s.id)", 10) { break }; default: break }
                }
            }
            if offscreen > 0 { row(s.id, "(\(offscreen) others)", "not tapped", "not on screen (another tab's content or scrolled out of sight)") }
            app.terminate()
        }
        try? (log.joined(separator: "\n") + "\n").write(toFile: Self.qa + "/ios-buttons-\(kind).md", atomically: true, encoding: .utf8)
        XCTAssertTrue(problems.isEmpty, "button pass problems:\n" + problems.joined(separator: "\n"))
    }

    /// Search, a result, its title page, the title page's own buttons, and Back.
    func testSearchResultTitleBack() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STREAMSETU_WALK"] != nil, "covered by SearchNavigationTests (every entry point); this older walk variant is skipped: see qa/ios-buttons-iphone.md")
        let app = launch(["--atlas-open", "screen.ios.tab.search"])
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field")
        field.tap(); field.typeText("Walk Film 1")
        let hit = app.staticTexts["Walk Film 1"].firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 15), "no result for Walk Film 1")
        hit.tap()
        XCTAssertTrue(waitFor(app, "atlas.screen:screen.ios.detail", 15), "the title page did not open")
        var rows: [String] = []
        for name in buttonNames(app).prefix(20) {
            if let why = Self.reasonNotTapped(name) { rows.append("not tapped: \(name) (\(why))"); continue }
            let b = app.buttons[name].firstMatch
            guard canTap(b, app) else { continue }
            b.tap(); settle(app)
            XCTAssertEqual(app.state, .runningForeground, "the app stopped after \(name)")
            if !probes(app).contains("atlas.screen:screen.ios.detail") { dismissTop(app, returningTo: "screen.ios.detail") }
            rows.append("tapped: \(name)")
        }
        try? FileManager.default.createDirectory(atPath: Self.qa, withIntermediateDirectories: true)
        try? ("## Title page buttons (\(kind))\n\n" + rows.map { "- " + $0 }.joined(separator: "\n") + "\n").write(toFile: Self.qa + "/ios-title-page-\(kind).md", atomically: true, encoding: .utf8)
        // Back from the title page returns to the search results.
        // (an iPad's first navigation button is the sidebar's; the Back button is the one that is not)
        let back = app.navigationBars.buttons.matching(NSPredicate(format: "NOT (label CONTAINS[c] %@)", "sidebar")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no Back button on the title page\n\(app.debugDescription)")
        back.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "Back did not return to Search\n\(app.debugDescription)")
    }

    // MARK: helpers

    /// Whether a button can be tapped now. Asking `isHittable` of a button that is half off the screen (a poster in a row) makes XCTest fail the test instead of answering, so the button's middle must be on screen first.
    func canTap(_ b: XCUIElement, _ app: XCUIApplication) -> Bool {
        guard b.exists, b.isEnabled else { return false }
        let f = b.frame, w = app.windows.firstMatch.frame
        guard !f.isEmpty, !f.isInfinite, !f.isNull, w.contains(CGPoint(x: f.midX, y: f.midY)) else { return false }
        return b.isHittable
    }

    static func reasonNotTapped(_ name: String) -> String? {
        guard let m = notTapped.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
        return "changes or removes something (matched \"\((name as NSString).substring(with: m.range))\")"
    }

    func waitFor(_ app: XCUIApplication, _ probe: String, _ timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if probes(app).contains(probe) { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        return probes(app).contains(probe)
    }

    /// Lets an animation finish: polls the tree until its size stops changing (at most 2 s).
    func settle(_ app: XCUIApplication) {
        var last = -1, same = 0
        let end = Date().addingTimeInterval(2)
        while same < 2, Date() < end {
            let n = app.descendants(matching: .any).count
            same = (n == last) ? same + 1 : 0; last = n
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    /// The buttons on the current screen (label, else identifier), without the tab bar, the Setu button and Back.
    func buttonNames(_ app: XCUIApplication) -> [String] {
        var out: [String] = []
        func walk(_ n: XCUIElementSnapshot) {
            if n.elementType == .button, n.isEnabled, !n.frame.isEmpty {
                let name = n.label.isEmpty ? n.identifier : n.label
                if !name.isEmpty, !name.hasPrefix("atlas"), !n.identifier.hasPrefix("tab."), n.identifier != "setu.open", name != "Back" { out.append(name) }
            }
            for c in n.children { walk(c) }
        }
        if let snap = try? app.snapshot() { walk(snap) }
        return out
    }

    /// Closes the topmost sheet, alert or pushed page: an alert's safe button, a sheet's Close/Done/Cancel, or Back. True when the screen is showing again.
    @discardableResult
    func dismissTop(_ app: XCUIApplication, returningTo id: String) -> Bool {
        for _ in 0..<4 {
            if probes(app).contains("atlas.screen:\(id)") { return true }
            if app.alerts.count > 0 {
                let alert = app.alerts.firstMatch
                if let n = ["Cancel", "Not Now", "OK", "Done", "Close"].first(where: { alert.buttons[$0].exists }) { alert.buttons[n].tap() } else { alert.buttons.firstMatch.tap() }
                settle(app); continue
            }
            if let n = ["Close", "Done", "Cancel", "Dismiss", "Not Now"].first(where: { app.buttons[$0].firstMatch.exists && app.buttons[$0].firstMatch.isHittable }) { app.buttons[n].firstMatch.tap(); settle(app); continue }
            let back = app.navigationBars.buttons.firstMatch
            if back.exists, back.isHittable { back.tap(); settle(app); continue }
            let region = app.otherElements["PopoverDismissRegion"].firstMatch          // an open menu or popover: a tap outside closes it
            if region.exists { region.tap(); settle(app); continue }
            if app.sheets.count > 0 { app.swipeDown(); settle(app); continue }
            break
        }
        return probes(app).contains("atlas.screen:\(id)")
    }
}
