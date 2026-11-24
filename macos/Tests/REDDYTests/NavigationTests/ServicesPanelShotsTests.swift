import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// Renders the Services list for every theme in both appearances over three busy backdrops. Runs only when SERVICES_PANEL_SHOTS names a folder.
@Suite("Services panel shots") @MainActor struct ServicesPanelShotsTests {
    private struct Backdrop: View {
        let kind: Int
        var body: some View {
            switch kind {
            case 0:
                ZStack {
                    LinearGradient(colors: [.orange, .pink, .purple, .cyan, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [.red, .clear], center: .init(x: 0.2, y: 0.3), startRadius: 0, endRadius: 200)
                    RadialGradient(colors: [.green, .clear], center: .init(x: 0.8, y: 0.7), startRadius: 0, endRadius: 220)
                }
            case 1:
                ZStack {
                    Color.white
                    VStack(spacing: 14) { ForEach(0..<30, id: \.self) { i in Rectangle().fill(i % 3 == 0 ? Color.black : Color(white: 0.6)).frame(height: 5) } }
                }
            default:
                VStack(spacing: 6) {
                    ForEach(0..<8, id: \.self) { r in
                        HStack(spacing: 6) {
                            ForEach(0..<4, id: \.self) { c in
                                Rectangle().fill(LinearGradient(colors: [Color(hue: Double((r * 4 + c) % 11) / 11, saturation: 0.8, brightness: 0.55), .black], startPoint: .top, endPoint: .bottom))
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func renderEveryThemeBothAppearances() throws {
        guard let dir = ProcessInfo.processInfo.environment["SERVICES_PANEL_SHOTS"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let saved = ThemeStore.current; ThemeStore.state.frostedOnly = true
        defer { ThemeStore.current = saved; ThemeStore.state.frostedOnly = false }
        var nav = ServicesNavigationBinding()
        nav.pinned = [.netflix, .hulu]; nav.recents = [.peacock, .youtube]; nav.active = .peacock
        let cell = CGSize(width: 400, height: 520)
        for theme in AppTheme.allCases {
            ThemeStore.current = theme
            let accent = ColorTokens.accentDefault
            let sheet = VStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { a in
                    HStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { k in
                            ZStack(alignment: .top) {
                                Backdrop(kind: k).frame(width: cell.width, height: cell.height).clipped()
                                ServicesDropdown(nav: nav, maxListHeight: 330).padding(.top, 20)
                            }
                            .frame(width: cell.width, height: cell.height).clipped()
                            .environment(\.colorScheme, a == 0 ? .dark : .light)
                        }
                    }
                }
            }
            .environment(\.reddyAccent, accent)
            let size = CGSize(width: cell.width * 3, height: cell.height * 2)
            let host = NSHostingView(rootView: AnyView(sheet.frame(width: size.width, height: size.height)))
            host.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
            for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent(theme.rawValue.replacingOccurrences(of: " ", with: "-") + ".png"))
            withExtendedLifetime(win) {}
        }
    }
}
