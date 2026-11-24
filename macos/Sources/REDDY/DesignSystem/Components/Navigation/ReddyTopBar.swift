import SwiftUI
import AppKit

/// Lets the borderless header move the window, since the title bar is hidden.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView { override var mouseDownCanMoveWindow: Bool { true } }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ v: NSView, context: Context) {}
}

struct TopBarState {
    var tab: AppTab
    var initials: String
    var accountMenuOpen: Bool
    /// Width of the window. The bar's spacing is derived from it (see `TopBarMetrics`).
    var width: CGFloat
    /// Which top-level destination is showing, and the services this platform has. The defaults are the plain five-tab bar.
    var destination: TopLevelDestination = .streamSetu
    var services: [ExternalService] = []
    /// Services that are shown but cannot be chosen now (Kids profile, locked app).
    var servicesDisabled = false
    /// The Services menu variant: pinned services plus one Services list instead of one tab per service. Off by default, and while it is off the bar is exactly the Netflix-only bar.
    var showsServicesMenu = false
    var servicesNav = ServicesNavigationBinding.empty
    /// The search box always searches the person's own library; while a service is on screen its words say so (typing there goes back to StreamSetu first).
    func searchPlaceholder(narrow: Bool) -> String {
        destination.isNative ? (narrow ? "Search" : "Search everything") : (narrow ? "Search library" : "Search your library")
    }
    var searchLabel: String { destination.isNative ? "Search everything" : "Search your library" }
}

/// How the one-row bar spends its width. Narrower windows give up flexible space first (tab padding, the search box, the
/// shortcut hint); no tab is ever hidden, moved to a second row or overlapped.
struct TopBarMetrics: Equatable {
    var tabPadding: CGFloat
    var searchMin: CGFloat
    var searchIdeal: CGFloat
    var searchMax: CGFloat
    var showShortcutHint: Bool

    static let leadingInset: CGFloat = 78            // clears the traffic lights
    static let trailingInset: CGFloat = 16
    static let accountWidth: CGFloat = 56
    /// The navigation group is a capsule around the items; this is the space between its edge and the first and last item, and the item height inside it.
    static let navGroupPadding: CGFloat = 3
    static let navItemHeight: CGFloat = 32
    /// Height of the nav capsule, the search capsule and the profile row: one line across the bar.
    static var rowHeight: CGFloat { navItemHeight + 2 * navGroupPadding }

    /// The width tiers, widest first: the window width from which each applies.
    static let tiers: [(from: CGFloat, metrics: TopBarMetrics)] = [
        (1360, TopBarMetrics(tabPadding: 15, searchMin: 150, searchIdeal: 250, searchMax: 280, showShortcutHint: true)),
        (1180, TopBarMetrics(tabPadding: 13, searchMin: 140, searchIdeal: 220, searchMax: 250, showShortcutHint: true)),
        (1100, TopBarMetrics(tabPadding: 11, searchMin: 130, searchIdeal: 180, searchMax: 210, showShortcutHint: false)),
        (0, TopBarMetrics(tabPadding: 9, searchMin: 110, searchIdeal: 150, searchMax: 170, showShortcutHint: false)),
    ]
    /// The tier a window width belongs to. The bar itself may pick a narrower tier when that keeps more names or pins (see `TopBarMenuRow.make`).
    static func metrics(for width: CGFloat) -> TopBarMetrics { tiers.first { width >= $0.from }!.metrics }

    /// The width the centred navigation group may use at this window width: what is left once both sides keep the room the brand and the search/profile need.
    func centerBudget(width: CGFloat, brandWidth: CGFloat, search: CGFloat? = nil) -> CGFloat {
        let left = Self.leadingInset + brandWidth + TopBarGeometry.gap
        let right = (search ?? searchMin) + 8 + Self.accountWidth + Self.trailingInset + TopBarGeometry.gap
        return max(0, width - 2 * max(left, right))
    }

    /// Smallest width at which the row fits with the tabs centred in the window, given measured text widths.
    func requiredWidth(brandWidth: CGFloat, tabTextWidths: [CGFloat]) -> CGFloat {
        let nav = tabTextWidths.reduce(0) { $0 + $1 + 2 * tabPadding }
        let left = Self.leadingInset + brandWidth + 12
        let right = searchMin + 8 + Self.accountWidth + Self.trailingInset + 12
        return nav + 2 * Self.navGroupPadding + 2 * max(left, right)
    }
}

/// Where the three zones of the bar go. Pure geometry: the same inputs always give the same frames, and none of the inputs
/// is the selected tab, the sidebar, the page, playback or search results.
enum TopBarGeometry {
    struct Frames: Equatable { var leading: CGRect; var center: CGRect; var trailing: CGRect }

    static let gap: CGFloat = 12

    /// The centre zone is centred on the whole bar, not on the space left between the other two. The trailing zone is given
    /// at most the room that is left to its right, so the search box gives way before anything collides. If even that is not
    /// enough the centre moves just far enough to stay clear, which only happens below the supported window width.
    static func frames(width: CGFloat, height: CGFloat, leading: CGSize, center: CGSize, trailingIdeal: CGSize, trailingMin: CGFloat,
                       leadingInset: CGFloat, trailingInset: CGFloat) -> Frames {
        let leadingFrame = CGRect(x: leadingInset, y: (height - leading.height) / 2, width: leading.width, height: leading.height)
        var centerX = ((width - center.width) / 2).rounded()
        let rightLimit = width - trailingInset
        // trailing: ideal width if it fits to the right of the centred nav, otherwise as narrow as its minimum allows
        let room = rightLimit - (centerX + center.width + gap)
        var trailingWidth = min(trailingIdeal.width, max(trailingMin, room))
        // keep the centre clear of both neighbours if the bar is too narrow to centre it
        if centerX < leadingFrame.maxX + gap { centerX = leadingFrame.maxX + gap }
        if centerX + center.width + gap > rightLimit - trailingWidth { trailingWidth = max(trailingMin, rightLimit - (centerX + center.width + gap)) }
        let trailingFrame = CGRect(x: rightLimit - trailingWidth, y: (height - trailingIdeal.height) / 2, width: trailingWidth, height: trailingIdeal.height)
        return Frames(leading: leadingFrame, center: CGRect(x: centerX, y: (height - center.height) / 2, width: center.width, height: center.height), trailing: trailingFrame)
    }
}

private struct TopBarZoneKey: LayoutValueKey { static let defaultValue: Zone = .center }
enum Zone { case leading, center, trailing }

/// Three independent zones. Each is placed from its own anchor (left edge, window centre, right edge), so what one zone
/// contains can never move another.
private struct TopBarLayout: Layout {
    var metrics: TopBarMetrics
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 1200, height: proposal.height ?? LayoutTokens.headerHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        func view(_ z: Zone) -> LayoutSubview? { subviews.first { $0[TopBarZoneKey.self] == z } }
        guard let l = view(.leading), let c = view(.center), let t = view(.trailing) else { return }
        let ls = l.sizeThatFits(.unspecified), cs = c.sizeThatFits(.unspecified)
        let ts = t.sizeThatFits(ProposedViewSize(width: metrics.searchIdeal + 8 + TopBarMetrics.accountWidth, height: bounds.height))
        let f = TopBarGeometry.frames(width: bounds.width, height: bounds.height, leading: ls, center: cs, trailingIdeal: ts,
                                      trailingMin: metrics.searchMin + 8 + TopBarMetrics.accountWidth, leadingInset: TopBarMetrics.leadingInset, trailingInset: TopBarMetrics.trailingInset)
        l.place(at: CGPoint(x: bounds.minX + f.leading.minX, y: bounds.minY + f.leading.minY), proposal: ProposedViewSize(ls))
        c.place(at: CGPoint(x: bounds.minX + f.center.minX, y: bounds.minY + f.center.minY), proposal: ProposedViewSize(cs))
        t.place(at: CGPoint(x: bounds.minX + f.trailing.minX, y: bounds.minY + f.trailing.minY), proposal: ProposedViewSize(width: f.trailing.width, height: f.trailing.height))
    }
}

/// Measured width of a tab label, so every tab has a fixed width that doesn't depend on which one is selected.
enum TabLabelMetrics {
    static func textWidth(_ title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)        // the one weight every tab uses
        return ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }
    static var brandWidth: CGFloat {
        ceil(("StreamSetu" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .bold)]).width) + 6
    }
}

/// What the one row shows for a destination: the five tabs and the services, or (with a service showing) the collapsed StreamSetu item and the services. Pure, so the identifiers, labels and the selected item are table-tested.
struct TopBarItem: Identifiable, Equatable {
    enum Kind: Equatable { case tab(AppTab), podcasts, streamSetu, service(ExternalService), servicesMenu }
    var kind: Kind
    var title: String
    var identifier: String
    var label: String?
    var selected: Bool
    var atlas: String?
    /// A small symbol before the label: only the collapsed StreamSetu item has one (it reads as the way home).
    var glyph: String? = nil
    /// A service's favicon (the bundled icon, or its initial tile) before the label.
    var icon: ProviderID? = nil
    /// Favicon-only: no label is drawn; the full name is the tooltip and the VoiceOver label.
    var compact = false
    /// The tooltip (the full service name for an icon-only chip).
    var help: String? = nil
    var id: String { identifier }
    var isTab: Bool { if case .tab = kind { true } else { false } }
    /// The native item this is (a tab or Podcasts), nil for the StreamSetu chip, a service or the Services button.
    var nativeTab: NavTab? { switch kind { case .tab(let t): NavTab(t); case .podcasts: .podcasts; default: nil } }
    var isService: Bool { if case .service = kind { true } else { false } }

    static let glyphWidth: CGFloat = 20
    /// The fixed width of an item: its measured text, the symbol if it has one, and the padding of the current width tier.
    func width(tabPadding: CGFloat) -> CGFloat {
        if compact { return ServiceChip.hitWidth }
        if icon != nil { return ServiceChip.expandedWidth(textWidth: TabLabelMetrics.textWidth(title), tabPadding: tabPadding) }
        return TabLabelMetrics.textWidth(title) + (glyph == nil ? 0 : Self.glyphWidth) + 2 * tabPadding
    }

    static let collapsedLabel = "StreamSetu, shows Home, Live TV, Movies, Series, TV Guide and Podcasts"
    static let podcastsTitle = "Podcasts"
    static let podcastsGlyph = "mic.fill"

    /// One native item in the requested mode. The full name is always the tooltip and the VoiceOver name, whatever is drawn.
    static func nativeItem(_ t: NavTab, mode: TabBarMode, selected: Bool) -> TopBarItem {
        TopBarItem(kind: t.appTab.map { .tab($0) } ?? .podcasts, title: t.title, identifier: "tab." + t.title, label: mode == .iconOnly ? t.title : nil, selected: selected,
                   atlas: t == .podcasts ? "screen.podcasts" : nil, glyph: mode == .nameOnly ? nil : t.symbol, compact: mode == .iconOnly, help: t.title)
    }

    /// The native items for a state, each in its requested mode. With a `budget` (the width the group may use), names drop to icon-only from the right-most
    /// item inward until the group fits; the result never wraps and an item never disappears. Pure.
    static func nativeItems(destination: TopLevelDestination, tab: AppTab, modes: TopBarTabModes, includesPodcasts: Bool, tabPadding: CGFloat, budget: CGFloat?) -> [TopBarItem] {
        let tabs = NavTab.allCases.filter { $0 != .podcasts || includesPodcasts }
        var effective = tabs.map { modes.mode($0) }
        func build() -> [TopBarItem] {
            zip(tabs, effective).map { t, m in nativeItem(t, mode: m, selected: t == .podcasts ? destination == .podcasts : (destination == .streamSetu && t.appTab == tab)) }
        }
        if let budget {
            var i = tabs.count - 1
            while i >= 0, build().reduce(0, { $0 + $1.width(tabPadding: tabPadding) }) > budget { effective[i] = .iconOnly; i -= 1 }
        }
        return build()
    }

    static func tabItems(destination: TopLevelDestination, tab: AppTab, modes: TopBarTabModes = TopBarTabModes()) -> [TopBarItem] {
        nativeItems(destination: destination, tab: tab, modes: modes, includesPodcasts: false, tabPadding: 0, budget: nil)
    }
    static func podcastsItem(selected: Bool, mode: TabBarMode = .iconAndName) -> TopBarItem { nativeItem(.podcasts, mode: mode, selected: selected) }
    static func streamSetuChip() -> TopBarItem {
        TopBarItem(kind: .streamSetu, title: "StreamSetu", identifier: "tab.StreamSetu", label: collapsedLabel, selected: false, atlas: "control.nav.streamsetu", glyph: "house.fill")
    }

    static func items(for state: TopBarState) -> [TopBarItem] {
        var out: [TopBarItem] = []
        if state.destination.isNative {
            out += tabItems(destination: state.destination, tab: state.tab, modes: state.servicesNav.tabModes)
        } else {
            out.append(streamSetuChip())
        }
        out += state.services.map { TopBarItem(kind: .service($0), title: $0.title, identifier: "tab." + $0.title, label: nil, selected: state.destination == .service($0), atlas: "control.nav.netflix") }
        return out
    }
}

/// The size of a service in the top row. Only the open service shows its name; the others are a favicon in a small chip, so more pinned services fit.
enum ServiceChip {
    static let iconSize: CGFloat = 22
    /// Width of an icon-only chip (the pointer's hit target is the chip, not just the icon).
    static let hitWidth: CGFloat = 32
    static let iconLead: CGFloat = (hitWidth - iconSize) / 2
    static let iconGap: CGFloat = 6
    /// The open service: its favicon, then its full name, in a capsule that grows from the icon-only chip.
    static func expandedWidth(textWidth: CGFloat, tabPadding: CGFloat) -> CGFloat { iconLead + iconSize + iconGap + textWidth + tabPadding }
}

/// The single-row plan of the Services menu variant, from the real window width. Pure.
///
/// State A (StreamSetu's own screens): Home, Live TV, Movies, Series, TV Guide and Podcasts in the mode each is set to (names by default), then the pinned
/// services as favicon-only chips, then Services. Pins overflow into the Services list first (from the end of the pinned order, as many as fit are kept);
/// names drop to icons (right-most first) only when the tabs plus Services cannot fit even with no pins. State B (a service is open): one StreamSetu chip (no tabs), the open service expanded to favicon and name
/// in its pinned place, the other pinned services as favicon-only chips, then Services. What does not fit goes to the Services list, from the
/// end of the pinned order; the open service never does (an unpinned one follows the pinned ones as a temporary chip).
struct TopBarMenuRow: Equatable {
    enum Mode: Equatable { case native, service }
    var mode: Mode
    var leading: [TopBarItem]
    var pinned: [TopBarItem]
    var chip: TopBarItem?
    var overflow: [ProviderID]
    var servicesItem: TopBarItem
    var tabPadding: CGFloat
    /// The width tier this row was planned with; the bar draws its padding and search box from it.
    var metrics: TopBarMetrics = TopBarMetrics.metrics(for: 0)
    var items: [TopBarItem] { leading + pinned + (chip.map { [$0] } ?? []) + [servicesItem] }
    var selectedIdentifier: String? { items.first(where: \.selected)?.identifier }
    /// Width of the whole navigation capsule.
    var width: CGFloat {
        items.reduce(0) { $0 + $1.width(tabPadding: tabPadding) } + 2 * TopBarMetrics.navGroupPadding
    }
    func item(for id: ProviderID) -> TopBarItem? { (pinned + (chip.map { [$0] } ?? [])).first { $0.kind == .service(id) } }

    static func serviceItem(_ id: ProviderID, active: ProviderID?) -> TopBarItem {
        let open = active == id
        return TopBarItem(kind: .service(id), title: id.title, identifier: "tab." + id.title, label: nil, selected: open,
                          atlas: id == .netflix ? "control.nav.netflix" : "control.nav.service", icon: id, compact: !open, help: open ? nil : id.title)
    }

    /// The plan for a window width. Each width tier that applies (the tier of the width and every narrower one) is planned on its own; the best plan wins:
    /// fewest names dropped to icons, then most pinned services, then the widest tier. A wider window therefore never shows fewer names or pins, even where a
    /// tier change would add padding and search width.
    static func make(for state: TopBarState, brandWidth: CGFloat = TabLabelMetrics.brandWidth) -> TopBarMenuRow {
        var best: TopBarMenuRow?
        var bestScore = (0, 0)
        for tier in TopBarMetrics.tiers where state.width >= tier.from || tier.from == 0 {
            let row = plan(state, metrics: tier.metrics, brandWidth: brandWidth)
            let score = (-row.droppedNames(for: state), row.pinned.count)
            if best == nil || score.0 > bestScore.0 || (score.0 == bestScore.0 && score.1 > bestScore.1) { best = row; bestScore = score }
        }
        return best!
    }

    /// Items whose name was removed although the person did not choose Icon Only.
    func droppedNames(for state: TopBarState) -> Int {
        mode == .native ? leading.filter { $0.compact && $0.nativeTab.map { state.servicesNav.tabModes.mode($0) != .iconOnly } == true }.count : 0
    }

    private static func plan(_ state: TopBarState, metrics m: TopBarMetrics, brandWidth: CGFloat) -> TopBarMenuRow {
        let active: ProviderID? = { if case .service(let s) = state.destination { s } else { nil } }()
        let services = TopBarItem(kind: .servicesMenu, title: "Services", identifier: "tab.Services", label: "Services", selected: false, atlas: "control.services.menu", glyph: "square.grid.2x2")
        let center = m.centerBudget(width: state.width, brandWidth: brandWidth) - 2 * TopBarMetrics.navGroupPadding
        let nativeBudget = center - services.width(tabPadding: m.tabPadding)
        var leading: [TopBarItem]
        var dropped = false
        if state.destination.isNative {
            // The six native items in their chosen modes. Pinned services overflow into the Services list first; only when the items at their chosen modes
            // do not fit even with no pins do names give way to icons, right-most first (and then the pins stay in the list, so a wider window brings the
            // names back before any pin).
            let nav = state.servicesNav
            leading = TopBarItem.nativeItems(destination: state.destination, tab: state.tab, modes: nav.tabModes, includesPodcasts: nav.podcastsAvailable, tabPadding: m.tabPadding, budget: nil)
            if leading.reduce(0, { $0 + $1.width(tabPadding: m.tabPadding) }) > nativeBudget {
                dropped = true
                leading = TopBarItem.nativeItems(destination: state.destination, tab: state.tab, modes: nav.tabModes, includesPodcasts: nav.podcastsAvailable, tabPadding: m.tabPadding, budget: nativeBudget)
            }
        } else {
            leading = [TopBarItem.streamSetuChip()]
        }
        var widths: [ProviderID: CGFloat] = [:]
        for id in Set(state.servicesNav.pinned).union(active.map { [$0] } ?? []) {
            widths[id] = serviceItem(id, active: active).width(tabPadding: m.tabPadding)
        }
        let leadingW = leading.reduce(0) { $0 + $1.width(tabPadding: m.tabPadding) }
        let plan = ServiceBarPlanner.plan(pinned: dropped ? [] : state.servicesNav.pinned, active: active, itemWidths: widths, servicesButtonWidth: services.width(tabPadding: m.tabPadding), budget: center - leadingW)
        let inline = plan.inline
        let overflow = dropped ? state.servicesNav.pinned.reduce(into: [ProviderID]()) { if !$0.contains($1) { $0.append($1) } } : plan.overflow
        return TopBarMenuRow(mode: state.destination.isNative ? .native : .service, leading: leading, pinned: inline.map { serviceItem($0, active: active) },
                             chip: plan.temporaryChip.map { serviceItem($0, active: active) }, overflow: overflow, servicesItem: services, tabPadding: m.tabPadding, metrics: m)
    }
}


private struct ServicesAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// The persistent top bar, owned by the root shell. Left: brand. Centre: the five tabs. Right: search and account.
/// Only the selected tab's colour depends on the selection; nothing about the layout does.
struct ReddyTopBar: View {
    let state: TopBarState
    @Binding var query: String
    var focusToken: Int
    /// A title page is open on top: the box must not take the cursor behind it.
    var titleOpen = false
    var onSubmit: () -> Void = {}
    var onResultsFocus: () -> Void = {}
    /// ⌘Return: hand what is typed to Setu instead of searching.
    var onAsk: (String) -> Void = { _ in }
    var onSelectTab: (AppTab) -> Void
    var onToggleAccount: () -> Void
    var onSelectService: (ExternalService) -> Void = { _ in }
    var onSelectStreamSetu: () -> Void = {}
    var onSelectPodcasts: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.reddyAccent) private var accent
    /// The selected tab's underline slides from tab to tab.
    @Namespace private var underline
    @FocusState private var searchFocused: Bool
    @State private var searchHover = false
    @State private var accountHover = false
    @State private var dismissRegion = SearchDismissRegion()
    @State private var servicesOpen = false
    @State private var servicesRegion = SearchDismissRegion()
    /// True when many pinned services leave the search box less than its ideal width: the short placeholder then fits instead of a clipped long one.
    private var searchIsSqueezed: Bool {
        guard state.showsServicesMenu else { return false }
        let row = TopBarMenuRow.make(for: state)
        return row.width > row.metrics.centerBudget(width: state.width, brandWidth: TabLabelMetrics.brandWidth, search: row.metrics.searchIdeal)
    }
    private var metrics: TopBarMetrics { state.showsServicesMenu ? TopBarMenuRow.make(for: state).metrics : TopBarMetrics.metrics(for: state.width) }

    var body: some View {
        TopBarLayout(metrics: metrics) {
            brand.layoutValue(key: TopBarZoneKey.self, value: .leading)
            navZone.layoutValue(key: TopBarZoneKey.self, value: .center)
            HStack(spacing: 8) { searchBox; accountButton }.layoutValue(key: TopBarZoneKey.self, value: .trailing)
        }
        .frame(height: LayoutTokens.headerHeight)
        .onReceive(NotificationCenter.default.publisher(for: .openServicesList)) { _ in if state.showsServicesMenu { servicesOpen = true } }
        .background(WindowDragArea())
        .background(headerBackground)
        .overlay(alignment: .bottom) {
            // a hairline that fades toward the window edges, so the bar melts into the content instead of ending in a hard line
            Rectangle().fill(LinearGradient(colors: [ColorTokens.line.opacity(0.25), ColorTokens.line, ColorTokens.line.opacity(0.25)], startPoint: .leading, endPoint: .trailing)).frame(height: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
        .overlayPreferenceValue(ServicesAnchorKey.self) { anchor in servicesPanel(anchor) }
        .background(SearchOutsideClickMonitor(region: servicesRegion, isActive: servicesOpen, onOutsideClick: { servicesOpen = false }))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in servicesOpen = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in servicesOpen = false }
    }

    /// The Services list: an in-window panel under the Services item with its own opaque themed surface (a system popover is see-through).
    /// It grows from the item (scale 0.97 and fade, spring), or only fades when Reduce Motion is on.
    private func servicesPanel(_ anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { g in
            if servicesOpen, let anchor {
                let r = g[anchor]
                let w = ServicesDropdown.width
                let x = min(max(8, r.midX - w / 2), max(8, g.size.width - w - 8))
                ServicesDropdown(nav: state.servicesNav, openDisabled: state.servicesDisabled, maxListHeight: Self.dropdownListHeight(), dismiss: { servicesOpen = false })
                    .background(SearchRegionAnchor(region: servicesRegion, isPanel: true))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.97, anchor: UnitPoint(x: min(max((r.midX - x) / w, 0), 1), y: 0)).combined(with: .opacity))
                    .offset(x: x, y: r.maxY + 8)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: servicesOpen)
    }

    private var headerBackground: some View {
        ZStack {
            if ColorTokens.nativeGlass { NativeGlass(shape: Rectangle(), tint: ColorTokens.barFill.opacity(0.18)) }
            else { Rectangle().fill(.ultraThinMaterial); Rectangle().fill(ColorTokens.barFill.opacity(ColorTokens.glassy ? 0.50 : 0.80)) }
            GlossSheen(streak: false)
        }
    }

    private var brand: some View {
        (Text("Stream").foregroundColor(.white) + Text("Setu").foregroundColor(accent))
            .font(.system(size: 20, weight: .bold)).tracking(-0.4)
            .lineLimit(1).fixedSize()
            .accessibilityElement(children: .ignore).accessibilityLabel("StreamSetu")
            // While a service is showing, the collapsed "StreamSetu" item in the row carries the name; the wordmark keeps its space so nothing moves.
            .opacity(state.destination.isNative ? 1 : 0).accessibilityHidden(!state.destination.isNative)
            .transaction(value: state.width) { $0.animation = nil }
            .animation(NavTransition.animation(reduceMotion: reduceMotion), value: state.destination.isNative)
    }

    @ViewBuilder private var navZone: some View {
        if state.showsServicesMenu { menuNav } else { nav }
    }

    /// The Services menu variant: the same capsule and item style, with the pinned services in order, the active service when it is not pinned
    /// (with a Pin button), and one Services item that opens the list. The plan comes from the real window width; what does not fit stays in the list.
    /// The list may be as tall as the window allows (room for the bar, the filter and the legend), between a short scrolling list and 400 points.
    private static func dropdownListHeight() -> CGFloat {
        let h = NSApp.keyWindow?.contentView?.bounds.height ?? 800
        return min(400, max(160, h - 190))
    }

    private var menuNav: some View {
        let row = TopBarMenuRow.make(for: state)
        let navBinding = state.servicesNav
        return HStack(spacing: 0) {
            ForEach(row.leading) { item in
                if let t = item.nativeTab {
                    navItem(item, selected: item.selected) { activate(item) }.tabModeMenu(t, nav: navBinding).atlasCovers("screen.tab.home")
                } else {
                    navItem(item, selected: item.selected) { activate(item) }.atlasCovers("screen.tab.home")
                }
            }
            PinnedServicesBar(ids: row.pinned.compactMap { if case .service(let s) = $0.kind { s } else { nil } }, nav: navBinding, disabled: state.servicesDisabled) { id in
                if let item = row.item(for: id) {
                    navItem(item, selected: item.selected) { activate(item) }.disabled(state.servicesDisabled)
                }
            }
            if let chip = row.chip, case .service(let id) = chip.kind {
                navItem(chip, selected: true) { activate(chip) }.disabled(state.servicesDisabled)
                    .unpinnedActiveBehaviour(id, nav: navBinding)
                .transition(NavTransition.item)
            }
            navItem(row.servicesItem, selected: false) { servicesOpen.toggle() }
                .anchorPreference(key: ServicesAnchorKey.self, value: .bounds) { $0 }
                .background(SearchRegionAnchor(region: servicesRegion, isPanel: false))
                .accessibilityValue(Text(servicesOpen ? "expanded" : "collapsed"))
                .accessibilityHint(Text(row.overflow.isEmpty ? "Opens the list of streaming services" : "Opens the list of streaming services, including \(row.overflow.count) more pinned"))
        }
        .navCapsule(NavKey(ids: row.items.map(\.identifier), selected: row.selectedIdentifier, chip: row.chip != nil), width: state.width, reduceMotion: reduceMotion, background: navGroupBackground)
        .accessibilityElement(children: .contain).accessibilityLabel(Text("Main navigation"))
    }

    /// Each item has a fixed width (its measured text plus padding), and every item uses the same font, so selecting one
    /// changes its colour and nothing else. With a service showing, the five tabs collapse into one "StreamSetu" item.
    private var nav: some View {
        let items = TopBarItem.items(for: state)
        return HStack(spacing: 0) {
            ForEach(items) { item in
                navItem(item, selected: item.selected) { activate(item) }
                    .atlasCovers("screen.tab.home")
                    .disabled(item.isService && state.servicesDisabled)
            }
        }
        // one transaction drives the capsule's width, its items, the selection pill and the edge together (see `navCapsule`)
        .navCapsule(NavKey(ids: items.map(\.identifier), selected: items.first(where: \.selected)?.identifier, chip: false), width: state.width, reduceMotion: reduceMotion, background: navGroupBackground)
        .accessibilityElement(children: .contain).accessibilityLabel(Text("Main navigation"))
    }

    /// The capsule around the navigation items: glass where the theme has it, a soft material otherwise, with a hairline edge.
    private var navGroupBackground: some View {
        ZStack {
            if ColorTokens.nativeGlass { NativeGlass(shape: Capsule(), tint: Color.white.opacity(0.03)) }
            else { Capsule().fill(Color.white.opacity(0.06)) }          // the bar behind is already a blurred material
        }
        .overlay(Capsule().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.5))          // a very light edge
        .compositingGroup()
    }

    private func activate(_ item: TopBarItem) {
        switch item.kind {
        case .tab(let t): onSelectTab(t)
        case .streamSetu: onSelectStreamSetu()
        case .podcasts: onSelectPodcasts()
        case .service(let s): onSelectService(s)
        case .servicesMenu: servicesOpen.toggle()
        }
    }

    private func navItem(_ item: TopBarItem, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: item.icon != nil ? ServiceChip.iconGap : 6) {
                if let id = item.icon { ServiceGlyph(id: id, size: ServiceChip.iconSize) }
                else if let g = item.glyph { Image(systemName: g).font(.system(size: 12, weight: .semibold)).frame(width: TopBarItem.glyphWidth - 6) }
                // an icon-only chip draws no label at all; the full name is its tooltip and its VoiceOver name
                if !item.compact { Text(item.title).font(Typography.nav).fontWeight(selected ? .semibold : .medium).lineLimit(1).fixedSize() }
            }
            .padding(.leading, item.icon != nil ? ServiceChip.iconLead : 0)
            .frame(width: item.width(tabPadding: metrics.tabPadding), height: TopBarMetrics.navItemHeight, alignment: item.icon != nil ? .leading : .center)
            .clipped()          // while an item grows from its icon, the name is revealed by the width, never drawn outside it
            .foregroundStyle(selected ? ColorTokens.textPrimary : ColorTokens.textSecondary)
            .background {
                if selected {
                    // one capsule: a soft accent-tinted glass fill and a single fine inner highlight, nothing drawn outside its edge
                    Capsule().fill(LinearGradient(colors: [accent.opacity(0.28), accent.opacity(0.16)], startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.5))
                        .compositingGroup()
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "nav-pill", in: underline)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(NavButtonStyle())
        .transition(NavTransition.item)
        .help(item.help.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(Text(LocalizedStringKey(item.label ?? item.title)))
        .accessibilityIdentifier(item.identifier)
        .atlasCovers("control.nav.netflix")          // the tabs are covered by their screen entries, the service item by this one
        .atlasOptional(item.atlas)
    }

    /// A real text field. Typing searches and shows results in the content area; nothing opens.
    private var searchBox: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(ColorTokens.textTertiary)
            TextField(LocalizedStringKey(state.searchPlaceholder(narrow: metrics.searchIdeal < 170 || state.width < 1360 || searchIsSqueezed)), text: $query)
                .textFieldStyle(.plain).font(Typography.row).focused($searchFocused).lineLimit(1)
                .onKeyPress(.escape) { query = ""; searchFocused = false; return .handled }
                .onKeyPress(.downArrow) { onResultsFocus(); return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command), !query.trimmingCharacters(in: .whitespaces).isEmpty else { return .ignored }
                    onAsk(query); return .handled
                }
                .onSubmit { onSubmit() }
                .accessibilityLabel(Text(LocalizedStringKey(state.searchLabel))).accessibilityHint("Searches all playlists: channels, movies, series, episodes and the guide").accessibilityIdentifier("search.field")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Clear search")
            } else if metrics.showShortcutHint && !searchFocused {
                Text("⌘K").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(ColorTokens.textTertiary)
                    .padding(.horizontal, 5).padding(.vertical, 2).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).frame(minWidth: metrics.searchMin, idealWidth: metrics.searchIdeal, maxWidth: metrics.searchIdeal).frame(height: TopBarMetrics.rowHeight)
        .background(searchBackground)
        .overlay(Capsule().strokeBorder(searchFocused ? AnyShapeStyle(accent.opacity(0.7)) : AnyShapeStyle(LinearGradient(colors: [Color.white.opacity(searchHover ? 0.20 : 0.11), Color.white.opacity(searchHover ? 0.08 : 0.04)], startPoint: .top, endPoint: .bottom)), lineWidth: searchFocused ? 1.5 : 0.75))
        .compositingGroup()
        .shadow(color: searchFocused ? accent.opacity(0.28) : .clear, radius: 8)
        .onHover { searchHover = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: searchHover)
        // ⌘K both ways: it focuses the box, and pressing it again while the box has the cursor closes the panel (the typed text stays).
        .onChange(of: focusToken) { _, _ in
            if searchFocused { closeSearchPanel() } else if SearchFocusPolicy.allowsFocus(titleOpen: titleOpen) { searchFocused = true }
        }
        // AppKit falls back to the first text field when the clicked tile loses the cursor; a title page opening must not hand it to search.
        .onChange(of: searchFocused) { _, f in if f && !SearchFocusPolicy.allowsFocus(titleOpen: titleOpen) { closeSearchPanel() } }
        .onChange(of: titleOpen) { _, open in if open { closeSearchPanel() } }
        .background(SearchRegionAnchor(region: dismissRegion, isPanel: false))
        .background(SearchOutsideClickMonitor(region: dismissRegion, isActive: searchFocused, onOutsideClick: closeSearchPanel))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in closeSearchPanel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in closeSearchPanel() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in closeSearchPanel() }
        .overlay(alignment: .topLeading) {
            if searchFocused && query.isEmpty {
                SearchIdeasPanel(pick: { query = $0; closeSearchPanel() })
                    .frame(width: 340)
                    .background(SearchRegionAnchor(region: dismissRegion, isPanel: true))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ColorTokens.glassEdge))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    .offset(y: 38)
                    .transition(.opacity)
            }
        }
        // focus changes the chip, the stroke, the glow and the ideas panel in one transaction
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: SearchFocusKey(focused: searchFocused, empty: query.isEmpty))
    }

    private var searchBackground: some View {
        ZStack {
            if ColorTokens.nativeGlass { NativeGlass(shape: Capsule(), tint: Color.white.opacity(searchFocused ? 0.06 : 0.02)) }
            else { Capsule().fill(Color.white.opacity(searchFocused ? 0.10 : (searchHover ? 0.08 : 0.055))) }
        }
    }

    /// Drops focus (which hides the ideas panel) and releases the AppKit first responder.
    private func closeSearchPanel() {
        guard searchFocused else { return }
        searchFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var accountButton: some View {
        Button(action: onToggleAccount) {
            HStack(spacing: 6) {
                Text(state.initials).font(.system(size: 11, weight: .bold, design: .rounded)).frame(width: 32, height: 32)
                    .background(LinearGradient(colors: [accent.opacity(0.35), Color.white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                    .overlay(Circle().strokeBorder(state.accountMenuOpen || accountHover ? accent.opacity(0.85) : ColorTokens.glassEdge, lineWidth: state.accountMenuOpen || accountHover ? 1.5 : 1))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(ColorTokens.textSecondary)
                    .rotationEffect(.degrees(state.accountMenuOpen ? 180 : 0))
            }
            .frame(width: TopBarMetrics.accountWidth, height: TopBarMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { accountHover = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: accountHover)
        .accessibilityLabel("Account menu").accessibilityValue(state.accountMenuOpen ? "expanded" : "collapsed").atlas("screen.accountMenu")
    }
}

struct SearchFocusKey: Equatable { var focused: Bool; var empty: Bool }

/// Everything that changes the navigation capsule's shape: the items it holds, the selected one and the pin chip. One value, so one
/// animation drives the width, the items, the pill and the edge together.
struct NavKey: Equatable { var ids: [String]; var selected: String?; var chip: Bool }

enum NavTransition {
    /// Items that join fade in once the capsule has nearly reached its new width; items that leave are gone at once. Old and new items are never on screen together, so nothing overlaps
    /// while the capsule changes width.
    static var item: AnyTransition { .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.16).delay(0.14)), removal: .identity) }
    static func animation(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .smooth(duration: 0.3) }
}

extension View {
    /// The navigation capsule: items, glass, stroke as one layer, animated by one value-keyed transaction on this very container.
    /// A live window resize is never animated: the bar follows the window with no spring.
    func navCapsule<B: View>(_ key: NavKey, width: CGFloat, reduceMotion: Bool, background: B) -> some View {
        self.padding(TopBarMetrics.navGroupPadding)
            .background(background)
            .fixedSize()
            .transaction(value: width) { $0.animation = nil; $0.disablesAnimations = true }
            .animation(NavTransition.animation(reduceMotion: reduceMotion), value: key)
    }
}

private struct NavButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { if hovering && !configuration.isPressed { Capsule().fill(Color.white.opacity(0.08)) } }          // a soft highlight under the pointer
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(hovering ? 0.12 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// Floating account menu under the header.
struct ReddyAccountMenu: View {
    let name: String
    var onChannelManager: () -> Void
    var onAbout: () -> Void
    enum Restricted { case locked, unlocked }
    /// nil when no PIN is set, so the menu has no parental entry at all.
    var restricted: Restricted?
    var onRestricted: () -> Void = {}
    /// The profiles on this Mac (more than one once somebody has been added), the one in use, and what to do to pick or add one.
    var profiles: [Profile] = []
    var activeProfileID = ""
    var canAddProfile = true
    var onPickProfile: (Profile) -> Void = { _ in }
    var onAddProfile: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Typography.rowMedium)
                Text(profiles.count > 1 ? "Profile · \(profiles.first { $0.id == activeProfileID }?.name ?? "")" : "Local profile · stored on this Mac").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            }.padding(.horizontal, 10).padding(.vertical, 8)
            Divider().overlay(ColorTokens.line).padding(.vertical, 3)
            if profiles.count > 1 {
                ForEach(profiles) { p in
                    Button { onPickProfile(p) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: p.id == activeProfileID ? "checkmark.circle.fill" : "person.circle").frame(width: 16).foregroundStyle(p.id == activeProfileID ? ColorTokens.accentDefault : ColorTokens.textSecondary)
                            Text(p.name + (p.kind == .kids ? "  ·  Kids" : "")).font(Typography.row); Spacer()
                            if p.hasPIN && p.kind == .adult && p.id != activeProfileID { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(ColorTokens.textTertiary) }
                        }.padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(MenuRowStyle()).atlas("screen.accountMenu")
                }
            }
            if canAddProfile { item("Add profile…", "person.badge.plus", onAddProfile) }
            Divider().overlay(ColorTokens.line).padding(.vertical, 3)
            item("Channel manager", "slider.horizontal.3", onChannelManager)
            SettingsLink { menuLabel("Settings", "gearshape") }.buttonStyle(MenuRowStyle())
            if let restricted {
                Divider().overlay(ColorTokens.line).padding(.vertical, 3)
                item(restricted == .locked ? "Unlock restricted content…" : "Lock restricted content", restricted == .locked ? "lock" : "lock.open", onRestricted)
            }
            item("About StreamSetu", "info.circle", onAbout)
        }
        .padding(6).frame(width: 240).glass(radius: 10)
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        .accessibilityElement(children: .contain).accessibilityLabel("Account menu")
    }

    private func menuLabel(_ t: String, _ symbol: String) -> some View {
        HStack(spacing: 10) { Image(systemName: symbol).frame(width: 16).foregroundStyle(ColorTokens.textSecondary); Text(t).font(Typography.row); Spacer() }
            .padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
    }

    private func item(_ t: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { menuLabel(t, symbol) }.buttonStyle(MenuRowStyle()).atlas("screen.accountMenu")
    }
}

struct MenuRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
    }
}


/// When the top search box may take the keyboard cursor.
enum SearchFocusPolicy {
    static func allowsFocus(titleOpen: Bool) -> Bool { !titleOpen }
}


