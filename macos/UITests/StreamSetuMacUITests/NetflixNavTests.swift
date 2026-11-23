import XCTest

/// The Netflix destination in the one-row top bar. WRITTEN, NOT EXECUTED: these click at screen level, so they run only through
/// UITests/run-mac-uitests.sh against the throwaway copy of the app (bundle id app.streamsetu.mac.uitest), never against an installed app.
/// The web view is pointed at a page on 127.0.0.1 (STREAMSETU_UITEST_NETFLIX_URL); the real site is never contacted. They skip when it is not set.
final class NetflixNavTests: MacUITestCase {
    override var extraEnvironment: [String: String] {
        guard let u = Self.env["STREAMSETU_UITEST_NETFLIX_URL"] else { return [:] }
        return ["STREAMSETU_NETFLIX_TEST_URL": u]
    }

    override func setUpWithError() throws {
        guard Self.env["STREAMSETU_UITEST_NETFLIX_URL"] != nil else { throw XCTSkip("STREAMSETU_UITEST_NETFLIX_URL (a http://127.0.0.1 page) is not set") }
        try super.setUpWithError()
    }

    private func selected(_ e: XCUIElement) -> Bool { e.isSelected }

    func testOneRowCollapsesToStreamSetuAndBack() {
        for t in ["Home", "Live TV", "Movies", "Series", "TV Guide", "Netflix"] { need(tab(t), "tab \(t)") }
        openTab("Movies")
        tab("Netflix").click()
        need(tab("StreamSetu"), "collapsed StreamSetu item")
        gone(tab("Home"), "Home hidden while Netflix shows"); gone(tab("Series"), "Series hidden")
        XCTAssertTrue(selected(tab("Netflix")), "Netflix is the selected item")
        XCTAssertFalse(selected(tab("StreamSetu")), "the collapsed item is a destination, not selected")
        need(byID("netflix.web"), "web view")
        tab("StreamSetu").click()
        need(tab("Home"), "tabs return")
        XCTAssertTrue(selected(tab("Movies")), "the last native section (Movies) is selected again")
        gone(byID("netflix.web"), "web view hidden")
    }

    func testKeyboardShortcutsAndRepeatedSwitching() {
        // Cmd-6 opens the Services list in the top row (it never opens a particular service); Cmd-0 leaves a service for StreamSetu.
        for _ in 0..<5 {
            tab("Netflix").click(); need(tab("StreamSetu"), "collapsed after opening Netflix from the bar")
            app.typeKey("0", modifierFlags: .command); need(tab("Home"), "expanded after Cmd-0")
        }
        app.typeKey("6", modifierFlags: .command)
        gone(byID("netflix.web"), "Cmd-6 only opens the Services list, not a service")
        app.typeKey(.escape, modifierFlags: [])
        tab("Netflix").click()
        app.typeKey("2", modifierFlags: .command)          // a native tab also leaves Netflix
        need(tab("Home"), "Cmd-2 returns to the native tabs"); XCTAssertTrue(selected(tab("Live TV")))
    }

    func testAlwaysAvailableBrowserActionAndSingleRow() {
        tab("Netflix").click()
        need(byID("netflix.openBrowser"), "Having trouble? Open in Default Browser")
        // one row: every item of the bar has the same vertical position
        let ys = ["StreamSetu", "Netflix"].map { tab($0).frame.midY }
        XCTAssertEqual(ys[0], ys[1], accuracy: 1)
        assertAlive("Netflix shown")
    }

    func testSearchAndProfileMenuStillWorkWhileNetflixShows() {
        tab("Netflix").click()
        need(byID("search.field"), "search field")
        need(button("Account menu"), "account menu").click()
        assertAlive("account menu over the web view")
    }
}
