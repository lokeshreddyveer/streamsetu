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
        let saved = ThemeStore.current; ThemeStore.state.frostedOnly = true
        defer { ThemeStore.current = saved; ThemeStore.state.frostedOnly = false }
        for theme in [AppTheme.obsidian, .liquidGlass, .liquidGlassBlue, .graphite] {
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

    /// The Services list and the bar with an open, unpinned service, for a look at clipping and overlap.
    @Test func renderTheServicesListAndPills() throws {
        guard let dir = ProcessInfo.processInfo.environment["NETFLIX_BAR_SHOTS"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let saved = ThemeStore.current; ThemeStore.state.frostedOnly = true
        defer { ThemeStore.current = saved; ThemeStore.state.frostedOnly = false }
        func shot<V: View>(_ view: V, _ size: CGSize, _ file: String) throws {
            let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height, alignment: .top).background(ColorTokens.background).environment(\.colorScheme, .dark)))
            host.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
            for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
            withExtendedLifetime(win) {}
        }
        for theme in [AppTheme.obsidian, .liquidGlass, .liquidGlassBlue, .graphite] {
            ThemeStore.current = theme
            let t = theme.rawValue.replacingOccurrences(of: " ", with: "-")
            var nav = ServicesNavigationBinding()
            nav.pinned = [.netflix, .hulu]; nav.recents = [.peacock, .netflix, .hulu]; nav.active = .peacock
            try shot(ServicesDropdown(nav: nav), CGSize(width: 340, height: 560), "\(t)-services-list.png")
            var short = nav; short.pinned = []; short.active = nil
            try shot(ServicesDropdown(nav: short, maxListHeight: 200), CGSize(width: 340, height: 330), "\(t)-services-list-short.png")
            for w: CGFloat in [1024, 1440] {
                var q = ""
                let st = TopBarState(tab: .movies, initials: "LO", accountMenuOpen: false, width: w, destination: .service(.peacock), services: [], showsServicesMenu: true, servicesNav: nav)
                let bar = ReddyTopBar(state: st, query: Binding(get: { q }, set: { q = $0 }), focusToken: 0, onSelectTab: { _ in }, onToggleAccount: {})
                try shot(bar, CGSize(width: w, height: LayoutTokens.headerHeight + 40), "\(t)-\(Int(w))-unpinned-active.png")
            }
        }
    }

    /// State A and State B of the redesigned bar, at three widths and in three themes, plus Podcasts open and hidden, for a look. Runs only with NETFLIX_BAR_SHOTS.
    @Test func renderStatesAAndB() throws {
        guard let dir = ProcessInfo.processInfo.environment["NETFLIX_BAR_SHOTS"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let saved = ThemeStore.current; ThemeStore.state.frostedOnly = true
        defer { ThemeStore.current = saved; ThemeStore.state.frostedOnly = false }
        func shot<V: View>(_ view: V, _ size: CGSize, _ file: String) throws {
            let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height, alignment: .top).background(ColorTokens.background).environment(\.colorScheme, .dark)))
            host.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
            for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
            withExtendedLifetime(win) {}
        }
        for theme in [AppTheme.obsidian, .liquidGlass, .liquidGlassBlue, .graphite] {
            ThemeStore.current = theme
            let t = theme.rawValue.replacingOccurrences(of: " ", with: "-")
            for w: CGFloat in [1024, 1280, 1728] {
                for (name, dest, inBar) in [("A", TopLevelDestination.streamSetu, true), ("B-hulu", .service(.hulu), true), ("B-unpinned-peacock", .service(.peacock), true), ("podcasts", .podcasts, true)] {
                    var nav = ServicesNavigationBinding()
                    nav.pinned = [.netflix, .hulu, .youtube, .hbomax, .disneyplus, .primevideo, .appletv]
                    if case .service(let s) = dest { nav.active = s }
                    var q = ""
                    let st = TopBarState(tab: .movies, initials: "LO", accountMenuOpen: false, width: w, destination: dest, services: [], showsServicesMenu: true, servicesNav: nav)
                    let bar = ReddyTopBar(state: st, query: Binding(get: { q }, set: { q = $0 }), focusToken: 0, onSelectTab: { _ in }, onToggleAccount: {})
                    try shot(bar, CGSize(width: w, height: LayoutTokens.headerHeight + 24), "\(t)-\(Int(w))-\(name).png")
                }
            }
            var hidden = ServicesNavigationBinding(); hidden.pinned = [.netflix, .hulu]; hidden.recents = [.peacock]
            try shot(ServicesDropdown(nav: hidden), CGSize(width: 340, height: 520), "\(t)-services-list.png")
        }
    }
}
