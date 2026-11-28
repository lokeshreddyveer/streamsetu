import Foundation
import Testing
@testable import REDDY

@MainActor @Suite("Round 13 fixes") struct Round13FixesTests {
    private func song(_ title: String, ms: Int?, album: String = "a", position: Int = 1) -> MusicFilmSongItem {
        MusicFilmSongItem(recording: .provisional(kind: .recording, providerUID: "p:\(title)\(ms ?? 0)\(album)"), title: title, durationMs: ms, imageRef: nil,
                          album: .provisional(kind: .album, name: album), albumName: album, dubLanguage: nil, disc: 1, position: position,
                          singers: [], providerUID: nil, releaseProviderUID: nil, status: .inferred)
    }

    @Test func twoSongsOfOneTitleAndDifferentLengthsAreTwoSongs() {
        let male = song("Tere Bina", ms: 200_000, position: 1), female = song("Tere Bina", ms: 290_000, position: 2)
        #expect(MusicFilmSongRules.arranged([male, female], limit: 10).count == 2, "a male and a female version are not one song")
        let again = song("Tere Bina", ms: 201_500, album: "deluxe", position: 1)
        #expect(MusicFilmSongRules.arranged([male, again], limit: 10).count == 1, "the same song on a deluxe edition is one row")
        #expect(MusicFilmSongRules.arranged([male, song("Tere Bina", ms: nil)], limit: 10).count == 1, "an unknown length does not make it another song")
    }

    @Test func languageNamesFollowTheAppLanguageNotTheMac() {
        let telugu = MusicFilmLanguageNames.name(for: "hi", locale: Locale(identifier: "te"))
        let english = MusicFilmLanguageNames.name(for: "hi", locale: Locale(identifier: "en"))
        #expect(telugu != english)
        #expect(MusicFilmLanguageNames.name(for: "xx").isEmpty)
    }

    @Test func listeningStatsBelongToTheSingerViewsOnly() {
        #expect(MusicPersonPage.hasPersonalListening(nil))
        #expect(MusicPersonPage.hasPersonalListening(.singer))
        #expect(MusicPersonPage.hasPersonalListening(.instrumentalist))
        #expect(!MusicPersonPage.hasPersonalListening(.composer), "the songs a composer wrote are sung by others, so \"not played yet\" would be wrong")
        #expect(!MusicPersonPage.hasPersonalListening(.lyricist))
        #expect(!MusicPersonPage.hasPersonalListening(.actor))
    }

    @Test func aReleaseDateHelperIsCallableOffTheMainActor() async {
        let ok = await Task.detached { MusicRecentlyAddedPage.isFuture("2999-01-01", now: Date()) }.value
        #expect(ok)
    }
}
