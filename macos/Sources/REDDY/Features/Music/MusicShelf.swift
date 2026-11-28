import SwiftUI
import AppKit

// Shelves: a heading, an optional description, See all / Show all, and a row of cards that scrolls sideways with hover paging buttons and arrow keys.

// MARK: - Pure paging maths

/// Keyboard navigation by index: left and right move by `delta` items and stop at the ends (no wrap).
enum MusicShelfKeyNav {
    static func nextIndex(current: Int, count: Int, delta: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(current + delta, 0), count - 1)
    }
}

/// Shelf scroll maths in points. Everything is a pure function of the offset, the viewport, the content width and the card step.
enum MusicShelfPaging {
    static let edgeTolerance: CGFloat = 0.5

    static func maxOffset(content: CGFloat, viewport: CGFloat) -> CGFloat { max(0, content - viewport) }

    /// How many whole cards fit in the viewport (at least one).
    static func itemsPerPage(viewport: CGFloat, step: CGFloat) -> Int {
        guard step > 0, viewport.isFinite, viewport > 0 else { return 1 }
        return max(1, Int(((viewport + MusicCardGeometry.shelfSpacing) / step).rounded(.down)))
    }

    /// Cards in a row of `content` points, given that cards are `step` apart and the last has no trailing gap.
    static func itemCount(content: CGFloat, step: CGFloat) -> Int {
        guard step > 0, content > 0 else { return 0 }
        return Int(((content + MusicCardGeometry.shelfSpacing) / step).rounded())
    }

    static func canPageBack(offset: CGFloat) -> Bool { offset > edgeTolerance }
    static func canPageForward(offset: CGFloat, content: CGFloat, viewport: CGFloat) -> Bool {
        offset < maxOffset(content: content, viewport: viewport) - edgeTolerance
    }

    /// Where to scroll to after `direction` (-1 back, +1 forward) by `items` cards, snapped to a card edge and clamped to the content.
    static func target(offset: CGFloat, direction: Int, items: Int, step: CGFloat, content: CGFloat, viewport: CGFloat) -> CGFloat {
        guard step > 0 else { return offset }
        let count = itemCount(content: content, step: step)
        let current = Int((offset / step).rounded())
        let next = MusicShelfKeyNav.nextIndex(current: current, count: count, delta: direction * max(1, items))
        return min(CGFloat(next) * step, maxOffset(content: content, viewport: viewport))
    }

    /// Index of the first card that is at least half visible.
    static func firstVisibleIndex(offset: CGFloat, step: CGFloat) -> Int {
        guard step > 0 else { return 0 }
        return max(0, Int((max(0, offset) / step).rounded(.down)))
    }

    /// The cards just past the visible edge, for artwork prefetch (never more than `window`).
    static func upcomingRange(offset: CGFloat, viewport: CGFloat, step: CGFloat, count: Int, window: Int) -> Range<Int> {
        guard step > 0, count > 0, window > 0 else { return 0..<0 }
        let first = firstVisibleIndex(offset: offset, step: step)
        let visible = Int(((max(0, offset) + max(0, viewport)) / step).rounded(.up))
        let lower = min(max(first, 0), count)
        let upper = min(count, max(lower, visible) + window)
        return lower..<max(lower, upper)
    }
}

/// When a shelf shows its paging arrows and its "Show all" link: only when the cards do not all fit in the visible row.
enum MusicShelfFit {
    /// True when the whole row fits in the viewport. Before the first measurement (no viewport yet) it counts as fitting, so the links
    /// appear only once the row is known to overflow.
    static func fits(content: CGFloat, viewport: CGFloat) -> Bool {
        guard viewport.isFinite, viewport > 0, content.isFinite else { return true }
        return content <= viewport + MusicShelfPaging.edgeTolerance
    }
    /// Arrows need something to scroll to.
    static func showsArrows(fits: Bool, canPage: Bool) -> Bool { !fits && canPage }
    /// "Show all" opens the full grid; it adds nothing when every card is already visible.
    static func showsShowAll(hasAll: Bool, fits: Bool) -> Bool { hasAll && !fits }
}

// MARK: - Scroll bridge

/// Finds the horizontal scroll view a shelf lives in, reports its offset and sizes, and scrolls it with a short animation. Reports are cheap
/// values; the shelf only re-renders when something it shows changes.
@MainActor final class MusicShelfScroller {
    private(set) weak var scrollView: NSScrollView?
    var onMetrics: ((CGFloat, CGFloat, CGFloat) -> Void)?
    private var observer: NSObjectProtocol?

    func attach(_ view: NSView) {
        guard let sv = view.enclosingScrollView, sv !== scrollView else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        scrollView = sv
        sv.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        report()
    }

    func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func report() {
        guard let sv = scrollView else { return }
        onMetrics?(sv.contentView.bounds.origin.x, sv.contentView.bounds.width, sv.documentView?.frame.width ?? 0)
    }

    var metrics: (offset: CGFloat, viewport: CGFloat, content: CGFloat) {
        guard let sv = scrollView else { return (0, 0, 0) }
        return (sv.contentView.bounds.origin.x, sv.contentView.bounds.width, sv.documentView?.frame.width ?? 0)
    }

    func scroll(to x: CGFloat, seconds: Double) {
        guard let sv = scrollView else { return }
        let point = NSPoint(x: x, y: sv.contentView.bounds.origin.y)
        if seconds <= 0 {
            sv.contentView.setBoundsOrigin(point)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = seconds
                ctx.allowsImplicitAnimation = true
                sv.contentView.animator().setBoundsOrigin(point)
            }
        }
        sv.reflectScrolledClipView(sv.contentView)
    }
}

private struct MusicShelfScrollBridge: NSViewRepresentable {
    let scroller: MusicShelfScroller
    final class Anchor: NSView {
        var onMove: ((NSView) -> Void)?
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); onMove?(self) }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onMove?(self) }
    }
    func makeNSView(context: Context) -> Anchor {
        let v = Anchor()
        v.onMove = { [scroller] view in MainActor.assumeIsolated { scroller.attach(view) } }
        return v
    }
    func updateNSView(_ nsView: Anchor, context: Context) {}
}

// MARK: - Shelf

/// A titled row of cards that scrolls sideways. With a `showAll` view it also offers "Show all", which opens every item in a grid.
/// Chain `detail`, `onSeeAll`, `cardWidth`, `loading`, `emptyMessage` and `prefetching` to add the rest.
struct MusicShelf<Content: View, All: View>: View {
    let title: String
    var subtitle: String?
    var hasAll: Bool
    var content: Content
    var all: All
    var detailText: String?
    var seeAllAction: (() -> Void)?
    var itemWidth: CGFloat = MusicCardGeometry.defaultWidth
    var isLoading = false
    var emptyText: String?
    var prefetchAddresses: [String] = []
    var prefetchClass: MusicArtworkClass = .tile
    @State private var showingAll = false
    @State private var hovering = false
    @State private var canBack = false
    @State private var canForward = false
    @State private var firstIndex = 0
    @State private var rowFits = true
    @State private var scroller = MusicShelfScroller()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder showAll: () -> All) {
        self.title = title; self.subtitle = subtitle; self.hasAll = true; self.content = content(); self.all = showAll()
    }

    // Modifiers (copy-and-set, so the existing initialisers keep working).
    func detail(_ text: String?) -> Self { var c = self; c.detailText = text; return c }
    func onSeeAll(_ action: @escaping () -> Void) -> Self { var c = self; c.seeAllAction = action; return c }
    func cardWidth(_ width: CGFloat) -> Self { var c = self; c.itemWidth = width; return c }
    func loading(_ on: Bool) -> Self { var c = self; c.isLoading = on; return c }
    /// Shows the empty state (with this message) instead of the cards.
    func emptyMessage(_ text: String?) -> Self { var c = self; c.emptyText = text; return c }
    /// The cover addresses of every card, in order; the shelf warms the artwork of the cards just past the visible edge.
    func prefetching(_ addresses: [String], artworkClass: MusicArtworkClass = .tile) -> Self {
        var c = self; c.prefetchAddresses = addresses; c.prefetchClass = artworkClass; return c
    }

    private var step: CGFloat { MusicCardGeometry.step(width: itemWidth) }
    private var owner: String { "shelf:" + title }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            heading
            if isLoading {
                MusicShelfSkeleton(width: itemWidth)
            } else if let emptyText {
                MusicEmptyState(glyph: .note, title: emptyText, compact: true)
            } else {
                row
            }
        }
        .sheet(isPresented: $showingAll) { MusicShowAllSheet(title: title, hub: .shared) { all } }
        .onDisappear { MusicArtworkPrefetcher.shared.cancel(owner: owner) }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: MusicSpace.xxs / 2) {
                MusicSectionTitle(title: title)
                if let subtitle, !subtitle.isEmpty { Text(verbatim: subtitle).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                if let detailText, !detailText.isEmpty { Text(verbatim: detailText).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).lineLimit(2) }
            }
            Spacer(minLength: MusicSpace.sm)
            if let seeAllAction {
                Button("See all", action: seeAllAction)
                    .musicButton(.tertiary, size: .compact)
                    .accessibilityLabel("See all in \(title)").atlas("control.music.shelfSeeAll")
            }
            if MusicShelfFit.showsShowAll(hasAll: hasAll, fits: rowFits) {
                Button("Show all") { showingAll = true }
                    .musicButton(.tertiary, size: .compact)
                    .accessibilityLabel("Show all in \(title)").atlas("control.music.showAll")
            }
        }
    }

    private var row: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: MusicCardGeometry.shelfSpacing) { content }
                .padding(.vertical, MusicSpace.xxs)
                .background(MusicShelfScrollBridge(scroller: scroller))
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .leading) { pagingButton(forward: false) }
        .overlay(alignment: .trailing) { pagingButton(forward: true) }
        .onHover { hovering = $0 }
        .onKeyPress(.leftArrow) { page(-1, items: 1) }
        .onKeyPress(.rightArrow) { page(1, items: 1) }
        .onAppear { wire() }
        .onDisappear { scroller.onMetrics = nil; scroller.detach() }
        .onChange(of: firstIndex) { _, _ in prefetchUpcoming() }
        .onChange(of: prefetchAddresses) { _, _ in prefetchUpcoming() }
    }

    @ViewBuilder private func pagingButton(forward: Bool) -> some View {
        let available = MusicShelfFit.showsArrows(fits: rowFits, canPage: forward ? canForward : canBack)
        Button { _ = page(forward ? 1 : -1, items: MusicShelfPaging.itemsPerPage(viewport: scroller.metrics.viewport, step: step)) } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textPrimary)
                .frame(width: MusicTokens.hitTarget + MusicSpace.xs, height: MusicTokens.hitTarget + MusicSpace.xs)
                .background(ColorTokens.elevated, in: Circle())
                .overlay(Circle().strokeBorder(ColorTokens.lineStrong, lineWidth: 0.75))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MusicSpace.xxs)
        .opacity(hovering && available ? 1 : 0)
        .allowsHitTesting(hovering && available)
        .musicAnimation(.hover, reduce: reduceMotion, value: hovering && available)
        .accessibilityLabel(forward ? "Show next in \(title)" : "Show previous in \(title)")
        .musicTooltip(forward ? "Next" : "Previous")
        .atlas(forward ? "control.music.shelfPageForward" : "control.music.shelfPageBack")
        .atlasCovers("control.music.shelfPageForward")
    }

    private func page(_ direction: Int, items: Int) -> KeyPress.Result {
        let m = scroller.metrics
        let can = direction > 0 ? MusicShelfPaging.canPageForward(offset: m.offset, content: m.content, viewport: m.viewport) : MusicShelfPaging.canPageBack(offset: m.offset)
        guard can else { return .ignored }
        let x = MusicShelfPaging.target(offset: m.offset, direction: direction, items: items, step: step, content: m.content, viewport: m.viewport)
        scroller.scroll(to: x, seconds: MusicMotion.seconds(.listChange, reduce: reduceMotion))
        return .handled
    }

    private func wire() {
        scroller.onMetrics = { offset, viewport, content in
            let back = MusicShelfPaging.canPageBack(offset: offset)
            let forward = MusicShelfPaging.canPageForward(offset: offset, content: content, viewport: viewport)
            let first = MusicShelfPaging.firstVisibleIndex(offset: offset, step: step)
            if back != canBack { canBack = back }
            if forward != canForward { canForward = forward }
            if first != firstIndex { firstIndex = first }
            let fit = MusicShelfFit.fits(content: content, viewport: viewport)
            if fit != rowFits { rowFits = fit }
        }
        scroller.report()
        prefetchUpcoming()
    }

    private func prefetchUpcoming() {
        guard !prefetchAddresses.isEmpty else { return }
        let m = scroller.metrics
        let viewport = m.viewport > 0 ? m.viewport : step * CGFloat(MusicLayoutGrid.columns(for: .expanded))
        let range = MusicShelfPaging.upcomingRange(offset: m.offset, viewport: viewport, step: step, count: prefetchAddresses.count, window: MusicArtworkPrefetcher.defaultWindow)
        MusicArtworkPrefetcher.shared.prefetch(addresses: Array(prefetchAddresses[range]), artworkClass: prefetchClass, scale: displayScale, priority: .low, owner: owner)
    }
}

extension MusicShelf where All == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.hasAll = false; self.content = content(); self.all = EmptyView()
    }
}

/// Every item of a shelf in one grid. It closes by itself when an item opens a page.
struct MusicShowAllSheet<Body: View>: View {
    let title: String
    let hub: MusicHub
    @ViewBuilder var content: Body
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: title).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(MusicTokens.iconSmall).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle()) }
                    .buttonStyle(.plain).hoverHighlight().keyboardShortcut(.cancelAction).accessibilityLabel("Close").atlas("control.music.sharedPartsClose")
            }
            .padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.md)
            Divider().overlay(ColorTokens.line)
            ScrollView {
                LazyVGrid(columns: MusicLayout.gridColumns, alignment: .leading, spacing: 18) { content }
                    .padding(Spacing.xl)
            }
            .scrollIndicators(.hidden)
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 480, idealHeight: 620)
        .background(ColorTokens.background)
        .onChange(of: hub.nav.stack) { _, _ in dismiss() }
    }
}

