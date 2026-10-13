import Testing
import Foundation
@testable import REDDY

@Suite struct SmartSearchTests {
    @Test func aLanguageAndAYearAreSeparatedFromTheTitleWords() {
        #expect(SmartQueryParser.parse("hindi movies 2024") == .init(text: "hindi", year: 2024))
        #expect(SmartQueryParser.parse("2024 telugu films") == .init(text: "telugu", year: 2024))
        #expect(SmartQueryParser.parse("dune 2021") == .init(text: "dune", year: 2021))
    }

    @Test func aSingleWordIsNeverTakenApart() {
        #expect(SmartQueryParser.parse("1917") == .init(text: "1917", year: nil))
        #expect(SmartQueryParser.parse("movies") == .init(text: "movies", year: nil))
        #expect(SmartQueryParser.parse("  Alpha ") == .init(text: "Alpha", year: nil))
    }

    @Test func onlyKindWordsAndAYearMeansEveryTitleOfThatYear() {
        #expect(SmartQueryParser.parse("movies 2023") == .init(text: "", year: 2023))
        #expect(SmartQueryParser.parse("new movies") == .init(text: "new movies", year: nil))
    }

    @Test func aMisspeltWordIsFixedFromTheLibrary() {
        let vocab = ["avengers": 40, "alpha": 12, "interstellar": 9, "rony": 2, "love": 80, "spell": 15]
        #expect(SpellingIndex.correct("avangers", vocabulary: vocab) == "avengers")
        #expect(SpellingIndex.correct("intersteller", vocabulary: vocab) == "interstellar")
        #expect(SpellingIndex.correct("love spel", vocabulary: vocab) == nil)             // "spel" is the start of "spell": still being typed
        #expect(SpellingIndex.correct("alpha", vocabulary: vocab) == nil)                 // already right
        #expect(SpellingIndex.correct("zzzzzz", vocabulary: vocab) == nil)               // nothing close
    }

    @Test func whenTwoWordsAreEquallyCloseTheMoreCommonOneWins() {
        #expect(SpellingIndex.correct("barn", vocabulary: ["bark": 1, "burn": 50, "born": 5]) == "burn")
        #expect(SpellingIndex.correct("storm", vocabulary: ["storn": 1, "stork": 30]) == "stork")
        #expect(SpellingIndex.correct("barx", vocabulary: ["bark": 1, "bard": 3]) == "bard")
    }

    @Test func swappedLettersCountAsOneMistake() {
        #expect(SpellingIndex.distance("movie", "mvoie", limit: 2) == 1)
        #expect(SpellingIndex.distance("hindi", "hindu", limit: 2) == 1)
        #expect(SpellingIndex.distance("alpha", "omega", limit: 2) == 3)
    }

    @Test func recentSearchesKeepTheNewestAndForgetDuplicates() {
        let d = UserDefaults(suiteName: "recent-\(UUID().uuidString)")!
        let r = RecentSearches(scope: "movies", defaults: d)
        for t in ["dune", "alpha", "Dune", "x", "rony"] { r.add(t) }
        #expect(r.list() == ["rony", "Dune", "alpha"])          // "x" is too short; "dune" and "Dune" are one search
        for i in 0..<20 { r.add("title \(i)") }
        #expect(r.list().count == RecentSearches.limit)
        r.clear()
        #expect(r.list().isEmpty)
    }
}
