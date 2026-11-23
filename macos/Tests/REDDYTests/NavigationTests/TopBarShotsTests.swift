import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// Renders the top bar offscreen to PNG files for a look. Runs only when NETFLIX_BAR_SHOTS names a folder; otherwise it checks nothing and passes.
@Suite("Top bar shots") @MainActor struct TopBarShotsTests {
    @Test func renderTheBarInThemesAndStates() throws {
        guard let dir = ProcessInfo.processInfo.environment["NETFLIX_BAR_SHOTS"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let saved = ThemeStore.current
        defer { ThemeStore.current = saved }
        for theme in [AppTheme.obsidian, .liquidGlass, .dracula] {
            ThemeStore.current = theme
            for w: CGFloat in [1024, 1440, 1920] {
                for (name, dest) in [("streamsetu", TopLevelDestination.streamSetu), ("netflix", .service(.netflix))] {
                    var q = ""
                    let state = TopBarState(tab: .movies, initials: "LO", accountMenuOpen: false, width: w, destination: dest, services: [.netflix])
                    let view = ReddyTopBar(state: state, query: Binding(get: { q }, set: { q = $0 }), focusToken: 0, onSelectTab: { _ in }, onToggleAccount: {})
                        .frame(width: w, height: LayoutTokens.headerHeight + 40, alignment: .top)
                        .background(ColorTokens.background).environment(\.colorScheme, .dark)
                    let host = NSHostingView(rootView: AnyView(view))
                    host.frame = NSRect(x: 0, y: 0, width: w, height: LayoutTokens.headerHeight + 40)
                    let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
                    for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
                    host.layoutSubtreeIfNeeded()
                    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let png = try #require(rep.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(theme.rawValue.replacingOccurrences(of: " ", with: "-"))-\(Int(w))-\(name).png"))
                    withExtendedLifetime(win) {}
                }
            }
        }
    }
}
