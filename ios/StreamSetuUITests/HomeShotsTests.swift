import XCTest

/// Pictures of Home and a title page for looking at (HOME_SHOTS names the folder; without it nothing is saved). The library is the app's own made-up fixture (`--atlas-walk`), never anyone's real one.
@MainActor final class HomeShotsTests: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["HOME_SHOTS"].flatMap { $0.isEmpty ? nil : $0 } }
    private var idiom: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    func testHomeAndTitleShots() throws {
        let dir = try XCTUnwrap(self.dir, "set HOME_SHOTS to a folder")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for dark in [true, false] {
            XCUIDevice.shared.appearance = dark ? .dark : .light
            let app = XCUIApplication()
            app.launchArguments = ["--atlas-walk"]
            app.launchEnvironment["REDDY_DB"] = NSTemporaryDirectory() + "home-shots-\(UUID().uuidString).sqlite"
            app.launch()
            let tag = "\(idiom)-\(dark ? "dark" : "light")"
            func shot(_ s: String) { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(tag)-\(s).png")) }
            XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 60) || app.staticTexts["Home"].waitForExistence(timeout: 5), "Home did not open")
            sleep(6)
            shot("home-1")
            app.swipeUp(); sleep(1); shot("home-2")
            app.swipeUp(); sleep(1); shot("home-3")
            app.swipeUp(); sleep(1); shot("home-4")
            // a title page: through Search, the way a person gets there
            app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown()
            let search = app.buttons["Search"].firstMatch
            if search.waitForExistence(timeout: 5) {
                search.tap()
                let field = app.searchFields.firstMatch
                if field.waitForExistence(timeout: 8) {
                    field.typeText("Walk Film 1")
                    let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Walk Film 1' AND NOT (label BEGINSWITH 'Ask')")).allElementsBoundByIndex.first { $0.exists && $0.isHittable }
                    row?.tap(); sleep(3)
                    shot("title-1")
                    app.swipeUp(); sleep(1); shot("title-2")
                }
            }
            app.terminate()
        }
        XCUIDevice.shared.appearance = .dark
    }
}
