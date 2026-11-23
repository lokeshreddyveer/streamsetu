import XCTest

final class LaunchTests: MacUITestCase {
    func testLaunchShowsFixtureLibraryAndTabs() {
        for t in ["Home", "Live TV", "Movies", "Series", "TV Guide"] { need(tab(t), "tab \(t)") }
        print(app.debugDescription)
    }
}
