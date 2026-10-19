import Testing
@testable import REDDY

@Suite struct QualityBadgesTests {
    @Test func theWordsInATitleBecomeBadges() {
        #expect(QualityBadges.from(["Dune Part Two (2024) [4K HDR] Atmos 5.1"]) == ["4K", "HDR", "Atmos", "5.1"])
        #expect(QualityBadges.from(["Heat (1995) 1080p DV"]) == ["1080p", "Dolby Vision"])
        #expect(QualityBadges.from(["Movie.2020.2160p.UHD.BluRay.HDR10+.DDP7.1"]) == ["4K", "HDR10+", "7.1"])
    }

    @Test func aTitleWithNoSuchWordsShowsNothing() {
        #expect(QualityBadges.from(["The Matrix (1999)"]).isEmpty)
        #expect(QualityBadges.from([nil, ""]).isEmpty)
        #expect(QualityBadges.from(["Dvorak: The Story"]).isEmpty)                    // "dv" inside a word is not Dolby Vision
        #expect(QualityBadges.from(["Chapter 5 1 and 25.10"]).isEmpty)                  // numbers that only look like channel layouts
    }

    @Test func onlyTheBestPictureSizeIsShownAndThereIsAnUpperLimit() {
        #expect(QualityBadges.from(["4K 1080p 720p"]) == ["4K"])
        #expect(QualityBadges.from(["4K HDR10+ Dolby Vision Atmos 7.1 5.1"]).count == 4)
    }

    @Test func theFolderNameCounts() {
        #expect(QualityBadges.from(["Some Film (2020)", "ENGLISH | 4K"]) == ["4K"])
    }
}
