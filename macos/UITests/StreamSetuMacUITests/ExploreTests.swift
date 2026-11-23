import XCTest

/// Not part of the suite's pass/fail: dumps the accessibility tree of screens to the out folder (as attachments), to see what identifiers and labels exist.
final class ExploreTests: MacUITestCase {
    func dump(_ name: String) { attachText(app.debugDescription, "tree-\(name).txt"); attachShot(name) }

    func testDumpTitleAndSetu() {
        need(tab("Home"), "home")
        let tile = need(app.buttons["View details for The Test Pattern (2019)"].firstMatch, "tile"); tile.click()
        sleep(4); dump("title")
        app.typeKey(.escape, modifierFlags: [])
        sleep(1); dump("afterEsc")
        need(byID("setu.open"), "setu").click(); sleep(2); dump("setu")
        let f = need(byID("setu.field"), "field"); f.click(); f.typeText("How do I turn on subtitles?\r"); sleep(8); dump("setuAnswer")
    }
    func testDumpSettings() {
        need(tab("Home"), "home")
        app.typeKey(",", modifierFlags: .command); sleep(3); dump("settings")
        for t in ["Appearance", "Playback", "Library", "Privacy", "Advanced"] {
            let b = app.toolbars.buttons[t].firstMatch
            if b.waitForExistence(timeout: 3) { b.click(); sleep(1); dump("settings-" + t) }
        }
    }
    func testDumpPlayer() {
        need(tab("Live TV"), "live"); openTab("Live TV")
        need(app.buttons["Alpha News"].firstMatch, "ch").click(); sleep(8); dump("player")
        app.buttons["Alpha News"].firstMatch.doubleClick(); sleep(3); dump("player2")
    }
}
