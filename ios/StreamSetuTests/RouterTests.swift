import XCTest
@testable import StreamSetu

/// The router and the screens it can open. These run inside the app, so they check the real IOSRouter, not a copy of its rules.
@MainActor final class RouterTests: XCTestCase {
    func testEveryDestinationLandsWhereItSays() {
        for screen in PhoneTab.allCases {
            let router = IOSRouter()
            router.go(screen)
            let expected = PhoneRoutes.resolve(screen)
            XCTAssertEqual(router.tab, expected.tab, "\(screen)")
            XCTAssertEqual(router.morePath, expected.page.map { [$0] } ?? [], "\(screen)")
        }
    }

    func testTheBarTabsAreSelectedAsThemselves() {
        for tab in [PhoneTab.home, .live, .movies, .series, .more] {
            let router = IOSRouter(); router.go(tab)
            XCTAssertEqual(router.tab, tab)
            XCTAssertTrue(router.morePath.isEmpty, "a bar tab pushes nothing")
        }
    }

    func testSearchAndTheGuideOpenInMoreNotOnHomeOrLiveTV() {
        let search = IOSRouter(); search.go(.search)
        XCTAssertEqual(search.tab, .more); XCTAssertEqual(search.morePath, [.search])
        let guide = IOSRouter(); guide.go(.guide)
        XCTAssertEqual(guide.tab, .more); XCTAssertEqual(guide.morePath, [.guide])
    }

    func testEveryPageOfMoreCanBeOpenedAndReplacesThePreviousOne() {
        let router = IOSRouter()
        for (screen, page) in [(PhoneTab.search, PhoneMoreRoute.search), (.guide, .guide), (.library, .library), (.playlists, .playlists), (.settings, .settings)] {
            router.go(screen)
            XCTAssertEqual(router.tab, .more); XCTAssertEqual(router.morePath, [page])
        }
    }

    func testGoingToABarTabLeavesTheMoreStackAlone() {
        let router = IOSRouter(); router.go(.settings); router.go(.live)
        XCTAssertEqual(router.tab, .live); XCTAssertEqual(router.morePath, [.settings])
    }

    func testEveryTabAnAppLinkCanNameIsOpenable() {
        for tab in AppTab.allCases {
            let router = IOSRouter(); router.go(IOSRouter.Tab(tab))
            XCTAssertEqual(router.tab, PhoneRoutes.resolve(PhoneTab(tab)).tab, "\(tab)")
        }
    }
}
