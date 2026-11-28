import Testing
import Foundation
@testable import REDDY

@Suite("Tile menus: every surface") struct TileMenuSurfacesTests {
    private static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    @MainActor @Test func goToCastAsksOnceForTheTitleThatWasOpened() {
        CastFocus.request("movie-1")
        #expect(!CastFocus.consume("movie-2"), "another title's page does not take it")
        #expect(CastFocus.consume("movie-1"))
        #expect(!CastFocus.consume("movie-1"), "taken once: coming back to the page does not scroll again")
    }

    @Test func channelMenuHasTheSameOrderOnEverySurface() {
        var f = TileMenu.Facts(kind: .channel); f.canMultiView = true; f.canRename = true
        #expect(TileMenu.entries(f).map(\.action) == [.play, .watchPrivately, .favorite, .collection, .share, .rename, .multiView, .hideChannel])
        let ids = TileMenu.entries(f).map(\.id)
        #expect(Set(ids).count == ids.count, "no duplicates")
    }

    @Test func everySurfaceGoesThroughTheSharedBuilderAndTheExpressLane() throws {
        func text(_ p: String) throws -> String { try String(contentsOf: Self.root.appendingPathComponent(p), encoding: .utf8) }
        let mac = "macos/Sources/REDDY/"
        #expect(try text(mac + "Features/Shared/ContextMenus.swift").contains("ChannelMenuContent"))
        #expect(try text("ios/StreamSetu/Screens/LiveTVView.swift").contains("ChannelMenuContent"))
        #expect(try text(mac + "Features/Search/Views/SearchResultsPage.swift").contains("SearchResultMenuModifier"))
        #expect(try text("ios/StreamSetu/Screens/SearchView.swift").contains("SearchResultMenuModifier"))
        #expect(try text(mac + "Features/Shared/Views/PersonPage.swift").contains("macTileMenu") && text(mac + "Features/Shared/Views/PersonPage.swift").contains("titleTileMenu"))
        #expect(try text("ios/StreamSetu/Components/FeaturedBanner.swift").contains("titleTileMenu(item)") && text("ios/StreamSetu/Components/FeaturedBanner.swift").contains("expressArtwork"))
        #expect(try text(mac + "Features/Home/Views/HomeScreen.swift").contains("expressHero") && text(mac + "Features/Home/Views/HomeScreen.swift").contains("TileMenuContent(item: s.item"))
        for p in [mac + "Features/Shared/Views/MacTitlePage.swift", "ios/StreamSetu/Screens/DetailView.swift"] {       // the Mac movie and series pages are both MacTitlePage
            #expect(try text(p).contains("castRowFocus"), "\(p) scrolls to the cast row")
        }
    }
}

@Suite("Rating badge on Mac tiles") struct MacTileRatingTests {
    @Test func aTileCarriesOnlyACredibleRating() throws {
        let db = try TestSupport.makeDB(); let src = try TestSupport.makeSource(db)
        var good = TestSupport.movie(src, "a", "Rated Tile Film", year: 2020); good.rating = "7.5"
        var junk = TestSupport.movie(src, "b", "Junk Tile Film", year: 2020); junk.rating = "10.0"
        let none = TestSupport.movie(src, "c", "Plain Tile Film", year: 2020)
        #expect(PosterCardModel(item: .movie(good)).rating == 7.5)
        #expect(PosterCardModel(item: .movie(junk)).rating == nil)
        #expect(PosterCardModel(item: .movie(none)).rating == nil)
    }
}

@Suite("Every poster shows the rating badge") struct RatingBadgeCoverageTests {
    /// Files that draw artwork but are not a film or series tile, each with the reason.
    static let exempt: [String: String] = [
        "DesignSystem/Components/Images/ArtworkImage.swift": "the picture component itself",
        "DesignSystem/Components/PlayerControls/AudioOnlyBackdrop.swift": "the player backdrop",
        "DesignSystem/Components/PlayerControls/ReddyBottomPlayer.swift": "the now-playing bar (a channel, episode or film in progress)",
        "Features/Series/Views/EpisodeCard.swift": "episodes have no rating of their own",
        "Features/Shared/Views/CastSection.swift": "people",
        "Features/CommandCenter/Views/TitleManagerView.swift": "a management list row: a small poster only to recognise the title, not a tile to open it",
        "Features/Home/Views/ShelfModeChips.swift": "the Collections tile is a franchise (several titles), so it has no single rating",
        "Features/Podcasts/PodcastsMainView.swift": "podcast cover art: a show, not a film or series",
        "Features/Files/PodcastsView.swift": "podcast cover art: a show, not a film or series",
        "Features/Podcasts/PodcastShowPage.swift": "podcast and episode artwork: a show, not a film or series",
        "Features/Podcasts/PodcastPlayerViews.swift": "podcast episode artwork in the audio player",
        "Features/Shared/Views/MacTitlePage.swift": "the title page itself: its chips row shows the rating",
        "Features/Shared/Views/MacTitleViews.swift": "the title page itself",
        "Features/Shared/Views/TitlePageParts.swift": "the title page itself",
        "DesignSystem/Components/Cards/FeaturedSlideshow.swift": "the hero banner prints the rating in its info line",
        "../../../../ios/StreamSetu/Screens/DetailView.swift": "the title page itself: its info line shows the rating",
    ]
    @Test func everyTileLikeViewUsesTheSharedBadge() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let roots = [root.appendingPathComponent("macos/Sources/REDDY"), root.appendingPathComponent("ios/StreamSetu")]
        var missing: [String] = []
        for base in roots {
            let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let u = e?.nextObject() as? URL {
                guard u.pathExtension == "swift", let t = try? String(contentsOf: u, encoding: .utf8), t.contains("ArtworkImage(") || t.contains("PosterArt(") else { continue }
                let rel = u.path.replacingOccurrences(of: base.path + "/", with: "")
                let key = base.lastPathComponent == "StreamSetu" ? "../../../../ios/StreamSetu/" + rel : rel
                if Self.exempt[key] != nil || t.contains("RatingBadge(") || t.contains(".ratingBadge(") || t.contains("RatingLabel(") || t.contains("star.fill") { continue }
                missing.append(rel)
            }
        }
        #expect(missing.isEmpty, "views that draw artwork without the rating badge (use .ratingBadge, or add an exemption with a reason): \(missing)")
    }
}
