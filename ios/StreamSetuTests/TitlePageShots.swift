import XCTest
import SwiftUI
import UIKit
@testable import StreamSetu

/// Opt-in screenshots of the title page (TITLE_SHOTS_DIR set): a movie and a series built from made-up data, drawn in a real window at the device's size.
@MainActor final class TitlePageShots: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["TITLE_SHOTS_DIR"] ?? (try? String(contentsOfFile: "/tmp/title-shots-dir.txt", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func image(_ w: Int, _ h: Int, hue: CGFloat, label: String? = nil) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        func c(_ x: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CGColor { UIColor(hue: x.truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1).cgColor }
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c(hue, 0.7, 0.85), c(hue + 0.06, 0.8, 0.45), c(hue + 0.12, 0.7, 0.12)] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
        ctx.setFillColor(UIColor(white: 1, alpha: 0.8).cgColor)
        let r = CGFloat(min(w, h)) * 0.2
        ctx.fillEllipse(in: CGRect(x: CGFloat(w) * 0.62 - r, y: CGFloat(h) * 0.58 - r, width: 2 * r, height: 2 * r))
        ctx.setFillColor(UIColor(white: 0.04, alpha: 0.9).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h) * 0.18))
        return ctx.makeImage()!
    }

    private func store(_ url: String, _ kind: ArtworkKind, _ img: CGImage, _ root: URL) throws {
        let d = root.appendingPathComponent(kind.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try XCTUnwrap(ImageCache.encode(img)).write(to: d.appendingPathComponent(ImageCache.key(URL(string: url)!, kind) + ".img"))
    }

    func testShots() async throws {
        guard let out = dir else { throw XCTSkip("TITLE_SHOTS_DIR not set") }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let c = try AppContainer(databasePath: NSTemporaryDirectory() + "title-shots-\(UUID().uuidString).sqlite", credentials: InMemoryCredentialStore())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("title-shots-art-\(UUID().uuidString)")
        let artwork = ArtworkService(cache: ImageCache(root: root, http: HTTPClient()))
        let src = PlaylistSource(name: "Demo", type: .xtream, baseURL: "http://provider.example:8080", lastSync: Date(), syncStatus: "completed", capabilities: SourceCapabilities(live: false, movies: true, series: true, epg: false))
        try c.catalog.save(source: src); try c.catalog.saveCapabilities(src.capabilities, sourceID: src.id)
        let mcat = CatalogCategory(id: "cat-m", sourceID: src.id, kind: .movie, providerID: "m", name: "Featured Picks", sortOrder: 0)
        let scat = CatalogCategory(id: "cat-s", sourceID: src.id, kind: .series, providerID: "s", name: "Drama Series", sortOrder: 0)
        let mid = ItemID.make(source: src.id, kind: .movie, provider: "m1"), sid = ItemID.make(source: src.id, kind: .series, provider: "s1")
        let story = "Odysseus, the legendary King of Ithaca, embarks on a long and perilous journey home following the Trojan War. Throughout his voyage, he is forced to confront the whims of gods, mythological monsters, and trials that stretch beyond the limits of any mortal."
        let movie = Movie(id: mid, sourceID: src.id, providerID: "m1", title: "The Odyssey", normalizedTitle: "the odyssey", overview: story, posterURL: "https://img.example/p/o.jpg", backdropURL: "https://img.example/b/o.jpg", releaseYear: 2026,
                          durationSeconds: 10_560, genre: "Adventure, Action, Fantasy", rating: "8.0", categoryID: mcat.id, categoryName: mcat.name, streamRef: "m1.mp4", addedAt: Date(), detailFetchedAt: Date())
        let series = Series(id: sid, sourceID: src.id, providerID: "s1", title: "Harbor Lights", normalizedTitle: "harbor lights", overview: "Secrets surface in a small coastal town when the lighthouse keeper's last log is found, and every family on the harbour has a reason to want it kept shut.",
                            posterURL: "https://img.example/p/h.jpg", backdropURL: "https://img.example/b/h.jpg", genre: "Drama, Mystery", releaseYear: 2024, rating: "8.4", categoryID: scat.id, categoryName: scat.name, addedAt: Date(), lastMetadataRefresh: Date())
        try c.indexer.commitMovies(source: src, categories: [mcat], movies: [movie])
        try c.indexer.commitSeries(source: src, categories: [scat], series: [series])
        try store("https://img.example/b/o.jpg", .backdrop, image(1280, 720, hue: 0.06), root); try store("https://img.example/p/o.jpg", .poster, image(400, 600, hue: 0.07), root)
        try store("https://img.example/b/h.jpg", .backdrop, image(1280, 720, hue: 0.55), root); try store("https://img.example/p/h.jpg", .poster, image(400, 600, hue: 0.56), root)
        var cast: [TitleDetails.Person] = []
        for (i, n) in [("Matt Damon", "Odysseus"), ("Tom Holland", "Telemachus"), ("Anne Hathaway", "Penelope"), ("Robert Pattinson", "Antinous"), ("Himesh Patel", "Eurylochus"), ("Charlize Theron", "Circe")].enumerated() {
            let u = "https://img.example/c/\(i).jpg"; try store(u, .poster, image(185, 278, hue: 0.1 * CGFloat(i) + 0.02), root)
            cast.append(.init(name: n.0, role: n.1, photoPath: u, tmdbID: 100 + i))
        }
        func save(_ d: TitleDetails, _ id: String) throws {
            let json = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
            try c.db.write { try $0.execute("INSERT OR REPLACE INTO title_details(item_id, json, fetched_at) VALUES(?,?,?)", [id, json, Date().timeIntervalSince1970]) }
        }
        try save(TitleDetails(tmdbID: 77, isSeries: false, tagline: "Every road leads home.", overview: story, runtimeMinutes: 176, releaseDate: "2026-07-15", genres: ["Adventure", "Action", "Fantasy"], certification: "PG-13", rating: 8.0, votes: 900, seasons: nil, trailers: [.init(key: "abc", name: "Official Trailer", type: "Trailer")], cast: cast, makers: ["Christopher Nolan"], similar: []), mid)
        try save(TitleDetails(tmdbID: 78, isSeries: true, tagline: nil, overview: series.overview, runtimeMinutes: 46, releaseDate: "2024-02-01", genres: ["Drama", "Mystery"], certification: "TV-MA", rating: 8.4, votes: 400, seasons: 3, trailers: [], cast: cast, makers: ["Mara Lindqvist"], similar: []), sid)
        let seasons = (1...3).map { Season(id: "\(sid)-s\($0)", seriesID: sid, number: $0, name: "Season \($0)") }
        let names = ["The Last Log", "Low Tide", "Salt and Iron", "What the Fog Kept", "Signal Fire", "Harbour Master"]
        var eps: [Episode] = []
        for s in seasons { for e in 1...6 { eps.append(Episode(id: "\(sid)-s\(s.number)e\(e)", seriesID: sid, seasonID: s.id, seasonNumber: s.number, providerEpisodeID: "\(s.number)\(e)", episodeNumber: e, title: names[e - 1], overview: "The town gathers as new evidence comes ashore, and old alliances begin to give way.", imageURL: nil, durationSeconds: 2700 + Double(e) * 60, streamRef: "x\(s.number)\(e).mp4")) } }
        try c.indexer.saveSeriesDetail(SeriesDetail(series: series, seasons: seasons, episodes: eps, extras: nil))
        try c.historyRepo.saveProgress(WatchProgress(itemID: mid, kind: .movie, seriesID: nil, positionSeconds: 3900, durationSeconds: 10_560, updatedAt: Date(), completed: false))
        for e in eps.prefix(7) { try c.historyRepo.markWatched(itemID: e.id, kind: .episode, seriesID: sid, duration: 2700) }
        try c.historyRepo.saveProgress(WatchProgress(itemID: eps[7].id, kind: .episode, seriesID: sid, positionSeconds: 1200, durationSeconds: 2820, updatedAt: Date(), completed: false))
        // a series whose provider sent no picture at all, with raw episode names (the first episode's picture is all there is)
        let rid = ItemID.make(source: src.id, kind: .series, provider: "s2")
        let bare = Series(id: rid, sourceID: src.id, providerID: "s2", title: "Murder in Mahim", normalizedTitle: "murder in mahim", overview: "A veteran journalist is drawn into a string of killings in Mumbai's oldest quarter.",
                          posterURL: nil, backdropURL: nil, genre: "Crime, Thriller", releaseYear: 2024, rating: "7.9", categoryID: scat.id, categoryName: scat.name, addedAt: Date(), lastMetadataRefresh: Date())
        try c.indexer.commitSeries(source: src, categories: [scat], series: [series, bare])
        for k in [ArtworkKind.still, .poster, .backdrop] { try store("https://img.example/e/1.jpg", k, image(640, 360, hue: 0.0), root) }
        let rseason = Season(id: "\(rid)-s1", seriesID: rid, number: 1, name: "Season 1")
        let reps = (1...4).map { Episode(id: "\(rid)-e\($0)", seriesID: rid, seasonID: rseason.id, seasonNumber: 1, providerEpisodeID: "\($0)", episodeNumber: $0, title: "Murder in Mahim (Telugu) - S01E0\($0) -", overview: nil, imageURL: "https://img.example/e/1.jpg", durationSeconds: 2400, streamRef: "r\($0).mp4") }
        try c.indexer.saveSeriesDetail(SeriesDetail(series: bare, seasons: [rseason], episodes: reps, extras: nil))
        let state = AppState(container: c)
        await state.start()

        let tag = ProcessInfo.processInfo.environment["TITLE_SHOTS_TAG"] ?? (try? String(contentsOfFile: "/tmp/title-shots-tag.txt", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "shot"
        let themes: [AppTheme] = [.cinematic, .liquidGlass, .dracula]
        for theme in themes {
            c.settings.theme = theme
            for (name, item) in [("movie", LibraryItem.movie(movie)), ("series", .series(series)), ("bareseries", .series(bare))] {
                let root = NavigationStack { DetailView(item: item).id(item.id).titleAndPersonDestinations() }
                    .environment(c.settings).environment(state).environment(IOSRouter()).environment(\.container, c).environment(\.artwork, artwork)
                    .background(ColorTokens.background)
                let host = UIHostingController(rootView: root)
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds; window.windowLevel = .alert + 100; window.backgroundColor = .black
                window.rootViewController = host; window.makeKeyAndVisible()
                try await Task.sleep(nanoseconds: 1_800_000_000)
                for step in 0..<2 {
                    if step == 1 { // scrolled: find the scroll view and move it
                        func scroll(_ v: UIView) -> UIScrollView? { if let s = v as? UIScrollView, s.contentSize.height > s.bounds.height { return s }; for x in v.subviews { if let r = scroll(x) { return r } }; return nil }
                        if let s = scroll(host.view) { s.setContentOffset(CGPoint(x: 0, y: min(s.contentSize.height - s.bounds.height, 700)), animated: false) }
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    let img = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    try XCTUnwrap(img.pngData()).write(to: URL(fileURLWithPath: "\(out)/\(tag)-\(name)-\(theme.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))-\(step).png"))
                }
                window.isHidden = true
            }
        }
    }
}
