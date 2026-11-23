import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// Opt-in (PERSONA_SHOTS=<out dir>, STREAMSETU_PERSONAS=<corpus dir>): the new Home drawn over synthetic persona libraries, the title page, the Setu chat and Settings credits.
@Suite("Persona screenshots (opt in)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["PERSONA_SHOTS"] != nil && PersonaCorpus.dir != nil))
@MainActor struct PersonaShotsTests {
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PERSONA_SHOTS"] ?? NSTemporaryDirectory())

    nonisolated static func pump(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    func shot<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = true, settle: Double = 2.5) async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host; win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.setFrameOrigin(NSPoint(x: 12 - size.width, y: 40)); win.orderFrontRegardless()
        let end = Date().addingTimeInterval(settle)
        while Date() < end { try await Task.sleep(nanoseconds: 60_000_000); Self.pump(0.03) }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + ".png"))
        win.orderOut(nil)
    }

    func library(_ persona: String, cap: Int) throws -> (AppContainer, AppState, ArtworkService) {
        let p = try PersonaCorpus.load(persona, PersonaCorpus.Persona.self)
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("persona-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("persona-art-\(UUID().uuidString)")
        let art = ArtworkService(cache: ImageCache(root: root, http: HTTPClient()))
        for i in 0..<24 { try TitlePageFixture.store("https://img.example/p/\(i).jpg", .poster, TitlePageFixture.cgImage(width: 300, height: 450, hue: Double(i) / 24, poster: false), root: root) }
        let src = PlaylistSource(name: "Persona", type: .xtream, baseURL: "http://provider.example:8080", lastSync: Date().addingTimeInterval(-3600), syncStatus: "completed", capabilities: SourceCapabilities(live: false, movies: true, series: true, epg: false))
        try c.catalog.save(source: src); try c.catalog.saveCapabilities(src.capabilities, sourceID: src.id)
        var items = p.items.filter { !$0.restricted }
        if items.count > cap { let step = Double(items.count) / Double(cap); items = (0..<cap).map { items[Int(Double($0) * step)] } }
        var cats: [String: CatalogCategory] = [:]
        func cat(_ n: String, _ k: ContentKind) -> CatalogCategory { let key = k.rawValue + n; if let x = cats[key] { return x }; let x = FixtureLibrary.category(src, k, n, cats.count); cats[key] = x; return x }
        var movies: [Movie] = [], shows: [Series] = []
        for (i, it) in items.enumerated() {
            let poster = it.poster ? "https://img.example/p/\(i % 24).jpg" : nil
            if it.kind == "series" {
                var s = TestSupport.series(src, "s\(i)", it.raw); let k = cat(it.category, .series); s.categoryID = k.id; s.categoryName = k.name
                s.genre = it.genre.isEmpty ? nil : it.genre; s.releaseYear = it.year; s.rating = it.rating.isEmpty ? nil : it.rating; s.posterURL = poster; s.addedAt = Date().addingTimeInterval(-Double(it.addedDays) * 86400); shows.append(s)
            } else {
                var m = TestSupport.movie(src, "m\(i)", it.raw, year: it.year); let k = cat(it.category, .movie); m.categoryID = k.id; m.categoryName = k.name
                m.genre = it.genre.isEmpty ? nil : it.genre; m.rating = it.rating.isEmpty ? nil : it.rating; m.posterURL = poster; m.addedAt = Date().addingTimeInterval(-Double(it.addedDays) * 86400); movies.append(m)
            }
        }
        try c.indexer.commitMovies(source: src, categories: cats.values.filter { $0.kind == .movie }.sorted { $0.sortOrder < $1.sortOrder }, movies: movies)
        try c.indexer.commitSeries(source: src, categories: cats.values.filter { $0.kind == .series }.sorted { $0.sortOrder < $1.sortOrder }, series: shows)
        let state = AppState(container: c, defaults: UserDefaults(suiteName: "persona-\(UUID().uuidString)")!)
        state.reload(); state.loaded = true
        return (c, state, art)
    }

    @Test func homeOverPersonas() async throws {
        UserDefaults.standard.set(true, forKey: "settings.reducemotion"); defer { UserDefaults.standard.removeObject(forKey: "settings.reducemotion"); ThemeStore.current = .obsidian }
        let personas: [(String, String, Int)] = [("small-english", "english-small", 400), ("hindi-telugu", "telugu-hindi", 3000), ("korean-drama", "asian-drama", 2000), ("huge", "huge-200k", 25000), ("brand-new", "new-user", 410), ("no-artwork", "bare-library", 2000)]
        let only = ProcessInfo.processInfo.environment["PERSONA_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        for (tag, persona, cap) in personas where only == nil || only!.contains(tag) {
            let (c, state, art) = try library(persona, cap: cap)
            for theme in [AppTheme.cinematic, .liquidGlass] {
                c.settings.theme = theme
                let router = AppRouter(); router.navigate(.home, nil)
                let view = HomeScreen().background(ColorTokens.background)
                    .environment(state).environment(router).environment(\.container, c).environment(\.artwork, art).environment(c.settings).reddyTheme(c.settings)
                try await shot(view, size: CGSize(width: 1100, height: 1500), name: "home-\(tag)-\(theme.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))", settle: 5)
            }
        }
    }

    @Test func settingsCredits() async throws {
        let sc = try TitlePageFixture.world()
        func env<V: View>(_ v: V) -> some View { v.environment(sc.container.settings).environment(sc.state).environment(AppRouter()).environment(\.container, sc.container).environment(\.artwork, sc.artwork).reddyTheme(sc.container.settings).background(ColorTokens.background) }
        for dark in [true, false] { try await shot(env(AdvancedSettingsPage(vm: AdvancedSettingsViewModel())).frame(width: 660), size: CGSize(width: 660, height: 1500), name: "settings-advanced-\(dark ? "dark" : "light")", dark: dark, settle: 1.5) }
    }
}
