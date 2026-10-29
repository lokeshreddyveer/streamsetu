import Testing
import Foundation
@testable import REDDY

@Suite("iPhone and iPad routes") struct PhoneRoutesTests {
    @Test func theBarTabsStayThemselves() {
        for t in [PhoneTab.home, .live, .movies, .series, .more] { #expect(PhoneRoutes.resolve(t) == PhoneRoute(tab: t, page: nil)) }
    }

    @Test func searchAndGuideOpenTheirOwnPageInMoreNotHomeOrLiveTV() {
        #expect(PhoneRoutes.resolve(.search) == PhoneRoute(tab: .more, page: .search))
        #expect(PhoneRoutes.resolve(.guide) == PhoneRoute(tab: .more, page: .guide))
        #expect(PhoneRoutes.resolve(.search).tab != .home && PhoneRoutes.resolve(.guide).tab != .live)
    }

    @Test func libraryPlaylistsAndSettingsDoTheSame() {
        #expect(PhoneRoutes.resolve(.library) == PhoneRoute(tab: .more, page: .library))
        #expect(PhoneRoutes.resolve(.playlists) == PhoneRoute(tab: .more, page: .playlists))
        #expect(PhoneRoutes.resolve(.settings) == PhoneRoute(tab: .more, page: .settings))
    }

    @Test func everyScreenResolvesAndEveryMorePageIsReachable() {
        var reached = Set<PhoneMoreRoute>()
        for t in PhoneTab.allCases {
            let r = PhoneRoutes.resolve(t)
            if let page = r.page { #expect(r.tab == .more, "a page of More is only shown inside More"); reached.insert(page) }
            else { #expect(r.tab == t) }
        }
        #expect(reached == [.search, .guide, .library, .playlists, .settings])
    }

    @Test func everyTabTheDeepLinksAndTheAssistantCanNameLandsWhereItSays() {
        // streamsetu://open?tab=... and the assistant's "open ..." commands name an AppTab.
        for t in AppTab.allCases {
            let route = PhoneRoutes.resolve(PhoneTab(t))
            switch t {
            case .guide: #expect(route == PhoneRoute(tab: .more, page: .guide))
            case .home: #expect(route.tab == .home)
            case .liveTV: #expect(route.tab == .live)
            case .movies: #expect(route.tab == .movies)
            case .series: #expect(route.tab == .series)
            }
        }
    }

    @Test func theCallersOfSearchAndGuideAllGetThePages() {
        // streamsetu://search, "Find series" links, the search commands (Guide, Library, Settings) and the toolbar buttons.
        let callers: [(name: String, screen: PhoneTab, page: PhoneMoreRoute)] = [
            ("search link", .search, .search), ("find series link", .search, .search), ("assistant: open Guide", .guide, .guide),
            ("search command: Guide", .guide, .guide), ("search command: Library", .library, .library), ("search command: Settings", .settings, .settings),
        ]
        for c in callers { #expect(PhoneRoutes.resolve(c.screen) == PhoneRoute(tab: .more, page: c.page), "\(c.name)") }
    }
}
