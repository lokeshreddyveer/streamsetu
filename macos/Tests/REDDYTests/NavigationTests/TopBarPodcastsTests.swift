import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// The redesigned top bar (State A: StreamSetu's own screens, State B: a service is open) and Podcasts as a main-window destination.
/// Every layout rule here is a pure function of the window width and the state; nothing needs a window.
@Suite("Top bar: states, favicon chips and Podcasts") @MainActor struct TopBarPodcastsTests {
    private func state(width: CGFloat, destination: TopLevelDestination = .streamSetu, pinned: [ProviderID], tab: AppTab = .home, modes: TopBarTabModes = TopBarTabModes()) -> TopBarState {
        var nav = ServicesNavigationBinding(); nav.pinned = pinned; nav.tabModes = modes
        if case .service(let s) = destination { nav.active = s }
        return TopBarState(tab: tab, initials: "LR", accountMenuOpen: false, width: width, destination: destination, services: [], showsServicesMenu: true, servicesNav: nav)
    }
    private func ids(_ row: TopBarMenuRow) -> [ProviderID] { row.pinned.compactMap { if case .service(let s) = $0.kind { s } else { nil } } }
    private let widths: [CGFloat] = [1024, 1100, 1180, 1280, 1440, 1728, 2200]
    private let all = Array(ProviderID.allCases)

    // MARK: State A and State B

    @Test("State A: full names for the six native items (Podcasts last), favicon-only chips after them, Services at the end")
    func stateA() {
        let row = TopBarMenuRow.make(for: state(width: 1440, pinned: [.netflix, .hulu, .peacock], tab: .movies))
        #expect(row.mode == .native)
        #expect(row.items.map(\.title) == ["Home", "Live TV", "Movies", "Series", "TV Guide", "Podcasts", "Netflix", "Hulu", "Peacock", "Services"])
        #expect(row.leading.last?.kind == .podcasts && row.leading.last?.glyph == "mic.fill")
        #expect(row.items.filter(\.selected).map(\.title) == ["Movies"])
        #expect(row.pinned.allSatisfy { $0.compact && $0.icon != nil && $0.label == nil })
        #expect(row.pinned.allSatisfy { $0.width(tabPadding: row.tabPadding) == ServiceChip.hitWidth })
        #expect(row.leading.allSatisfy { !$0.compact })
    }

    @Test("State B: the StreamSetu chip (no tabs), the open service expanded in its pinned place, the other pins as favicons")
    func stateB() {
        let row = TopBarMenuRow.make(for: state(width: 1440, destination: .service(.hulu), pinned: [.netflix, .hulu, .peacock]))
        #expect(row.mode == .service)
        #expect(row.items.map(\.title) == ["StreamSetu", "Netflix", "Hulu", "Peacock", "Services"])
        #expect(!row.items.contains { $0.isTab || $0.kind == .podcasts })
        #expect(row.leading.count == 1 && row.leading[0].title == "StreamSetu" && row.leading[0].label == TopBarItem.collapsedLabel)
        let hulu = row.pinned[1]
        #expect(hulu.selected && !hulu.compact && hulu.help == nil)
        #expect(hulu.width(tabPadding: row.tabPadding) == ServiceChip.expandedWidth(textWidth: TabLabelMetrics.textWidth("Hulu"), tabPadding: row.tabPadding))
        #expect(row.pinned.filter(\.compact).map(\.title) == ["Netflix", "Peacock"])
        #expect(row.items.filter(\.selected).map(\.title) == ["Hulu"])
    }

    @Test("Favicon-only chips are small (about 32 pt) and the expanded service is wider than its chip")
    func chipSizes() {
        #expect(ServiceChip.iconSize == 22 && ServiceChip.hitWidth == 32 && ServiceChip.iconLead == 5)
        let compact = TopBarMenuRow.serviceItem(.netflix, active: nil), open = TopBarMenuRow.serviceItem(.netflix, active: .netflix)
        #expect(compact.width(tabPadding: 11) == 32)
        #expect(open.width(tabPadding: 11) > compact.width(tabPadding: 11) + TabLabelMetrics.textWidth("Netflix"))
        #expect(TopBarItem.items(for: TopBarState(tab: .home, initials: "A", accountMenuOpen: false, width: 1280)).allSatisfy { !$0.compact })
    }

    @Test("Accessibility and help: an icon-only chip is named and explained by the full service name; the open service needs no tooltip")
    func labelsAndHelp() {
        let row = TopBarMenuRow.make(for: state(width: 1728, destination: .service(.hulu), pinned: [.netflix, .hulu]))
        let net = row.pinned[0], hulu = row.pinned[1]
        #expect(net.help == "Netflix" && (net.label ?? net.title) == "Netflix" && net.identifier == "tab.Netflix")
        #expect(hulu.help == nil && (hulu.label ?? hulu.title) == "Hulu")
        #expect(TopBarItem.streamSetuChip().label == "StreamSetu, shows Home, Live TV, Movies, Series, TV Guide and Podcasts")
        for id in ProviderID.allCases { #expect(TopBarMenuRow.serviceItem(id, active: nil).help == id.title) }
    }

    @Test("Netflix keeps its store id and stays the only default pin")
    func netflixAndDefaults() {
        #expect(ProviderID.netflix.rawValue == "netflix" && ProviderID.netflix.title == "Netflix")
        #expect(ProviderCatalog.defaultPinned == [.netflix])
        #expect(ServicePreferences.initial().pinned == [.netflix])
    }

    // MARK: width planning

    @Test("At every width, in both states, the row fits its budget, keeps pinned order and never overlaps search or the profile")
    func fitsEveryWidth() {
        for w in widths {
            for dest in [TopLevelDestination.streamSetu, .podcasts, .service(all[all.count - 1]), .service(.netflix)] {
                let row = TopBarMenuRow.make(for: state(width: w, destination: dest, pinned: all))
                let m = row.metrics     // the tier the row was planned with (a narrower tier can keep more names or pins)
                #expect(row.width <= m.centerBudget(width: w, brandWidth: TabLabelMetrics.brandWidth) + 0.5, "\(dest) at \(w): \(row.width)")
                #expect(ids(row) == all.filter { ids(row).contains($0) }, "inline order at \(w) for \(dest)")
                #expect(row.overflow == all.filter { row.overflow.contains($0) }, "overflow order at \(w) for \(dest)")
                #expect(Set(ids(row)).isDisjoint(with: row.overflow))
                #expect(Set(ids(row)).union(row.overflow) == Set(all), "every pinned service is inline or in the list at \(w)")
                let f = TopBarGeometry.frames(width: w, height: LayoutTokens.headerHeight, leading: CGSize(width: TabLabelMetrics.brandWidth, height: 28),
                                              center: CGSize(width: row.width, height: LayoutTokens.headerHeight),
                                              trailingIdeal: CGSize(width: m.searchIdeal + 8 + TopBarMetrics.accountWidth, height: 30), trailingMin: m.searchMin + 8 + TopBarMetrics.accountWidth,
                                              leadingInset: TopBarMetrics.leadingInset, trailingInset: TopBarMetrics.trailingInset)
                #expect(f.leading.maxX + TopBarGeometry.gap <= f.center.minX + 0.5 && f.center.maxX + TopBarGeometry.gap <= f.trailing.minX + 0.5, "overlap at \(w) for \(dest)")
                #expect(f.trailing.width >= m.searchMin + 8 + TopBarMetrics.accountWidth - 0.5, "search kept its minimum at \(w)")
            }
        }
    }

    @Test("Every native item and Services are visible at the narrowest supported window; only pinned services overflow")
    func nativeItemsNeverHidden() {
        for dest in [TopLevelDestination.streamSetu, .podcasts] {
            let row = TopBarMenuRow.make(for: state(width: 1024, destination: dest, pinned: all))
            #expect(row.leading.map(\.title) == ["Home", "Live TV", "Movies", "Series", "TV Guide", "Podcasts"])
            #expect(row.items.last?.kind == .servicesMenu)
            #expect(row.pinned.count + row.overflow.count == all.count)
        }
    }

    @Test("Favicon-only chips let more pinned services fit than the old name pills did")
    func moreServicesFit() {
        for w in [CGFloat(1180), 1440, 1728] {
            let compactRow = TopBarMenuRow.make(for: state(width: w, pinned: all))
            let m = compactRow.metrics
            // what the same row would hold if every service still drew its name (the previous bar)
            let namedWidth = all.map { TabLabelMetrics.textWidth($0.title) + 2 * m.tabPadding }
            let leadingW = compactRow.leading.reduce(0) { $0 + $1.width(tabPadding: m.tabPadding) }
            let budget = m.centerBudget(width: w, brandWidth: TabLabelMetrics.brandWidth) - 2 * TopBarMetrics.navGroupPadding - leadingW - compactRow.servicesItem.width(tabPadding: m.tabPadding)
            var used: CGFloat = 0, namedCount = 0
            for n in namedWidth { if used + n <= budget { used += n; namedCount += 1 } else { break } }
            #expect(compactRow.pinned.count >= namedCount, "width \(w): \(compactRow.pinned.count) vs \(namedCount)")
            #expect(compactRow.pinned.count == min(all.count, Int(budget / ServiceChip.hitWidth)) || compactRow.pinned.count == all.count, "width \(w)")
        }
    }

    @Test("Wider windows show more pinned services and never fewer names in either state; overflow shrinks (names are kept, pins overflow first)")
    func monotonic() {
        for dest in [TopLevelDestination.streamSetu, .service(.netflix)] {
            var last = 0, lastNames = 0
            for w in widths {
                let row = TopBarMenuRow.make(for: state(width: w, destination: dest, pinned: all))
                #expect(row.pinned.count >= last, "\(dest) \(w)"); last = row.pinned.count
                let names = row.leading.filter { !$0.compact }.count
                #expect(names >= lastNames, "\(dest) \(w) names"); lastNames = names
            }
        }
    }

    @Test("The open service is never overflowed: pinned, it keeps its place; unpinned, it follows the pins as an expanded chip")
    func activeIsAlwaysVisible() {
        let last = all[all.count - 1]
        let pinned = TopBarMenuRow.make(for: state(width: 1024, destination: .service(last), pinned: all))
        #expect(ids(pinned).contains(last) && !pinned.overflow.contains(last) && pinned.pinned.first { $0.kind == .service(last) }?.compact == false)
        let unpinned = TopBarMenuRow.make(for: state(width: 1024, destination: .service(.hulu), pinned: [.netflix]))
        #expect(unpinned.chip?.title == "Hulu" && unpinned.chip?.compact == false && unpinned.chip?.selected == true)
        #expect(unpinned.items.map(\.title) == ["StreamSetu", "Netflix", "Hulu", "Services"])
        let crowded = TopBarMenuRow.make(for: state(width: 1024, destination: .service(.hulu), pinned: all.filter { $0 != .hulu }))
        #expect(crowded.chip?.title == "Hulu")
        #expect(crowded.pinned.count + crowded.overflow.count == all.count - 1)
    }

    @Test("Moving between states changes the same service from a chip to an expanded item and back, keeping its place in the order")
    func transitionKeepsOrder() {
        let a = TopBarMenuRow.make(for: state(width: 1440, pinned: [.netflix, .hulu, .peacock]))
        let b = TopBarMenuRow.make(for: state(width: 1440, destination: .service(.hulu), pinned: [.netflix, .hulu, .peacock]))
        #expect(ids(a) == ids(b))
        #expect(a.pinned.map(\.identifier) == b.pinned.map(\.identifier))
        #expect(a.pinned[1].compact && !b.pinned[1].compact)
        // the row is a pure function of its inputs
        #expect(TopBarMenuRow.make(for: state(width: 1440, pinned: [.netflix, .hulu, .peacock])) == a)
    }

    @Test("Reduce Motion swaps instantly; otherwise one smooth animation drives the whole change")
    func reduceMotion() {
        #expect(NavTransition.animation(reduceMotion: true) == nil)
        #expect(NavTransition.animation(reduceMotion: false) != nil)
        let a = NavKey(ids: ["tab.Home"], selected: "tab.Home", chip: false), b = NavKey(ids: ["tab.StreamSetu", "tab.Netflix"], selected: "tab.Netflix", chip: false)
        #expect(a != b)          // a state change is one value change, so one transaction
    }

    // MARK: Podcasts in the bar, hidden, and in the Services list

    @Test("Podcasts selected: exactly one item is selected, and it is Podcasts")
    func podcastsSelected() {
        let row = TopBarMenuRow.make(for: state(width: 1440, destination: .podcasts, pinned: [.netflix], tab: .series))
        #expect(row.items.filter(\.selected).map(\.identifier) == ["tab.Podcasts"])
        #expect(TopBarState(tab: .home, initials: "A", accountMenuOpen: false, width: 1024, destination: .podcasts).searchLabel == "Search everything")
    }

    @Test("An old stored podcastsInBar value is ignored without error, Podcasts is always in the bar, and the key is never written again")
    func oldHiddenValueIsIgnored() throws {
        let old = Data(#"{"pinned":["netflix","hulu"],"recents":["peacock"],"podcastsInBar":false}"#.utf8)
        let p = ServicePreferences.decode(old)
        #expect(p.pinned == [.netflix, .hulu] && p.recents == [.peacock])
        let keys = try #require(JSONSerialization.jsonObject(with: p.encoded()) as? [String: Any]).keys.sorted()
        #expect(keys == ["pinned", "recents"])
        let row = TopBarMenuRow.make(for: state(width: 1440, pinned: [.netflix]))
        #expect(row.leading.last?.kind == .podcasts)
        #expect(ServicePreferences.decode(Data(#"["netflix"]"#.utf8)).pinned == [.netflix] && ServicePreferences.decode(nil).pinned == [.netflix])
    }

    @Test("Podcasts is a destination, not an AppTab")
    func destinationModel() {
        #expect(TopLevelDestination.podcasts.rawValue == "podcasts" && TopLevelDestination.podcasts.isNative && TopLevelDestination.streamSetu.isNative)
        #expect(!TopLevelDestination.service(.netflix).isNative)
        #expect(AppTab.allCases.map(\.title) == ["Home", "Live TV", "Movies", "Series", "TV Guide"])
        #expect(DestinationState(rawValue: "podcasts", capabilities: .macOS).active == .podcasts)
        var s = DestinationState(capabilities: .macOS)
        s.selectPodcasts()
        #expect(s.active == .podcasts && s.navExpanded && !s.showsTabs && s.activeService == nil)
    }

    @Test("From Podcasts into a service and back returns to Podcasts; a tab always returns to the tabs")
    func returnsToWhereYouWere() {
        let router = AppRouter(), nav = ServiceNavigation(capabilities: .macOS)
        nav.attach(to: router)
        router.navigate(.series)
        #expect(nav.selectPodcasts() && nav.active == .podcasts && nav.navExpanded && !nav.showsTabs)
        #expect(nav.select(.netflix) && nav.activeService == .netflix)
        nav.returnToStreamSetu()
        #expect(nav.active == .podcasts)          // the last native screen was Podcasts
        router.navigate(.guide)
        #expect(nav.active == .streamSetu && nav.showsTabs && router.tab == .guide)
        #expect(nav.select(.hulu)); nav.returnToStreamSetu()
        #expect(nav.active == .streamSetu && router.tab == .guide)          // the last tab is restored
        nav.selectPodcasts(); router.open(movie: Movie(id: "m", sourceID: UUID(), providerID: "m", title: "T", normalizedTitle: "t", streamRef: "x"))
        #expect(nav.active == .streamSetu)
        nav.selectPodcasts(); nav.returnToStreamSetu(); #expect(nav.active == .podcasts)          // not in a service: nothing to return from
    }

    @Test("Opening Podcasts stops a service first, and the router can open it by name")
    func opensFromServiceAndRouter() {
        final class Spy: ExternalServiceHost {
            var events: [String] = []
            func serviceBecameVisible() { events.append("show") }
            func serviceBecameHidden() { events.append("hide") }
            func openInDefaultBrowser() {}
            func clearServiceData() async {}
            func releaseResources() {}
        }
        let spy = Spy(), router = AppRouter(), nav = ServiceNavigation(capabilities: .macOS)
        nav.host = spy; nav.attach(to: router)
        nav.select(.netflix); #expect(nav.selectPodcasts()); #expect(spy.events == ["show", "hide"] && nav.activeService == nil)
        router.go(.home); #expect(nav.active == .streamSetu)
        router.go(.podcasts); #expect(nav.active == .podcasts)
        #expect(AppRouter().tab == .home); AppRouter().go(.podcasts)          // a router without the hook (iOS) ignores it
    }

    @Test("Locked: Podcasts cannot be opened and nothing else changes. Kids profile: Podcasts is refused too (the public directory is unfiltered), services as well")
    func lockAndKids() {
        let nav = ServiceNavigation(capabilities: .macOS)
        nav.lockGate = { true }; nav.gate = { true }
        #expect(!nav.selectPodcasts() && nav.active == .streamSetu)
        nav.lockGate = { false }; nav.kidsGate = { true }          // a Kids profile: the services gate is on, the lock is not
        #expect(!nav.selectPodcasts() && nav.active == .streamSetu && !nav.podcastsAllowed && nav.isKidsProfile)
        #expect(!nav.select(.netflix))
        nav.gate = { false }; nav.kidsGate = { false }
        #expect(nav.selectPodcasts() && nav.active == .podcasts && nav.select(.netflix))
    }

    @Test("Kids profile: router.go(.podcasts), a direct open and the hook all refuse; switching to Kids while Podcasts is open leaves it")
    func kidsRefusesEveryRoute() {
        let nav = ServiceNavigation(capabilities: .macOS), router = AppRouter()
        nav.attach(to: router)
        var kids = true
        nav.kidsGate = { kids }
        router.go(.podcasts); #expect(nav.active == .streamSetu)
        #expect(!nav.selectPodcasts() && !nav.restore("podcasts"))
        kids = false
        router.go(.podcasts); #expect(nav.active == .podcasts)
        kids = true; nav.enforcePodcastsRule(); #expect(nav.active == .streamSetu)
        nav.enforcePodcastsRule(); #expect(nav.active == .streamSetu)
    }

    @Test("Kids profile or locked: Podcasts is not offered in the bar, and the Services list never lists it")
    func kidsHidesTheBarItem() {
        var nav = ServicesNavigationBinding(); nav.pinned = [.netflix]; nav.podcastsAvailable = false
        let st = TopBarState(tab: .home, initials: "LR", accountMenuOpen: false, width: 1440, destination: .streamSetu, services: [], showsServicesMenu: true, servicesNav: nav)
        let row = TopBarMenuRow.make(for: st)
        #expect(!row.items.contains { $0.kind == .podcasts } && row.leading.count == 5)
        #expect(ServicesMenuModel(nav: nav).rows(filter: "pod").isEmpty)
    }

    @Test("Podcasts opens regardless of any bar preference")
    func podcastsAlwaysOpens() {
        let nav = ServiceNavigation(capabilities: .macOS)
        #expect(nav.selectPodcasts() && nav.active == .podcasts)
    }

    // MARK: engine reuse (synthetic feed, no network)

    @Test("The browse model follows by feed address, lists the shows and unfollows through the one PodcastService")
    func browseModel() async throws {
        let feed = Data("""
        <?xml version="1.0"?><rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Sample Show</title><itunes:author>Example</itunes:author>
        <item><title>Episode One</title><enclosure url="https://example.invalid/1.mp3" type="audio/mpeg"/><pubDate>Mon, 02 Nov 2026 10:00:00 +0000</pubDate></item></channel></rss>
        """.utf8)
        let defaults = UserDefaults(suiteName: "TopBarPodcastsTests.\(UUID().uuidString)")!
        let model = PodcastsBrowseModel()
        model.service = PodcastService(defaults: defaults, fetch: { _ in feed })
        model.reload(); #expect(model.subscriptions.isEmpty)
        model.term = "https://example.invalid/feed.xml"; model.search()
        for _ in 0..<100 where model.subscriptions.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(model.subscriptions.map(\.title) == ["Sample Show"] && model.term.isEmpty && model.message == "Following Sample Show.")
        let show = PodcastShowModel(show: model.subscriptions[0])
        #expect(!show.following && show.feed == nil)
        model.unfollow(model.subscriptions[0]); #expect(model.subscriptions.isEmpty)
    }
}
