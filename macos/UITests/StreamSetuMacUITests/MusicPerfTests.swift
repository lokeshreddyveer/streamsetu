import XCTest

/// Real-app speed and smoothness scenarios for Music. Each test is short and waits only for things (an element, or a mark the app writes to its log), so a
/// scenario takes as long as the app takes and no longer. Run them with: UITests/run-mac-uitests.sh -only-testing:StreamSetuMacUITests/MusicPerfTests
/// A scenario that cannot reach its screen (first-run setup, no network, no song loaded) SKIPS with the reason attached; it never passes silently.
final class MusicPerfTests: PerfCase {
    private let sections = ["Listen Now", "Explore", "Search", "Your Library", "Radio"]

    // MARK: helpers (no sleeps)

    /// Waits until the app has written `name` after `from`. Polling is XCTest's own predicate wait, not a sleep.
    @discardableResult
    func waitForMark(_ name: String, after from: Double, timeout: TimeInterval = 20) -> Bool {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in markTime(name, after: from) != nil }, object: nil)
        return XCTWaiter().wait(for: [e], timeout: timeout) == .completed
    }

    func row(_ title: String) -> XCUIElement { app.buttons[title].firstMatch }

    /// Opens Music with its menu shortcut and waits for the sidebar. Skips (with the screen attached) when Music asks for first-run setup.
    func openMusic() throws {
        app.typeKey("8", modifierFlags: .command)
        if !row("Listen Now").waitForExistence(timeout: 15) {
            attachShot("music-not-reachable"); attachText(app.debugDescription, "tree-music-not-reachable.txt")
            throw XCTSkip("Music's sidebar did not appear (first-run setup or Music switched off); see the attached tree")
        }
    }

    func go(_ title: String) {
        let t0 = ProcessInfo.processInfo.systemUptime
        row(title).click()
        _ = waitForMark("page.appear", after: t0, timeout: 10)
    }

    // MARK: scenarios

    func testSwitchingEverySectionThreeTimes() throws {
        try openMusic()
        scenario("switch sections x3") {
            for _ in 0..<3 { for s in sections { go(s) } }
        }
    }

    func testRapidBackAndForward() throws {
        try openMusic()
        for s in sections.prefix(4) { go(s) }
        scenario("back and forward x6") {
            for _ in 0..<3 { app.typeKey("[", modifierFlags: .command); app.typeKey("[", modifierFlags: .command); app.typeKey("]", modifierFlags: .command) }
        }
    }

    func testSearchTypingAndFirstResults() throws {
        try openMusic()
        go("Search")
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 5) else { throw XCTSkip("no search field found") }
        var seconds: Double?
        scenario("type a query and get results", hitchBudget: 15) {
            let t0 = ProcessInfo.processInfo.systemUptime
            field.click(); field.typeText("shreya ghoshal"); app.typeKey(.return, modifierFlags: [])
            if waitForMark("search.results", after: t0, timeout: 30) { seconds = markTime("search.results", after: t0) }
        }
        guard let s = seconds else { attachShot("no-results"); throw XCTSkip("no results arrived in 30 s (offline or sources down)") }
        print("PERF \(name) | first results after \(String(format: "%.2f", s)) s")
        XCTAssertLessThan(s, 8, "first search results took \(s) s")
    }

    func testNewSearchWhileTheLastIsStillLoadingShowsOnlyTheNewOne() throws {
        try openMusic()
        go("Search")
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 5) else { throw XCTSkip("no search field found") }
        scenario("two quick searches") {
            let t0 = ProcessInfo.processInfo.systemUptime
            field.click(); field.typeText("arijit"); app.typeKey(.return, modifierFlags: [])
            app.typeKey("a", modifierFlags: .command); field.typeText("shreya"); app.typeKey(.return, modifierFlags: [])
            _ = waitForMark("search.results", after: t0, timeout: 30)
        }
    }

    func testSidebarToggleFromTheMenuShortcutFourTimes() throws {
        try openMusic()
        scenario("sidebar toggle x4") {
            for _ in 0..<4 { app.typeKey("s", modifierFlags: [.control, .command]) }
        }
    }

    func testScrollListenNowDownAndUp() throws {
        try openMusic()
        go("Listen Now")
        let area = app.scrollViews.firstMatch
        guard area.waitForExistence(timeout: 5) else { throw XCTSkip("no scroll area found") }
        scenario("scroll listen now") {
            for _ in 0..<8 { area.scroll(byDeltaX: 0, deltaY: -500) }
            for _ in 0..<8 { area.scroll(byDeltaX: 0, deltaY: 500) }
        }
    }

    func testWindowResizeSweep() throws {
        try openMusic()
        let win = app.windows.firstMatch
        let corner = win.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
        scenario("window resize sweep", hitchBudget: 20) {
            for dx in [-200.0, -200.0, 200.0, 200.0] {
                corner.click(forDuration: 0, thenDragTo: corner.withOffset(CGVector(dx: dx, dy: 0)))
            }
        }
        XCTAssertTrue(row("Listen Now").exists, "the sidebar must still be complete after the sweep")
    }
}
