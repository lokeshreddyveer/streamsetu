import XCTest
@testable import StreamSetu

/// When the bottom bar shrinks to a pill and the top buttons fold into the title, decided apart from the screen.
final class ScrollChromeTrackerTests: XCTestCase {
    private func scroll(_ t: inout ScrollChromeTracker, _ ys: [CGFloat]) -> ScrollChromeTracker.Result { var r = ScrollChromeTracker.Result(barCollapsed: false, topMerged: false); for y in ys { r = t.moved(to: y) }; return r }

    func testNothingFoldsAtTheTop() {
        var t = ScrollChromeTracker()
        let r = scroll(&t, [0, 2, 4])
        XCTAssertEqual(r, .init(barCollapsed: false, topMerged: false))
    }

    func testTheBarShrinksOnTheWayDownOnceAwayFromTheTop() {
        var t = ScrollChromeTracker()
        XCTAssertFalse(scroll(&t, [10, 20, 30]).barCollapsed, "a little scrolling near the top changes nothing")
        XCTAssertTrue(scroll(&t, [60, 90, 120]).barCollapsed)
    }

    func testTheBarComesBackOnAnyRealScrollUp() {
        var t = ScrollChromeTracker()
        _ = scroll(&t, [100, 160, 220, 300])
        XCTAssertTrue(t.barCollapsed)
        XCTAssertTrue(scroll(&t, [296, 292]).barCollapsed, "a flick of a few points does not bring it back")
        XCTAssertFalse(scroll(&t, [286, 280]).barCollapsed, "10 points up does")
    }

    func testThePageEasingBackAfterABounceDoesNotBringTheBarBack() {
        var t = ScrollChromeTracker()
        _ = scroll(&t, [100, 300, 520])
        var r = ScrollChromeTracker.Result(barCollapsed: false, topMerged: false)
        for y in stride(from: CGFloat(510), through: 440, by: -10) { r = t.moved(to: y, dragging: false) }
        XCTAssertTrue(r.barCollapsed)
    }

    func testTheBarComesBackAtTheTopWhateverTheDirection() {
        var t = ScrollChromeTracker()
        _ = scroll(&t, [100, 200, 300])
        XCTAssertFalse(scroll(&t, [2]).barCollapsed)
    }

    func testTheTopButtonsFoldOnlyWhileThePageMovesAwayFromTheTop() {
        var t = ScrollChromeTracker()
        XCTAssertFalse(scroll(&t, [10, 16]).topMerged, "near the top they stay out")
        XCTAssertTrue(scroll(&t, [60, 90]).topMerged)
        XCTAssertFalse(scroll(&t, [90.2]).topMerged, "a page that has stopped (no movement) does not keep them folded")
    }

    func testPullingTheTopDownNeverFoldsAnything() {
        var t = ScrollChromeTracker()
        XCTAssertEqual(scroll(&t, [-10, -40, -80]), .init(barCollapsed: false, topMerged: false))
    }

    func testChangingScreenBringsEverythingBack() async {
        let c = await ScrollChrome()
        await c.scrolled(to: 100); await c.scrolled(to: 200); await c.scrolled(to: 300)
        let collapsed = await c.barCollapsed; XCTAssertTrue(collapsed)
        await c.reset()
        let after = await (c.barCollapsed, c.topMerged); XCTAssertFalse(after.0); XCTAssertFalse(after.1)
    }
}
