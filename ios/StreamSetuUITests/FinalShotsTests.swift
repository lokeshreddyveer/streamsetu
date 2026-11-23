import XCTest

/// Pictures for the last look before a build (FINAL_SHOTS names the folder; without it nothing runs): Home, a film page, a series page, Setu's answer card, and Settings > About > Credits at the normal and the largest text size, light and dark. The library is the app's own made-up fixture (`--atlas-walk`).
@MainActor final class FinalShotsTests: XCTestCase {
    private var app = XCUIApplication()
    private var dir = ""
    private var theme = "Cinematic"

    override func setUpWithError() throws {
        continueAfterFailure = false
        let d = ProcessInfo.processInfo.environment["FINAL_SHOTS"] ?? ""
        try XCTSkipIf(d.isEmpty, "set FINAL_SHOTS to a folder")
        dir = d
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        // The iPhone app is dark in every system appearance (preferredColorScheme(.dark)); its two looks here are two of its own themes.
        app.launchArguments = ["--atlas-walk", "-settings.theme", theme] + extra
        app.launchEnvironment["REDDY_DB"] = NSTemporaryDirectory() + "final-shots-\(UUID().uuidString).sqlite"
        app.launch()
        _ = app.buttons["Home"].waitForExistence(timeout: 60)
        clearFirstRunScreens(app)
    }
    private func shot(_ tag: String, _ name: String) { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(tag)-\(name).png")) }
    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func openTitle(_ title: String) -> Bool {
        guard app.buttons["Search"].firstMatch.waitForExistence(timeout: 20) else { return false }
        app.buttons["Search"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        guard field.waitForExistence(timeout: 10) else { return false }
        field.typeText(title)
        let q = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (label BEGINSWITH %@)", title, "Ask"))
        let end = Date().addingTimeInterval(20)
        while Date() < end {
            if let hit = q.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { hit.tap(); break }
            usleep(300_000)
        }
        return app.buttons["Play"].firstMatch.waitForExistence(timeout: 15)
    }

    func testFinalShots() throws {
        for t in ["Cinematic", "Graphite"] {
            theme = t
            let tag = t.lowercased()
            // Home, a film page and a series page
            launch()
            XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 60), "Home did not open")
            XCTAssertTrue(app.staticTexts["This Week's Top Picks"].waitForExistence(timeout: 20))
            sleep(3); shot(tag, "1-home")
            XCTAssertTrue(openTitle("Walk Film 1"), "film page")
            sleep(2); shot(tag, "2-film")
            app.swipeUp(); sleep(1); shot(tag, "2-film-b")
            app.terminate()
            launch()
            XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 60))
            XCTAssertTrue(openTitle("Walk Show 1"), "series page")
            sleep(2); shot(tag, "3-series")
            app.terminate()
            // Setu answer card
            launch(["--atlas-open", "screen.ios.tab.settings"])
            let open = el("setu.open")
            XCTAssertTrue(open.waitForExistence(timeout: 30), "Setu button")
            open.tap()
            let field = el("setu.field")
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap(); field.typeText("how do I turn on play the next episode automatically\n")
            XCTAssertTrue(el("setu.showMe").waitForExistence(timeout: 30), "answer card")
            sleep(1); shot(tag, "4-setu")
            app.terminate()
            // Settings > About > Credits, normal and largest text
            for big in [false, true] {
                launch(["--atlas-open", "screen.ios.tab.settings"] + (big ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []))
                let about = el("settings.row.about")
                var n = 0
                while !about.isHittable && n < 8 { app.swipeUp(); n += 1 }
                XCTAssertTrue(about.waitForExistence(timeout: 30), "About row")
                about.tap()
                let credits = app.staticTexts["Credits"].firstMatch
                n = 0
                while !credits.isHittable && n < 10 { app.swipeUp(); n += 1 }
                XCTAssertTrue(credits.exists, "Credits group")
                app.swipeUp(); usleep(500_000)
                shot(tag, big ? "5-credits-xxxl-a" : "5-credits-a")
                for i in 1...(big ? 6 : 2) { app.swipeUp(); usleep(600_000); shot(tag, (big ? "5-credits-xxxl-" : "5-credits-") + String(UnicodeScalar(UInt8(97 + i)))) }
                app.terminate()
            }
        }
    }
}
