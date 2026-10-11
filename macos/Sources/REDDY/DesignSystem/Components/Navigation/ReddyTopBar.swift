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

    static func metrics(for width: CGFloat) -> TopBarMetrics {
        switch width {
        case 1360...: TopBarMetrics(tabPadding: 15, searchMin: 150, searchIdeal: 250, searchMax: 280, showShortcutHint: true)
        case 1180...: TopBarMetrics(tabPadding: 13, searchMin: 140, searchIdeal: 220, searchMax: 250, showShortcutHint: true)
        case 1100...: TopBarMetrics(tabPadding: 11, searchMin: 130, searchIdeal: 180, searchMax: 210, showShortcutHint: false)
        default: TopBarMetrics(tabPadding: 9, searchMin: 110, searchIdeal: 150, searchMax: 170, showShortcutHint: false)
        }
    }

    /// Smallest width at which the row fits with the tabs centred in the window, given measured text widths.
    func requiredWidth(brandWidth: CGFloat, tabTextWidths: [CGFloat]) -> CGFloat {
        let nav = tabTextWidths.reduce(0) { $0 + $1 + 2 * tabPadding }
        let left = Self.leadingInset + brandWidth + 12
        let right = searchMin + 8 + Self.accountWidth + Self.trailingInset + 12
        return nav + 2 * max(left, right)
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

/// The persistent top bar, owned by the root shell. Left: brand. Centre: the five tabs. Right: search and account.
/// Only the selected tab's colour depends on the selection; nothing about the layout does.
struct ReddyTopBar: View {
    let state: TopBarState
    @Binding var query: String
    var focusToken: Int
    var onSubmit: () -> Void = {}
    var onResultsFocus: () -> Void = {}
    var onSelectTab: (AppTab) -> Void
    var onToggleAccount: () -> Void
    @Environment(\.reddyAccent) private var accent
    @FocusState private var searchFocused: Bool
    private var metrics: TopBarMetrics { TopBarMetrics.metrics(for: state.width) }

    var body: some View {
        TopBarLayout(metrics: metrics) {
            brand.layoutValue(key: TopBarZoneKey.self, value: .leading)
            nav.layoutValue(key: TopBarZoneKey.self, value: .center)
            HStack(spacing: 8) { searchBox; accountButton }.layoutValue(key: TopBarZoneKey.self, value: .trailing)
        }
        .frame(height: LayoutTokens.headerHeight)
        .background(WindowDragArea())
        .background(headerBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(ColorTokens.line).frame(height: 1) }
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
    }

    /// Each tab has a fixed width (its measured text plus padding), and every tab uses the same font, so selecting one
    /// changes its colour and nothing else.
    private var nav: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { t in
                Button { onSelectTab(t) } label: {
                    Text(t.title).font(Typography.nav).lineLimit(1).fixedSize()
                        .frame(width: TabLabelMetrics.textWidth(t.title) + 2 * metrics.tabPadding, height: LayoutTokens.headerHeight)
                        .foregroundStyle(state.tab == t ? accent : ColorTokens.textSecondary)
                        .overlay(alignment: .bottom) {
                            Capsule().fill(accent).frame(width: 18, height: 2).padding(.bottom, 1)
                                .opacity(state.tab == t ? 1 : 0).scaleEffect(x: state.tab == t ? 1 : 0.4)
                        }
                        .animation(AnimationTokens.standard, value: state.tab)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NavButtonStyle())
                .accessibilityAddTraits(state.tab == t ? .isSelected : [])
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain).accessibilityLabel("Main navigation")
    }

    /// A real text field. Typing searches and shows results in the content area; nothing opens.
    private var searchBox: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(ColorTokens.textTertiary)
            TextField(metrics.searchIdeal < 170 ? "Search" : "Search everything", text: $query)
                .textFieldStyle(.plain).font(Typography.row).focused($searchFocused).lineLimit(1)
                .onKeyPress(.escape) { query = ""; searchFocused = false; return .handled }
                .onKeyPress(.downArrow) { onResultsFocus(); return .handled }
                .onSubmit { onSubmit() }
                .accessibilityLabel("Search everything").accessibilityHint("Searches all playlists: channels, movies, series, episodes and the guide")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Clear search")
            } else if metrics.showShortcutHint && !searchFocused {
                Text("⌘ K").font(Typography.timestamp).foregroundStyle(ColorTokens.textTertiary)
            }
        }
        .padding(.horizontal, 10).frame(minWidth: metrics.searchMin, idealWidth: metrics.searchIdeal, maxWidth: metrics.searchIdeal).frame(height: 30)
        .background(Color.white.opacity(searchFocused ? 0.07 : 0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(searchFocused ? accent.opacity(0.6) : ColorTokens.glassEdge))
        .onChange(of: focusToken) { _, _ in searchFocused = true }
    }

    private var accountButton: some View {
        Button(action: onToggleAccount) {
            HStack(spacing: 6) {
                Text(state.initials).font(.system(size: 10, weight: .bold)).frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.07), in: Circle()).overlay(Circle().strokeBorder(ColorTokens.glassEdge))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(ColorTokens.textSecondary)
            }
            .frame(width: TopBarMetrics.accountWidth, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account menu").accessibilityValue(state.accountMenuOpen ? "expanded" : "collapsed")
    }
}

private struct NavButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(hovering && !configuration.isPressed ? 1 : 0.96)
            .brightness(hovering ? 0.25 : 0)
            .onHover { hovering = $0 }
    }
}

/// Floating account menu under the header.
struct ReddyAccountMenu: View {
    let name: String
    var onPlaylists: () -> Void
    var onChannelManager: () -> Void
    var onAbout: () -> Void
    enum Restricted { case locked, unlocked }
    /// nil when no PIN is set, so the menu has no parental entry at all.
    var restricted: Restricted?
    var onRestricted: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Typography.rowMedium)
                Text("Local profile · stored on this Mac").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            }.padding(.horizontal, 10).padding(.vertical, 8)
            Divider().overlay(ColorTokens.line).padding(.vertical, 3)
            item("Manage playlists", "list.bullet.rectangle", onPlaylists)
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
        Button(action: action) { menuLabel(t, symbol) }.buttonStyle(MenuRowStyle())
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
