import SwiftUI
import Observation

/// The five top-level tabs, centred in the header.
enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case home = "Home", liveTV = "Live TV", movies = "Movies", series = "Series", guide = "TV Guide"
    var id: String { rawValue }
    var title: String { rawValue }
}

/// Fixed shortcuts pinned at the top of a tab's sidebar.
enum Shortcut: String, Hashable, Sendable {
    case tonight, discover, continueWatching, recentlyWatched, watchHistory, favorites, watchLater, collections
    case featured, allMovies, recentlyAdded, library, allChannels, statistics
    /// Smart lists: made by rules from what the library holds and what has been played, never typed in.
    case unwatched, unwatchedFavorites, addedThisMonth, newEpisodes

    var title: String {
        switch self {
        case .tonight: "Tonight"
        case .discover: "Discover"
        case .continueWatching: "Continue Watching"
        case .recentlyWatched: "Recently Watched"
        case .watchHistory: "Watch History"
        case .favorites: "Favorites"
        case .watchLater: "Watch Later"
        case .collections: "Collections"
        case .featured: "Featured"
        case .allMovies: "All Movies"
        case .recentlyAdded: "Recently Added"
        case .library: "Library"
        case .allChannels: "All Channels"
        case .statistics: "Statistics"
        case .unwatched: "Unwatched"
        case .unwatchedFavorites: "Unwatched Favorites"
        case .addedThisMonth: "Added in 30 Days"
        case .newEpisodes: "New Episodes"
        }
    }

    var symbol: String {
        switch self {
        case .tonight: "moon.stars"
        case .discover, .featured: "sparkle"
        case .continueWatching: "play"
        case .recentlyWatched, .recentlyAdded: "clock.arrow.circlepath"
        case .watchHistory: "list.bullet"
        case .favorites: "heart"
        case .watchLater: "bookmark"
        case .collections, .allMovies, .library: "square.grid.2x2"
        case .allChannels: "list.bullet"
        case .statistics: "chart.bar"
        case .unwatched: "eye.slash"
        case .unwatchedFavorites: "heart.slash"
        case .addedThisMonth: "calendar.badge.plus"
        case .newEpisodes: "sparkles.tv"
        }
    }

    static func pinned(for tab: AppTab) -> [Shortcut] {
        switch tab {
        case .home: [.discover, .tonight, .continueWatching, .recentlyWatched, .watchHistory, .favorites, .watchLater, .collections, .statistics]
        case .movies: [.featured, .allMovies, .recentlyAdded, .continueWatching, .favorites, .watchLater, .unwatched, .unwatchedFavorites, .addedThisMonth]
        case .series: [.library, .recentlyAdded, .continueWatching, .favorites, .watchLater, .newEpisodes, .unwatched, .unwatchedFavorites, .addedThisMonth]
        case .liveTV: [.allChannels, .recentlyAdded, .recentlyWatched, .favorites]
        case .guide: [.allChannels, .favorites]
        }
    }

    var folderKind: ContentKind? { nil }
}

enum SidebarSelection: Hashable, Sendable {
    case shortcut(Shortcut)
    case folder(String)          // category id
}

struct Navigation: Hashable, Sendable {
    var tab: AppTab
    var selection: SidebarSelection
}

/// Destinations that other parts of the app ask for by name.
enum Destination: Hashable, Sendable {
    case home, liveTV, movies, series, guide
    case favorites, continueWatching, history, collections
    case channelManager, playlists
}

enum ModalRoute: Hashable, Identifiable, Sendable {
    case playlists, addPlaylist, about, channelManager, unlockRestricted
    var id: Self { self }
}

/// Navigation state. A fresh launch always starts at Home → Discover; nothing here is restored from a previous run.
@MainActor @Observable
final class AppRouter {
    private(set) var tab: AppTab = .home
    private var selections: [AppTab: SidebarSelection] = [:]
    var movie: Movie?
    var series: Series?
    var modal: ModalRoute?
    var sidebarCollapsed = false
    /// A playlist address or file dropped on the window or opened from a link, waiting to be put in the Add Playlist form.
    var pendingAdd: PendingAdd?
    /// When off, choosing a tab always opens its first sidebar item instead of the folder you were last in.
    var rememberFolders = true
    var accountMenuOpen = false
    var playlistMenuOpen = false
    var focusSearch = 0
    /// What is typed in the top bar. While it is non-empty, results replace the content area; the screen beneath stays alive.
    var searchQuery = ""
    var topSearchFocus = 0
    /// Bumped by ↓ in the search field to move keyboard focus into the results.
    var searchResultsFocus = 0
    /// Category to preselect in a tab (set by other screens, consumed once).
    var pendingFolder: String?
    /// Words for the next list screen's own search box, set by a command typed in the top search ("open movies: top rated telugu"). Consumed once.
    var libraryQuery: String?

    static func defaultSelection(for tab: AppTab) -> SidebarSelection { .shortcut(Shortcut.pinned(for: tab)[0]) }

    var selection: SidebarSelection { selections[tab] ?? Self.defaultSelection(for: tab) }

    func select(_ s: SidebarSelection) { selections[tab] = s }

    func navigate(_ tab: AppTab, _ selection: SidebarSelection? = nil) {
        self.tab = tab
        selections[tab] = selection ?? (rememberFolders ? selections[tab] : nil) ?? Self.defaultSelection(for: tab)
        playlistMenuOpen = false; accountMenuOpen = false
    }

    func openFolder(_ tab: AppTab, categoryID: String) { navigate(tab, .folder(categoryID)) }

    func go(_ d: Destination) {
        switch d {
        case .home: navigate(.home, .shortcut(.discover))
        case .liveTV: navigate(.liveTV, .shortcut(.allChannels))
        case .movies: navigate(.movies, .shortcut(.allMovies))
        case .series: navigate(.series, .shortcut(.library))
        case .guide: navigate(.guide, .shortcut(.allChannels))
        case .favorites: navigate(.home, .shortcut(.favorites))
        case .continueWatching: navigate(.home, .shortcut(.continueWatching))
        case .history: navigate(.home, .shortcut(.recentlyWatched))
        case .collections: navigate(.home, .shortcut(.collections))
        case .channelManager: modal = .channelManager
        case .playlists: modal = .playlists
        }
    }

    // MARK: details & search

    func open(movie: Movie) { series = nil; self.movie = movie }
    func open(series: Series) { movie = nil; self.series = series }
    func closeDetail() { movie = nil; series = nil }

    /// ⌘K: focus the search field in the top bar. Search never opens a dialog.
    func focusTopSearch() { topSearchFocus += 1 }
    func clearSearch() { searchQuery = "" }
    var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }
    /// ⌘F: focus the current screen's own search field.
    func focusCurrentScreenSearch() { focusSearch += 1 }
    func closeMenus() { accountMenuOpen = false; playlistMenuOpen = false }
}
