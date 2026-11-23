import XCTest

/// Gate (c): walks the screens the Atlas declares for this device and checks that what it declares is really on screen.
///
/// The app is started with `--atlas-walk` (a debug-only hook: a fixed small library, and an invisible probe element for every marker) and writes the Atlas plan for this device.
/// For each screen that can be reached by a route, the walk opens it, checks that the screen's own marker (`atlas.screen:<id>`) is on screen, scrolls through it,
/// and compares the markers it finds (`atlas:<id>`) with what the Atlas declares:
///   - declared but missing: the Atlas lists a control under that screen, the source marks it, and it is not on the screen
///   - marked but undeclared: a marker names an id the Atlas does not have
///   - screen missing: the route was followed and the screen's marker never appeared
/// New drift fails the test. Drift already known is listed in atlas-walk-known.json next to this file (and reported, not failed), so the gate stops new problems without hiding old ones.
/// Screens that need state a fixture cannot give (a playing stream, a title page, a lock) are listed as "not walkable" with the reason, never silently skipped.
/// Run: Scripts/check-atlas-walk.sh (iPhone and iPad simulators). The report is written to /tmp/streamsetu-atlas-walk/.
@MainActor final class AtlasWalkTests: XCTestCase {
    static let dir = "/tmp/streamsetu-atlas-walk"
    struct Child: Codable { var id: String; var kind: String; var title: String }
    struct Screen: Codable { var id: String; var kind: String; var title: String; var path: [String]; var reach: String; var children: [Child] }
    struct Plan: Codable { var platform: String; var screens: [Screen]; var entries: [Child] }

    override func setUpWithError() throws { continueAfterFailure = true }

    override func tearDown() {
        if let run = testRun, !run.hasSucceeded {          // a picture of wherever the failing step left the app
            let a = XCTAttachment(screenshot: XCUIApplication().screenshot()); a.name = "failure"; a.lifetime = .keepAlways; add(a)
        }
    }

    func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--atlas-walk"] + extra
        app.launchEnvironment["REDDY_DB"] = Self.dir + "/walk.sqlite"
        app.launch()
        return app
    }

    /// The ids of every marker on screen, read from one snapshot of the accessibility tree (asking element by element is far too slow).
    func probes(_ app: XCUIApplication) -> Set<String> {
        var out = Set<String>()
        func walk(_ n: XCUIElementSnapshot) {
            if n.identifier.hasPrefix("atlas") { out.insert(n.identifier) }
            for c in n.children { walk(c) }
        }
        if let snap = try? app.snapshot() { walk(snap) }
        return out
    }

    /// Everything the screen shows, scrolled from top to bottom (lists draw only the rows on screen).
    private func scrollAndCollect(_ app: XCUIApplication) -> Set<String> {
        var seen = probes(app), still = 0
        for _ in 0..<14 {
            app.swipeUp(velocity: .fast)
            let now = probes(app)
            if now.isSubset(of: seen) { still += 1; if still >= 2 { break } } else { still = 0 }
            seen.formUnion(now)
        }
        return seen
    }

    /// Where a screen is reached from: a launch argument that opens it, or taps on the Settings list.
    enum Route { case open, settingsRow(String), libraryRow(String), playlistRow(String), notWalkable(String) }
    func route(_ s: Screen) -> Route {
        if s.id == "screen.ios.settings.playlistDetail" { return .playlistRow("Walk Playlist") }          // the fixture's one playlist, opened from the Playlists tab
        if s.reach.hasPrefix("tab(") || s.reach.hasPrefix("modal(\"ios.addPlaylist") || s.reach.hasPrefix("modal(\"ios.multiView") { return .open }
        if s.path.count == 2, s.path[0] == "Library", s.id.hasPrefix("screen.ios.") { return .libraryRow(s.title) }
        if s.reach.hasPrefix("settingsPage("), s.id.hasPrefix("screen.ios.settings."), s.path.first == "Library", s.path.count == 3 { return .settingsRow(s.title) }
        if s.reach.hasPrefix("modal(") { return .notWalkable("needs a playing stream or a chosen title") }
        return .notWalkable("no route reaches it from a fixture library (reach: \(s.reach))")
    }

    enum Opened { case opened(XCUIApplication), notWalkable(String), missing(String) }
    /// Launches the app on the screen: by launch argument for tabs and sheets, by tapping rows for pages under Library, Settings and Playlists.
    func openScreen(_ s: Screen) -> Opened {
        func tapRow(_ opening: String, _ title: String, where place: String) -> Opened {
            let app = launch(["--atlas-open", opening])
            let row = app.staticTexts[title].firstMatch
            // A long list draws only the rows near the screen: scroll until the row has been drawn (the last rows, About, App DNS and VPN, are below the first screenful).
            var found = row.waitForExistence(timeout: 8), scrolls = 0
            while !found, scrolls < 8 { app.swipeUp(); scrolls += 1; found = row.waitForExistence(timeout: 1) }
            if !found { return .missing("no row \"\(title)\" in \(place)") }
            // Scroll until the row is clear of the floating tab bar, then tap it.
            var tries = 0
            while tries < 8, row.frame.maxY > app.frame.height - 130 || row.frame.minY < 0 { app.swipeUp(); tries += 1 }
            row.tap()
            return .opened(app)
        }
        switch route(s) {
        case .notWalkable(let why): return .notWalkable(why)
        case .open: return .opened(launch(["--atlas-open", s.id]))
        case .playlistRow(let title): return tapRow("screen.ios.tab.playlists", title, where: "Playlists")
        case .libraryRow(let title): return tapRow("screen.ios.tab.library", title, where: "Library")
        case .settingsRow(let title): return tapRow("screen.ios.tab.settings", title, where: "Settings")
        }
    }

    func readPlan() throws -> Plan {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let planPath = Self.dir + "/plan-\(idiom).json"
        try? fm.removeItem(atPath: planPath)
        let first = launch(["--atlas-plan", planPath])
        XCTAssertTrue(first.buttons["Home"].waitForExistence(timeout: 30) || first.staticTexts["Home"].exists, "the fixture library did not open")
        let deadline = Date().addingTimeInterval(20)
        while !fm.fileExists(atPath: planPath), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        return try JSONDecoder().decode(Plan.self, from: try Data(contentsOf: URL(fileURLWithPath: planPath)))
    }

    func testWalk() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STREAMSETU_WALK"] != nil, "slow (10+ min on a simulator): run it with TEST_RUNNER_STREAMSETU_WALK=1; see qa/ios-buttons-iphone.md")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let planPath = Self.dir + "/plan-\(idiom).json"
        try? fm.removeItem(atPath: planPath)
        let drop = ProcessInfo.processInfo.environment["ATLAS_WALK_DROP"] ?? ""          // set by `check-atlas-walk.sh --prove <id>`: that declaration is left out, and the walk must say so
        let first = launch(["--atlas-plan", planPath] + (drop.isEmpty ? [] : ["--atlas-drop-declaration", drop]))
        XCTAssertTrue(first.buttons["Home"].waitForExistence(timeout: 30) || first.staticTexts["Home"].exists, "the fixture library did not open")
        let deadline = Date().addingTimeInterval(20)
        while !fm.fileExists(atPath: planPath), Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        let plan = try JSONDecoder().decode(Plan.self, from: try Data(contentsOf: URL(fileURLWithPath: planPath)))
        let declared = Set(plan.entries.map(\.id))
        let marked: Set<String>? = (try? String(contentsOfFile: Self.dir + "/marked.txt", encoding: .utf8)).map { Set($0.split(separator: "\n").map(String.init)) }
        let known: Set<String> = {
            guard let d = fm.contents(atPath: (#filePath as NSString).deletingLastPathComponent + "/atlas-walk-known.json"),
                  let j = try? JSONDecoder().decode([String: [String]].self, from: d) else { return [] }
            return Set(j[idiom] ?? [])
        }()
        // Declared controls the walk cannot see for a stated reason (a menu item, an error state, content the fixture does not have). Each needs its reason; one that is seen anyway is reported so it can be removed.
        let exempt: [String: String] = {
            guard let d = fm.contents(atPath: (#filePath as NSString).deletingLastPathComponent + "/atlas-walk-exempt.json"),
                  let j = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
            return j
        }()
        var exemptSeen: [String] = []
        var drift: [String] = [], notWalkable: [String] = [], walked = 0, declaredChildren = 0, foundChildren = 0
        var everySeen = Set<String>(), seenLines: [String] = []

        for s in plan.screens {
            let app: XCUIApplication
            switch openScreen(s) {
            case .notWalkable(let why): notWalkable.append("\(s.id): \(why)"); continue
            case .missing(let why): drift.append("screen missing: \(s.id) (\(why))"); continue
            case .opened(let a): app = a
            }
            walked += 1
            var onScreen = false
            for _ in 0..<20 where !onScreen { onScreen = probes(app).contains("atlas.screen:\(s.id)"); if !onScreen { Thread.sleep(forTimeInterval: 0.5) } }
            if !onScreen { drift.append("screen missing: \(s.id) (\(s.title))"); continue }
            let seen = scrollAndCollect(app)
            everySeen.formUnion(seen)
            seenLines.append("\(s.id): " + seen.sorted().joined(separator: " "))
            for c in s.children {
                declaredChildren += 1
                if seen.contains("atlas:" + c.id) { foundChildren += 1; if exempt[c.id] != nil { exemptSeen.append(c.id) } }
                else if exempt[c.id] != nil { continue }
                else if marked?.contains(c.id) ?? false { drift.append("declared but missing: \(c.id) on \(s.id)") }
            }
            for p in seen where p.hasPrefix("atlas:") && !declared.contains(String(p.dropFirst(6))) { drift.append("marked but undeclared: \(p.dropFirst(6))") }          // one line per id, however many screens show it
            for p in seen where p.hasPrefix("atlas.screen:") && !declared.contains(String(p.dropFirst(13))) { drift.append("marked but undeclared: \(p.dropFirst(13))") }
            app.terminate()
        }

        let unmarked = plan.screens.flatMap(\.children).filter { !(marked?.contains($0.id) ?? true) }.count
        let newDrift = Set(drift).subtracting(known).sorted(), oldDrift = Set(drift).intersection(known).sorted()
        let stale = known.subtracting(drift)
        var report = "atlas-walk \(plan.platform): \(plan.screens.count) declared screens, \(walked) walked, \(notWalkable.count) not walkable; \(foundChildren)/\(declaredChildren) declared controls found; \(unmarked) declared controls not marked in source (informational)\n"
        report += "NEW DRIFT (\(newDrift.count)):\n" + newDrift.map { "  " + $0 }.joined(separator: "\n") + "\n"
        report += "KNOWN DRIFT (\(oldDrift.count)):\n" + oldDrift.map { "  " + $0 }.joined(separator: "\n") + "\n"
        report += "KNOWN BUT GONE (remove from atlas-walk-known.json) (\(stale.count)):\n" + stale.sorted().map { "  " + $0 }.joined(separator: "\n") + "\n"
        report += "EXEMPT BUT SEEN (remove from atlas-walk-exempt.json) (\(exemptSeen.count)):\n" + exemptSeen.map { "  " + $0 }.joined(separator: "\n") + "\n"
        report += "EXEMPT (\(exempt.count)): each has a reason in atlas-walk-exempt.json\n"
        report += "SEEN PER SCREEN:\n" + seenLines.map { "  " + $0 }.joined(separator: "\n") + "\n"
        report += "NOT WALKABLE (\(notWalkable.count)):\n" + notWalkable.map { "  " + $0 }.joined(separator: "\n") + "\n"
        try? report.write(toFile: Self.dir + "/report-\(idiom).txt", atomically: true, encoding: .utf8)
        try? JSONEncoder().encode(drift.sorted()).write(to: URL(fileURLWithPath: Self.dir + "/drift-\(idiom).json"))
        print(report)
        XCTAssertTrue(newDrift.isEmpty, "new Atlas drift:\n" + newDrift.joined(separator: "\n"))
        XCTAssertGreaterThan(walked, 5, "the walk reached almost nothing")
    }
}
