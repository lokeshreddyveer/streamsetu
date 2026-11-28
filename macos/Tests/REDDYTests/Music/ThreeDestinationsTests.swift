import Foundation
import Testing
@testable import REDDY

/// Listen Now, Explore and Recently Added have different jobs and different data. These tests hold the boundaries between them, so a later change cannot quietly make Explore
/// depend on what the person plays, or make Listen Now a page of charts.
@Suite("Three music destinations stay separate") struct ThreeDestinationsTests {
    private static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY")
    }
    private func read(_ rel: String) throws -> String { try String(contentsOf: Self.sources.appendingPathComponent(rel), encoding: .utf8) }

    @Test func exploreNeverReadsListeningOrSetup() throws {
        let banned = ["MusicTastePreferences", "MusicTasteBias", "MusicTastePrefs", "library.history", "library.liked", "library.recent", "followedArtists", "HomeTaste", "MusicAffinity", "MusicRecommender"]
        for file in ["Features/Music/MusicExploreView.swift", "Features/Music/MusicExploreLazyShelf.swift"] {
            let text = try read(file)
            for b in banned { #expect(!text.contains(b), "\(file) must not use \(b): Explore is the same for every listener") }
        }
    }

    @Test func recentlyAddedIsDrivenBySetupAndSourcesNotByRecommendationScores() throws {
        let text = try read("Features/Music/MusicRecentlyAddedPage.swift")
        for b in ["HomeTaste", "HomeEngine", "MusicHomeSignalLoader", "MusicAffinity", "MusicRecommender", "library.history"] { #expect(!text.contains(b), "Recently Added must not use \(b)") }
        #expect(text.contains("MusicTastePreferences") && text.contains("MusicTasteBias"), "it is the setup choices that drive it")
    }

    @Test func listenNowHasNoChartsAndNoSetupPicks() {
        let names = Mirror(reflecting: HomeSignals()).children.compactMap(\.label)
        #expect(!names.contains("charts") && !names.contains("languageCharts"), "Listen Now takes no chart data")
    }

    @Test func listenNowLoaderAndEngineDoNotReadSetupPicks() throws {
        for file in ["Features/Music/Home/MusicHomeSignalLoader.swift", "Features/Music/Home/MusicHomeFeedModel.swift", "Services/Music/Home/HomeEngine.swift"] {
            let text = try read(file)
            for b in ["MusicTastePreferences", "MusicTasteBias", "lovedGenres", "dislikedGenres", "MusicLanguageDiscovery", "MusicRegionalDiscovery"] {
                #expect(!text.contains(b), "\(file) must not use \(b): Listen Now follows what the person plays")
            }
        }
    }

    /// Listen Now is made only from the listening signals: the same signals and context give the same feed, whatever the person picked in setup (the engine has no way to read the picks).
    @MainActor @Test func aSetupChangeDoesNotTouchTheListeningShelves() {
        let signals = HomePersona.heavy(), ctx = HomePersona.ctx()
        let before = HomeEngine.compose(signals, ctx: ctx)
        MusicTastePreferences.shared.update { $0.languages.insert("telugu"); $0.genres.insert("Pop") }
        defer { MusicTastePreferences.shared.update { $0 = MusicTastePrefs() } }
        let after = HomeEngine.compose(signals, ctx: ctx)
        #expect(before.sections.map(\.id) == after.sections.map(\.id))
        #expect(before.sections.map { $0.items.map(\.id) } == after.sections.map { $0.items.map(\.id) })
    }
}

@Suite("Taste bias and source text") struct TasteBiasTests {
    @MainActor @Test func pickedGenresAreLedByLovedAndNeverIncludeDisliked() {
        var p = MusicTastePrefs(); p.languages = ["telugu"]; p.genres = ["Jazz", "Pop"]; p.lovedGenres = ["Pop"]; p.dislikedGenres = ["Metal", "Jazz"]
        #expect(MusicTasteBias.genres(p).map(\.name) == ["Pop"], "a genre marked not for me is not asked for")
        #expect(MusicTasteBias.genreQuery("Pop", prefs: p) == "Telugu Pop songs")
    }

    @Test func aSourceNameIsNotACaption() {
        for s in ["YouTube Music", "youtube music", "By YouTube Music", "JioSaavn", "Audius", "Spotify", "Apple Music (basic)", "Deezer", "Local files"] { #expect(MusicSourceText.isSource(s), "\(s)") }
        for s in ["Chill vibes for a rainy day", "Songs by Anirudh", "Top hits of 2020"] { #expect(!MusicSourceText.isSource(s), "\(s)") }
        #expect(MusicSourceText.clean("  YouTube Music ") == nil && MusicSourceText.clean("A real description") == "A real description")
    }

    @Test func aDislikedGenreIsRecognisedOnASong() {
        var p = MusicTastePrefs(); p.dislikedGenres = ["Metal"]
        var metal = MusicTrack(id: "1", providerID: "x", title: "Loud", durationMs: 1000, artists: [], creditBundle: nil)
        metal.creditBundle = MusicCreditBundle(credits: [], hints: MusicProviderHints(genre: "Metal"))
        #expect(p.dislikesGenre(metal))
        #expect(!MusicTastePrefs().dislikesGenre(metal))
    }

    @Test func chartProvenanceCarriesSourceCountryPeriodAndTime() {
        let c = MusicChartProvenance(sourceName: "Apple charts", region: "India", period: "Daily")
        #expect(c.sourceName == "Apple charts" && c.region == "India" && c.period == "Daily")
    }
}
