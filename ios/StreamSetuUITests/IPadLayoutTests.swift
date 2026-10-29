import XCTest

/// Opens each sidebar destination on an iPad and saves a picture of it, so the layout can be looked at. Needs a library on the device; skipped otherwise.
final class IPadLayoutTests: XCTestCase {
    func testEverySidebarDestinationOpens() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        let app = XCUIApplication()
        app.launch()
        if app.buttons["Not Now"].waitForExistence(timeout: 6) { app.buttons["Not Now"].tap() }
        let dir = "/tmp/ipad-shots"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func shot(_ name: String) {
            let png = app.screenshot().pngRepresentation
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ipad-\(name).png"))
        }
        try XCTSkipUnless(app.staticTexts["Movies"].waitForExistence(timeout: 15) || app.buttons["Movies"].exists, "no library is open on this device")
        shot("home")
        for name in ["Movies", "Live TV", "Guide", "Series", "Search", "Library", "Playlists", "Settings"] {
            // The sidebar row: the text with that name that sits in the left column.
            let rows = app.staticTexts.matching(identifier: name).allElementsBoundByIndex.filter { $0.exists && $0.frame.minX < 300 }
            guard let item = rows.first else { XCTFail("\(name) is missing from the sidebar"); continue }
            item.tap()
            sleep(2)
            shot(name.lowercased().replacingOccurrences(of: " ", with: ""))
        }
    }
}
