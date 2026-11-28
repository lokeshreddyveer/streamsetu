import Foundation
import Testing
@testable import REDDY

@Suite struct ArtistPageGaps2Tests {
    @Test func portraitNamesWithShortWordsInsideAreKept() {
        #expect(MusicPersonWikiRules.isPortraitFile("Elvis Costello.jpg"))
        #expect(MusicPersonWikiRules.isPortraitFile("Mstislav Rostropovich 1977.jpg"))
        #expect(MusicPersonWikiRules.isPortraitFile("Robert Frost portrait.png"))
        #expect(MusicPersonWikiRules.isPortraitFile("Mapleton Singh.jpeg"))
    }

    @Test func portraitNamesWithWholeBadWordsAreRejected() {
        #expect(!MusicPersonWikiRules.isPortraitFile("Film poster.jpg"))
        #expect(!MusicPersonWikiRules.isPortraitFile("Movie Posters 2019.png"))
        #expect(!MusicPersonWikiRules.isPortraitFile("Singer_logo.png"))
        #expect(!MusicPersonWikiRules.isPortraitFile("Film OST cover.jpg"))
        #expect(!MusicPersonWikiRules.isPortraitFile("Coat of arms.png"))
        #expect(!MusicPersonWikiRules.isPortraitFile("Someone.svg"))
    }

    @Test @MainActor func aWeakFilmLinkIsWordedAsPossible() throws {
        let sure = try #require(MusicPersonWording.reason(.fromFilm("Roja")))
        let weak = try #require(MusicPersonWording.reason(.possibleFilmLink("Roja")))
        #expect(sure != weak)
        #expect(weak.contains("Roja"))
    }

    @Test @MainActor func similarArtistReasonNamesNoSource() throws {
        let line = try #require(MusicPersonWording.reason(.storedSimilar("SomeProvider")))
        #expect(!line.contains("SomeProvider"))
    }
}
