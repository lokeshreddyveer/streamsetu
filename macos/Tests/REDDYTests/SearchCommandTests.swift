import Testing
import Foundation
@testable import REDDY

@Suite struct SearchCommandTests {
    private func kinds(_ s: String) -> [SearchCommand.Kind] { SearchCommands.parse(s).map(\.kind) }

    @Test func screensAreRecognisedByTheirNamesWithOrWithoutAVerb() {
        #expect(kinds("go to live tv") == [.go(.liveTV, library: nil)])
        #expect(kinds("open settings") == [.go(.settings, library: nil)])
        #expect(kinds("tv guide") == [.go(.guide, library: nil)])
        #expect(kinds("show me my favourites") == [.go(.favorites, library: nil)])
        #expect(kinds("watch later") == [.go(.watchLater, library: nil)], "this is a screen, not a request to play something called later")
        #expect(kinds("continue watching") == [.go(.continueWatching, library: nil)])
        #expect(kinds("statistics") == [.go(.statistics, library: nil)])
    }

    @Test func aLoneAmbiguousWordIsJustASearch() {
        #expect(kinds("live").isEmpty && kinds("saved").isEmpty && kinds("home").isEmpty)
        #expect(kinds("go to home") == [.go(.discover, library: nil)])
    }

    @Test func aListWithItsOwnFiltersOpensThatListWithTheWordsInItsSearchBox() {
        #expect(kinds("top rated telugu movies") == [.go(.movies, library: "top rated telugu movies")])
        #expect(kinds("show unwatched series") == [.go(.series, library: "unwatched series")])
        #expect(kinds("open movies shortest first") == [.go(.movies, library: "movies shortest first")])
    }

    @Test func playingAndResuming() {
        #expect(kinds("play Inception") == [.play("Inception")])
        #expect(kinds("watch the dark knight") == [.play("the dark knight")])
        #expect(kinds("resume") == [.resume])
        #expect(kinds("pick up where I left off") == [.resume])
        #expect(kinds("last channel") == [.lastChannel])
        #expect(kinds("play it").isEmpty && kinds("play").isEmpty)
    }

    @Test func favouritesAndWatchLaterKeepTheTitleAsTyped() {
        #expect(kinds("add Jersey to watch later") == [.watchLater("Jersey", on: true)])
        #expect(kinds("add Pokiri to my favourites") == [.favourite("Pokiri", on: true)])
        #expect(kinds("remove Jersey from favorites") == [.favourite("Jersey", on: false)])
        #expect(kinds("favourite Srimanthudu") == [.favourite("Srimanthudu", on: true)])
        #expect(kinds("unfavourite Jersey") == [.favourite("Jersey", on: false)])
    }

    @Test func anOrdinaryTitleOrSentenceIsNotACommand() {
        #expect(kinds("inception").isEmpty)
        #expect(kinds("the dark knight").isEmpty)
        #expect(kinds("telugu movies with mahesh babu").first != nil, "this one does open Movies with the words, and the smart picks still show as well")
        #expect(kinds("ab").isEmpty)
    }

    @Test func eachCommandSaysWhatItWillDo() {
        #expect(SearchCommands.parse("go to live tv").first?.title == "Go to Live TV")
        #expect(SearchCommands.parse("play Inception").first?.title == "Play “Inception”")
        #expect(SearchCommands.parse("top rated telugu movies").first?.title == "Open Movies: top rated telugu movies")
    }
}

@Suite struct SortAndGenreWordsTests {
    @Test func orderingWordsSetTheSort() {
        #expect(NaturalQuery.parse("telugu movies top rated").sort == .rating)
        #expect(NaturalQuery.parse("action newest first").sort == .year)
        #expect(NaturalQuery.parse("hindi oldest").sort == .yearOldest)
        #expect(NaturalQuery.parse("comedies a to z").sort == .title)
        #expect(NaturalQuery.parse("drama z to a").sort == .titleDescending)
        #expect(NaturalQuery.parse("telugu shortest first").sort == .durationShortest)
        #expect(NaturalQuery.parse("english longest").sort == .durationLongest)
    }

    @Test func genresAreIncludedAndLeftOut() {
        let q = NaturalQuery.parse("telugu thriller not horror")
        #expect(q.language == "Telugu" && q.genres == ["Thriller"] && q.excludeGenres == ["Horror"])
        #expect(q.summary.contains("no Horror") && q.summary.contains("Thriller"))
    }

    @Test func aSingleWordStaysATitleSearch() {
        #expect(!NaturalQuery.parse("action").isStructured)
        #expect(!NaturalQuery.parse("drama").isStructured)
    }

    @Test func existingMeaningsAreKept() {
        let q = NaturalQuery.parse("telugu movies 2024 under 2 hours unwatched")
        #expect(q.language == "Telugu" && q.year == 2024 && q.maxMinutes == 120 && q.unwatched)
        #expect(NaturalQuery.parse("top rated telugu movies").sort == .rating)
    }
}
