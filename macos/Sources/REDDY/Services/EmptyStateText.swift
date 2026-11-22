import Foundation

/// What an empty list says, matched to what is being looked at: a shelf filter (Favourites, Watch Later, Unwatched …) gets its own
/// words, never the folder's ("This playlist has no movies in this folder" is only for a folder that really is empty). Pure, so the
/// choice can be tested. Shared by the Mac and the iPhone/iPad apps.
struct EmptyStateText: Equatable {
    let symbol: String
    let title: String
    let message: String?

    enum Shelf { case all, favourites, watchLater, continueWatching, unwatched, unwatchedFavourites, thisMonth, newEpisodes }

    /// For the Movies and Series grids. `inFolder`: a folder is chosen (not "All"). `syncing`: the playlist is still being read.
    static func library(shelf: Shelf, series: Bool, query: String, inFolder: Bool, syncing: Bool) -> EmptyStateText {
        let noun = series ? "series" : "movies", one = series ? "a series" : "a movie"
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return EmptyStateText(symbol: "magnifyingglass", title: "No matches", message: "Nothing matches “\(query)”.")
        }
        switch shelf {
        case .favourites:
            return EmptyStateText(symbol: "heart", title: "No favourites yet", message: "Tap the heart on \(one) to add it here.")
        case .watchLater:
            return EmptyStateText(symbol: "bookmark", title: "Nothing saved for later", message: "Tap the bookmark on a title to save it.")
        case .continueWatching:
            return EmptyStateText(symbol: "play.circle", title: "Nothing to continue", message: series ? "Series you're partway through appear here." : "Movies you start but don't finish appear here.")
        case .unwatched:
            return inFolder ? EmptyStateText(symbol: "eye.slash", title: "Nothing unwatched in this folder", message: nil)
                            : EmptyStateText(symbol: "eye.slash", title: "You've watched everything here", message: nil)
        case .unwatchedFavourites:
            return EmptyStateText(symbol: "heart.slash", title: "No unwatched favourites", message: "Favourites you have not played yet appear here.")
        case .thisMonth:
            return EmptyStateText(symbol: "calendar.badge.plus", title: "Nothing new this month", message: "Titles your provider added in the last 30 days appear here.")
        case .newEpisodes:
            return EmptyStateText(symbol: "sparkles.tv", title: "No new episodes", message: "When a series you watch gets a new episode, it appears here.")
        case .all:
            if syncing { return EmptyStateText(symbol: "arrow.triangle.2.circlepath", title: "Loading your library…", message: "Titles appear when the playlist has been read.") }
            return EmptyStateText(symbol: series ? "rectangle.stack" : "film", title: "Nothing here",
                                  message: inFolder ? "This playlist has no \(noun) in this folder." : "This playlist has no \(noun).")
        }
    }

    /// For the Live TV list.
    static func liveTV(favouritesOnly: Bool, query: String, syncing: Bool) -> EmptyStateText {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return EmptyStateText(symbol: "magnifyingglass", title: "No matches", message: nil) }
        if favouritesOnly { return EmptyStateText(symbol: "heart", title: "No favourite channels", message: "Favorite a few channels to find them here.") }
        if syncing { return EmptyStateText(symbol: "arrow.triangle.2.circlepath", title: "Loading channels…", message: "Channels appear when the playlist has been read.") }
        return EmptyStateText(symbol: "dot.radiowaves.left.and.right", title: "No channels", message: "This playlist has no live channels, or the folder is empty.")
    }
}
