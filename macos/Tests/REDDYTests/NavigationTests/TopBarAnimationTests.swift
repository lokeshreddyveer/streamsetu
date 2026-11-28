import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// Drives the top bar through its animated transitions offscreen and captures frames (t=0, mid, end). Frames are written only when
/// NETFLIX_BAR_ANIM names a folder; the assertions below always run.
@MainActor final class TopBarDriver: ObservableObject {
    @Published var destination: TopLevelDestination = .streamSetu
    @Published var width: CGFloat = 1440
    @Published var menu = false
    @Published var query = ""
    @Published var focus = 0
    var state: TopBarState {
        var s = TopBarState(tab: .movies, initials: "LO", accountMenuOpen: false, width: width, destination: destination, services: menu ? [] : [.netflix])
        s.showsServicesMenu = menu
        return s
    }
}

private struct TopBarHarness: View {
    @ObservedObject var d: TopBarDriver
    var body: some View {
        ReddyTopBar(state: d.state, query: Binding(get: { d.query }, set: { d.query = $0 }), focusToken: d.focus, onSelectTab: { _ in }, onToggleAccount: {})
            .frame(width: d.width, height: LayoutTokens.headerHeight + 40, alignment: .top)
            .background(ColorTokens.background).environment(\.colorScheme, .dark)
    }
}

@MainActor enum TopBarFrames {
    static func host(_ d: TopBarDriver) -> (NSHostingView<TopBarHarness2>, NSWindow) {
        let host = NSHostingView(rootView: TopBarHarness2(d: d))
        host.frame = NSRect(x: 0, y: 0, width: 1920, height: LayoutTokens.headerHeight + 40)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
        win.orderFrontRegardless()
        return (host, win)
    }
    static func pump(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    static func png(_ host: NSView) throws -> Data {
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }
    static func shot(_ host: NSView, _ path: String) throws {
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
struct TopBarHarness2: View { @ObservedObject var d: TopBarDriver; var body: some View { TopBarHarness(d: d) } }

@Suite("Top bar animation") @MainActor struct TopBarAnimationTests {
    @Test func captureTransitions() throws {
        guard let dir = ProcessInfo.processInfo.environment["NETFLIX_BAR_ANIM"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let saved = ThemeStore.current; defer { ThemeStore.current = saved }
        ThemeStore.current = .liquidGlass
        let times: [(String, TimeInterval)] = [("t0", 0.0), ("t1", 0.08), ("t2", 0.18), ("t3", 0.35), ("end", 1.2)]
        for menu in [false, true] {
            let tag = menu ? "menu" : "plain"
            let d = TopBarDriver(); d.menu = menu
            let (host, win) = TopBarFrames.host(d)
            TopBarFrames.pump(0.5)
            try TopBarFrames.shot(host, "\(dir)/\(tag)-enter-before.png")
            // enter the service: a plain state change, as the app does it (the bar supplies the animation itself)
            d.destination = .service(.netflix)
            var last = 0.0
            for (n, t) in times { TopBarFrames.pump(t - last); last = t; try TopBarFrames.shot(host, "\(dir)/\(tag)-enter-\(n).png") }
            // leave it again
            d.destination = .streamSetu
            last = 0
            for (n, t) in times { TopBarFrames.pump(t - last); last = t; try TopBarFrames.shot(host, "\(dir)/\(tag)-leave-\(n).png") }
            // live window resize, in steps (no animation transaction supplied, like AppKit)
            let widths: [CGFloat] = [1440, 1380, 1300, 1200, 1100, 1024]
            for (i, w) in widths.enumerated() {
                d.width = w
                TopBarFrames.pump(0.02)
                try TopBarFrames.shot(host, "\(dir)/\(tag)-resize-\(i)-\(Int(w)).png")
            }
            // search focus: chip, stroke, glow and panel together
            d.destination = .streamSetu; TopBarFrames.pump(0.6)
            win.makeKey()
            d.focus += 1
            last = 0
            for (n, t) in times { TopBarFrames.pump(t - last); last = t; try TopBarFrames.shot(host, "\(dir)/\(tag)-focus-\(n).png") }
            withExtendedLifetime(win) {}
        }
    }

    /// A live window resize is followed at once: a frame taken right after the width changes equals the settled frame at that width,
    /// so nothing springs, pops or leaves a second edge behind.
    @Test func resizeTracksTheWindowWithoutAnimation() async throws {
        await HeavyTestSlot.shared.acquire(); defer { Task { await HeavyTestSlot.shared.release() } }      // one heavy test at a time (see HeavyTestSlot)
        _ = NSApplication.shared
        let saved = ThemeStore.current; defer { ThemeStore.current = saved }
        ThemeStore.current = .liquidGlass
        for menu in [false, true] {
            let d = TopBarDriver(); d.menu = menu; d.destination = .service(.netflix)
            let (host, win) = TopBarFrames.host(d)
            TopBarFrames.pump(0.6)
            for w: CGFloat in [1440, 1300, 1200, 1100, 1024] {
                d.width = w
                TopBarFrames.pump(0.03)
                let quick = try TopBarFrames.png(host)
                TopBarFrames.pump(0.4)
                let settled = try TopBarFrames.png(host)
                #expect(quick == settled, "width \(Int(w)) menu \(menu): the frame right after a resize differs from the settled one")
            }
            withExtendedLifetime(win) {}
        }
    }
}
