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

    @Test func aFolderResultOpensTheTabThatShowsItsKind() {
        #expect(PhoneRoutes.folderTab(for: .channel) == .live)
        #expect(PhoneRoutes.folderTab(for: .movie) == .movies)
        #expect(PhoneRoutes.folderTab(for: .series) == .series)
        #expect(PhoneRoutes.folderTab(for: .episode) == nil, "episodes have no folders")
        for k in ContentKind.allCases { if let tab = PhoneRoutes.folderTab(for: k) { #expect(PhoneRoutes.resolve(tab) == PhoneRoute(tab: tab, page: nil), "a folder's tab is a bar tab") } }
    }

    @Test func everyKindOfSearchResultHasAnAction() {
        let all: [SearchDestination] = [.playChannel(channelID: "c"), .movie(id: "m"), .series(id: "s"), .episode(id: "e", seriesID: "s"), .programme(channelID: "c"),
                                        .folder(categoryID: "f", kind: .channel), .folder(categoryID: "f", kind: .movie), .folder(categoryID: "f", kind: .series), .collection(id: "x")]
        let actions = all.map(\.phoneAction)
        #expect(!actions.contains(.unavailable), "nothing the search can return does nothing")
        #expect(SearchDestination.folder(categoryID: "f", kind: .movie).phoneAction == .showFolder(tab: .movies, kind: .movie, categoryID: "f"))
        #expect(SearchDestination.folder(categoryID: "f", kind: .channel).phoneAction == .showFolder(tab: .live, kind: .channel, categoryID: "f"))
        #expect(SearchDestination.folder(categoryID: "f", kind: .series).phoneAction == .showFolder(tab: .series, kind: .series, categoryID: "f"))
        #expect(SearchDestination.collection(id: "x").phoneAction == .showCollection(id: "x"))
        #expect(SearchDestination.folder(categoryID: "f", kind: .episode).phoneAction == .unavailable)
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
