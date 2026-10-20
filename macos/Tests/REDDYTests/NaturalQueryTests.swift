import Testing
import Foundation
@testable import REDDY

@Suite struct NaturalQueryTests {
    @Test func aWholeSentenceBecomesFilters() {
        let q = NaturalQuery.parse("telugu movies 2024 under 2 hours I haven't watched")
        #expect(q.language == "Telugu" && q.year == 2024 && q.maxMinutes == 120 && q.unwatched)
        #expect(q.text == "")
        #expect(q.summary == ["Telugu", "2024", "under 2 h", "unwatched"])
    }

    @Test func whatIsNotUnderstoodStaysAsTheTitle() {
        let q = NaturalQuery.parse("hindi action heist 4k")
        #expect(q.language == "Hindi" && q.quality == "4K" && q.text == "action heist")
    }

    @Test func ordinaryTitlesAreUntouched() {
        for t in ["Heat", "Look Who's Back", "1917", "2012", "The Outsider", "Sarkaru Vaari Paata", "Oppenheimer 2023"] {
            let q = NaturalQuery.parse(t)
            if t == "Oppenheimer 2023" { #expect(q.year == 2023 && q.text == "oppenheimer") } else { #expect(!q.isStructured && q.text == t) }
        }
    }

    @Test func lengthsDecadesAndRatings() {
        #expect(NaturalQuery.parse("comedy less than 90 minutes").maxMinutes == 90)
        #expect(NaturalQuery.parse("drama longer than 2.5 hours").minMinutes == 150)
        #expect(NaturalQuery.parse("action 90s").decade == 1990)
        #expect(NaturalQuery.parse("thriller rated 8+").minRating == 8)
        #expect(NaturalQuery.parse("best rated english").minRating == 8)
        #expect(NaturalQuery.parse("my favourites in 1080p").favorites)
        #expect(NaturalQuery.parse("recently added telugu").addedWithinDays == 30)
    }
}
