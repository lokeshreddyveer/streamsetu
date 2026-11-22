import Testing
import Foundation
@testable import REDDY

@Suite("Motion kit") struct BrandMotionTests {
    @Test func onlyTheFirstScreenfulIsStaggered() {
        #expect(BrandMotion.staggerDelay(index: 0) == 0)
        #expect(BrandMotion.staggerDelay(index: 3) == 0.09)
        #expect(BrandMotion.staggerDelay(index: 11) != nil)
        #expect(BrandMotion.staggerDelay(index: 12) == nil)
        #expect(BrandMotion.staggerDelay(index: -1) == nil)
        #expect(BrandMotion.staggerDelay(index: 5, step: 0.04, cap: 4) == nil)
    }

    @Test func emptyStatesGetArtFromTheSymbolTheyAlreadyUse() {
        #expect(BrandEmptyArt.kind(for: "magnifyingglass") == .search)
        #expect(BrandEmptyArt.kind(for: "line.3.horizontal.decrease.circle") == .search)
        #expect(BrandEmptyArt.kind(for: "bookmark") == .bookmark)
        #expect(BrandEmptyArt.kind(for: "heart") == .heart)
        #expect(BrandEmptyArt.kind(for: "arrow.down.circle") == .downloads)
        #expect(BrandEmptyArt.kind(for: "wifi.slash") == .noConnection)
        #expect(BrandEmptyArt.kind(for: "exclamationmark.triangle") == .error)
        #expect(BrandEmptyArt.kind(for: "list.bullet.rectangle") == .ribbon)
        #expect(BrandEmptyArt.kind(for: "play.tv") == .tuning)
    }
}

@Suite("Empty-state wording") struct EmptyStateTextTests {
    @Test func aShelfFilterGetsItsOwnWordsNeverTheFolders() {
        let fav = EmptyStateText.library(shelf: .favourites, series: false, query: "", inFolder: false, syncing: false)
        #expect(fav.title == "No favourites yet" && fav.message == "Tap the heart on a movie to add it here." && fav.symbol == "heart")
        #expect(EmptyStateText.library(shelf: .favourites, series: true, query: "", inFolder: true, syncing: true).message == "Tap the heart on a series to add it here.")
        let later = EmptyStateText.library(shelf: .watchLater, series: false, query: "", inFolder: false, syncing: false)
        #expect(later.title == "Nothing saved for later" && later.message == "Tap the bookmark on a title to save it.")
        #expect(EmptyStateText.library(shelf: .unwatched, series: false, query: "", inFolder: false, syncing: false).title == "You've watched everything here")
        #expect(EmptyStateText.library(shelf: .unwatched, series: false, query: "", inFolder: true, syncing: false).title == "Nothing unwatched in this folder")
        // Only "All" in a folder says the folder is empty; while the playlist is read it says so instead.
        #expect(EmptyStateText.library(shelf: .all, series: false, query: "", inFolder: true, syncing: false).message == "This playlist has no movies in this folder.")
        #expect(EmptyStateText.library(shelf: .all, series: false, query: "", inFolder: true, syncing: true).title == "Loading your library…")
        for shelf in [EmptyStateText.Shelf.favourites, .watchLater, .unwatched, .unwatchedFavourites, .thisMonth, .newEpisodes, .continueWatching] {
            #expect(EmptyStateText.library(shelf: shelf, series: false, query: "", inFolder: true, syncing: false).message?.contains("this folder") != true, "\(shelf)")
        }
        #expect(EmptyStateText.library(shelf: .favourites, series: false, query: "leo", inFolder: false, syncing: false).title == "No matches")
    }

    @Test func liveTVFavourites() {
        #expect(EmptyStateText.liveTV(favouritesOnly: true, query: "", syncing: false).message == "Favorite a few channels to find them here.")
        #expect(EmptyStateText.liveTV(favouritesOnly: false, query: "", syncing: true).title == "Loading channels…")
        #expect(EmptyStateText.liveTV(favouritesOnly: true, query: "bbc", syncing: false).title == "No matches")
    }
}
