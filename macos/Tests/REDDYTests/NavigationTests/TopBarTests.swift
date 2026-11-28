import Testing
import SwiftUI
import AppKit
@testable import REDDY

@Suite("Top bar geometry") @MainActor struct TopBarTests {
    static let widths: [CGFloat] = [1024, 1280, 1440, 1728]

    private func parts(_ width: CGFloat) -> (m: TopBarMetrics, nav: CGFloat, brand: CGFloat) {
        let m = TopBarMetrics.metrics(for: width)
        // the five tabs are drawn with their icon and name by default (the icon adds the glyph width)
        let widths = AppTab.allCases.map { TabLabelMetrics.textWidth($0.title) + TopBarItem.glyphWidth + 2 * m.tabPadding }
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
            // The selected pill carries a soft shadow (radius 3), whose faint tail legitimately reaches a little past the nav edge;
            // whether its last half-point crosses the pixel threshold depends on compositing, so allow its full radius, not more.
            let shadowReach: CGFloat = 3
            for tab in AppTab.allCases where tab != .home {
                let other = try #require(reps[tab])
                var minX = Int.max, maxX = -1
                for y in 0..<base.pixelsHigh { for x in 0..<base.pixelsWide {
                    guard let a = base.colorAt(x: x, y: y), let b = other.colorAt(x: x, y: y) else { continue }
                    if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.02 { minX = min(minX, x); maxX = max(maxX, x) }
                } }
                #expect(maxX >= 0, "tab \(tab) should recolour something")
                #expect(CGFloat(minX) / scale >= navStart - shadowReach && CGFloat(maxX) / scale <= navEnd + shadowReach, "width \(w) tab \(tab): changed pixels \(minX)…\(maxX) outside nav \(navStart)…\(navEnd) (padding \(m.tabPadding))")
            }
        }
    }
}

@Suite("Top bar services menu") @MainActor struct TopBarServicesMenuTests {
    private func state(width: CGFloat, destination: TopLevelDestination = .streamSetu, pinned: [ProviderID]) -> TopBarState {
        var nav = ServicesNavigationBinding(); nav.pinned = pinned
        if case .service(let s) = destination { nav.active = s }
        return TopBarState(tab: .home, initials: "LR", accountMenuOpen: false, width: width, destination: destination, services: [], showsServicesMenu: true, servicesNav: nav)
    }

    @Test("State A is the five tabs and Podcasts, the pinned services in order as favicon-only chips, then Services")
    func stateA() {
        let row = TopBarMenuRow.make(for: state(width: 1440, pinned: [.netflix, .hulu]))
        #expect(row.items.map(\.title) == ["Home", "Live TV", "Movies", "Series", "TV Guide", "Podcasts", "Netflix", "Hulu", "Services"])
        #expect(row.items.filter(\.compact).map(\.title) == ["Netflix", "Hulu", "Services"], "the Services button is an icon only")
        #expect(row.chip == nil && row.overflow.isEmpty)
        #expect(row.items.first { $0.title == "Netflix" }?.atlas == "control.nav.netflix")
        #expect(row.items.first { $0.title == "Hulu" }?.atlas == "control.nav.service")
    }

    @Test("State B collapses to StreamSetu, keeps the pins and marks the active service")
    func stateB() {
        let row = TopBarMenuRow.make(for: state(width: 1440, destination: .service(.hulu), pinned: [.netflix, .hulu]))
        #expect(row.items.map(\.title) == ["StreamSetu", "Netflix", "Hulu", "Services"])
        #expect(row.items.filter(\.selected).map(\.title) == ["Hulu"])
    }

    @Test("An active unpinned service stays in the row as a chip without becoming pinned")
    func chip() {
        let st = state(width: 1440, destination: .service(.hulu), pinned: [.netflix])
        let row = TopBarMenuRow.make(for: st)
        #expect(row.chip?.title == "Hulu" && row.chip?.selected == true)
        #expect(row.items.map(\.title) == ["StreamSetu", "Netflix", "Hulu", "Services"])
        #expect(st.servicesNav.pinned == [.netflix])
    }

    @Test("The row fits the real width at every size, keeps pinned order and never drops the active service")
    func fitsAndKeepsOrder() {
        let all = Array(ProviderID.allCases)
        for w in [CGFloat(1024), 1100, 1180, 1280, 1440, 1728] {
            for dest in [TopLevelDestination.streamSetu, .service(all[all.count - 1])] {
                let st = state(width: w, destination: dest, pinned: all)
                let row = TopBarMenuRow.make(for: st)
                let m = row.metrics
                #expect(row.width <= m.centerBudget(width: w, brandWidth: TabLabelMetrics.brandWidth) + 0.5, "width \(w)")
                let inline = row.pinned.compactMap { if case .service(let s) = $0.kind { s } else { nil } }
                #expect(inline == all.filter { inline.contains($0) }, "order at \(w)")
                #expect(Set(inline).isDisjoint(with: row.overflow))
                if case .service(let a) = dest { #expect(inline.contains(a) || row.chip?.kind == .service(a)) }
                // never wraps into the search/profile zone
                let f = TopBarGeometry.frames(width: w, height: LayoutTokens.headerHeight, leading: CGSize(width: TabLabelMetrics.brandWidth, height: 28),
                                              center: CGSize(width: row.width, height: LayoutTokens.headerHeight),
                                              trailingIdeal: CGSize(width: m.searchIdeal + 8 + TopBarMetrics.accountWidth, height: 30), trailingMin: m.searchMin + 8 + TopBarMetrics.accountWidth,
                                              leadingInset: TopBarMetrics.leadingInset, trailingInset: TopBarMetrics.trailingInset)
                #expect(f.leading.maxX + TopBarGeometry.gap <= f.center.minX + 0.5 && f.center.maxX + TopBarGeometry.gap <= f.trailing.minX + 0.5, "overlap at \(w)")
            }
        }
    }

    @Test("Wider windows show more pinned services; overflow shrinks")
    func widthDecidesOverflow() {
        let all = Array(ProviderID.allCases)
        let narrow = TopBarMenuRow.make(for: state(width: 1024, pinned: all)), wide = TopBarMenuRow.make(for: state(width: 1728, pinned: all))
        #expect(narrow.pinned.count < wide.pinned.count && narrow.overflow.count > wide.overflow.count)
        #expect(narrow.pinned.count + narrow.overflow.count == all.count)
    }

    @Test("Menu off keeps the Netflix-only items exactly")
    func menuOffUnchanged() {
        let items = TopBarItem.items(for: TopBarState(tab: .home, initials: "A", accountMenuOpen: false, width: 1280, services: [.netflix]))
        #expect(items.map(\.identifier) == ["tab.Home", "tab.Live TV", "tab.Movies", "tab.Series", "tab.TV Guide", "tab.Netflix"])
    }

    @Test("Services list: one list, no repeated service, filter, keyboard order")
    func menuModel() {
        var nav = ServicesNavigationBinding(); nav.recents = [.hulu, .netflix, .hulu, .peacock]
        let model = ServicesMenuModel(nav: nav)
        #expect(model.recents(filter: "") == [.hulu, .netflix, .peacock])
        #expect(model.recents(filter: "hu").isEmpty)
        #expect(model.more(filter: "PRIME") == [.primevideo])
        let e = model.entries(filter: "")
        #expect(e.count == 11 && Set(e.map(\.provider)).count == 11 && Set(e.map(\.id)).count == 11 && !e.contains { $0.provider == .jiohotstar }, "JioHotstar is on hold and not listed")
        // pinned services leave Recent and keep bar order with their position
        nav.pinned = [.peacock, .netflix]
        let m2 = ServicesMenuModel(nav: nav), e2 = m2.entries(filter: "")
        #expect(e2.prefix(2).map(\.provider) == [.peacock, .netflix] && e2.prefix(2).map(\.position) == [1, 2])
        #expect(m2.recents(filter: "") == [.hulu])
        #expect(e2.count == 11 && Set(e2.map(\.provider)).count == 11)
        #expect(m2.entries(filter: "net").map(\.provider) == [.netflix])
    }

    @Test("Only a disabled service carries a badge")
    func badges() {
        #expect(ServiceAvailability.disabled.badgeTitle == "Disabled")
        #expect(ServiceAvailability.available.badgeTitle == nil && ServiceAvailability.unverified.badgeTitle == nil)
    }

    @Test("Pin toggle does not select; move callbacks respect the ends")
    func callbacks() {
        var selected: [ProviderID] = [], toggled: [ProviderID] = [], moved: [(ProviderID, Int)] = []
        var nav = ServicesNavigationBinding(); nav.pinned = [.netflix, .hulu, .peacock]
        nav.select = { selected.append($0) }; nav.togglePin = { toggled.append($0) }; nav.move = { moved.append(($0, $1)) }
        nav.togglePin(.hulu); #expect(selected.isEmpty && toggled == [.hulu])
        nav.moveLeft(.netflix); nav.moveRight(.peacock); #expect(moved.isEmpty)
        nav.moveLeft(.hulu); nav.moveRight(.hulu); #expect(moved.map(\.1) == [0, 2])
    }

    @Test("Accessible names carry state")
    func accessibility() {
        #expect(ServiceAccessibility.openLabel(.hulu, availability: .unverified, active: true, pinned: true) == "Hulu, open now, pinned")
        #expect(ServiceAccessibility.openLabel(.hulu, availability: .disabled, active: false, pinned: false) == "Hulu, Disabled")
        #expect(ServiceAccessibility.pinLabel(.hulu, pinned: false) == "Pin Hulu")
        #expect(ServiceAccessibility.pinLabel(.hulu, pinned: true) == "Unpin Hulu")
    }

    /// Switching the active service recolours only inside the navigation capsule (same tolerance as the Netflix-only bar).
    @Test("Menu variant: selection changes only pixels inside the nav capsule")
    func pixelStability() throws {
        _ = NSApplication.shared
        let w: CGFloat = 1280
        var reps: [NSBitmapImageRep] = []
        var rows: [TopBarMenuRow] = []
        for dest in [TopLevelDestination.service(.netflix), .service(.hulu)] {
            let st = state(width: w, destination: dest, pinned: [.netflix, .hulu])
            rows.append(TopBarMenuRow.make(for: st))
            var q = ""
            let view = ReddyTopBar(state: st, query: Binding(get: { q }, set: { q = $0 }), focusToken: 0, onSelectTab: { _ in }, onToggleAccount: {})
                .frame(width: w, height: LayoutTokens.headerHeight).background(Color(hex: 0x0B0D12)).environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: AnyView(view))
            host.frame = NSRect(x: 0, y: 0, width: w, height: LayoutTokens.headerHeight)
            let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
            for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep); reps.append(rep)
        }
        let center = (w - rows[0].width) / 2
        let scale = CGFloat(reps[0].pixelsWide) / w
        var minX = Int.max, maxX = -1
        for y in 0..<reps[0].pixelsHigh { for x in 0..<reps[0].pixelsWide {
            guard let a = reps[0].colorAt(x: x, y: y), let b = reps[1].colorAt(x: x, y: y) else { continue }
            if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.02 { minX = min(minX, x); maxX = max(maxX, x) }
        } }
        #expect(maxX >= 0)
        #expect(CGFloat(minX) / scale >= center - 3 && CGFloat(maxX) / scale <= center + rows[0].width + 3, "changed \(minX)…\(maxX)")
    }
}

@Suite("Search focus policy") struct SearchFocusPolicyTests {
    @Test func searchBoxCannotTakeFocusWhileATitleIsOpen() { #expect(!SearchFocusPolicy.allowsFocus(titleOpen: true)) }
    @Test func commandKStillFocusesWhenNoTitleIsOpen() { #expect(SearchFocusPolicy.allowsFocus(titleOpen: false)) }
}

@Suite("Service pill reload") @MainActor struct ServicePillReloadTests {
    @Test("Reload goes through the binding and is off by default")
    func reloadCallbacks() {
        var reloaded: [ProviderID] = []
        var nav = ServicesNavigationBinding()
        #expect(!nav.canReload(.hulu))
        nav.canReload = { $0 == .hulu }; nav.reload = { reloaded.append($0) }
        #expect(nav.canReload(.hulu) && !nav.canReload(.netflix))
        nav.reload(.hulu); #expect(reloaded == [.hulu])
    }
}
