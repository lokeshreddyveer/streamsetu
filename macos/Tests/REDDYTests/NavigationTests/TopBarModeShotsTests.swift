import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// Renders the top bar with the per-item modes in every theme, for a look. Runs only when TOPBAR_MODE_SHOTS names a folder.
@Suite("Top bar mode shots") @MainActor struct TopBarModeShotsTests {
    @Test func renderTheModesInEveryTheme() throws {
        guard let dir = ProcessInfo.processInfo.environment["TOPBAR_MODE_SHOTS"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let saved = ThemeStore.current; defer { ThemeStore.current = saved }
        let only = ProcessInfo.processInfo.environment["TOPBAR_MODE_THEMES"]?.split(separator: ",").map(String.init)
        func modes(_ m: TabBarMode) -> TopBarTabModes { var t = TopBarTabModes(); NavTab.baseTabs.forEach { t.set(m, for: $0) }; return t }
        var mixed = TopBarTabModes(); mixed.set(.iconOnly, for: .home); mixed.set(.nameOnly, for: .movies); mixed.set(.iconOnly, for: .guide)
        let variants: [(String, TopBarTabModes, TopLevelDestination)] = [("default", TopBarTabModes(), .streamSetu), ("icons", modes(.iconOnly), .streamSetu), ("names", modes(.nameOnly), .streamSetu),
                                                                          ("mixed", mixed, .streamSetu), ("stateB", TopBarTabModes(), .service(.hulu)), ("podcasts", TopBarTabModes(), .podcasts)]
        for theme in AppTheme.allCases where theme != .custom && (only == nil || only!.contains(theme.rawValue)) {
            ThemeStore.current = theme
            let t = theme.rawValue.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "é", with: "e")
            for w: CGFloat in [1024, 1440] {
                for (name, m, dest) in variants {
                    var nav = ServicesNavigationBinding(); nav.pinned = [.netflix, .hulu, .youtube, .hbomax, .disneyplus]; nav.tabModes = m
                    if case .service(let s) = dest { nav.active = s }
                    var q = ""
                    let st = TopBarState(tab: .movies, initials: "LO", accountMenuOpen: false, width: w, destination: dest, services: [], showsServicesMenu: true, servicesNav: nav)
                    let view = ReddyTopBar(state: st, query: Binding(get: { q }, set: { q = $0 }), focusToken: 0, onSelectTab: { _ in }, onToggleAccount: {})
                        .frame(width: w, height: LayoutTokens.headerHeight + 12, alignment: .top).background(ThemeBackdrop()).environment(\.colorScheme, .dark)
                    let host = NSHostingView(rootView: AnyView(view))
                    host.frame = NSRect(x: 0, y: 0, width: w, height: LayoutTokens.headerHeight + 12)
                    let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
                    for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.04)) }
                    host.layoutSubtreeIfNeeded()
                    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(t)-\(Int(w))-\(name).png"))
                    withExtendedLifetime(win) {}
                }
            }
        }
    }
}
