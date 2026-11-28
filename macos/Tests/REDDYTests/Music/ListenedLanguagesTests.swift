import Foundation
import Testing
@testable import REDDY

@MainActor
@Suite struct ListenedLanguagesTests {
    private func track(_ title: String, _ lang: String?) -> MusicTrack {
        var t = MusicTrack(id: title, providerID: "p", title: title, durationMs: 200_000, artists: [MusicArtistRef(id: "a", name: "A")])
        if let lang { t.hints = MusicProviderHints(language: lang) }
        return t
    }

    @Test func aTeluguListenerGetsTeluguOnlyWhateverElseIsOut() {
        let plays = (0..<20).map { track("t\($0)", "telugu") } + [track("x", "tamil")]
        let set = MusicSimilarityRules.listenedLanguages(plays)
        #expect(set == [.telugu])
    }

    @Test func aMixedListenerKeepsEveryLanguageTheyReallyPlay() {
        let plays = (0..<10).map { track("t\($0)", "telugu") } + (0..<10).map { track("h\($0)", "hindi") }
        #expect(MusicSimilarityRules.listenedLanguages(plays) == [.telugu, .hindi])
    }

    @Test func tooLittleListeningFiltersNothing() {
        #expect(MusicSimilarityRules.listenedLanguages((0..<3).map { track("t\($0)", "telugu") }).isEmpty)
    }

    @Test func theFilterDropsOtherLanguagesButKeepsUnknown() {
        let kept = MusicSimilarityRules.filtered([track("a", "tamil"), track("b", "telugu"), track("c", nil)], hidden: MusicHiddenSet(), isBlocked: { _ in false }, languages: [.telugu])
        #expect(kept.map(\.title) == ["b", "c"])
    }
}
