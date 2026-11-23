import XCTest

/// Base class: starts every test from a known state (a fresh copy of the app, a throwaway data folder, the fixture playlist),
/// finds things by accessibility identifier or label, waits with waitForExistence (no sleeps, no coordinates) and attaches a screenshot on every failure.
class MacUITestCase: XCTestCase {
    var app: XCUIApplication!
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var outDir: URL { URL(fileURLWithPath: env["STREAMSETU_UITEST_OUT"] ?? NSTemporaryDirectory()) }

    /// Set to false in a subclass to start with no playlist (the onboarding screen).
    var withFixture: Bool { true }
    /// Extra launch environment for a subclass (the Netflix tests point the web view at a local page).
    var extraEnvironment: [String: String] { [:] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let path = Self.env["STREAMSETU_UITEST_APP"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("STREAMSETU_UITEST_APP is not set; run UITests/run-mac-uitests.sh")
        }
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchEnvironment["STREAMSETU_TESTING"] = "1"          // throwaway data and cache folders, no reports, no iCloud
        app.launchEnvironment["SS_SKIP_INTRO"] = "1"
        if withFixture, let m3u = Self.env["STREAMSETU_UITEST_M3U"] { app.launchEnvironment["STREAMSETU_UITEST_M3U"] = m3u }
        for (k, v) in extraEnvironment { app.launchEnvironment[k] = v }
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "no window after launch")
    }

    override func tearDownWithError() throws {
        if let run = testRun, run.totalFailureCount > 0, app != nil { attachShot("failure"); attachText(app.debugDescription, "tree-at-failure.txt") }
        app?.terminate()
    }

    func attachShot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
        let w = app.windows.firstMatch
        if w.exists { let b = XCTAttachment(screenshot: w.screenshot()); b.name = name + "-window"; b.lifetime = .keepAlways; add(b) }
    }

    /// The runner is sandboxed, so files go out as attachments; the script exports them from the result bundle into the out folder.
    func attachText(_ text: String, _ name: String) {
        let a = XCTAttachment(string: text); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    // MARK: lookups
    func byID(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    func tab(_ title: String) -> XCUIElement { byID("tab." + title) }
    func button(_ label: String) -> XCUIElement { app.buttons[label].firstMatch }
    func text(_ s: String) -> XCUIElement { app.staticTexts[s].firstMatch }

    @discardableResult func need(_ e: XCUIElement, _ what: String, timeout: TimeInterval = 15) -> XCUIElement {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "missing: \(what)")
        return e
    }
    func gone(_ e: XCUIElement, _ what: String, timeout: TimeInterval = 5) {
        let p = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: e)], timeout: timeout), .completed, "still there: \(what)")
    }

    func openTab(_ title: String) {
        let t = need(tab(title), "tab \(title)"); t.click()
        let sel = NSPredicate(format: "isSelected == true")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: sel, evaluatedWith: t)], timeout: 8), .completed, "tab \(title) not selected")
    }

    /// Fails if the app has crashed or its window went blank/away.
    func assertAlive(_ ctx: String) {
        XCTAssertEqual(app.state, .runningForeground, "app not running in the foreground after \(ctx)")
        XCTAssertTrue(app.windows.firstMatch.exists, "no window after \(ctx)")
    }
}
