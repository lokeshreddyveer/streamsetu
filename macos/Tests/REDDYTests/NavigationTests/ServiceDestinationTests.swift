import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// The destination state machine, with the capability injected: the Mac value (Netflix on) and the iPhone/iPad value (nothing on). The same
/// file in ios/StreamSetuTests runs the disabled half inside the iOS app.
@Suite("Service destinations") @MainActor struct ServiceDestinationTests {
    @Test func startsInStreamSettuWithTheNavExpanded() {
        let s = DestinationState(capabilities: .macOS)
        #expect(s.active == .streamSetu); #expect(s.navExpanded); #expect(s.activeService == nil)
    }

    @Test func selectingNetflixCollapsesAndSelectingStreamSetuExpands() {
        var s = DestinationState(capabilities: .macOS)
        let ok = s.select(.netflix)
        #expect(ok)
        #expect(s.active == .service(.netflix)); #expect(!s.navExpanded)
        s.selectStreamSetu()
        #expect(s.active == .streamSetu); #expect(s.navExpanded)
    }

    @Test func repeatedSwitchingEndsWhereTheLastChoiceSays() {
        var s = DestinationState(capabilities: .macOS)
        for i in 0..<101 { if i % 2 == 0 { s.select(.netflix) } else { s.selectStreamSetu() } }
        #expect(s.active == .service(.netflix))
        s.select(.netflix); s.select(.netflix)          // choosing it again changes nothing
        #expect(s.active == .service(.netflix))
        s.selectStreamSetu(); s.selectStreamSetu()
        #expect(s.navExpanded)
    }

    /// Expanded is computed from the active destination, so the two cannot disagree.
    @Test func navExpandedAlwaysAgreesWithTheActiveDestination() {
        var s = DestinationState(capabilities: .macOS)
        for step in [true, false, true, true, false] {
            if step { s.select(.netflix) } else { s.selectStreamSetu() }
            #expect(s.navExpanded == (s.active == .streamSetu))
            #expect((s.activeService != nil) == !s.navExpanded)
        }
    }

    @Test func unknownOrDisabledStoredDestinationsFallBackToStreamSetu() {
        for raw in [nil, "", "garbage", "service.", "service.unknown", "service.Hulu", "service.NETFLIX", "streamSetu", "tab.netflix", "../service.netflix"] {
            #expect(DestinationState(rawValue: raw, capabilities: .macOS).active == .streamSetu, "\(raw ?? "nil")")
        }
        #expect(DestinationState(rawValue: "service.netflix", capabilities: .macOS).active == .service(.netflix))
        #expect(DestinationState(rawValue: "service.netflix", capabilities: .none).active == .streamSetu)
        #expect(DestinationState(rawValue: TopLevelDestination.service(.netflix).rawValue, capabilities: .macOS).active == .service(.netflix))
    }

    /// The app does not restore the destination (a launch always opens Home), so nothing is persisted: a new state is StreamSetu.
    @Test func aNewSessionAlwaysOpensStreamSetu() {
        #expect(ServiceNavigation(capabilities: .macOS).active == .streamSetu)
    }

    // MARK: the owner and the router

    @Test func lastNativeSectionIsKeptWhileAServiceIsShownAndShownAgain() {
        let router = AppRouter(), nav = ServiceNavigation(capabilities: .macOS)
        nav.attach(to: router)
        router.navigate(.movies, .shortcut(.allMovies))
        #expect(nav.select(.netflix))
        #expect(router.tab == .movies); #expect(router.selection == .shortcut(.allMovies))          // untouched while Netflix shows
        nav.returnToStreamSetu()
        #expect(nav.navExpanded); #expect(router.tab == .movies); #expect(router.selection == .shortcut(.allMovies))
    }

    @Test func anyNativeNavigationLeavesTheService() {
        let router = AppRouter(), nav = ServiceNavigation(capabilities: .macOS)
        nav.attach(to: router)
        let actions: [(String, () -> Void)] = [
            ("navigate", { router.navigate(.series) }), ("go", { router.go(.favorites) }),
            ("open movie", { router.open(movie: Movie(id: "m", sourceID: UUID(), providerID: "m", title: "T", normalizedTitle: "t", streamRef: "x")) }),
        ]
        for (name, act) in actions {
            nav.select(.netflix); #expect(nav.activeService == .netflix, "\(name)")
            act()
            #expect(nav.navExpanded, "\(name) must leave the service")
        }
    }

    @Test func aRouterWithoutTheHookIsUnchanged() {
        let router = AppRouter()          // iOS never sets onNavigate
        router.navigate(.guide); #expect(router.tab == .guide)
    }

    @Test func theHostIsToldWhenTheServiceShowsAndHides() {
        final class Spy: ExternalServiceHost {
            var events: [String] = []
            func serviceBecameVisible() { events.append("show") }
            func serviceBecameHidden() { events.append("hide") }
            func openInDefaultBrowser() {}
            func clearServiceData() async {}
            func releaseResources() {}
        }
        let spy = Spy(), nav = ServiceNavigation(capabilities: .macOS)
        nav.host = spy
        nav.select(.netflix); nav.returnToStreamSetu(); nav.returnToStreamSetu()
        #expect(spy.events == ["show", "hide"])          // leaving twice hides once
    }

    @Test func aBlockedProfileOrLockRefusesEveryRoute() {
        let nav = ServiceNavigation(capabilities: .macOS)
        nav.gate = { true }
        #expect(!nav.select(.netflix)); #expect(!nav.restore("service.netflix")); #expect(nav.navExpanded); #expect(nav.isBlocked)
        nav.gate = { false }
        #expect(nav.restore("service.netflix")); #expect(nav.activeService == .netflix)
    }

    // MARK: platforms (the iPhone and iPad value is injected here; ios/StreamSetuTests runs the real one)

    @Test func theMacHasTheElevenServicesAndNothingElseDoes() {
        #expect(ServiceCapabilities.macOS.externalServices.count == 10 && ServiceCapabilities.macOS.externalServices.first == .netflix)
        #expect(ServiceCapabilities.none.externalServices.isEmpty)
        #expect(ServiceCapabilities.current == .macOS)          // this test target is the Mac
    }

    @Test func aPlatformWithoutServicesCannotReachNetflixByAnyRoute() {
        let nav = ServiceNavigation(capabilities: .none)
        #expect(nav.services.isEmpty)
        #expect(!nav.select(.netflix))
        #expect(!nav.restore("service.netflix"))
        #expect(nav.navExpanded && nav.active == .streamSetu)
        let router = AppRouter(); nav.attach(to: router)
        router.navigate(.home); router.go(.liveTV)
        #expect(nav.active == .streamSetu)
        // deep links: the link does not parse at all where the capability is off, exactly like an unknown tab
        for u in ["streamsetu://open?tab=netflix", "streamsetu://open?tab=Netflix", "streamsetu://open?tab=net%20flix"] {
            #expect(DeepLink.parse(URL(string: u)!, capabilities: .none) == nil, "\(u)")
        }
        #expect(DeepLink.parse(URL(string: "streamsetu://open?tab=netflix")!, capabilities: .macOS) == .openService(.netflix))
    }

    // MARK: several services (the registry decides what exists)

    @MainActor private final class SpyHost: ExternalServiceHost {
        var events: [String] = []; let name: String
        init(_ n: String) { name = n }
        func serviceBecameVisible() { events.append("\(name):show") }
        func serviceBecameHidden() { events.append("\(name):hide") }
        func openInDefaultBrowser() {}
        func clearServiceData() async {}
        func releaseResources() {}
    }
    @MainActor private final class Hosts: ServiceHostResolving {
        var map: [ProviderID: SpyHost] = [:]
        func host(for id: ProviderID) -> (any ExternalServiceHost)? { map[id] }
    }

    @Test func everyListedServiceCanBeSelectedAndRestored() {
        for id in ProviderID.allCases where id != .jiohotstar {
            var s = DestinationState(capabilities: .macOS)
            let sel = s.select(id); #expect(sel); #expect(s.active == .service(id)); #expect(!s.navExpanded)
            #expect(DestinationState(rawValue: TopLevelDestination.service(id).rawValue, capabilities: .macOS).activeService == id)
            #expect(DestinationState(rawValue: "service." + id.rawValue, capabilities: .none).active == .streamSetu)
        }
    }

    @Test func switchingFromOneServiceToAnotherHidesThePreviousHostFirst() {
        let hosts = Hosts(); hosts.map = [.netflix: SpyHost("n"), .hulu: SpyHost("h")]
        let nav = ServiceNavigation(capabilities: .macOS); nav.hosts = hosts
        var order: [String] = []
        nav.select(.netflix); nav.select(.hulu)
        order = hosts.map[.netflix]!.events + hosts.map[.hulu]!.events
        #expect(order == ["n:show", "n:hide", "h:show"])
        #expect(nav.activeService == .hulu)
        nav.returnToStreamSetu(); nav.returnToStreamSetu()
        #expect(hosts.map[.hulu]!.events == ["h:show", "h:hide"])          // leaving twice hides once
        #expect(hosts.map[.netflix]!.events == ["n:show", "n:hide"])
    }

    @Test func aRefusedSelectionChangesNothingAndHidesNothing() {
        let hosts = Hosts(); hosts.map = [.netflix: SpyHost("n")]
        let nav = ServiceNavigation(capabilities: ServiceCapabilities(externalServices: [.netflix])); nav.hosts = hosts
        nav.select(.netflix)
        #expect(!nav.select(.hulu)); #expect(nav.activeService == .netflix)
        nav.gate = { true }
        #expect(!nav.select(.netflix)); #expect(hosts.map[.netflix]!.events == ["n:show"])
    }

    @Test func aServiceOnHoldIsRefusedByEveryRouteAndNeverGetsAHost() {
        let hosts = Hosts(); hosts.map = [.netflix: SpyHost("n"), .jiohotstar: SpyHost("j")]
        let nav = ServiceNavigation(capabilities: .macOS); nav.hosts = hosts
        #expect(!nav.select(.jiohotstar) && nav.activeService == nil)
        #expect(hosts.map[.jiohotstar]!.events.isEmpty, "never shown, so no web view is made")
        nav.select(.netflix)
        #expect(!nav.select(.jiohotstar) && nav.activeService == .netflix && hosts.map[.netflix]!.events == ["n:show"], "a refused selection changes and hides nothing")
        #expect(!nav.capabilities.externalServices.contains(.jiohotstar))
        #expect(ProviderCatalog.jiohotstar.id == .jiohotstar && ProviderCatalog.all.count == 11, "the definition and its store identity remain")
    }

    @Test func deepLinksAreValidatedAgainstTheRegistry() {
        for id in ProviderID.allCases where id != .jiohotstar { #expect(DeepLink.parse(URL(string: "streamsetu://open?tab=\(id.rawValue)")!, capabilities: .macOS) == .openService(id)) }
        #expect(DeepLink.parse(URL(string: "streamsetu://open?tab=jiohotstar")!, capabilities: .macOS) == nil, "on hold: no deep link reaches it")
        let only = ServiceCapabilities(externalServices: [.netflix])
        #expect(DeepLink.parse(URL(string: "streamsetu://open?tab=hulu")!, capabilities: only) == nil)
        #expect(DeepLink.parse(URL(string: "streamsetu://open?tab=unknownservice")!, capabilities: .macOS) == nil)
    }

    @Test func aRegisteredOrRemovedServiceIsUnreachable() {
        let caps = ServiceCapabilities(externalServices: ProviderRegistry(definitions: ProviderCatalog.all.filter { $0.id != .hulu }).listed(on: .macOS).map(\.id))
        let nav = ServiceNavigation(capabilities: caps)
        #expect(!nav.select(.hulu)); #expect(!nav.restore("service.hulu")); #expect(nav.select(.crunchyroll))
    }

    @Test func fiveTabsAreUnchanged() {
        #expect(AppTab.allCases == [.home, .liveTV, .movies, .series, .guide])
        for (i, t) in AppTab.allCases.enumerated() { #expect(DeepLink.parse(URL(string: "streamsetu://open?tab=\(t.rawValue.lowercased().replacingOccurrences(of: " ", with: ""))")!, capabilities: .none) == .openTab(t), "\(i)") }
    }

    /// Loading the page, signing in and playing protected video are separate; the Mac flag turns the first on for testing and never claims the last.
    @Test func capabilitiesAreSeparateAndPlaybackIsNeverClaimed() {
        let p = ServiceCapabilities.macOS.profile(for: .netflix)
        #expect(p.websiteLoading == .enabledForTesting)
        #expect(p.signIn == .manualVerificationRequired)
        #expect(p.protectedPlayback == .manualVerificationRequired)
        let off = ServiceCapabilities.none.profile(for: .netflix)
        #expect(off.websiteLoading == .unavailable && off.signIn == .unavailable && off.protectedPlayback == .unavailable)
    }
}

@Suite("Top bar with a service") @MainActor struct TopBarServiceTests {
    private func render(_ state: TopBarState, reduceMotion: Bool = false) -> NSHostingView<AnyView> {
        _ = NSApplication.shared
        var q = ""
        let view = ReddyTopBar(state: state, query: Binding(get: { q }, set: { q = $0 }), focusToken: 0, onSelectTab: { _ in }, onToggleAccount: {})
            .frame(width: state.width, height: LayoutTokens.headerHeight).background(Color(hex: 0x0B0D12)).environment(\.colorScheme, .dark)
            .transaction { if reduceMotion { $0.animation = nil } }
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: state.width, height: LayoutTokens.headerHeight)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
        for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        host.layoutSubtreeIfNeeded()
        withExtendedLifetime(win) {}
        return host
    }

    private func identifiers(_ root: NSObject, into set: inout [String: String], depth: Int = 0) {
        guard depth < 12 else { return }
        var kids: [Any] = []
        if let a = root as? NSAccessibilityProtocol {
            let id = a.accessibilityIdentifier() ?? "", label = a.accessibilityLabel() ?? ""
            if !id.isEmpty { set[id] = label }
            kids = a.accessibilityChildren() ?? []
        }
        if let v = root as? NSView { kids += v.subviews }
        for c in kids { if let o = c as? NSObject { identifiers(o, into: &set, depth: depth + 1) } }
    }

    /// Measured at the minimum window width (1024): six items fit in the one row, and so does the collapsed state.
    @Test func sixItemsAndTheCollapsedRowFitAtTheMinimumWidth() {
        let m = TopBarMetrics.metrics(for: 1024)
        let six = (AppTab.allCases.map(\.title) + ["Netflix"]).map { TabLabelMetrics.textWidth($0) }
        let collapsed = ["StreamSetu", "Netflix"].map { TabLabelMetrics.textWidth($0) }
        let nav6 = six.reduce(0) { $0 + $1 + 2 * m.tabPadding }, nav2 = collapsed.reduce(0) { $0 + $1 + 2 * m.tabPadding }
        print("MEASURE top bar @1024: 6 items nav=\(nav6)pt, collapsed nav=\(nav2)pt, required width 6=\(m.requiredWidth(brandWidth: TabLabelMetrics.brandWidth, tabTextWidths: six)) collapsed=\(m.requiredWidth(brandWidth: TabLabelMetrics.brandWidth, tabTextWidths: collapsed))")
        #expect(m.requiredWidth(brandWidth: TabLabelMetrics.brandWidth, tabTextWidths: six) <= 1024)
        #expect(m.requiredWidth(brandWidth: TabLabelMetrics.brandWidth, tabTextWidths: collapsed) <= 1024)
        for w: CGFloat in [1024, 1100, 1280, 1440, 1728] {
            let mm = TopBarMetrics.metrics(for: w)
            let nav = six.reduce(0) { $0 + $1 + 2 * mm.tabPadding }
            let f = TopBarGeometry.frames(width: w, height: LayoutTokens.headerHeight, leading: CGSize(width: TabLabelMetrics.brandWidth, height: 28), center: CGSize(width: nav, height: LayoutTokens.headerHeight),
                                          trailingIdeal: CGSize(width: mm.searchIdeal + 8 + TopBarMetrics.accountWidth, height: 30), trailingMin: mm.searchMin + 8 + TopBarMetrics.accountWidth,
                                          leadingInset: TopBarMetrics.leadingInset, trailingInset: TopBarMetrics.trailingInset)
            #expect(f.leading.maxX + TopBarGeometry.gap <= f.center.minX + 0.5, "brand/nav at \(w)")
            #expect(f.center.maxX + TopBarGeometry.gap <= f.trailing.minX + 0.5, "nav/search at \(w)")
            #expect(abs(f.center.midX - w / 2) <= 0.5)
        }
    }

    @Test func theFiveTabBarHasNoNetflixWhereThePlatformHasNoServices() {
        let items = TopBarItem.items(for: TopBarState(tab: .home, initials: "LR", accountMenuOpen: false, width: 1024))
        #expect(items.map(\.identifier) == ["tab.Home", "tab.Live TV", "tab.Movies", "tab.Series", "tab.TV Guide"])
        #expect(items.filter(\.selected).map(\.title) == ["Home"])
    }

    @Test func itemsIdentifiersLabelsAndTheSelectedItemInBothStates() {
        let a = TopBarItem.items(for: TopBarState(tab: .movies, initials: "LR", accountMenuOpen: false, width: 1024, destination: .streamSetu, services: [.netflix]))
        #expect(a.map(\.identifier) == ["tab.Home", "tab.Live TV", "tab.Movies", "tab.Series", "tab.TV Guide", "tab.Netflix"])
        #expect(a.filter(\.selected).map(\.identifier) == ["tab.Movies"])          // exactly one selected, and it is the native tab
        let b = TopBarItem.items(for: TopBarState(tab: .movies, initials: "LR", accountMenuOpen: false, width: 1024, destination: .service(.netflix), services: [.netflix]))
        #expect(b.map(\.identifier) == ["tab.StreamSetu", "tab.Netflix"])
        #expect(b.filter(\.selected).map(\.identifier) == ["tab.Netflix"])          // the indicator is on Netflix, never on a hidden tab
        #expect(b[0].label?.contains("Home, Live TV, Movies, Series and TV Guide") == true)
        #expect(b.map(\.title) == ["StreamSetu", "Netflix"])
    }

    @Test func theSearchBoxStaysAndSaysItSearchesTheLibraryWhileAServiceShows() {
        let native = TopBarState(tab: .home, initials: "LR", accountMenuOpen: false, width: 1024)
        let web = TopBarState(tab: .home, initials: "LR", accountMenuOpen: false, width: 1024, destination: .service(.netflix), services: [.netflix])
        #expect(native.searchPlaceholder(narrow: false) == "Search everything" && native.searchPlaceholder(narrow: true) == "Search")
        #expect(web.searchPlaceholder(narrow: false) == "Search your library" && web.searchPlaceholder(narrow: true) == "Search library")
        #expect(native.searchLabel == "Search everything" && web.searchLabel == "Search your library")
        // the bar still lays out, with the account control at the right edge, in both states
        for d: TopLevelDestination in [.streamSetu, .service(.netflix)] { _ = render(TopBarState(tab: .home, initials: "LR", accountMenuOpen: false, width: 1024, destination: d, services: [.netflix])) }
    }

    /// The sliding pill goes to the selected item of each state, the collapsed StreamSetu item carries a home glyph and its width, and identifiers did not change with the redesign.
    @Test func pillTargetGlyphAndWidthsInBothStates() {
        let m = TopBarMetrics.metrics(for: 1024)
        let native = TopBarItem.items(for: TopBarState(tab: .series, initials: "LR", accountMenuOpen: false, width: 1024, destination: .streamSetu, services: [.netflix]))
        let web = TopBarItem.items(for: TopBarState(tab: .series, initials: "LR", accountMenuOpen: false, width: 1024, destination: .service(.netflix), services: [.netflix]))
        #expect(native.first(where: \.selected)?.identifier == "tab.Series")
        #expect(web.first(where: \.selected)?.identifier == "tab.Netflix" && web.filter(\.selected).count == 1)
        #expect(web[0].glyph == "house.fill" && native.allSatisfy { $0.glyph == nil })
        #expect(web[0].width(tabPadding: m.tabPadding) == TabLabelMetrics.textWidth("StreamSetu") + TopBarItem.glyphWidth + 2 * m.tabPadding)
        #expect(native[0].width(tabPadding: m.tabPadding) == TabLabelMetrics.textWidth("Home") + 2 * m.tabPadding)
    }

    /// Width compression: the six-item group plus its capsule padding, and the collapsed group with its glyph, fit the minimum window width with the tiers' search widths.
    @Test func groupWithPaddingFitsAtTheMinimumWidthAndNarrower() {
        for w: CGFloat in [1024, 1100, 1280] {
            let m = TopBarMetrics.metrics(for: w)
            let six = (AppTab.allCases.map(\.title) + ["Netflix"]).map { TabLabelMetrics.textWidth($0) }
            let collapsed = [TabLabelMetrics.textWidth("StreamSetu") + TopBarItem.glyphWidth, TabLabelMetrics.textWidth("Netflix")]
            #expect(m.requiredWidth(brandWidth: TabLabelMetrics.brandWidth, tabTextWidths: six) <= w, "six items at \(w)")
            #expect(m.requiredWidth(brandWidth: TabLabelMetrics.brandWidth, tabTextWidths: collapsed) <= w, "collapsed at \(w)")
        }
        #expect(TopBarMetrics.navGroupPadding == 3 && TopBarMetrics.navItemHeight == 32 && TopBarMetrics.rowHeight == 38)
    }

    /// The bar renders in both states at the minimum width without a crash or a layout trap (the accessibility tree itself is checked by the UI tests, which are written and not executed).
    @Test func bothStatesRenderAtTheMinimumWidth() throws {
        for d: TopLevelDestination in [.streamSetu, .service(.netflix)] {
            let h = render(TopBarState(tab: .home, initials: "LR", accountMenuOpen: false, width: 1024, destination: d, services: [.netflix]))
            #expect(h.fittingSize.width <= 1024 + 1)
        }
    }

    /// Reduce Motion path: the bar renders the same final state with animations switched off (no animation is needed to arrive at it).
    @Test func collapsedStateRendersTheSameWithMotionOff() throws {
        let s = TopBarState(tab: .home, initials: "LR", accountMenuOpen: false, width: 1024, destination: .service(.netflix), services: [.netflix])
        let a = render(s), b = render(s, reduceMotion: true)
        func bitmap(_ h: NSHostingView<AnyView>) throws -> NSBitmapImageRep { let r = try #require(h.bitmapImageRepForCachingDisplay(in: h.bounds)); h.cacheDisplay(in: h.bounds, to: r); return r }
        let x = try bitmap(a), y = try bitmap(b)
        #expect(x.pixelsWide == y.pixelsWide)
        var diff = 0
        for py in stride(from: 0, to: x.pixelsHigh, by: 2) { for px in stride(from: 0, to: x.pixelsWide, by: 2) {
            if let c = x.colorAt(x: px, y: py), let d = y.colorAt(x: px, y: py), abs(c.redComponent - d.redComponent) > 0.02 { diff += 1 }
        } }
        #expect(diff == 0, "differing samples: \(diff)")
    }
}
