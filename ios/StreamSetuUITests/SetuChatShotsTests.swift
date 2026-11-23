import XCTest

/// Pictures of the Setu chat for looking at: each state in a few themes, light and dark, and at the largest text size. Files go to SETU_CHAT_SHOTS (default /tmp/streamsetu-setu-chat).
@MainActor final class SetuChatShotsTests: XCTestCase {
    private var dir: String { ProcessInfo.processInfo.environment["SETU_CHAT_SHOTS"] ?? "/tmp/streamsetu-setu-chat" }
    override func setUpWithError() throws { continueAfterFailure = true; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    private var idiom: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        let f = app.textFields["Message to Setu"].firstMatch
        return f.exists ? f : app.textViews["Message to Setu"].firstMatch
    }

    private func run(theme: String, dark: Bool, xxl: Bool = false) {
        XCUIDevice.shared.appearance = dark ? .dark : .light
        let app = XCUIApplication()
        app.launchArguments = ["--atlas-walk", "-settings.theme", theme] + (xxl ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"] : [])
        app.launchEnvironment["REDDY_DB"] = "/tmp/streamsetu-atlas-walk/walk.sqlite"
        app.launch()
        let tag = "\(idiom)-\(theme.replacingOccurrences(of: " ", with: ""))-\(dark ? "dark" : "light")\(xxl ? "-xxl" : "")"
        func shot(_ s: String) { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(tag)-\(s).png")) }
        let button = app.buttons["Setu assistant"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 40), "no Setu button")
        button.tap()
        let f = field(app)
        XCTAssertTrue(f.waitForExistence(timeout: 10), "chat did not open")
        shot("1-welcome")
        let grab = app.otherElements["Sheet Grabber"].firstMatch
        if grab.exists { grab.swipeUp(); sleep(1) }          // the large detent: the keyboard leaves room for the conversation
        f.tap(); f.typeText("How do I turn on subtitles?")
        shot("2-keyboard-typed")
        f.typeText("\n")
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'subtitle'")).element(boundBy: 1).waitForExistence(timeout: 10)
        sleep(1)
        shot("3-answer")
        f.tap(); f.typeText("sync\n"); sleep(2)
        shot("4-choices")
        app.terminate()
    }

    func testCinematicDark() { run(theme: "Cinematic", dark: true) }
    func testCinematicLight() { run(theme: "Cinematic", dark: false) }
    func testNordDark() { run(theme: "Nord", dark: true) }
    func testLiquidGlassDark() { run(theme: "Liquid Glass", dark: true) }
    func testCinematicXXL() { run(theme: "Cinematic", dark: true, xxl: true) }
}
