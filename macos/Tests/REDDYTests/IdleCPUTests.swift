import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// Opt-in measurement (IDLE_CPU=1): the Home screen over a synthetic library in an offscreen window; reports process CPU time over a
/// few seconds per theme. Synthetic data only.
@Suite("Idle CPU (opt in)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["IDLE_CPU"] == "1"))
@MainActor struct IdleCPUTests {
    nonisolated static func pump(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
    static func cpu() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    @Test func plainDriftIdle() async throws {
        _ = NSApplication.shared
        if ProcessInfo.processInfo.environment["FIN"] != nil { NSApp.setActivationPolicy(.regular); NSApp.finishLaunching() }
        let host = NSHostingView(rootView: PlainDrift().frame(width: 700, height: 400)); host.frame = NSRect(x: 0, y: 0, width: 700, height: 400); if ProcessInfo.processInfo.environment["NOSIZE"] != nil { host.sizingOptions = [] }
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: 40, y: 40)); win.makeKeyAndOrderFront(nil)
        let settle = Date().addingTimeInterval(1.5); while Date() < settle { try await Task.sleep(nanoseconds: 50_000_000) }
        let t0 = Self.cpu(), w0 = Date()
        let end = Date().addingTimeInterval(4); while Date() < end { if ProcessInfo.processInfo.environment["PUMP"] != nil { Self.pump(0.05) } else { try await Task.sleep(nanoseconds: 50_000_000) } }
        print("windows \(NSApp.windows.count) \(NSApp.windows.map { String(describing: type(of: $0)) })")
        print("ENV \(ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("DYLD") || $0.key.hasPrefix("MTC") || $0.key.contains("SANITIZ") || $0.key.hasPrefix("SWIFT") || $0.key.hasPrefix("NS") || $0.key.hasPrefix("CA_") || $0.key.hasPrefix("OS_") })")
        print("IDLECPU plain: \(String(format: "%.1f", (Self.cpu() - t0) / Date().timeIntervalSince(w0) * 100)) %")
        if let h = ProcessInfo.processInfo.environment["HOLD"].flatMap(Double.init) { let e = Date().addingTimeInterval(h); while Date() < e { try await Task.sleep(nanoseconds: 50_000_000) } }
        win.orderOut(nil)
    }

    @Test func homeIdle() async throws {
        _ = NSApplication.shared
        UserDefaults.standard.set(false, forKey: DefaultsKey.reduceMotion); defer { UserDefaults.standard.removeObject(forKey: DefaultsKey.reduceMotion) }
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("idle-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idle-art-\(UUID().uuidString)")
        let art = ArtworkService(cache: ImageCache(root: root, http: HTTPClient()))
        for i in 0..<24 {
            try TitlePageFixture.store("https://img.example/p/\(i).jpg", .poster, TitlePageFixture.cgImage(width: 300, height: 450, hue: Double(i) / 24, poster: true, label: "T\(i)"), root: root)
            try TitlePageFixture.store("https://img.example/b/\(i).jpg", .backdrop, TitlePageFixture.cgImage(width: 1280, height: 720, hue: Double(i) / 24, poster: false), root: root)
        }
        let src = PlaylistSource(name: "Idle", type: .xtream, baseURL: "http://provider.example:8080", lastSync: Date().addingTimeInterval(-3600), syncStatus: "completed", capabilities: SourceCapabilities(live: false, movies: true, series: true, epg: false))
        try c.catalog.save(source: src); try c.catalog.saveCapabilities(src.capabilities, sourceID: src.id)
        let genres = ["Drama", "Action", "Comedy", "Thriller", "Sci-Fi"]
        let cats = genres.map { FixtureLibrary.category(src, .movie, $0.uppercased(), 0) }
        let movies: [Movie] = (0..<(Int(ProcessInfo.processInfo.environment["IDLE_N"] ?? "") ?? 300)).map { i in
            var m = TestSupport.movie(src, "m\(i)", "The Synthetic Film \(i)", year: 1990 + i % 30)
            m.categoryID = cats[i % 5].id; m.categoryName = cats[i % 5].name; m.genre = genres[i % 5]; m.rating = "7.\(i % 10)"
            m.overview = "A synthetic overview that is long enough to be featured on the home banner, number \(i)."
            m.posterURL = "https://img.example/p/\(i % 24).jpg"; m.backdropURL = "https://img.example/b/\(i % 24).jpg"
            m.addedAt = Date().addingTimeInterval(-Double(i) * 3000); return m }
        _ = try c.indexer.commitMovies(source: src, categories: cats, movies: movies)
        let state = AppState(container: c, defaults: InMemoryDefaults())
        state.reload(); state.loaded = true
        for theme in (ProcessInfo.processInfo.environment["IDLE_LONG"] != nil ? [AppTheme.liquidGlass] : [AppTheme.cinematic, .liquidGlass, .liquidGlassBlue]) {
            c.settings.theme = theme; c.settings.reduceMotion = false
            let router = AppRouter(); router.navigate(.home, nil)
            let size = CGSize(width: 1400, height: 900)
            let slides = movies.prefix(6).compactMap { FeaturedPolicy.slide(.movie($0)) }
            let view = Group { if ProcessInfo.processInfo.environment["IDLE_SLIDE"] == "3" { PlainDrift() } else if ProcessInfo.processInfo.environment["IDLE_SLIDE"] == "2" { Rectangle().fill(.red).frame(width: 600, height: 300).kenBurns().clipped().padding() } else if ProcessInfo.processInfo.environment["IDLE_SLIDE"] == "1" { FeaturedSlideshow(slides: slides, kicker: "K", height: 340, onPlay: { _ in }, onInfo: { _ in }).environment(\.artwork, art).environment(c.settings).reddyTheme(c.settings).padding() } else if ProcessInfo.processInfo.environment["IDLE_SHELL"] == "1" { MainShell(router: router, keys: PlayerKeyMonitor(), container: c, state: state).environment(\.artwork, art) } else { HomeScreen().background(ColorTokens.background) } }
                .environment(state).environment(router).environment(\.container, c).environment(\.artwork, art).environment(c.settings).reddyTheme(c.settings)
            let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
            host.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
            win.setFrameOrigin(NSPoint(x: 40, y: 40)); win.alphaValue = 1; NSApp.setActivationPolicy(.regular); win.ignoresMouseEvents = true; win.level = .screenSaver; win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let settle = Date().addingTimeInterval(2.5); while Date() < settle { try await Task.sleep(nanoseconds: 50_000_000) }
            print("NSVIEWS \(theme.rawValue): \(Self.countViews(host)) views, \(host.layer?.sublayers?.count ?? 0) top sublayers"); let ctr = TickCounter(); let dl = host.displayLink(target: ctr, selector: #selector(TickCounter.tick)); if ProcessInfo.processInfo.environment["NO_DL"] == nil { dl.add(to: .main, forMode: .common) }
            let t0 = Self.cpu(), w0 = Date()

            if let long = ProcessInfo.processInfo.environment["IDLE_LONG"].flatMap(Int.init) {
                for k in 0..<long { let a = Self.cpu(), b = Date(); let e = Date().addingTimeInterval(10); while Date() < e { try await Task.sleep(nanoseconds: 50_000_000) }; print("IDLECPU window \(k): \(String(format: "%.1f", (Self.cpu() - a) / Date().timeIntervalSince(b) * 100)) %") }
            }
            let end = Date().addingTimeInterval(4); while Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
            let pct = (Self.cpu() - t0) / Date().timeIntervalSince(w0) * 100
            print("reduce app=\(c.settings.reduceMotion) std=\(UserDefaults.standard.bool(forKey: DefaultsKey.reduceMotion)) sys=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)"); print("ticks \(ctr.n)"); dl.invalidate(); print("screens \(NSScreen.screens.count) winscreen \(String(describing: win.screen?.frame)) frame \(win.frame) active \(NSApp.isActive) onActiveSpace \(win.isOnActiveSpace)"); print("hasLibrary \(state.hasLibrary) loaded \(state.loaded) win visible \(win.isVisible) occl \(win.occlusionState.contains(.visible))"); print("IDLECPU \(theme.rawValue): \(String(format: "%.1f", pct)) %")
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("streamsetu-idlecpu-home-\(theme.rawValue.replacingOccurrences(of: " ", with: "")).png")) }
            win.orderOut(nil)
        }
    }
}

/// Opt-in audit (IDLE_CPU=1): each always-on animation on its own in a window for 3 s; reports process CPU. Also dumps the NSView count of the Home window.
extension IdleCPUTests {
    @Test func animationAudit() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        UserDefaults.standard.set(false, forKey: DefaultsKey.reduceMotion); defer { UserDefaults.standard.removeObject(forKey: DefaultsKey.reduceMotion) }
        for gated in [false, true] {
        AppActivity.shared.forced = gated ? false : true; defer { AppActivity.shared.forced = nil }
        print("AUDIT mode: \(gated ? "app in background (gated)" : "live")")
        let items: [(String, AnyView)] = [
            ("BrandLoader", AnyView(BrandLoader())), ("SkeletonLine shimmer", AnyView(SkeletonLine(width: 300))),
            ("PulsingDot", AnyView(PulsingDot(color: .red))), ("BrandEmptyArt tuning", AnyView(BrandEmptyArt(kind: .tuning))),
            ("ArtworkImage placeholder shimmer", AnyView(ArtworkImage(url: "https://img.example/none.jpg", kind: .backdrop).frame(width: 300, height: 200))),
            ("ThinkingDots", AnyView(ThinkingDots(status: nil))),
            ("KenBurnsArtwork (layer)", AnyView(KenBurnsArtwork(url: nil).frame(width: 600, height: 300))),
            ("Idle control", AnyView(Color.clear)),
        ]
        for (name, view) in items {
            let host = NSHostingView(rootView: view.frame(width: 700, height: 400).environment(AppSettings(defaults: UserDefaults(suiteName: "audit-\(UUID().uuidString)")!))); host.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
            let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = host; win.setFrameOrigin(NSPoint(x: 40, y: 40)); win.makeKeyAndOrderFront(nil)
            let settle = Date().addingTimeInterval(1.5); while Date() < settle { try await Task.sleep(nanoseconds: 50_000_000) }
            let t0 = Self.cpu(), w0 = Date()
            let end = Date().addingTimeInterval(3); while Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
            print("AUDIT \(name): \(String(format: "%.1f", (Self.cpu() - t0) / Date().timeIntervalSince(w0) * 100)) % live=\(AppActivity.shared.isLive)")
            win.orderOut(nil)
        }
        }
    }

    static func countViews(_ v: NSView) -> Int { 1 + v.subviews.reduce(0) { $0 + countViews($1) } }
}

final class TickCounter: NSObject { var n = 0; @objc func tick() { n += 1 } }

private struct PlainDrift: View {
    @State private var on = false
    var body: some View { Rectangle().fill(.red).frame(width: 600, height: 300).scaleEffect(on ? 1.03 : 1).animation(.linear(duration: 1).repeatForever(autoreverses: true), value: on).onAppear { on = true }.padding() }
}
