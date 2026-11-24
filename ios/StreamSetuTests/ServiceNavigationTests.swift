import XCTest
@testable import StreamSetu

/// iPhone and iPad have no outside services: the shared destination model refuses every route to one, and the five-tab navigation is unchanged.
@MainActor final class ServiceNavigationTests: XCTestCase {
    func testThisPlatformHasNoServices() {
        XCTAssertTrue(ServiceCapabilities.current.externalServices.isEmpty)
        XCTAssertEqual(ServiceCapabilities.current, .none)
    }

    func testNetflixCannotBeSelectedRestoredOrLinked() {
        let nav = ServiceNavigation()
        XCTAssertTrue(nav.services.isEmpty)
        XCTAssertFalse(nav.select(.netflix))
        XCTAssertFalse(nav.restore("service.netflix"))
        XCTAssertTrue(nav.navExpanded)
        XCTAssertEqual(nav.active, .streamSetu)
        XCTAssertEqual(DestinationState(rawValue: "service.netflix").active, .streamSetu)
        for u in ["streamsetu://open?tab=netflix", "streamsetu://open?tab=Netflix"] {
            XCTAssertNil(DeepLink.parse(URL(string: u)!), u)
        }
    }

    func testCapabilityProfileIsUnavailableEverywhere() {
        let p = ServiceCapabilities.current.profile(for: .netflix)
        XCTAssertEqual(p.websiteLoading, .unavailable)
        XCTAssertEqual(p.signIn, .unavailable)
        XCTAssertEqual(p.protectedPlayback, .unavailable)
    }

    func testNoServiceInTheRegistryIsReachableOnThisPlatform() {
        let nav = ServiceNavigation()
        for id in ProviderID.allCases {
            XCTAssertFalse(nav.select(id), id.rawValue)
            XCTAssertFalse(nav.restore("service." + id.rawValue), id.rawValue)
            XCTAssertNil(DeepLink.parse(URL(string: "streamsetu://open?tab=\(id.rawValue)")!), id.rawValue)
            XCTAssertFalse(ServiceCapabilities.current.allows(id), id.rawValue)
        }
        XCTAssertEqual(ProviderRegistry.standard.definitions.count, 12)
        XCTAssertEqual(ServicePreferences.initial().pinned, [.netflix])
        XCTAssertEqual(nav.active, .streamSetu)
    }

    func testTheFiveTabsAndTheirLinksAreUnchanged() {
        XCTAssertEqual(AppTab.allCases.map(\.title), ["Home", "Live TV", "Movies", "Series", "TV Guide"])
        for (name, tab) in [("home", AppTab.home), ("live", .liveTV), ("movies", .movies), ("series", .series), ("guide", .guide)] {
            XCTAssertEqual(DeepLink.parse(URL(string: "streamsetu://open?tab=\(name)")!), .openTab(tab))
        }
    }

    func testRoutingNeverLeavesTheNativeDestination() {
        let router = AppRouter(), nav = ServiceNavigation()
        nav.attach(to: router)
        router.navigate(.movies); router.go(.favorites)
        XCTAssertEqual(nav.active, .streamSetu)
        XCTAssertEqual(router.tab, .home)
    }
}
