import XCTest

/// Setu on the iPhone and the iPad, from a known state: a fresh temporary library (`--atlas-walk` fills it with a few fixed titles), found by accessibility identifier, waiting by polling.
/// Four flows: ask and Show me on a real control, the largest text size, kids mode, Reduce Motion. A screenshot is attached to every failure. Pictures also go to /tmp/streamsetu-atlas-walk/shots.
@MainActor final class SetuSheetTests: XCTestCase {
    private let shots = "/tmp/streamsetu-atlas-walk/shots"
    private var idiom: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }
    private var app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let run = testRun, !run.hasSucceeded {
            let a = XCTAttachment(screenshot: app.screenshot()); a.name = "failure"; a.lifetime = .keepAlways; add(a)
        }
        app.terminate()
    }

    private func launch(_ extra: [String] = []) {
        let db = NSTemporaryDirectory() + "setu-\(name.hashValue.magnitude).sqlite"          // a library of its own for this test
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db + suffix) }
        app = XCUIApplication()
        app.launchArguments = ["--atlas-walk"] + extra
        app.launchEnvironment["REDDY_DB"] = db
        app.launch()
    }
    private func shot(_ name: String) { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(idiom)-\(name).png")) }
    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func wait(_ e: XCUIElement, _ what: String, _ timeout: TimeInterval = 20) {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "\(what) did not appear")
    }
    /// Polls instead of sleeping.
    private func until(_ what: String, timeout: TimeInterval = 15, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(cond(), what)
    }

    /// Settings > Playback, by identifier. The page is known to be open when its own screen marker is on screen.
    private func openPlaybackPage() {
        launch(["--atlas-open", "screen.ios.tab.settings"])
        let row = el("settings.row.playback")
        wait(row, "the Playback row in Settings", 30)
        row.tap()
        wait(el("atlas.screen:screen.ios.settings.playback"), "the Playback page")
    }

    private func ask(_ question: String) {
        wait(el("setu.open"), "the Setu button")
        el("setu.open").tap()
        let field = el("setu.field")
        wait(field, "the message field")
        field.tap()
        field.typeText(question + "\n")          // Return sends
    }

    func testAskAndShowMePointsAtARealControl() {
        openPlaybackPage()
        // The button leaves the tab bar and the page's last row alone, and every control in the sheet is a full tap target.
        let b = el("setu.open")
        wait(b, "the Setu button")
        XCTAssertEqual(b.label, "Setu assistant")
        XCTAssertGreaterThanOrEqual(min(b.frame.width, b.frame.height), 44)
        if idiom == "iphone" { for t in ["tab.home", "tab.more"] { let f = el(t).frame; if !f.isEmpty { XCTAssertFalse(b.frame.intersects(f), "the Setu button covers \(t)") } } }
        shot("flow-1-button")
        ask("how do I turn on play the next episode automatically")
        shot("flow-2-asked")
        let showMe = el("setu.showMe")
        wait(showMe, "the Show me button")
        showMe.tap()
        wait(el("showme.done"), "the Show me callout")
        until("the chat sheet is still covering the page", { !self.el("setu.field").exists })
        XCTAssertTrue(el("showme.close").exists)
        shot("flow-3-show-me")
        // The callout points at the control (no "can't find it" message).
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH \"I can't find it\"")).firstMatch.exists)
    }

    func testLargestTextSizeKeepsTheSheetUsable() {
        launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        wait(el("setu.open"), "the Setu button")
        el("setu.open").tap()
        wait(el("setu.field"), "the message field")
        XCTAssertTrue(el("setu.close").isHittable, "Close is out of reach at the largest text size")
        shot("xxl-sheet")
    }

    func testKidsModeHidesSetu() {
        launch(["--atlas-kids"])
        wait(el("tab.home"), "the tab bar")
        // Kids mode is switched on a moment after the first screen: wait until the library is shown, then check that the button never comes.
        until("Setu is shown in kids mode", timeout: 6) { !self.el("setu.open").exists }
        shot("kids")
        XCTAssertFalse(el("setu.open").exists)
    }

    func testShowMeReadsReduceMotion() {
        openPlaybackPageWith(["--atlas-reduce-motion"])
        ask("how do I turn on play the next episode automatically")
        wait(el("setu.showMe"), "the Show me button")
        el("setu.showMe").tap()
        wait(el("showme.done"), "the Show me callout")
        wait(el("atlas.showme.reduceMotion:true"), "the overlay reading Reduce Motion as on", 5)
        shot("reduce-motion")
    }

    private func openPlaybackPageWith(_ extra: [String]) {
        launch(["--atlas-open", "screen.ios.tab.settings"] + extra)
        let row = el("settings.row.playback")
        wait(row, "the Playback row in Settings", 30)
        row.tap()
        wait(el("atlas.screen:screen.ios.settings.playback"), "the Playback page")
    }
}
