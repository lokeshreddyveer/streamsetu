import Foundation
@testable import REDDY

/// A demo playlist with 32+ folders per content type, used by tests and screenshots only.
/// The app never injects this into a real playlist.
enum FixtureLibrary {
    static let liveGroups = [
        "UK | Entertainment", "News", "Sports", "Documentary", "Kids", "Music", "Movies", "US | Premium", "Indian Entertainment", "Arabic News",
        "International Premium Sports Channels HD (Extended Long Group Name)", "Regional | North", "Regional | South", "Weather", "Shopping", "Religious",
        "Radio | Pop", "Radio | Rock", "Radio | Classical", "Adult Swim Block", "Cooking", "Travel", "Gaming", "Anime", "Classic TV", "Education",
        "Local Council", "Parliament", "Pay Per View", "Events", "24/7 Movies", "24/7 Series", "Fashion", "Business"
    ]
    static let movieGroups = [
        "Featured Picks", "Action", "Comedy", "Drama", "Thriller", "Horror", "Sci-Fi", "Animation", "Family", "Documentary", "Netflix Movies",
        "Prime Video Originals", "Apple TV+ Films", "Indian Movies", "Hindi", "Telugu", "Tamil", "Classics", "Western", "War", "Romance", "Crime",
        "Mystery", "Fantasy", "Musical", "Biography", "Sport", "Foreign Language | Very Long Folder Name For Truncation Checks", "4K Collection", "Kids Movies",
        "Christmas", "Stand-up", "Short Films", "Concerts"
    ]
    static let seriesGroups = [
        "Drama Series", "Comedy Series", "Crime", "Sci-Fi & Fantasy", "Reality", "Documentary Series", "Kids Shows", "Anime", "Netflix Series",
        "Prime Video Series", "Apple TV+ Shows", "Indian Series", "Hindi Shows", "Telugu Shows", "Korean Drama", "Turkish Drama", "British Panel Shows",
        "Medical", "Legal", "Historical", "Mini-Series", "Soap Operas", "Talk Shows", "News Magazines", "Cooking Shows", "Travel Shows", "True Crime",
        "Superhero", "Horror Series", "Western Series", "Sitcoms", "Late Night", "Game Shows", "Sports Docs"
    ]

    static func category(_ src: PlaylistSource, _ kind: ContentKind, _ name: String, _ i: Int) -> CatalogCategory {
        CatalogCategory(id: "cat-\(kind.rawValue)-\(i)", sourceID: src.id, kind: kind, providerID: "\(kind.rawValue)\(i)", name: name, sortOrder: i)
    }

    /// Seeds one playlist and returns it. Three titles per folder; a programme guide for the first channels.
    @MainActor
    @discardableResult
    static func seed(_ c: AppContainer, name: String = "My IPTV") throws -> PlaylistSource {
        let src = PlaylistSource(name: name, type: .xtream, baseURL: "http://provider.example:8080", lastSync: Date().addingTimeInterval(-3600), syncStatus: "completed",
                                 capabilities: SourceCapabilities(live: true, movies: true, series: true, epg: true))
        try c.catalog.save(source: src)
        try c.catalog.saveCapabilities(src.capabilities, sourceID: src.id)

        let liveCats = liveGroups.enumerated().map { category(src, .channel, $0.element, $0.offset) }
        var channels: [Channel] = []
        let channelNames = ["BBC One HD", "CNN International", "Sky Sports Main Event", "National Geographic", "Eurosport 1", "Disney Channel", "MTV Hits", "Al Jazeera English", "HBO", "Discovery"]
        for (gi, cat) in liveCats.enumerated() {
            for k in 0..<3 {
                let n = gi * 3 + k
                let title = n < channelNames.count ? channelNames[n] : "\(cat.name.prefix(12)) \(k + 1)"
                var ch = TestSupport.channel(src, "\(n)", title, cat: nil, order: n, epg: n < 12 ? "id\(n)" : nil)
                ch.categoryID = cat.id; ch.categoryName = cat.name
                channels.append(ch)
            }
        }
        try c.indexer.commitChannels(source: src, categories: liveCats, channels: channels)

        let movieCats = movieGroups.enumerated().map { category(src, .movie, $0.element, $0.offset) }
        var movies: [Movie] = []
        let movieTitles = ["The Last Voyage", "Midnight in Madrid", "Iron Harbor", "Echoes of Tomorrow", "Silent Mountain", "Neon Rain", "Paper Moons", "Harvest of Glass"]
        for (gi, cat) in movieCats.enumerated() {
            for k in 0..<3 {
                let n = gi * 3 + k
                var m = TestSupport.movie(src, "m\(n)", "\(movieTitles[n % movieTitles.count]) \(n / movieTitles.count + 1)", year: 2018 + n % 8)
                m.categoryID = cat.id; m.categoryName = cat.name
                m.overview = "A gripping story of courage and consequence across two continents."
                m.durationSeconds = 6000 + Double(n % 5) * 420
                m.genre = ["Drama", "Thriller", "Action"][n % 3]
                m.rating = String(format: "%.1f", 6.0 + Double(n % 30) / 10)
                m.addedAt = Date().addingTimeInterval(-Double(n) * 3600)
                movies.append(m)
            }
        }
        try c.indexer.commitMovies(source: src, categories: movieCats, movies: movies)

        let seriesCats = seriesGroups.enumerated().map { category(src, .series, $0.element, $0.offset) }
        var shows: [Series] = []
        let showTitles = ["Harbor Lights", "The Long Night", "Capital Crimes", "Northern Lines", "Glass Orchard", "Second Tide"]
        for (gi, cat) in seriesCats.enumerated() {
            for k in 0..<3 {
                let n = gi * 3 + k
                var s = TestSupport.series(src, "s\(n)", "\(showTitles[n % showTitles.count]) \(n / showTitles.count + 1)")
                s.categoryID = cat.id; s.categoryName = cat.name
                s.overview = "Secrets surface in a small coastal town."
                s.genre = "Drama"; s.releaseYear = 2019 + n % 6; s.rating = String(format: "%.1f", 6.5 + Double(n % 25) / 10)
                shows.append(s)
            }
        }
        try c.indexer.commitSeries(source: src, categories: seriesCats, series: shows)

        let now = Date()
        let xml = "<tv>" + (0..<12).map { "<channel id=\"id\($0)\"><display-name>ch\($0)</display-name></channel>" }.joined()
            + (0..<12).flatMap { i in ["Morning Briefing", "World Report", "Evening Headlines", "Late Night"].enumerated().map { k, t in
                "<programme start=\"\(EPGTests.stamp(now.addingTimeInterval(Double(k - 1) * 3600 - 900)))\" stop=\"\(EPGTests.stamp(now.addingTimeInterval(Double(k) * 3600 - 900)))\" channel=\"id\(i)\"><title>\(t)</title><desc>Coverage of the day's main stories.</desc></programme>" } }.joined() + "</tv>"
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).xml")
        try xml.write(to: f, atomically: true, encoding: .utf8)
        _ = try c.epgSync.importFile(f, sourceID: src.id)
        return src
    }

    /// A second playlist with a handful of items, to exercise the playlist selector.
    @MainActor
    static func seedEmpty(_ c: AppContainer, name: String) throws {
        let src = PlaylistSource(name: name, type: .m3uRemote, baseURL: "http://example.com/\(UUID().uuidString).m3u", lastSync: Date(), syncStatus: "completed")
        try c.catalog.save(source: src)
        try c.indexer.commitChannels(source: src, categories: [], channels: [TestSupport.channel(src, "1", "Local One")])
    }

    /// Resume point, favorites and recent plays so the Home pages have something to show.
    @MainActor
    static func seedUserData(_ c: AppContainer) throws {
        let chans = try c.catalog.channels(ChannelQuery(collapseVariants: false, limit: 8))
        let movies = try c.catalog.movies(VODQuery(limit: 8))
        for (i, m) in movies.prefix(6).enumerated() {                 // six unfinished movies, different positions
            try c.historyRepo.saveProgress(WatchProgress(itemID: m.id, kind: .movie, seriesID: nil, positionSeconds: 900 + Double(i) * 800, durationSeconds: 6900, updatedAt: Date().addingTimeInterval(-Double(i) * 600), completed: false))
            try c.historyRepo.recordPlay(itemID: m.id, kind: .movie, title: m.title)
        }
        for ch in chans.dropFirst(3) { try c.historyRepo.recordPlay(itemID: ch.id, kind: .channel, title: ch.name) }
        for ch in chans.prefix(3) { try c.favoritesRepo.setFavorite(ch.id, kind: .channel, on: true); try c.historyRepo.recordPlay(itemID: ch.id, kind: .channel, title: ch.name) }
        if movies.count > 1 { try c.favoritesRepo.setFavorite(movies[1].id, kind: .movie, on: true) }
    }
}
