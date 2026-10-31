import XCTest

/// Saves the pictures for the App Store listing: adds a demo library (openly licensed films and Apple's public test streams, served by a small local server) and
/// opens each main screen. It does nothing unless STREAMSETU_SHOTS names a folder, so a normal test run is not affected:
///   TEST_RUNNER_STREAMSETU_SHOTS=/path/to/folder TEST_RUNNER_STREAMSETU_DEMO=http://localhost:8099 xcodebuild test ... -only-testing:StreamSetuUITests/ListingPicturesTests
final class ListingPicturesTests: XCTestCase {
    func testSaveListingPictures() throws {
        let env = ProcessInfo.processInfo.environment
        let dir = try XCTUnwrap(env["STREAMSETU_SHOTS"].flatMap { $0.isEmpty ? nil : $0 }, "set STREAMSETU_SHOTS to a folder to save the pictures")
        let demo = env["STREAMSETU_DEMO"] ?? "http://localhost:8099"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ipad = UIDevice.current.userInterfaceIdiom == .pad
        let prefix = ipad ? "ipad" : "iphone"
        let app = XCUIApplication()
        app.launch()
        func shot(_ name: String) {
            let png = app.screenshot().pngRepresentation
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-\(name).png"))
        }
        func dismissAlerts() { for label in ["Not Now", "Allow", "OK", "Don’t Allow"] where app.alerts.buttons[label].exists { app.alerts.buttons[label].tap() } }

        // Add the demo library once: a link with a login in it fills the whole form, then Add.
        let alreadyThere = app.staticTexts["Movies"].waitForExistence(timeout: 12) || app.buttons["Movies"].exists
        if !alreadyThere || app.staticTexts["Welcome"].exists {
            if app.buttons["Add a Playlist"].waitForExistence(timeout: 5) { app.buttons["Add a Playlist"].tap() }
            let field = app.textFields["Paste any address"]
            XCTAssertTrue(field.waitForExistence(timeout: 10), "the Add Playlist form did not open\n\(app.debugDescription)")
            field.tap(); field.typeText("\(demo)/get.php?username=demo&password=demo&type=m3u_plus")
            app.buttons["Add"].tap()
            if app.alerts.buttons["Save Anyway"].waitForExistence(timeout: 4) { app.alerts.buttons["Save Anyway"].tap() }
            XCTAssertTrue(app.staticTexts["Movies"].waitForExistence(timeout: 90) || app.buttons["Movies"].waitForExistence(timeout: 5), "the library did not open\n\(app.debugDescription)")
            sleep(6)                                                     // posters and guide arrive
        }
        dismissAlerts()
        // Home has loaded when its rows are on screen; the first picture is taken only then (the splash screen is still up for a moment after launch).
        XCTAssertTrue(app.staticTexts["Trending in Your Library"].waitForExistence(timeout: 30) || app.staticTexts["Top Movies This Week"].waitForExistence(timeout: 5), "Home did not load\n\(app.debugDescription)")
        sleep(4)                                                         // the posters arrive
        shot("1-home")

        // On an iPad the destinations are in the sidebar; on an iPhone, in the tab bar.
        func open(_ name: String) -> Bool {
            let rows = app.staticTexts.matching(identifier: name).allElementsBoundByIndex.filter { $0.exists && ($0.frame.minX < 300 || !ipad) }
            if let r = rows.first { r.tap(); return true }
            if app.buttons[name].exists { app.buttons[name].tap(); return true }
            return false
        }
        // On an iPhone the Guide is a button in the Live TV toolbar, and Settings is inside More.
        func visit(_ name: String) -> Bool {
            if !ipad && name == "Guide" {
                guard open("Live TV") else { return false }
                sleep(2); let g = app.buttons["TV Guide"].firstMatch
                guard g.waitForExistence(timeout: 5) else { return false }
                g.tap(); return true
            }
            if !ipad && name == "Settings" {
                guard app.buttons["More"].waitForExistence(timeout: 5) else { return false }
                app.buttons["More"].tap(); sleep(3); shot("7-more")
                let row = app.staticTexts["Settings"].firstMatch
                guard row.waitForExistence(timeout: 5) else { return false }
                row.tap(); return true
            }
            return open(name)
        }
        for (name, file) in [("Movies", "2-movies"), ("Live TV", "3-livetv"), ("Guide", "4-guide"), ("Series", "5-series"), ("Settings", "9-settings")] {
            if visit(name) { sleep(4); shot(file) } else { XCTFail("\(name) was not found\n\(app.debugDescription)") }
        }
        // A film's page.
        if open("Movies") {
            sleep(3)
            let film = app.staticTexts["Sintel (2010)"].firstMatch
            if film.waitForExistence(timeout: 5) { film.tap(); sleep(4); shot("8-film") }
        }
        // Search last: it leaves the keyboard open, which would cover the pages after it.
        _ = open("Home"); sleep(2)
        if visit("Search") { sleep(4); shot("6-search") } else { XCTFail("Search was not found\n\(app.debugDescription)") }
    }
}
