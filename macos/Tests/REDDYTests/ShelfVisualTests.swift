import Testing
import Foundation
@testable import REDDY

@Suite("Shelf display rules") struct ShelfVisualTests {
    private func movie(_ id: String, _ title: String, poster: String?) -> LibraryItem {
        let src = try! TestSupport.makeSource(TestSupport.makeDB()); var m = TestSupport.movie(src, id, title); m.posterURL = poster; return .movie(m)
    }

    @Test func aRankedShelfPutsPosterlessTitlesLastOrDropsThem() {
        let a = movie("1", "A", poster: nil), b = movie("2", "B", poster: "https://x/b.jpg"), c = movie("3", "C", poster: nil), d = movie("4", "D", poster: "https://x/d.jpg")
        #expect(FolderTileOrder.preferPosters([a, b, c, d]).map(\.title) == ["B", "D", "A", "C"], "ranking order kept among each group; placeholders go last")
        let many = (0..<8).map { movie("p\($0)", "P\($0)", poster: "https://x/\($0).jpg") }
        #expect(FolderTileOrder.preferPosters([a] + many).count == 8, "with enough posters the placeholder is left out")
    }

    @Test func junkRatingsShowNoBadge() {
        for junk in [nil, "", "0", "0.0", "10", "10.0", "11.5", "abc", "-3", "7,4"] as [String?] { #expect(RatingRule.credible(junk) == nil, "\(junk ?? "nil")") }
        #expect(RatingRule.credible("7.4") == 7.4)
        #expect(RatingRule.credible("8") == 8)
        #expect(SmartMixScoring.ratingTenths("7.4") == 74, "the badge and the ranking share one rule")
    }

    @Test func displayTitlesAreCleanedAndCollisionsKeepTheirTag() {
        let labels = DisplayTitle.labels([("1", "Dulhaniya Le Aaeegi (2026) (Hindi)"), ("2", "Nocturne (English)"), ("3", "Rage (Furia)"), ("4", "Pathaan (Hindi)"), ("5", "Pathaan (Telugu)")])
        #expect(labels["1"] == "Dulhaniya Le Aaeegi" && labels["2"] == "Nocturne" && labels["3"] == "Rage")
        #expect(labels["4"] == "Pathaan (Hindi)" && labels["5"] == "Pathaan (Telugu)", "two versions of one title keep the tag that tells them apart")
    }

    @Test func theTileOfATitleWithoutAPosterDoesNotRepeatTheTitle() {
        #expect(ArtworkTile.Content(title: "X", detail: "2022").showsTitle, "other users of the tile keep the title")
        #expect(!ArtworkTile.Content(title: "X", detail: nil, showsTitle: false).showsTitle)
    }
}
