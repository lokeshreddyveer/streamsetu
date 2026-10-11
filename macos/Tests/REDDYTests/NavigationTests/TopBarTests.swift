import Testing
import SwiftUI
import AppKit
@testable import REDDY

@Suite("Top bar geometry") @MainActor struct TopBarTests {
    static let widths: [CGFloat] = [1024, 1280, 1440, 1728]

    private func parts(_ width: CGFloat) -> (m: TopBarMetrics, nav: CGFloat, brand: CGFloat) {
        let m = TopBarMetrics.metrics(for: width)
        let widths = AppTab.allCases.map { TabLabelMetrics.textWidth($0.title) + 2 * m.tabPadding }
        return (m, widths.reduce(0, +), TabLabelMetrics.brandWidth)
    }

    private func frames(_ width: CGFloat) -> TopBarGeometry.Frames {
        let p = parts(width)
        return TopBarGeometry.frames(width: width, height: LayoutTokens.headerHeight, leading: CGSize(width: p.brand, height: 28),
                                     center: CGSize(width: p.nav, height: LayoutTokens.headerHeight),
                                     trailingIdeal: CGSize(width: p.m.searchIdeal + 8 + TopBarMetrics.accountWidth, height: 30),
                                     trailingMin: p.m.searchMin + 8 + TopBarMetrics.accountWidth,
                                     leadingInset: TopBarMetrics.leadingInset, trailingInset: TopBarMetrics.trailingInset)
    }

    @Test("Navigation is centred on the whole window at every supported width")
    func centred() {
        for w in Self.widths {
            let f = frames(w)
            #expect(abs(f.center.midX - w / 2) <= 0.5, "width \(w): centre \(f.center.midX)")
        }
    }

    @Test("Zones never overlap and stay inside the bar at every supported width")
    func noCollisions() {
        for w in Self.widths {
            let f = frames(w)
            #expect(f.leading.maxX + TopBarGeometry.gap <= f.center.minX + 0.5, "brand/nav at \(w)")
            #expect(f.center.maxX + TopBarGeometry.gap <= f.trailing.minX + 0.5, "nav/search at \(w)")
            #expect(f.trailing.maxX <= w - TopBarMetrics.trailingInset + 0.5)
            #expect(f.leading.minY >= 0 && f.trailing.maxY <= LayoutTokens.headerHeight)
        }
    }

    @Test("Required width fits the narrowest supported window")
    func requiredWidth() {
        for w in Self.widths {
            let p = parts(w)
            let tabs = AppTab.allCases.map { TabLabelMetrics.textWidth($0.title) }
            #expect(p.m.requiredWidth(brandWidth: p.brand, tabTextWidths: tabs) <= w, "width \(w)")
        }
    }

    @Test("Frames depend only on width, never on selection or sidebar")
    func independentOfState() {
        // The geometry has no parameter for tab, sidebar, page or playback, so equal widths give equal frames.
        for w in Self.widths { #expect(frames(w) == frames(w)) }
        // The brand and account anchors do not move when the window grows: brand from the left, account from the right.
        let a = frames(1280), b = frames(1728)
        #expect(a.leading.minX == b.leading.minX)
        #expect(1280 - a.trailing.maxX == 1728 - b.trailing.maxX)
    }

    /// Renders only the bar for each tab and checks that the pixels differ nowhere except inside the two tabs' own labels:
    /// brand, search and account are pixel-identical, and no neighbouring tab moves.
    @Test("Switching tabs changes only the tab labels' colour")
    func pixelStability() throws {
        _ = NSApplication.shared
        for w in [1024.0, 1280.0, 1728.0] {
            var reps: [AppTab: NSBitmapImageRep] = [:]
            for tab in AppTab.allCases {
                var q = ""
                let view = ReddyTopBar(state: TopBarState(tab: tab, initials: "LR", accountMenuOpen: false, width: w),
                                       query: Binding(get: { q }, set: { q = $0 }), focusToken: 0, onSelectTab: { _ in }, onToggleAccount: {})
                    .frame(width: w, height: LayoutTokens.headerHeight)
                    .background(Color(hex: 0x0B0D12)).environment(\.colorScheme, .dark)
                let host = NSHostingView(rootView: AnyView(view))
                host.frame = NSRect(x: 0, y: 0, width: w, height: LayoutTokens.headerHeight)
                let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
                for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                reps[tab] = rep
            }
            let f = frames(w)
            let m = TopBarMetrics.metrics(for: w)
            // x-range of the nav, in points
            let navStart = f.center.minX, navEnd = f.center.maxX
            let base = try #require(reps[.home])
            let scale = CGFloat(base.pixelsWide) / w
            for tab in AppTab.allCases where tab != .home {
                let other = try #require(reps[tab])
                var minX = Int.max, maxX = -1
                for y in 0..<base.pixelsHigh { for x in 0..<base.pixelsWide {
                    guard let a = base.colorAt(x: x, y: y), let b = other.colorAt(x: x, y: y) else { continue }
                    if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.02 { minX = min(minX, x); maxX = max(maxX, x) }
                } }
                #expect(maxX >= 0, "tab \(tab) should recolour something")
                #expect(CGFloat(minX) / scale >= navStart - 1 && CGFloat(maxX) / scale <= navEnd + 1, "width \(w) tab \(tab): changed pixels \(minX)…\(maxX) outside nav \(navStart)…\(navEnd) (padding \(m.tabPadding))")
            }
        }
    }
}
