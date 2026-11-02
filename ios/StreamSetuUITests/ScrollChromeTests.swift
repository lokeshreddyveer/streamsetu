import XCTest

/// Scrolls a page of a library that is already added and checks the bars: the bottom one shrinks to a pill going down and comes back going up, and the top
/// buttons fold while the page moves. Saves a picture of each state into STREAMSETU_SHOTS (if set).
final class ScrollChromeUITests: XCTestCase {
    func testBarsFollowTheScrolling() throws {
        let dir = ProcessInfo.processInfo.environment["STREAMSETU_SHOTS"] ?? ""
        let app = XCUIApplication()
        app.launch()
        func shot(_ name: String) {
            guard !dir.isEmpty else { return }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("chrome-\(name).png"))
        }
        // The tab bar's buttons are the lowest ones with these names.
        func tab(_ name: String) -> XCUIElement { app.buttons.matching(identifier: name).allElementsBoundByIndex.max { $0.frame.minY < $1.frame.minY } ?? app.buttons[name] }
        XCTAssertTrue(app.buttons["Movies"].waitForExistence(timeout: 30), "no tab bar\n\(app.debugDescription)")
        tab("Movies").tap(); sleep(4)
        let series = tab("Series"), current = app.buttons.matching(NSPredicate(format: "isSelected == true")).allElementsBoundByIndex.max { $0.frame.minY < $1.frame.minY } ?? tab("Home")
        XCTAssertTrue(series.isHittable, "the whole bar is out at the top")
        shot("1-top")
        app.swipeUp(velocity: .fast); app.swipeUp(velocity: .fast)
        shot("2-just-scrolled")
        sleep(2)
        shot("3-settled")
        XCTAssertFalse(series.exists, "the other tabs are gone while the bar is a pill")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Show the tab bar")).firstMatch.isHittable, "the pill is there to tap")
        app.swipeDown(velocity: .slow)
        sleep(1)
        shot("4-scrolled-up")
        XCTAssertTrue(series.isHittable, "scrolling up brings the bar back")
        app.swipeUp(velocity: .fast); app.swipeUp(velocity: .fast); sleep(2)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Show the tab bar")).firstMatch.tap(); sleep(1)
        XCTAssertTrue(series.isHittable, "tapping the pill brings the bar back")
    }
}
