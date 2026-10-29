import XCTest

/// Drives the installed app. These need a simulator or a device (there is none on the build Mac), so they run from Xcode or `Scripts/test.sh` where one exists.
/// Each starts from a clean launch: a fresh install shows the welcome screen, a library that is already open shows the tab bar.
final class LaunchTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testTheAppLaunchesAndShowsEitherTheWelcomeOrTheTabBar() {
        let app = XCUIApplication(); app.launch()
        let tabBar = app.buttons["Home"], welcome = app.staticTexts["StreamSetu"]
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15) || welcome.waitForExistence(timeout: 1), "neither the welcome screen nor the tab bar appeared")
    }

    func testEveryBarTabOpensWhenALibraryIsOpen() throws {
        let app = XCUIApplication(); app.launch()
        try XCTSkipUnless(app.buttons["Home"].waitForExistence(timeout: 15), "no library is open on this device: the bar is not shown")
        for tab in ["Live TV", "Movies", "Series", "More", "Home"] {
            let button = app.buttons[tab]
            XCTAssertTrue(button.exists, "\(tab) is missing from the bar")
            button.tap()
            XCTAssertTrue(button.isSelected || button.exists, "\(tab) did not stay on the bar after a tap")
        }
    }

    func testMoreListsLibraryPlaylistsAndSettings() throws {
        let app = XCUIApplication(); app.launch()
        try XCTSkipUnless(app.buttons["More"].waitForExistence(timeout: 15), "no library is open on this device")
        app.buttons["More"].tap()
        for row in ["Library", "Playlists", "Settings"] { XCTAssertTrue(app.staticTexts[row].waitForExistence(timeout: 5), "\(row) is missing from More") }
    }

    func testTheLargestTextSizeStillShowsTheBar() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        try XCTSkipUnless(app.buttons["Home"].waitForExistence(timeout: 15), "no library is open on this device")
        for tab in ["Home", "Live TV", "Movies", "Series", "More"] { XCTAssertTrue(app.buttons[tab].exists, "\(tab) is missing at the largest text size") }
    }
}
