import XCTest

/// A search result opens its page on top of Search, and Back returns to the same results with the query intact.
/// Runs on the app's own fixture library (`--atlas-walk`: no network, films "Walk Film 1"..., series "Walk Show 1"...) in a database of its own, from every place Search can be opened.
/// The first launch after an install puts two things over Home, both by design: the "What's New" page (Continue) once the library has playlists and the version is new, and, 1.5 s later, the "Help fix playback problems?" alert (Not Now). Neither is part of what the tests check, and either swallows taps: answer what is there, then wait until neither is.
func clearFirstRunScreens(_ app: XCUIApplication) {
    let cont = app.buttons["Continue"], notice = app.alerts["Help fix playback problems?"]
    var quietSince: Date?
    let end = Date().addingTimeInterval(20)
    while Date() < end {
        if cont.exists { cont.tap(); quietSince = nil }
        else if notice.exists { notice.buttons["Not Now"].tap(); quietSince = nil }
        else {
            if quietSince == nil { quietSince = Date() }
            if Date().timeIntervalSince(quietSince!) > 3.5 { return }       // the alert comes 1.5 s after the first screen: 3.5 s of nothing means both are done (or never came)
        }
        usleep(250_000)
    }
}

final class SearchNavigationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--atlas-walk"] + extra
        app.launchEnvironment["REDDY_DB"] = NSTemporaryDirectory() + "search-nav-\(UUID().uuidString).sqlite"
        app.launch()
        let ready = app.buttons["Home"].waitForExistence(timeout: 60) || app.staticTexts["Home"].waitForExistence(timeout: 5)
        XCTAssertTrue(ready, "the fixture library did not open\n\(app.debugDescription)")
        clearFirstRunScreens(app)
        return app
    }

    /// A picture of the current screen when STREAMSETU_SNAPS names a folder (for diagnosing a failing step; no effect otherwise).
    private func snap(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["STREAMSETU_SNAPS"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func isPad() -> Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Types in the open search field and returns the result row for `title`.
    private func search(_ app: XCUIApplication, for title: String) -> XCUIElement {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists { field.tap() }
        field.typeText(title)
        snap(app, "typed")
        return resultRow(app, title)
    }

    /// The row on screen for `title`: the screens underneath Search can hold a button with the same name, so only one that can be tapped counts.
    private func resultRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let q = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (label BEGINSWITH %@)", title, "Ask"))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let hit = q.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return hit }
            usleep(300_000)
        }
        XCTFail("no result row for \(title)\n\(app.debugDescription)")
        return q.firstMatch
    }

    private func titlePageIsOnTop(_ app: XCUIApplication, _ entry: String) {
        // The title page shows Play (or its info line); Search's own field must not be on top of it.
        let page = app.buttons["Play"].firstMatch.waitForExistence(timeout: 10) || app.buttons["Play Now"].firstMatch.exists || app.navigationBars.buttons.firstMatch.exists && !app.searchFields.firstMatch.isHittable
        XCTAssertTrue(page, "\(entry): the title page did not open\n\(app.debugDescription)")
        XCTAssertFalse(app.searchFields.firstMatch.isHittable, "\(entry): Search is still on top of the title page\n\(app.debugDescription)")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "\(entry): the keyboard is still up over the title page")
    }

    private func openAndGoBack(_ app: XCUIApplication, from entry: String, title: String = "Walk Film 1") {
        let row = search(app, for: title)
        snap(app, "\(entry)-1-results")
        row.tap()
        sleep(1); snap(app, "\(entry)-2-after-tap")
        titlePageIsOnTop(app, entry)
        // Back returns to the same results with the query intact (a single Back, not two).
        let back = backButton(app)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "\(entry): no Back button\n\(app.debugDescription)")
        back.tap()
        sleep(1); snap(app, "\(entry)-3-after-back")
        let again = resultRow(app, title)
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, title, "\(entry): the query was lost")
        // Open it a second time: the result still works after returning.
        again.tap()
        titlePageIsOnTop(app, entry + " (second time)")
    }

    /// The navigation bar's Back button (on an iPad the first button is the sidebar's).
    private func backButton(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "NOT (label CONTAINS[c] %@) AND NOT (label CONTAINS[c] %@)", "sidebar", "more")).firstMatch
    }

    /// A tab on an iPhone, a sidebar row on an iPad.
    private func tab(_ app: XCUIApplication, _ name: String) {
        if isPad() {
            // The sidebar's own row (a table cell in the left column), tapped until the detail column follows: a tap on its text alone can land while the list is still settling.
            let cell = app.cells.containing(.staticText, identifier: name).allElementsBoundByIndex.first { $0.frame.minX < 300 } ?? app.buttons[name].firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 10), "no sidebar row \(name)\n\(app.debugDescription)")
            cell.tap(); return
        }
        let b = app.buttons[name].firstMatch
        if b.waitForExistence(timeout: 5) { b.tap() } else { app.staticTexts[name].firstMatch.tap() }
    }

    private func openSearchButton(_ app: XCUIApplication) {
        let b = app.buttons["Search"].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 8), "no Search button\n\(app.debugDescription)")
        // Tap only once the button can be hit (the bar's buttons are not tappable while they are folded or covered), and again if the field did not come.
        for _ in 0..<3 {
            let end = Date().addingTimeInterval(10)
            while !b.isHittable && Date() < end { usleep(200_000) }
            b.tap()
            if app.searchFields.firstMatch.waitForExistence(timeout: 4) { return }
        }
    }

    /// The owner's bug, asserted strictly and without sleeps: after a query and a tap on a result the title's own page is on top (it shows its name and Play, a Back button exists, the search field is gone); Back returns to the results with the query intact.
    private func strictTitleOnTopThenBack(_ app: XCUIApplication, from entry: String, title: String = "Walk Film 1") {
        let row = search(app, for: title)
        row.tap()
        // The title page draws its name in the page itself (its navigation bar holds only Back): wait for that name and the Play button, which Search's own rows do not have.
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 15), "\(entry): the title page never opened\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts[title].firstMatch.exists, "\(entry): the title page does not show its name \(title)")
        XCTAssertTrue(backButton(app).waitForExistence(timeout: 5), "\(entry): no Back button on the title page")
        let deadline = Date().addingTimeInterval(10)
        while app.searchFields.firstMatch.exists && Date() < deadline { usleep(200_000) }
        XCTAssertFalse(app.searchFields.firstMatch.exists, "\(entry): the search field is still present over the title page")
        backButton(app).tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "\(entry): Back did not return to Search\n\(app.debugDescription)")
        XCTAssertEqual(field.value as? String, title, "\(entry): the query was lost after Back")
        _ = resultRow(app, title)
        XCTAssertFalse(app.buttons["Play"].firstMatch.exists, "\(entry): the title page is still showing after Back")
    }

    func testStrictHomeTitleOnTopThenBackKeepsQuery() throws {
        try XCTSkipIf(isPad(), "iPhone entry point")
        let app = try launch()
        tab(app, "Home")
        openSearchButton(app)
        strictTitleOnTopThenBack(app, from: "Home")
    }

    func testStrictMoviesTitleOnTopThenBackKeepsQuery() throws {
        try XCTSkipIf(isPad(), "iPhone entry point")
        let app = try launch()
        tab(app, "Movies")
        openSearchButton(app)
        strictTitleOnTopThenBack(app, from: "Movies")
    }

    func testHomeSearchOpensTheTitleAboveSearch() throws {
        try XCTSkipIf(isPad(), "the iPhone's entry point: an iPad opens Search from its sidebar")
        let app = try launch()
        tab(app, "Home")
        openSearchButton(app)
        openAndGoBack(app, from: "Home")
    }

    func testMoviesSearchOpensTheTitleAboveSearch() throws {
        try XCTSkipIf(isPad(), "the iPhone's entry point: an iPad opens Search from its sidebar")
        let app = try launch()
        tab(app, "Movies")
        openSearchButton(app)
        openAndGoBack(app, from: "Movies")
    }

    func testSeriesSearchOpensTheTitleAboveSearch() throws {
        try XCTSkipIf(isPad(), "the iPhone's entry point: an iPad opens Search from its sidebar")
        let app = try launch()
        tab(app, "Series")
        openSearchButton(app)
        openAndGoBack(app, from: "Series", title: "Walk Show 1")
    }

    func testLiveTVSearchOpensAndBackReturns() throws {
        try XCTSkipIf(isPad(), "the iPhone's entry point: an iPad opens Search from its sidebar")
        let app = try launch()
        tab(app, "Live TV")
        openSearchButton(app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.typeText("Walk")
        backButton(app).tap()
        XCTAssertTrue(app.buttons["Search"].firstMatch.waitForExistence(timeout: 8), "Back from Search returns to Live TV\n\(app.debugDescription)")
    }

    /// Search opened by code (a link, Setu, "open search") on an iPhone lands in the More tab's own stack (IOSRouter.moreStack): the result must open on top of it, and Back must return to it.
    func testMoreStackSearchOpensTheTitleAboveSearch() throws {
        try XCTSkipIf(isPad(), "the More tab is the iPhone's")
        let app = try launch(["--atlas-open", "screen.ios.tab.search"])
        openAndGoBack(app, from: "More")
    }

    /// iPad with a sidebar: Search is its own tab with its own stack.
    func testIPadSidebarSearchOpensTheTitleAboveSearch() throws {
        try XCTSkipUnless(isPad(), "iPad only")
        let app = try launch()
        tab(app, "Search")
        openAndGoBack(app, from: "iPad sidebar")
    }
}
