import Testing
import SwiftUI
import AppKit
import ImageIO
@testable import REDDY

/// Opt-in smoothness bench. Set STREAMSETU_BENCH_DB to a read-only COPY of a library database (never the live one) and run with `--filter SmoothAuditBench`.
/// It prints timings and counts only, never titles, addresses or logins. Without the variable every test here is skipped.
@Suite("Smooth audit", .serialized, .enabled(if: ProcessInfo.processInfo.environment["STREAMSETU_BENCH_DB"] != nil))
@MainActor struct SmoothAuditBench {
    static func ms(_ f: () throws -> Void) rethrows -> Double { let t = CFAbsoluteTimeGetCurrent(); try f(); return (CFAbsoluteTimeGetCurrent() - t) * 1000 }
    static func msA(_ f: () async throws -> Void) async rethrows -> Double { let t = CFAbsoluteTimeGetCurrent(); try await f(); return (CFAbsoluteTimeGetCurrent() - t) * 1000 }
    func out(_ s: String) { print("SMOOTH " + s) }
    func pct(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))] }
    func fmt(_ x: Double) -> String { String(format: "%.1f", x) }

    func container() throws -> AppContainer {
        try AppContainer(databasePath: ProcessInfo.processInfo.environment["STREAMSETU_BENCH_DB"]!, credentials: InMemoryCredentialStore())
    }

    @Test func dataPaths() async throws {
        var c: AppContainer!
        let open = try Self.ms { c = try container() }
        out("container open+migrate: \(fmt(open)) ms")
        let sid: UUID? = nil
        let disc = c.discover, hist = c.history
        // Home data
        for run in 0..<3 {
            var smart: SmartMixHomeResult?
            let t1 = await Self.msA { smart = await c.smartMix.home(profile: c.profiles.activeID, sourceID: sid, preferredLanguage: c.settings.preferredAudioLanguage) }
            var shelves = 0, items = 0
            let sm = smart
            let t2 = await Self.msA { let b = await Task.detached { try? disc.build(sourceID: sid, smart: sm) }.value; shelves = b?.shelves.count ?? 0; items = b?.shelves.reduce(0) { $0 + $1.items.count } ?? 0 }
            let t3 = await Self.msA { _ = await Task.detached { (try? hist.continueWatching(limit: 12, sourceID: sid)) ?? [] }.value }
            out("home run\(run): smartMix.home \(fmt(t1)) ms | discover.build \(fmt(t2)) ms (shelves \(shelves), items \(items), smart \(smart == nil ? "nil" : "ok")) | continueWatching \(fmt(t3)) ms")
        }
        // Library page, folder rows
        let q = VODQuery(sourceID: sid, sort: .recentlyAdded, limit: 120)
        var n = 0
        out("movies page(120) recentlyAdded: \(fmt(try Self.ms { n = try c.catalog.movies(q).count })) ms rows \(n)")
        out("countMovies: \(fmt(try Self.ms { n = try c.catalog.countMovies(VODQuery(sourceID: sid)) })) ms total \(n)")
        for s in [VODSort.title, .rating, .year] {
            out("movies page sort \(s): \(fmt(try Self.ms { _ = try c.catalog.movies(VODQuery(sourceID: sid, sort: s, limit: 120)) })) ms")
        }
        out("movies offset 30000: \(fmt(try Self.ms { _ = try c.catalog.movies(VODQuery(sourceID: sid, sort: .recentlyAdded, limit: 120, offset: 30000)) })) ms")
        var cats: [CatalogCategory] = []
        out("categories(movie): \(fmt(try Self.ms { cats = try c.catalog.categories(sourceID: (try #require(try c.catalog.sources().first?.id)), kind: .movie, includeHidden: false) })) ms count \(cats.count)")
        let sourceID = try #require(try c.catalog.sources().first?.id)
        var tt: [Double] = []
        for cat in cats.prefix(12) { tt.append(try Self.ms { _ = try c.catalog.movies(VODQuery(sourceID: sourceID, categoryID: cat.id, sort: .recentlyAdded, limit: 12)) }) }
        out("folder row tiles (12 each, first 12 folders): p50 \(fmt(pct(tt, 0.5))) max \(fmt(tt.max() ?? 0)) ms")
    }

    @Test func searchLatency() async throws {
        let c = try container()
        let qs = ["a", "th", "the", "lo", "sta", "mar", "dark", "news", "2020", "zzqq"]
        _ = try? await c.globalSearch.search("warm")
        for q in qs {
            var total = 0.0, first = 0.0, counts = 0
            var ts: [Double] = []
            for _ in 0..<3 {
                let t = CFAbsoluteTimeGetCurrent()
                var firstSeen = false
                for try await u in c.globalSearch.updates(q) {
                    if !firstSeen { firstSeen = true; first = (CFAbsoluteTimeGetCurrent() - t) * 1000 }
                    counts = u.results.byKind.values.reduce(0) { $0 + $1.count }
                }
                ts.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            }
            total = ts.sorted()[1]
            out("search '\(q)': first stage \(fmt(first)) ms | final median \(fmt(total)) ms | results \(counts)")
        }
    }

    @Test func readerContention() async throws {
        let c = try container()
        let id = try #require(try c.catalog.movies(VODQuery(limit: 1)).first?.id)
        // idle PK read latency
        var idle: [Double] = []
        for _ in 0..<50 { idle.append(try Self.ms { _ = try c.catalog.movie(id: id) }) }
        // while a broad search runs in the background
        let sr = c.searchRepo
        let bg = Task.detached { for _ in 0..<6 { _ = try? sr.search(term: "a", filters: SearchFilters(kinds: [.movie], sourceID: nil), limit: 25) } }
        try await Task.sleep(nanoseconds: 30_000_000)
        var busy: [Double] = []
        for _ in 0..<20 { busy.append(try Self.ms { _ = try c.catalog.movie(id: id) }) }
        await bg.value
        out("PK read on main: idle p50 \(fmt(pct(idle, 0.5))) ms, max \(fmt(idle.max()!)) | while search('a') runs on the single reader: p50 \(fmt(pct(busy, 0.5))) ms, max \(fmt(busy.max()!)) ms")
    }

    @Test func tileCosts() throws {
        let c = try container()
        let movies = try c.catalog.movies(VODQuery(sort: .recentlyAdded, limit: 400))
        let items = movies.map { LibraryItem.movie($0) }
        var m = 0.0
        m = Self.ms { for it in items { _ = PosterCardModel(item: it) } }
        out("PosterCardModel init x\(items.count): \(fmt(m)) ms total, \(fmt(m * 1000 / Double(items.count))) us each (built in body per tile per re-eval)")
        m = Self.ms { for it in items { _ = MetadataNormalizer.normalize(it.title) } }
        out("MetadataNormalizer.normalize x\(items.count): \(fmt(m)) ms => \(fmt(m * 1000 / Double(items.count))) us each")
    }

    static func cg(width: Int, height: Int, hue: Double, poster: Bool, label: String?) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).cgColor, NSColor(hue: hue + 0.1, saturation: 0.8, brightness: 0.2, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [])
        var seed: UInt64 = 7
        for _ in 0..<400 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; ctx.setFillColor(CGColor(gray: CGFloat(seed >> 60) / 15, alpha: 0.5)); ctx.fill(CGRect(x: Int(seed >> 20) % width, y: Int(seed >> 40) % height, width: 40, height: 40)) }
        return ctx.makeImage()!
    }

    @Test func imagePipeline() async throws {
        // synthetic 1000x1500 poster as a JPEG
        let img = Self.cg(width: 1000, height: 1500, hue: 0.3, poster: true, label: "x")
        let data = try #require(ImageCache.encode(img))
        var times: [Double] = []
        for _ in 0..<20 { times.append(Self.ms { _ = ImageCache.decode(data, maxPixel: 400) }) }
        out("ImageCache.decode 1000x1500 -> 400px: p50 \(fmt(pct(times, 0.5))) ms, max \(fmt(times.max()!)) ms (jpeg \(data.count / 1024) KB)")
        // serialization on the actor: 60 distinct disk-cached posters requested at once
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smooth-img-\(UUID().uuidString)")
        let cache = ImageCache(root: root, http: HTTPClient())
        let small = try #require(ImageCache.encode(Self.cg(width: 400, height: 600, hue: 0.5, poster: true, label: "y")))
        var urls: [URL] = []
        for i in 0..<60 {
            let u = URL(string: "https://img.example/p/\(i).jpg")!
            let dir = root.appendingPathComponent(ArtworkKind.poster.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try small.write(to: dir.appendingPathComponent(ImageCache.key(u, .poster) + ".img")); urls.append(u)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        await withTaskGroup(of: Void.self) { g in for u in urls { g.addTask { _ = await cache.image(for: u, kind: .poster) } } }
        let cold = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let t1 = CFAbsoluteTimeGetCurrent()
        await withTaskGroup(of: Void.self) { g in for u in urls { g.addTask { _ = await cache.image(for: u, kind: .poster) } } }
        let warm = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        var one: [Double] = []
        for u in urls.prefix(30) { one.append(await Self.msA { _ = await cache.image(for: u, kind: .poster) }) }
        out("ImageCache 60 disk-cached posters concurrently (400x600 JPEG): cold(disk->decode) \(fmt(cold)) ms total = \(fmt(cold / 60)) ms/poster; memory-hit pass \(fmt(warm)) ms total; single memory-hit await p50 \(fmt(pct(one, 0.5))) ms")
        // pure parallel decode for comparison
        let t2 = CFAbsoluteTimeGetCurrent()
        await withTaskGroup(of: Void.self) { g in for _ in 0..<60 { g.addTask { _ = ImageCache.decode(small, maxPixel: 400) } } }
        out("same 60 decodes in parallel across cores: \(fmt((CFAbsoluteTimeGetCurrent() - t2) * 1000)) ms total")
    }
}
