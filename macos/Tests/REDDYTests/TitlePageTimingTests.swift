import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// Opt-in (REDDY_TITLE_SHOTS=<dir>): how the Mac title page opens. Opening is measured as the time the main thread is blocked
/// while the page is first built, laid out and drawn, and as the longest stall of the run loop in the next two seconds.
@Suite("Title page opening (opt-in)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["REDDY_TITLE_SHOTS"] != nil))
@MainActor struct TitlePageTimingTests {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REDDY_TITLE_SHOTS"] ?? NSTemporaryDirectory())

    static func env<V: View>(_ v: V, _ w: TitlePageFixture.World, router: AppRouter = AppRouter()) -> some View {
        v.environment(w.container.settings).environment(w.state).environment(router).environment(\.container, w.container).environment(\.artwork, w.artwork).reddyTheme(w.container.settings).background(ColorTokens.background)
    }

    /// A real, on-screen but fully transparent window (animations only run in windows the system considers visible).
    static func window(_ host: NSView, size: CGSize) -> NSWindow {
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
        win.ignoresMouseEvents = true; win.hasShadow = false
        win.setFrameOrigin(NSPoint(x: 12 - size.width, y: 40))        // all but a 12 pt sliver is off screen: still 'visible', so animations run; win.orderFrontRegardless()
        return win
    }

    struct Stats { var firstFrameMs: Double; var maxStallMs: Double; var stallsOver16: Int; var firstPaint: Double }

    func open<V: View>(_ view: V, size: CGSize) async -> (Stats, NSWindow, NSHostingView<AnyView>) {
        _ = NSApplication.shared
        let t0 = CFAbsoluteTimeGetCurrent()
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let win = Self.window(host, size: size)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let first = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        var last = CFAbsoluteTimeGetCurrent(), worst = 0.0, over = 0
        let end = last + 2.0
        while CFAbsoluteTimeGetCurrent() < end {
            try? await Task.sleep(nanoseconds: 2_000_000); Self.pump(0.001)
            let now = CFAbsoluteTimeGetCurrent(); let gap = (now - last) * 1000
            if gap > worst { worst = gap }; if gap > 16.7 { over += 1 }
            last = now
        }
        host.layoutSubtreeIfNeeded()
        return (Stats(firstFrameMs: first, maxStallMs: worst, stallsOver16: over, firstPaint: 0), win, host)
    }

    nonisolated static func pump(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    func png(_ host: NSView, _ name: String) throws {
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name + ".png"))
    }

    func log(_ s: String) { print("TITLE-TIMING " + s); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); let f = dir.appendingPathComponent("timing.log"); let d = Data((s + "\n").utf8); if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? d.write(to: f) } }

    @Test func openingTimes() async throws {
        let tag = ProcessInfo.processInfo.environment["REDDY_TITLE_TAG"] ?? "run"
        for run in 0..<3 {
            let w = try TitlePageFixture.world()
            let (a, wa, _) = await open(Self.env(MovieDetailView(movie: w.movie), w), size: CGSize(width: 1000, height: 760)); wa.orderOut(nil)
            let (b, wb, _) = await open(Self.env(SeriesDetailView(series: w.series), w), size: CGSize(width: 1000, height: 760)); wb.orderOut(nil)
            log("\(tag) run\(run) movie firstFrame=\(String(format: "%.1f", a.firstFrameMs))ms maxStall=\(String(format: "%.1f", a.maxStallMs))ms stalls>16ms=\(a.stallsOver16) | series firstFrame=\(String(format: "%.1f", b.firstFrameMs))ms maxStall=\(String(format: "%.1f", b.maxStallMs))ms stalls>16ms=\(b.stallsOver16)")
        }
    }

    /// When the picture stops changing: samples the drawn page every 40 ms and reports the last change and how many frames differed (each is a visible pop or jump).
    func settle<V: View>(_ view: V, size: CGSize, name: String) async throws -> String {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let win = Self.window(host, size: size)
        let t0 = CFAbsoluteTimeGetCurrent()
        var prev: Data?, lastChange = 0.0, changes = 0
        var firstShot = false
        while CFAbsoluteTimeGetCurrent() - t0 < (ProcessInfo.processInfo.environment["REDDY_TITLE_SETTLE"].flatMap(Double.init) ?? 2.5) {
            try await Task.sleep(nanoseconds: 40_000_000); Self.pump(0.005)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let d = rep.representation(using: .tiff, properties: [:]) ?? Data()
            if !firstShot { firstShot = true; try png(host, name + "-first") }
            if d != prev { if prev != nil { changes += 1; lastChange = (CFAbsoluteTimeGetCurrent() - t0) * 1000 }; prev = d }
        }
        try png(host, name + "-settled")
        win.orderOut(nil)
        return "\(name) lastVisibleChange=\(Int(lastChange))ms changedFrames=\(changes)"
    }

    @Test func settleTimes() async throws {
        let tag = ProcessInfo.processInfo.environment["REDDY_TITLE_TAG"] ?? "run"
        let w = try TitlePageFixture.world()
        log("\(tag) " + (try await settle(Self.env(MovieDetailView(movie: w.movie), w), size: CGSize(width: 1000, height: 760), name: "\(tag)-movie")))
        log("\(tag) " + (try await settle(Self.env(SeriesDetailView(series: w.series), w), size: CGSize(width: 1000, height: 760), name: "\(tag)-series")))
    }

    /// Screenshots of the page in three themes and three sizes (the dialog size for a 1100x800 window, for the smallest window 1024x680, and a narrow 720x560 page).
    @Test func shots() async throws {
        UserDefaults.standard.set(true, forKey: "settings.reducemotion"); defer { UserDefaults.standard.removeObject(forKey: "settings.reducemotion"); ThemeStore.current = .obsidian }
        let sizes: [(String, CGSize)] = [("1004", TitlePageLogic.dialogSize(window: CGSize(width: 1100, height: 800))), ("928", TitlePageLogic.dialogSize(window: CGSize(width: 1024, height: 680))), ("720", CGSize(width: 720, height: 560))]
        for theme in [AppTheme.cinematic, .liquidGlass, .dracula] {
            let w = try TitlePageFixture.world()
            w.container.settings.theme = theme
            let tag = theme.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
            for (sn, size) in sizes {
                let wide = sn != "1004" && theme != .cinematic ? false : true
                _ = wide
                _ = try await settle(Self.env(MovieDetailView(movie: w.movie), w), size: size, name: "shot-movie-\(tag)-\(sn)")
                if theme != .liquidGlass || sn == "1004" { _ = try await settle(Self.env(SeriesDetailView(series: w.series), w), size: size, name: "shot-series-\(tag)-\(sn)") }
            }
        }
        let tall = try TitlePageFixture.world()
        _ = try await settle(Self.env(SeriesDetailView(series: tall.series), tall), size: CGSize(width: 1004, height: 1500), name: "shot-series-tall-1004")
        _ = try await settle(Self.env(MovieDetailView(movie: tall.movie), tall), size: CGSize(width: 1004, height: 1500), name: "shot-movie-tall-1004")
        let bare = try TitlePageFixture.world(backdrop: false)
        _ = try await settle(Self.env(MovieDetailView(movie: bare.movie), bare), size: sizes[0].1, name: "shot-movie-poster-only-1004")
        let none = try TitlePageFixture.world(backdrop: false, poster: false)
        _ = try await settle(Self.env(MovieDetailView(movie: none.movie), none), size: sizes[0].1, name: "shot-movie-no-art-1004")
    }

    /// The metadata hub's logo and next-episode time. The hub is one shared instance bound to the first container made in the process, so run this alone (--filter hubShots).
    @Test func hubShots() async throws {
        UserDefaults.standard.set(true, forKey: "settings.reducemotion"); defer { UserDefaults.standard.removeObject(forKey: "settings.reducemotion") }
        let size = TitlePageLogic.dialogSize(window: CGSize(width: 1100, height: 800))
        let hubbed = try TitlePageFixture.world(hub: true)
        _ = try await settle(Self.env(MovieDetailView(movie: hubbed.movie), hubbed), size: size, name: "shot-movie-logo-1004")
        _ = try await settle(Self.env(SeriesDetailView(series: hubbed.series), hubbed), size: size, name: "shot-series-nextep-1004")
    }
}
