import Foundation

/// Every screen a request to open something can name on iPhone and iPad, which share one bar.
enum PhoneTab: Hashable, CaseIterable, Sendable {
    case home, live, guide, movies, series, search, library, playlists, settings, more
    init(_ t: AppTab) {
        switch t { case .home: self = .home; case .liveTV: self = .live; case .guide: self = .guide; case .movies: self = .movies; case .series: self = .series }
    }
}

/// The pages that live inside the More tab, so Movies and Series stay on the bar.
enum PhoneMoreRoute: Hashable, Sendable { case search, guide, library, playlists, settings }

/// Where a request actually lands: the tab to select and, for a page inside More, the page to push on top of it.
struct PhoneRoute: Equatable, Sendable {
    let tab: PhoneTab
    let page: PhoneMoreRoute?
}

enum PhoneRoutes {
    /// Home, Live TV, Movies, Series and More are tabs. Search, the TV Guide, Library, Playlists and Settings are pages of More, so opening one selects More and pushes that page:
    /// a request for Search must never end on Home, and one for the Guide must never end on Live TV (they only hold a button that opens them). Deep links, the assistant, search
    /// commands and the toolbar all go through this one rule, on iPhone and iPad alike.
    static func resolve(_ screen: PhoneTab) -> PhoneRoute {
        switch screen {
        case .search: PhoneRoute(tab: .more, page: .search)
        case .guide: PhoneRoute(tab: .more, page: .guide)
        case .library: PhoneRoute(tab: .more, page: .library)
        case .playlists: PhoneRoute(tab: .more, page: .playlists)
        case .settings: PhoneRoute(tab: .more, page: .settings)
        case .home, .live, .movies, .series, .more: PhoneRoute(tab: screen, page: nil)
        }
    }
}
