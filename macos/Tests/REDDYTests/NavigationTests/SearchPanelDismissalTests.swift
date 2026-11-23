import XCTest
@testable import REDDY

final class SearchPanelDismissalTests: XCTestCase {
    private let field = CGRect(x: 100, y: 700, width: 250, height: 30)
    private let panel = CGRect(x: 100, y: 330, width: 340, height: 330)

    func testClickInsideFieldOrPanelKeepsOpen() {
        XCTAssertFalse(SearchPanelDismissal.shouldDismiss(click: CGPoint(x: 150, y: 710), field: field, panel: panel))
        XCTAssertFalse(SearchPanelDismissal.shouldDismiss(click: CGPoint(x: 150, y: 400), field: field, panel: panel))
    }

    func testClickOutsideDismisses() {
        XCTAssertTrue(SearchPanelDismissal.shouldDismiss(click: CGPoint(x: 800, y: 300), field: field, panel: panel))
        XCTAssertTrue(SearchPanelDismissal.shouldDismiss(click: CGPoint(x: 10, y: 710), field: field, panel: panel))
        XCTAssertTrue(SearchPanelDismissal.shouldDismiss(click: CGPoint(x: 150, y: 710), field: nil, panel: nil))
    }

    func testTopBarWiresEveryDismissalTrigger() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/REDDY/DesignSystem/Components/Navigation/ReddyTopBar.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        for needle in ["SearchOutsideClickMonitor", "didResignKeyNotification", "didResignActiveNotification", "didBeginTrackingNotification", "pick: { query = $0; closeSearchPanel() }", "onKeyPress(.escape)"] {
            XCTAssertTrue(src.contains(needle), needle)
        }
    }
}
