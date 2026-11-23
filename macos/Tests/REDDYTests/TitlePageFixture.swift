import Foundation
import AppKit
import CoreGraphics
@testable import REDDY

/// Real-looking data for the title page tests and screenshots: a movie and a series with overview, cached TMDB details (cast, makers, trailer),
/// artwork served from a throwaway image cache (no network), a version in another language, episodes and resume progress.
@MainActor enum TitlePageFixture {
    struct World {
        let container: AppContainer
        let state: AppState
        let artwork: ArtworkService
        let movie: Movie
        let series: Series
        let artworkRoot: URL
    }

    static func cgImage(width: Int, height: Int, hue: Double, poster: Bool, label: String? = nil) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        func col(_ h: Double, _ s: Double, _ b: Double) -> CGColor { NSColor(hue: h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1).cgColor }
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [col(hue, 0.75, 0.85), col(hue + 0.06, 0.8, 0.45), col(hue + 0.12, 0.7, 0.12)] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        // a sun and a dark horizon, so the picture has shape and not just a gradient
        ctx.setFillColor(col(hue + 0.02, 0.2, 1).copy(alpha: 0.85)!)
        let r = CGFloat(min(width, height)) * 0.22
        ctx.fillEllipse(in: CGRect(x: CGFloat(width) * 0.62 - r, y: CGFloat(height) * 0.58 - r, width: r * 2, height: r * 2))
        ctx.setFillColor(CGColor(gray: 0.04, alpha: 0.9))
        ctx.move(to: CGPoint(x: 0, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: CGFloat(height) * 0.28))
        var x: CGFloat = 0
        while x < CGFloat(width) { x += CGFloat(width) / 9; ctx.addLine(to: CGPoint(x: x, y: CGFloat(height) * (0.18 + 0.12 * CGFloat(sin(Double(x) * 0.02 + hue * 9))))) }
        ctx.addLine(to: CGPoint(x: CGFloat(width), y: 0)); ctx.fillPath()
        if poster, let label {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: CGFloat(width) * 0.09, weight: .heavy), .foregroundColor: NSColor.white.withAlphaComponent(0.9)]
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            (label.uppercased() as NSString).draw(in: CGRect(x: CGFloat(width) * 0.08, y: CGFloat(height) * 0.06, width: CGFloat(width) * 0.84, height: CGFloat(height) * 0.2), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
        return ctx.makeImage()!
    }

    static func store(_ url: String, _ kind: ArtworkKind, _ img: CGImage, root: URL) throws {
        let dir = root.appendingPathComponent(kind.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try need(ImageCache.encode(img)).write(to: dir.appendingPathComponent(ImageCache.key(URL(string: url)!, kind) + ".img"))
    }

    static func world(overview: String? = nil, backdrop: Bool = true, poster: Bool = true, progress: Bool = true, hub: Bool = false) throws -> World {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-tp-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        try FixtureLibrary.seed(c)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-tp-art-\(UUID().uuidString)")
        let artwork = ArtworkService(cache: ImageCache(root: root, http: HTTPClient()))
        var movie = try need(try c.catalog.movies(VODQuery(limit: 3)).first)
        movie.title = "The Odyssey"; movie.releaseYear = 2026; movie.durationSeconds = 10_560; movie.rating = "8.0"; movie.genre = "Adventure, Action, Fantasy"
        movie.overview = overview ?? "Odysseus, the legendary King of Ithaca, embarks on a long and perilous journey home following the Trojan War. Throughout his voyage, he is forced to confront the whims of gods, mythological monsters, and trials that stretch beyond the limits of any mortal. Every island asks him for something he is no longer sure he has left to give."
        movie.posterURL = poster ? "https://img.example/p/odyssey.jpg" : nil
        movie.backdropURL = backdrop ? "https://img.example/b/odyssey.jpg" : nil
        try c.db.write { try $0.execute("UPDATE movies SET title=?, release_year=?, duration_seconds=?, rating=?, genre=?, overview=?, poster_url=?, backdrop_url=?, detail_fetched_at=? WHERE id=?", [movie.title, movie.releaseYear, movie.durationSeconds, movie.rating, movie.genre, movie.overview, movie.posterURL, movie.backdropURL, Date(), movie.id]) }
        movie = try need(try c.catalog.movie(id: movie.id))
        if backdrop { try store("https://img.example/b/odyssey.jpg", .backdrop, cgImage(width: 1280, height: 720, hue: 0.06, poster: false), root: root) }
        if poster { try store("https://img.example/p/odyssey.jpg", .poster, cgImage(width: 400, height: 600, hue: 0.07, poster: true, label: "The Odyssey"), root: root) }
        let names = [("Matt Damon", "Odysseus"), ("Tom Holland", "Telemachus"), ("Anne Hathaway", "Penelope"), ("Robert Pattinson", "Antinous"), ("Himesh Patel", "Eurylochus"), ("Charlize Theron", "Circe"), ("Zendaya", "Athena"), ("Lupita Nyong'o", "Calypso")]
        var cast: [TitleDetails.Person] = []
        for (i, n) in names.enumerated() {
            let u = "https://img.example/c/\(i).jpg"
            try store(u, .poster, cgImage(width: 185, height: 278, hue: 0.1 * Double(i) + 0.02, poster: false), root: root)
            cast.append(.init(name: n.0, role: n.1, photoPath: u, tmdbID: 100 + i))
        }
        let td = TitleDetails(tmdbID: 77, isSeries: false, tagline: "Every road leads home.", overview: movie.overview, runtimeMinutes: 176, releaseDate: "2026-07-15", genres: ["Adventure", "Action", "Fantasy"], certification: "PG-13", rating: 8.0, votes: 900, seasons: nil, trailers: [.init(key: "abc", name: "Official Trailer", type: "Trailer")], cast: cast, makers: ["Christopher Nolan"], similar: [])
        try saveDetails(td, id: movie.id, c)

        var series = try need(try c.catalog.series(VODQuery(limit: 3)).first)
        series.title = "Harbor Lights"; series.releaseYear = 2024; series.rating = "8.4"; series.genre = "Drama, Mystery"
        series.overview = "Secrets surface in a small coastal town when the lighthouse keeper's last log is found, and every family on the harbour has a reason to want it kept shut."
        series.posterURL = poster ? "https://img.example/p/harbor.jpg" : nil; series.backdropURL = backdrop ? "https://img.example/b/harbor.jpg" : nil
        if backdrop { try store("https://img.example/b/harbor.jpg", .backdrop, cgImage(width: 1280, height: 720, hue: 0.55, poster: false), root: root) }
        if poster { try store("https://img.example/p/harbor.jpg", .poster, cgImage(width: 400, height: 600, hue: 0.56, poster: true, label: "Harbor Lights"), root: root) }
        try c.db.write { try $0.execute("UPDATE series SET title=?, release_year=?, rating=?, genre=?, overview=?, poster_url=?, backdrop_url=? WHERE id=?", [series.title, series.releaseYear, series.rating, series.genre, series.overview, series.posterURL, series.backdropURL, series.id]) }
        series = try need(try c.catalog.seriesItem(id: series.id))
        let seasons = (1...3).map { Season(id: "\(series.id)-s\($0)", seriesID: series.id, number: $0, name: "Season \($0)") }
        let titles = ["The Last Log", "Low Tide", "Salt and Iron", "What the Fog Kept", "Signal Fire", "Harbour Master", "Undertow", "The Keeper's Daughter"]
        var eps: [Episode] = []
        for s in seasons { for e in 1...8 { eps.append(Episode(id: "\(series.id)-s\(s.number)e\(e)", seriesID: series.id, seasonID: s.id, seasonNumber: s.number, providerEpisodeID: "\(s.number)\(e)", episodeNumber: e, title: titles[e - 1], overview: "The town gathers as new evidence comes ashore, and old alliances begin to give way.", imageURL: nil, durationSeconds: 2700 + Double(e) * 60, streamRef: "x\(s.number)\(e).mp4")) } }
        try c.indexer.saveSeriesDetail(SeriesDetail(series: series, seasons: seasons, episodes: eps, extras: nil))
        let stv = TitleDetails(tmdbID: 78, isSeries: true, tagline: nil, overview: series.overview, runtimeMinutes: 46, releaseDate: "2024-02-01", genres: ["Drama", "Mystery"], certification: "TV-MA", rating: 8.4, votes: 400, seasons: 3, trailers: [], cast: Array(cast.prefix(6)), makers: ["Mara Lindqvist"], similar: [])
        try saveDetails(stv, id: series.id, c)
        series = try need(try c.catalog.seriesItem(id: series.id))
        if progress {
            try c.historyRepo.saveProgress(WatchProgress(itemID: movie.id, kind: .movie, seriesID: nil, positionSeconds: 3900, durationSeconds: 10_560, updatedAt: Date(), completed: false))
            try c.historyRepo.saveProgress(WatchProgress(itemID: eps[9].id, kind: .episode, seriesID: series.id, positionSeconds: 1200, durationSeconds: 2820, updatedAt: Date(), completed: false))
            for e in eps.prefix(9) { try c.historyRepo.markWatched(itemID: e.id, kind: .episode, seriesID: series.id, duration: 2700) }
        }
        if hub {
            let store = HubStore(db: c.db)
            let logo = logoImage(text: "THE ODYSSEY")
            try store_(root, "https://img.example/l/odyssey.png", logo)
            store.put(movie.id, "logo", value: "https://img.example/l/odyssey.png", source: .tmdb, quality: 1, keep: 86400)
            let next = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 86400 + 3600))
            store.put(series.id, "nextepisode", value: next, source: .tvdb, quality: 1, keep: 86400)
        }
        let state = AppState(container: c, defaults: UserDefaults(suiteName: "tp-\(UUID().uuidString)")!)
        state.reload(); state.loaded = true
        return World(container: c, state: state, artwork: artwork, movie: movie, series: series, artworkRoot: root)
    }

    /// A transparent picture of a title in white type, like a clear logo.
    static func logoImage(text: String) -> CGImage {
        let w = 900, h = 260
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(in: CGRect(x: 10, y: 70, width: w - 20, height: 150), withAttributes: [.font: NSFont(name: "Georgia-Bold", size: 84) ?? NSFont.systemFont(ofSize: 84, weight: .black), .foregroundColor: NSColor(calibratedRed: 0.96, green: 0.85, blue: 0.6, alpha: 1), .kern: 4])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    static func store_(_ root: URL, _ url: String, _ img: CGImage) throws { try store(url, .backdrop, img, root: root) }

    static func saveDetails(_ d: TitleDetails, id: String, _ c: AppContainer) throws {
        let json = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
        try c.db.write { try $0.execute("INSERT OR REPLACE INTO title_details(item_id, json, fetched_at) VALUES(?,?,?)", [id, json, Date().timeIntervalSince1970]) }
    }
}

struct FixtureMissing: Error {}
func need<T>(_ v: T?) throws -> T { guard let v else { throw FixtureMissing() }; return v }
