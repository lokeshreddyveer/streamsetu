import XCTest
@testable import StreamSetu

/// The links the app opens from outside (Shortcuts, Siri, the widget, other apps), as installed in this app.
@MainActor final class DeepLinkRoutingTests: XCTestCase {
    private func link(_ s: String) -> DeepLink? { URL(string: s).flatMap(DeepLink.parse) }

    func testSearchLinkCarriesItsWordsAndOpensSearchInMore() {
        guard case .search(let q)? = link("streamsetu://search?q=football") else { return XCTFail("did not parse") }
        XCTAssertEqual(q, "football")
        let router = IOSRouter(); router.query = q; router.go(.search)
        XCTAssertEqual(router.tab, .more); XCTAssertEqual(router.morePath, [.search]); XCTAssertEqual(router.query, "football")
    }

    func testOpenTabLinksReachTheirScreens() {
        for (url, tab, page) in [("live", PhoneTab.live, nil), ("TV%20Guide", .more, PhoneMoreRoute.guide), ("movies", .movies, nil), ("series", .series, nil), ("home", .home, nil)] {
            guard case .openTab(let t)? = link("streamsetu://open?tab=\(url)") else { return XCTFail("\(url) did not parse") }
            let router = IOSRouter(); router.go(IOSRouter.Tab(t))
            XCTAssertEqual(router.tab, tab, url); XCTAssertEqual(router.morePath, page.map { [$0] } ?? [], url)
        }
    }

    func testDangerousLinksAreRefused() {
        XCTAssertNil(link("https://example.com/add?url=http://x"))
        XCTAssertNil(link("streamsetu://add?url=javascript:alert(1)"))
        XCTAssertNil(link("streamsetu://add?url=file:///etc/passwd"))
    }
}
