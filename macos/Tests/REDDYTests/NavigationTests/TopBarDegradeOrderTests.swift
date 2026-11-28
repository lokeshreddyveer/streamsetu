import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// The degrade order of State A: pinned services overflow into the Services list first; names drop to icons (right-most first) only when the six items
/// at their chosen modes plus Services cannot fit even with no pins. Property-style over widths, per-item modes and pin counts. Pure planner, no window.
// Changed: each sweep plans tens of thousands of rows on the main actor. Run as one synchronous block, a test held the main actor for 10 to 40 seconds in a full run, and every other
// main-actor test (the assistant suite with its one-minute limit, the recording and web-model tests that measure wall time) waited behind it. The sweeps now yield between pin counts;
// the assertions and the swept widths are unchanged.
@Suite("Top bar: degrade order") @MainActor struct TopBarDegradeOrderTests {
    private let all: [ProviderID] = { let l = ProviderRegistry.standard.listed(on: .macOS).map(\.id); return l + ProviderID.allCases.filter { !l.contains($0) } }()
    private func state(_ w: CGFloat, modes: TopBarTabModes, pins: Int, destination: TopLevelDestination = .streamSetu) -> TopBarState {
        var nav = ServicesNavigationBinding(); nav.pinned = Array(all.prefix(pins)); nav.tabModes = modes; nav.podcastsAvailable = true
        if case .service(let s) = destination { nav.active = s }
        return TopBarState(tab: .movies, initials: "LR", accountMenuOpen: false, width: w, destination: destination, services: [], showsServicesMenu: true, servicesNav: nav)
    }
    private func modes(_ m: TabBarMode) -> TopBarTabModes { var t = TopBarTabModes(); NavTab.baseTabs.forEach { t.set(m, for: $0) }; return t }
    private var configs: [(String, TopBarTabModes)] {
        var a = TopBarTabModes(); a.set(.iconOnly, for: .home); a.set(.nameOnly, for: .movies); a.set(.iconOnly, for: .guide)
        var b = TopBarTabModes(); b.set(.nameOnly, for: .liveTV); b.set(.nameOnly, for: .series); b.set(.nameOnly, for: .podcasts)
        return [("default", TopBarTabModes()), ("icons", modes(.iconOnly)), ("names", modes(.nameOnly)), ("mixedA", a), ("mixedB", b)]
    }
    private let sweep: [CGFloat] = stride(from: 1024, through: 2400, by: 4).map { CGFloat($0) }
    private func budget(_ row: TopBarMenuRow, _ w: CGFloat) -> CGFloat { row.metrics.centerBudget(width: w, brandWidth: TabLabelMetrics.brandWidth) }
    /// Items whose name was removed although the person did not choose Icon Only.
    private func degraded(_ row: TopBarMenuRow, _ t: TopBarTabModes) -> [Bool] {
        row.leading.enumerated().map { $0.element.compact && t.mode(NavTab.baseTabs[$0.offset]) != .iconOnly }
    }
    /// Number of drawn names: items that show their title.
    private func names(_ row: TopBarMenuRow) -> Int { row.leading.filter { !$0.compact }.count }

    @Test func at1512WithElevenPinsTheTabsShowTheirNames() {
        let row = TopBarMenuRow.make(for: state(1512, modes: TopBarTabModes(), pins: 11))
        #expect(row.leading.count == 6 && row.leading.allSatisfy { !$0.compact && $0.glyph != nil })
        #expect(row.pinned.count + row.overflow.count == 11 && !row.pinned.isEmpty)
        #expect(row.width <= budget(row, 1512) + 0.5)
    }

    @Test func widerNeverShowsFewerPinsOrFewerNames() async {
        await HeavyTestSlot.shared.acquire(); defer { Task { await HeavyTestSlot.shared.release() } }      // one heavy test at a time (see HeavyTestSlot)
        for (name, t) in configs {
            for pins in 0...12 {
                await Task.yield()          // Changed: hands the main actor back between sweeps (see the suite note)
                var lastPins = 0, lastNames = 0
                for w in sweep {
                    let row = TopBarMenuRow.make(for: state(w, modes: t, pins: pins))
                    #expect(row.pinned.count >= lastPins, "\(name) pins=\(pins) w=\(w): pins \(row.pinned.count) < \(lastPins)")
                    #expect(names(row) >= lastNames, "\(name) pins=\(pins) w=\(w): names \(names(row)) < \(lastNames)")
                    lastPins = row.pinned.count; lastNames = names(row)
                }
            }
        }
    }

    @Test func tabsKeepTheirChosenModeWhileAnyPinCanStillOverflow() async {
        await HeavyTestSlot.shared.acquire(); defer { Task { await HeavyTestSlot.shared.release() } }      // one heavy test at a time (see HeavyTestSlot)
        for (name, t) in configs {
            for pins in 0...12 {
                await Task.yield()          // Changed: hands the main actor back between sweeps (see the suite note)
                for w in sweep {
                    let row = TopBarMenuRow.make(for: state(w, modes: t, pins: pins))
                    if degraded(row, t).contains(true) {
                        #expect(row.pinned.isEmpty && row.overflow.count == pins, "\(name) pins=\(pins) w=\(w): names dropped while pins remain")
                    } else {
                        for (i, item) in row.leading.enumerated() { #expect(item.compact == (t.mode(NavTab.baseTabs[i]) == .iconOnly), "\(name) w=\(w)") }
                    }
                }
            }
        }
    }

    @Test func namesDropFromTheRightMostItemInwardOnlyWhenEvenZeroPinsDoNotFit() async {
        await HeavyTestSlot.shared.acquire(); defer { Task { await HeavyTestSlot.shared.release() } }      // one heavy test at a time (see HeavyTestSlot)
        for (name, t) in configs {
            await Task.yield()
            for w in sweep {
                let row = TopBarMenuRow.make(for: state(w, modes: t, pins: 12))
                let d = degraded(row, t)
                if let first = d.firstIndex(of: true) {
                    #expect(row.pinned.isEmpty)
                    for i in first..<row.leading.count { #expect(row.leading[i].compact, "\(name) w=\(w): right of a dropped name") }
                    // the requested modes really did not fit with zero pins
                    var requested = row; requested.leading = TopBarItem.nativeItems(destination: .streamSetu, tab: .movies, modes: t, includesPodcasts: true, tabPadding: row.tabPadding, budget: nil)
                    requested.pinned = []
                    #expect(requested.width > budget(row, w) + 0.5, "\(name) w=\(w): names dropped although the requested modes fit")
                }
            }
        }
    }

    @Test func atLeastThreeFaviconsWhenTheyFitAndNeverMoreThanFit() async {
        await HeavyTestSlot.shared.acquire(); defer { Task { await HeavyTestSlot.shared.release() } }      // one heavy test at a time (see HeavyTestSlot)
        for (name, t) in configs {
            for pins in 0...12 {
                await Task.yield()          // Changed: hands the main actor back between sweeps (see the suite note)
                for w in sweep {
                    let row = TopBarMenuRow.make(for: state(w, modes: t, pins: pins))
                    if degraded(row, t).contains(true) { continue }   // names dropped: pins wait in the list so that a wider window restores names first
                    let room = budget(row, w) - row.width
                    if row.pinned.count < min(3, pins) { #expect(room < ServiceChip.hitWidth - 0.5, "\(name) pins=\(pins) w=\(w): fewer than 3 shown although another fits") }
                    if row.pinned.count < pins { #expect(room < ServiceChip.hitWidth - 0.5, "\(name) pins=\(pins) w=\(w): a pin overflowed although it fits") }
                    if pins >= 3, !degraded(row, t).contains(true) {
                        var three = row; three.pinned = Array(row.pinned.prefix(0)); three.leading = row.leading
                        let need = three.width + 3 * ServiceChip.hitWidth
                        if need <= budget(row, w) + 0.5 { #expect(row.pinned.count >= 3, "\(name) pins=\(pins) w=\(w)") }
                    }
                }
            }
        }
    }

    @Test func neverOverlapsSearchAndProfileAndKeepsAllSix() async {
        await HeavyTestSlot.shared.acquire(); defer { Task { await HeavyTestSlot.shared.release() } }      // one heavy test at a time (see HeavyTestSlot)
        for (name, t) in configs {
            for pins in [0, 3, 7, 12] {
                await Task.yield()
                for w in sweep {
                    let row = TopBarMenuRow.make(for: state(w, modes: t, pins: pins))
                    #expect(row.leading.count == 6 && row.items.last?.kind == .servicesMenu)
                    #expect(row.width <= budget(row, w) + 0.5, "\(name) pins=\(pins) w=\(w)")
                }
            }
        }
        // the narrowest supported window: everything icon-only still fits with Services
        let narrow = TopBarMenuRow.make(for: state(1024, modes: modes(.iconOnly), pins: 12))
        #expect(narrow.leading.allSatisfy(\.compact) && narrow.width <= budget(narrow, 1024) + 0.5)
    }

    @Test func overflowedPinsStayInPinnedOrderAndReachableInTheServicesList() {
        for w: CGFloat in [1024, 1280, 1512, 1728] {
            let st = state(w, modes: TopBarTabModes(), pins: 12)
            let row = TopBarMenuRow.make(for: st)
            let shown = row.pinned.compactMap { if case .service(let s) = $0.kind { s } else { nil } }
            #expect(shown + row.overflow == st.servicesNav.pinned, "w=\(w): inline then overflow is the pinned order")
            let listed = ServicesMenuModel(nav: st.servicesNav).pinned(filter: "").map(\.provider)
            #expect(listed == st.servicesNav.pinned.filter { st.servicesNav.listed.contains($0) } && Set(row.overflow).isSubset(of: Set(listed)) || !st.servicesNav.pinned.allSatisfy { st.servicesNav.listed.contains($0) })
        }
    }

    @Test func theActiveServiceIsAlwaysVisibleAndStateBIsUnchangedByTheModes() {
        for w in sweep where Int(w) % 16 == 0 {
            for active in [all[0], all[5], all[11]] {
                let row = TopBarMenuRow.make(for: state(w, modes: modes(.nameOnly), pins: 12, destination: .service(active)))
                #expect(row.items.contains { $0.kind == .service(active) } && row.leading.map(\.title) == ["StreamSetu"], "w=\(w) \(active)")
                #expect(row.width <= budget(row, w) + 0.5 || row.pinned.isEmpty)
            }
        }
    }

    @Test func deterministic() {
        for (_, t) in configs { for w in [1024, 1337, 1512, 2200] as [CGFloat] { #expect(TopBarMenuRow.make(for: state(w, modes: t, pins: 9)) == TopBarMenuRow.make(for: state(w, modes: t, pins: 9))) } }
    }

    /// Renders State A at the checked widths for a look. Runs only when TOPBAR_DEGRADE_SHOTS names a folder.
    @Test func renderTheDegradeOrder() throws {
        guard let dir = ProcessInfo.processInfo.environment["TOPBAR_DEGRADE_SHOTS"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let saved = ThemeStore.current; defer { ThemeStore.current = saved }
        var mixed = TopBarTabModes(); mixed.set(.iconOnly, for: .home); mixed.set(.nameOnly, for: .movies); mixed.set(.iconOnly, for: .guide)
        for theme in [AppTheme.obsidian, .liquidGlass, .dracula, .graphite] {
            ThemeStore.current = theme
            let t = theme.rawValue.replacingOccurrences(of: " ", with: "-")
            for w: CGFloat in [1024, 1280, 1512, 1728, 2200] {
                for pins in [11, 3] {
                    for (mname, m) in [("default", TopBarTabModes()), ("mixed", mixed)] {
                        var q = ""
                        let st = state(w, modes: m, pins: pins)
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
                        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(t)-\(Int(w))-\(pins)pins-\(mname).png"))
                        withExtendedLifetime(win) {}
                    }
                }
            }
        }
    }
}
