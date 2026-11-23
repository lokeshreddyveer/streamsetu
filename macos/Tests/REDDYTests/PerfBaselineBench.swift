import Testing
import SwiftUI
import AppKit
import Foundation
@testable import REDDY

extension Tag { @Tag static var perfBench: Self }

/// Opt-in performance baseline: `PERF_BENCH=1 swift test --filter PerfBaselineBench`. Everything is skipped unless PERF_BENCH=1.
/// Synthetic fixtures only (20,000 films, 5,000 series, 3,000 channels with a guide); no real library, session or key is read.
/// Writes `perf-results.json` into PERF_OUT (default: a folder in the temporary directory) and prints one `PERF` line per number.
/// Limits: debug build unless run with `-c release`; this process's file cache is warm after the seed, so "cold" means the first call after the database was opened, not a cold disk.
@Suite("Perf baseline (opt-in)", .serialized, .tags(.perfBench), .enabled(if: ProcessInfo.processInfo.environment["PERF_BENCH"] == "1"))
@MainActor struct PerfBaselineBench {
    static let runs = Int(ProcessInfo.processInfo.environment["PERF_RUNS"] ?? "") ?? 25
    static let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PERF_OUT"] ?? NSTemporaryDirectory() + "perf-bench", isDirectory: true)
    static var results: [String: Any] = [:]
    static var world: World?

    struct World { let c: AppContainer; let state: AppState; let artwork: ArtworkService; let src: PlaylistSource; let dbPath: String; let artRoot: URL }

    // MARK: helpers
    nonisolated static func pump(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
    static func ms(_ f: () throws -> Void) rethrows -> Double { let t = CFAbsoluteTimeGetCurrent(); try f(); return (CFAbsoluteTimeGetCurrent() - t) * 1000 }
    static func msA(_ f: () async throws -> Void) async rethrows -> Double { let t = CFAbsoluteTimeGetCurrent(); try await f(); return (CFAbsoluteTimeGetCurrent() - t) * 1000 }
    static func pct(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int((Double(s.count) * p).rounded(.down)))] }
    static func stats(_ a: [Double]) -> [String: Double] {
        let warm = Array(a.dropFirst())
        return ["n": Double(a.count), "cold_ms": a.first ?? 0, "warm_median_ms": pct(warm, 0.5), "warm_p95_ms": pct(warm, 0.95), "warm_min_ms": warm.min() ?? 0, "warm_max_ms": warm.max() ?? 0, "all_median_ms": pct(a, 0.5), "all_p95_ms": pct(a, 0.95)]
    }
    static func record(_ section: String, _ key: String, _ value: [String: Double]) {
        var s = (results[section] as? [String: Any]) ?? [:]; s[key] = value; results[section] = s
        print("PERF \(section)/\(key): " + value.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.joined(separator: " "))
        flush()
    }
    static func flush() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: outDir.appendingPathComponent("perf-results.json")) }
    }
    static func timed(_ n: Int = runs, _ f: () throws -> Void) rethrows -> [Double] { var r: [Double] = []; for _ in 0..<n { r.append(try ms(f)) }; return r }

    static let words = ["Last", "Midnight", "Iron", "Echo", "Silent", "Neon", "Paper", "Harvest", "Crimson", "Harbor", "Golden", "Winter", "Shadow", "River", "Storm", "Garden", "Broken", "Hidden", "Final", "Lost", "The", "Of", "Night", "Road", "Empire", "Signal", "Glass", "Wild", "Northern", "Island"]
    static let langs = ["English", "Hindi", "Telugu", "Tamil", "Korean", "Spanish"]
    static func title(_ i: Int) -> String { "The \(words[i % 30]) \(words[(i / 30 + 7) % 30]) \(i % 977) (\(langs[i % 6]))" }

    /// Builds (once per process) the synthetic library: seeded, deterministic, no network.
    static func makeWorld() throws -> World {
        if let w = world { return w }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("perf-bench-\(UUID().uuidString).sqlite").path
        let c = try AppContainer(databasePath: path, credentials: InMemoryCredentialStore())
        let src = PlaylistSource(name: "Synthetic", type: .xtream, baseURL: "http://provider.example:8080", lastSync: Date().addingTimeInterval(-3600), syncStatus: "completed", capabilities: SourceCapabilities(live: true, movies: true, series: true, epg: true))
        try c.catalog.save(source: src); try c.catalog.saveCapabilities(src.capabilities, sourceID: src.id)
        let t0 = CFAbsoluteTimeGetCurrent()
        let mcats = (0..<60).map { FixtureLibrary.category(src, .movie, "MOVIES \($0)", $0) }
        let scats = (0..<40).map { FixtureLibrary.category(src, .series, "SERIES \($0)", $0) }
        let ccats = (0..<50).map { FixtureLibrary.category(src, .channel, "LIVE \($0)", $0) }
        let genres = ["Drama", "Action", "Comedy", "Thriller", "Sci-Fi", "Documentary", "Family"]
        let movies: [Movie] = (0..<20_000).map { i in
            var m = TestSupport.movie(src, "m\(i)", title(i), year: 1975 + i % 50)
            m.categoryID = mcats[i % 60].id; m.categoryName = mcats[i % 60].name; m.genre = genres[i % 7]; m.rating = String(format: "%.1f", 3.0 + Double(i % 70) / 10)
            m.durationSeconds = 4800 + Double(i % 90) * 60; m.overview = "A synthetic summary."; m.posterURL = i % 20 == 0 ? nil : "https://img.example/p/\(i % 400).jpg"
            m.addedAt = Date().addingTimeInterval(-Double(20_000 - i) * 3_000); return m }
        _ = try c.indexer.commitMovies(source: src, categories: mcats, movies: movies)
        let shows: [Series] = (0..<5_000).map { i in
            var s = TestSupport.series(src, "s\(i)", title(i + 3)); s.categoryID = scats[i % 40].id; s.categoryName = scats[i % 40].name
            s.genre = genres[i % 7]; s.releaseYear = 1985 + i % 40; s.rating = String(format: "%.1f", 4.0 + Double(i % 55) / 10); s.overview = "A synthetic summary."
            s.posterURL = "https://img.example/p/\(i % 400).jpg"; s.addedAt = Date().addingTimeInterval(-Double(5_000 - i) * 9_000); return s }
        _ = try c.indexer.commitSeries(source: src, categories: scats, series: shows)
        let chans: [Channel] = (0..<3_000).map { i in var ch = TestSupport.channel(src, "c\(i)", "\(words[i % 30]) \(words[(i / 30) % 30]) HD \(i)", cat: nil, order: i, epg: "ch\(i)"); ch.categoryID = ccats[i % 50].id; ch.categoryName = ccats[i % 50].name; return ch }
        _ = try c.indexer.commitChannels(source: src, categories: ccats, channels: chans)
        let now = Date().timeIntervalSince1970, sid = src.id.uuidString.lowercased()
        try c.db.write { db in
            for i in 0..<3_000 { for k in -6..<18 {   // 24 programmes per channel: 6 past, 18 ahead, 30 min each
                let s = now - 900 + Double(k) * 1800
                try db.execute("INSERT INTO epg_programs(source_id,xmltv_channel_id,start_time,end_time,title,description,import_id) VALUES(?,?,?,?,?,?,0)", [sid, "ch\(i)", s, s + 1800, "Show \(i % 211) part \(k)", "Synthetic description"])
            } }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf-bench-art-\(UUID().uuidString)")
        let art = ArtworkService(cache: ImageCache(root: root, http: HTTPClient()))
        let state = AppState(container: c, defaults: UserDefaults(suiteName: "perf-\(UUID().uuidString)")!)
        state.reload(); state.loaded = true
        let w = World(c: c, state: state, artwork: art, src: src, dbPath: path, artRoot: root); world = w
        let sizeMB = ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) / 1_048_576
        record("fixture", "seed", ["movies": 20000, "series": 5000, "channels": 3000, "epg_rows": 72000, "seed_seconds": CFAbsoluteTimeGetCurrent() - t0, "db_mb": Double(sizeMB)])
        return w
    }

    // MARK: 1. catalog filter / sort / search
    @Test func catalog() throws {
        let w = try Self.makeWorld(); let c = w.c, sid = w.src.id
        let mfolder = try #require(try c.catalog.categories(sourceID: sid, kind: .movie, includeHidden: false).first).id
        let sfolder = try #require(try c.catalog.categories(sourceID: sid, kind: .series, includeHidden: false).first).id
        func q(_ f: (inout VODQuery) -> Void = { _ in }) -> VODQuery { var x = VODQuery(sourceID: sid, sort: .recentlyAdded, limit: 120); f(&x); return x }
        let movieCases: [(String, VODQuery)] = [
            ("movies page120 recentlyAdded", q()), ("movies page120 titleAZ", q { $0.sort = .title }), ("movies page120 titleZA", q { $0.sort = .titleDescending }),
            ("movies page120 year", q { $0.sort = .year }), ("movies page120 rating", q { $0.sort = .rating }), ("movies page120 durationShortest", q { $0.sort = .durationShortest }),
            ("movies page120 offset 10000", q { $0.offset = 10_000 }), ("movies folder page120", q { $0.categoryID = mfolder }),
            ("movies search 'the' (common)", q { $0.search = "the" }), ("movies search 'iron harbor' (2 words)", q { $0.search = "iron harbor" }), ("movies search 'zzqx' (miss)", q { $0.search = "zzqx" }),
            ("movies filter language+decade", q { $0.language = "Telugu"; $0.decade = 2010 }), ("movies filter genres+minRating", q { $0.genres = ["Drama", "Action"]; $0.minRating = 6.0; $0.sort = .rating }),
            ("movies unwatchedOnly", q { $0.unwatchedOnly = true }), ("movies addedWithinDays 30", q { $0.addedWithinDays = 30 }),
        ]
        _ = try c.catalog.movies(q { $0.limit = 1 })   // opens nothing new; lets the first case be the first real page read
        for (name, qq) in movieCases { var rows = 0; var st = Self.stats(try Self.timed { rows = try c.catalog.movies(qq).count }); st["rows"] = Double(rows); Self.record("catalog", name, st) }
        for (name, qq) in [("movies count all", q()), ("movies count search 'the'", q { $0.search = "the" }), ("movies count filter", q { $0.language = "Telugu"; $0.decade = 2010 })] { Self.record("catalog", name, Self.stats(try Self.timed { _ = try c.catalog.countMovies(qq) })) }
        for (name, qq) in [("series page120 recentlyAdded", q()), ("series page120 titleAZ", q { $0.sort = .title }), ("series search 'the'", q { $0.search = "the" }), ("series folder page120", q { $0.categoryID = sfolder })] { var rows = 0; var st = Self.stats(try Self.timed { rows = try c.catalog.series(qq).count }); st["rows"] = Double(rows); Self.record("catalog", name, st) }
        Self.record("catalog", "series count all", Self.stats(try Self.timed { _ = try c.catalog.countSeries(q()) }))
        Self.record("catalog", "metadataCoverage(movie)", Self.stats(try Self.timed { _ = try c.catalog.metadataCoverage(kind: .movie, sourceID: sid) }))
        Self.record("catalog", "filterOptions(movie)", Self.stats(try Self.timed { _ = try c.catalog.filterOptions(sourceID: sid, kind: .movie) }))
        Self.record("catalog", "AppState.reload (visibleCounts+favorites)", Self.stats(try Self.timed(10) { w.state.reload() }))
        Self.record("catalog", "AppState.reloadWatched (main-thread part only; the scan runs off main)", Self.stats(try Self.timed(10) { w.state.reloadWatched() }))
    }

    /// The whole work a Movies/Series tab visit starts: a brand-new view model's first load (coverage + options + page + count), which is what every revisit pays because screens are rebuilt.
    @Test func libraryFirstLoad() async throws {
        let w = try Self.makeWorld()
        for kind in [ContentKind.movie, .series] {
            var t: [Double] = []
            for _ in 0..<Self.runs { let vm = LibraryBrowserViewModel(kind: kind); t.append(await Self.msA { await vm.reset(w.c, selection: AppRouter.defaultSelection(for: kind == .movie ? .movies : .series), source: w.src.id) }) }
            Self.record("library_first_load", kind == .movie ? "movies new VM reset (to items set)" : "series new VM reset (to items set)", Self.stats(t))
            var ts: [Double] = []
            for _ in 0..<Self.runs { let vm = LibraryBrowserViewModel(kind: kind); vm.search = "the"; ts.append(await Self.msA { await vm.reset(w.c, selection: AppRouter.defaultSelection(for: kind == .movie ? .movies : .series), source: w.src.id) }) }
            Self.record("library_first_load", (kind == .movie ? "movies" : "series") + " new VM reset with search 'the'", Self.stats(ts))
        }
    }

    // MARK: 2. global search
    @Test func globalSearch() async throws {
        let w = try Self.makeWorld()
        for term in ["t", "th", "the", "the last", "iron harbor", "zzqx", "2020"] {
            var t: [Double] = []; var n = 0
            for _ in 0..<Self.runs { t.append(await Self.msA { n = (try? await w.c.globalSearch.search(term).byKind.values.reduce(0) { $0 + $1.count }) ?? -1 }) }
            var s = Self.stats(t); s["results"] = Double(n); Self.record("global_search", "'\(term)'", s)
        }
    }

    // MARK: 3. images
    @Test func images() async throws {
        let n = 300
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf-img-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(root: root, http: HTTPClient())
        // 1000x1500 JPEG: a typical provider poster; real ones are often larger.
        let big = TitlePageFixture.cgImage(width: 1000, height: 1500, hue: 0.3, poster: true, label: "Synthetic")
        let data = try #require(ImageCache.encode(big))
        let dir = root.appendingPathComponent(ArtworkKind.poster.rawValue, isDirectory: true); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for i in 0..<n { let u = URL(string: "https://img.example/p/\(i).jpg")!; try data.write(to: dir.appendingPathComponent(ImageCache.key(u, .poster) + ".img")); urls.append(u) }
        // pure decode+downsample, one thread
        var decodeT: [Double] = []
        for _ in 0..<60 { decodeT.append(Self.ms { _ = ImageCache.decode(data, maxPixel: ArtworkKind.poster.maxPixel) }) }
        var s = Self.stats(decodeT); s["source_bytes"] = Double(data.count); s["source_px"] = 1000 * 1500; s["maxPixel"] = Double(ArtworkKind.poster.maxPixel)
        s["single_thread_images_per_s"] = 1000 / max(Self.pct(decodeT, 0.5), 0.001); Self.record("images", "decode+downsample poster (1 thread)", s)
        // cold disk->memory through the cache, concurrently, like a grid appearing
        Perf.resetCounters(); Perf.collecting = true; defer { Perf.collecting = false }
        let t0 = CFAbsoluteTimeGetCurrent()
        await withTaskGroup(of: Void.self) { g in for u in urls { g.addTask { _ = await cache.image(for: u, kind: .poster) } }; await g.waitForAll() }
        let coldWall = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let coldDecodes = Perf.counts()["imageDecode"] ?? 0
        Self.record("images", "cold load \(n) distinct posters via cache (disk->decode)", ["wall_ms": coldWall, "images_per_s": Double(n) / (coldWall / 1000), "decodes": Double(coldDecodes)])
        // warm memory hits
        var hit = 0; let tw = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 { for u in urls where cache.cachedImage(for: u, kind: .poster) != nil { hit += 1 } }
        let warmNs = (CFAbsoluteTimeGetCurrent() - tw) * 1e9 / Double(max(hit, 1))
        Self.record("images", "warm memory hit (cachedImage)", ["hits": Double(hit), "of": Double(n * 20), "ns_per_hit": warmNs])
        // dedupe: 40 askers for each of 50 new urls -> expect 50 decodes
        let root2 = FileManager.default.temporaryDirectory.appendingPathComponent("perf-img-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: root2) }
        let cache2 = ImageCache(root: root2, http: HTTPClient()); let dir2 = root2.appendingPathComponent(ArtworkKind.poster.rawValue, isDirectory: true); try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        for i in 0..<50 { try data.write(to: dir2.appendingPathComponent(ImageCache.key(urls[i], .poster) + ".img")) }
        Perf.resetCounters()
        await withTaskGroup(of: Void.self) { g in for _ in 0..<40 { for u in urls.prefix(50) { g.addTask { _ = await cache2.image(for: u, kind: .poster) } } }; await g.waitForAll() }
        Self.record("images", "dedupe 2000 asks for 50 urls", ["asks": 2000, "distinct": 50, "decodes": Double(Perf.counts()["imageDecode"] ?? 0)])
        // decoded size in memory
        if let img = cache.cachedImage(for: urls[0], kind: .poster) { Self.record("images", "decoded poster in memory", ["w": Double(img.width), "h": Double(img.height), "bytes": Double(img.bytesPerRow * img.height)]) }
    }

    // MARK: 4. DB on the main thread
    @Test func mainThreadDatabase() async throws {
        let w = try Self.makeWorld(); let sid = w.src.id
        Perf.resetCounters(); Perf.collecting = true; defer { Perf.collecting = false }
        for _ in 0..<Self.runs {
            _ = try w.c.catalog.movies(VODQuery(sourceID: sid, sort: .recentlyAdded, limit: 120))
            w.state.reload(); w.state.reloadWatched()
            try w.c.db.write { try $0.execute("UPDATE movies SET rating = rating WHERE source_id = ? AND provider_id = 'm1'", [sid.uuidString.lowercased()]) }
        }
        let m = Perf.mainTimes()
        for (k, v) in m { var s = Self.stats(v); s["calls"] = Double(v.count); s["total_ms"] = v.reduce(0, +); Self.record("main_thread_db", "\(k) called from main (a query page, reload, reloadWatched, a write)", s) }
        // container construction on an already populated database = what a relaunch does on the main actor
        var open: [Double] = []
        for _ in 0..<5 { open.append(try Self.ms { _ = try AppContainer(databasePath: w.dbPath, credentials: InMemoryCredentialStore()) }) }
        Self.record("startup", "AppContainer init on populated DB (main actor, includes migrations check, token cleanup, privacy purge)", Self.stats(open))
        var boot: [Double] = []
        for _ in 0..<5 { let st = AppState(container: w.c, defaults: UserDefaults(suiteName: "perf-\(UUID().uuidString)")!); boot.append(await Self.msA { await st.start() }) }
        Self.record("startup", "AppState.start() to loaded (reload on main + observers)", Self.stats(boot))
        // guide hub refresh pass with nothing due (signpost GuideHubRefresh)
        var hub: [Double] = []
        for _ in 0..<5 { hub.append(await Self.msA { _ = await w.c.runGuideHub() }) }
        Self.record("guide_hub", "runGuideHub pass, nothing due", Self.stats(hub))
    }

    // MARK: 5. tab switch: how many times heavy screens are rebuilt
    @Test func tabSwitch() async throws {
        let w = try Self.makeWorld(); _ = NSApplication.shared
        UserDefaults.standard.set(true, forKey: "settings.reducemotion"); defer { UserDefaults.standard.removeObject(forKey: "settings.reducemotion") }
        let router = AppRouter(); router.navigate(.home, nil)
        let view = ContentRouter().environment(w.state).environment(router).environment(\.container, w.c).environment(\.artwork, w.artwork).environment(w.c.settings).reddyTheme(w.c.settings).background(ColorTokens.background)
        let size = CGSize(width: 1100, height: 760)
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height))); host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: 12 - size.width, y: 40)); win.orderFrontRegardless()
        func pump(_ s: Double) async { let end = CFAbsoluteTimeGetCurrent() + s; while CFAbsoluteTimeGetCurrent() < end { try? await Task.sleep(nanoseconds: 5_000_000); Self.pump(0.001) } }
        host.layoutSubtreeIfNeeded(); await pump(1.5)
        Perf.resetCounters(); Perf.collecting = true; defer { Perf.collecting = false }
        let seq: [AppTab] = [.movies, .home, .movies, .series, .movies, .liveTV, .guide, .home, .movies, .guide, .liveTV, .series]
        var perTab: [String: [Double]] = [:], blocked: [Double] = [], vmBuilt: [String: Int] = [:], syncBodies: [String: [Double]] = [:], parts: [String: [Double]] = [:], gapTab: [String: [Double]] = [:]
        for tab in seq + seq {
            let before = Perf.counts()
            let t0 = CFAbsoluteTimeGetCurrent()
            router.navigate(tab, nil); let tN = CFAbsoluteTimeGetCurrent(); host.layoutSubtreeIfNeeded(); let tL = CFAbsoluteTimeGetCurrent(); host.displayIfNeeded(); let tD = CFAbsoluteTimeGetCurrent()
            parts["\(tab)/navigate", default: []].append((tN - t0) * 1000); parts["\(tab)/layout", default: []].append((tL - tN) * 1000); parts["\(tab)/display", default: []].append((tD - tL) * 1000)
            let sync = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            let inSync = Perf.counts()
            for (k, v) in inSync where k.hasSuffix("Body") { syncBodies["\(tab)/\(k)", default: []].append(Double(v - (before[k] ?? 0))) }
            var worst = 0.0, last = CFAbsoluteTimeGetCurrent(); let end = last + 0.6
            while CFAbsoluteTimeGetCurrent() < end { try? await Task.sleep(nanoseconds: 2_000_000); Self.pump(0.001); let now = CFAbsoluteTimeGetCurrent(); worst = max(worst, (now - last) * 1000); last = now }
            perTab["\(tab)", default: []].append(sync); blocked.append(worst); gapTab["\(tab)", default: []].append(worst)
            let after = Perf.counts()
            for (k, v) in after { vmBuilt["\(tab)/\(k)", default: 0] += v - (before[k] ?? 0) }
        }
        for (t, v) in perTab { Self.record("tab_switch", "to \(t): sync build+layout on main", Self.stats(v)) }
        Self.record("tab_switch", "longest run-loop gap in 0.6 s after a switch", Self.stats(blocked))
        for (k, v) in gapTab.sorted(by: { $0.key < $1.key }) { Self.record("tab_switch_gap_by_tab", k, Self.stats(v)); Self.record("tab_switch_gap_by_tab", k + " (all samples)", v.enumerated().reduce(into: [String: Double]()) { $0["s\($1.offset)"] = $1.element }) }
        for (k, v) in parts.sorted(by: { $0.key < $1.key }) { Self.record("tab_switch_parts", k, Self.stats(v)) }
        for (k, v) in syncBodies.sorted(by: { $0.key < $1.key }) { Self.record("tab_switch_bodies_in_sync_window", k, Self.stats(v)) }
        let total = Perf.counts(); Self.record("tab_switch", "screen models constructed over \(seq.count * 2) switches", total.mapValues { Double($0) })
        for (k, v) in vmBuilt.sorted(by: { $0.key < $1.key }) where v > 0 { Self.record("tab_switch_models_per_destination", k, ["constructed_in_total": Double(v)]) }
        win.orderOut(nil)
    }

    // MARK: 6. return to Movies/Series: retained model against a cleared one (old behaviour), same code, same build
    @Test func returnToTab() async throws {
        let w = try Self.makeWorld(); _ = NSApplication.shared
        UserDefaults.standard.set(true, forKey: "settings.reducemotion"); defer { UserDefaults.standard.removeObject(forKey: "settings.reducemotion") }
        let router = AppRouter(); router.navigate(.home, nil)
        let view = ContentRouter().environment(w.state).environment(router).environment(\.container, w.c).environment(\.artwork, w.artwork).environment(w.c.settings).reddyTheme(w.c.settings).background(ColorTokens.background)
        let size = CGSize(width: 1100, height: 760)
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height))); host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: 12 - size.width, y: 40)); win.orderFrontRegardless()
        func pump(_ s: Double) async { let end = CFAbsoluteTimeGetCurrent() + s; while CFAbsoluteTimeGetCurrent() < end { try? await Task.sleep(nanoseconds: 5_000_000); Self.pump(0.001) } }
        host.layoutSubtreeIfNeeded(); await pump(1.5)
        Perf.resetCounters(); Perf.collecting = true; defer { Perf.collecting = false }
        for tab in [AppTab.movies, .series] {
            for mode in ["retained", "cleared (old behaviour)"] {
                var sync: [Double] = [], gaps: [Double] = [], busy: [Double] = [], tileBodies: [Double] = [], syncTileBodies: [Double] = []
                for i in 0..<8 {
                    router.navigate(.home, nil); host.layoutSubtreeIfNeeded(); await pump(0.5)
                    if mode != "retained" { w.c.screens.clear() }
                    let b0 = Perf.counts()["TileBody"] ?? 0
                    let t0 = CFAbsoluteTimeGetCurrent()
                    router.navigate(tab, nil); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    let s0 = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    let b1 = Perf.counts()["TileBody"] ?? 0
                    var worst = 0.0, total = 0.0, last = CFAbsoluteTimeGetCurrent(); let end = last + 0.8
                    while CFAbsoluteTimeGetCurrent() < end { try? await Task.sleep(nanoseconds: 2_000_000); Self.pump(0.001); let now = CFAbsoluteTimeGetCurrent(); let g = (now - last) * 1000; worst = max(worst, g); if g > 6 { total += g }; last = now }
                    if i > 0 { syncTileBodies.append(Double(b1 - b0)); tileBodies.append(Double((Perf.counts()["TileBody"] ?? 0) - b0)); sync.append(s0); gaps.append(worst); busy.append(s0 + total) }
                }
                Self.record("return_to_tab", "\(tab) \(mode): tile bodies in sync", Self.stats(syncTileBodies)); Self.record("return_to_tab", "\(tab) \(mode): tile bodies in 0.8 s", Self.stats(tileBodies))
                Self.record("return_to_tab", "\(tab) \(mode): sync ms", Self.stats(sync))
                Self.record("return_to_tab", "\(tab) \(mode): longest gap after sync ms", Self.stats(gaps))
                Self.record("return_to_tab", "\(tab) \(mode): sync + all later stalls over 6 ms", Self.stats(busy))
            }
        }
        win.orderOut(nil)
    }

    // MARK: 7. Home first-frame tail (diagnosis aid; PERF_HOME_LOOPS visits of Home, each followed by Series)
    @Test func homeVisits() async throws {
        let w = try Self.makeWorld(); _ = NSApplication.shared
        UserDefaults.standard.set(true, forKey: "settings.reducemotion"); defer { UserDefaults.standard.removeObject(forKey: "settings.reducemotion") }
        let router = AppRouter(); router.navigate(.series, nil)
        let view = ContentRouter().environment(w.state).environment(router).environment(\.container, w.c).environment(\.artwork, w.artwork).environment(w.c.settings).reddyTheme(w.c.settings).background(ColorTokens.background)
        let size = CGSize(width: 1100, height: 760)
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height))); host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: 12 - size.width, y: 40)); win.orderFrontRegardless()
        func pump(_ s: Double) async { let end = CFAbsoluteTimeGetCurrent() + s; while CFAbsoluteTimeGetCurrent() < end { try? await Task.sleep(nanoseconds: 5_000_000); Self.pump(0.001) } }
        host.layoutSubtreeIfNeeded(); await pump(1.5)
        let loops = Int(ProcessInfo.processInfo.environment["PERF_HOME_LOOPS"] ?? "") ?? 8
        var gaps: [Double] = []
        for _ in 0..<loops {
            router.navigate(.series, nil); host.layoutSubtreeIfNeeded(); await pump(0.5)
            router.navigate(.home, nil); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            var worst = 0.0, last = CFAbsoluteTimeGetCurrent(); let end = last + 0.6
            while CFAbsoluteTimeGetCurrent() < end { try? await Task.sleep(nanoseconds: 2_000_000); Self.pump(0.001); let now = CFAbsoluteTimeGetCurrent(); worst = max(worst, (now - last) * 1000); last = now }
            gaps.append(worst)
        }
        Self.record("home_tail", "longest gap after switching to Home", Self.stats(gaps))
        win.orderOut(nil)
    }

    // MARK: 4b. DB on the main thread, through the app-level paths that were moved off main (reloadAsync, reloadWatched, folder open)
    @Test func mainThreadDatabaseAppPaths() async throws {
        let w = try Self.makeWorld()
        Perf.resetCounters(); Perf.collecting = true; defer { Perf.collecting = false }
        var wall: [String: [Double]] = [:]
        for _ in 0..<Self.runs {
            wall["reloadAsync (awaited)", default: []].append(await Self.msA { await w.state.reloadAsync() })
            wall["reloadWatched (call returns)", default: []].append(Self.ms { w.state.reloadWatched() })
            await w.state.settleWatched()
            wall["noteFolderOpened (call returns)", default: []].append(Self.ms { _ = w.c.smartMix.noteFolderOpened(profile: "main", categoryID: "perf-folder") })
        }
        for (k, v) in wall { Self.record("app_paths_main_thread", k + ": main-thread time of the call", Self.stats(v)) }
        for (k, v) in Perf.mainTimes() { var st = Self.stats(v); st["calls"] = Double(v.count); st["total_ms"] = v.reduce(0, +); Self.record("app_paths_main_thread_db", "\(k) called from main during \(Self.runs) rounds of the three paths", st) }
        if Perf.mainTimes().isEmpty { Self.record("app_paths_main_thread_db", "no database call from the main thread in \(Self.runs) rounds", ["calls": 0, "total_ms": 0]) }
    }
}
