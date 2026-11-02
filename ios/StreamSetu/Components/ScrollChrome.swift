import SwiftUI

/// The decisions behind the bars that move out of the way while a page scrolls, apart from the screen so they can be tested.
/// `y` is how far the page has scrolled, 0 at the top (negative while it is pulled down).
struct ScrollChromeTracker {
    struct Result: Equatable { var barCollapsed: Bool; var topMerged: Bool }
    /// Scrolling down this far (and being at least `awayFromTop` below the top) shrinks the bottom bar.
    static let downToCollapse: CGFloat = 16
    /// Scrolling up this far brings it back.
    static let upToExpand: CGFloat = 10
    static let awayFromTop: CGFloat = 48
    /// The top buttons only fold once the page has really left the top.
    static let topFoldsBelow: CGFloat = 24

    private var last: CGFloat = 0
    private var down: CGFloat = 0
    private var up: CGFloat = 0
    private(set) var barCollapsed = false

    /// `dragging`: a finger is on the page. Only then does moving up bring the bar back; the page easing back after a bounce at the bottom is not the reader scrolling up.
    mutating func moved(to y: CGFloat, dragging: Bool = true) -> Result {
        let delta = y - last; last = y
        if y <= 4 { down = 0; up = 0; barCollapsed = false; return Result(barCollapsed: false, topMerged: false) }          // at the top everything shows
        if delta > 0 {
            down += delta; up = 0
            if down >= Self.downToCollapse && y > Self.awayFromTop { barCollapsed = true }
        } else if delta < 0 && dragging {
            up -= delta; down = 0
            if up >= Self.upToExpand { barCollapsed = false }
        }
        return Result(barCollapsed: barCollapsed, topMerged: abs(delta) > 0.5 && y > Self.topFoldsBelow)
    }
}

/// What the page being scrolled tells the bars. The bottom bar becomes a small pill on the way down and comes back on the way up; the top buttons
/// fold into the title pill while the page moves and spread out again once it has stopped. Nothing here moves the page itself.
@MainActor @Observable final class ScrollChrome {
    private(set) var barCollapsed = false
    private(set) var topMerged = false
    @ObservationIgnored private var tracker = ScrollChromeTracker()
    @ObservationIgnored private var settle: Task<Void, Never>?
    /// How long the page must be still before the top buttons spread out again.
    static let stillFor: UInt64 = 450_000_000

    func scrolled(to y: CGFloat, dragging: Bool = true) {
        let r = tracker.moved(to: y, dragging: dragging)
        set(bar: r.barCollapsed, top: r.topMerged)
        settle?.cancel()
        guard r.topMerged else { return }
        settle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.stillFor)
            guard !Task.isCancelled else { return }
            self?.set(bar: nil, top: false)
        }
    }

    /// Tapping the small pill, or changing screen, brings the bars back.
    func reset() {
        settle?.cancel(); tracker = ScrollChromeTracker()
        set(bar: false, top: false)
    }

    private func set(bar: Bool?, top: Bool) {
        if let bar, bar != barCollapsed { withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { barCollapsed = bar } }
        if top != topMerged { withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { topMerged = top } }
    }
}

/// Applied once, to every themed screen: tells the shared bars how far the page under them has scrolled. Without a `ScrollChrome` in the
/// environment (the iPad sidebar layout) it does nothing.
struct DrivesChrome: ViewModifier {
    @Environment(ScrollChrome.self) private var chrome: ScrollChrome?
    /// Screens of the other tabs stay alive underneath; only the one on show may speak for the bars.
    @Environment(\.tabActive) private var tabActive
    @State private var dragging = false
    func body(content: Content) -> some View {
        // The offset is held inside the page's real range: the rubber-band bounce at the bottom would otherwise read as scrolling up.
        content.onScrollGeometryChange(for: CGFloat.self) {
            let top = $0.contentInsets.top
            let furthest = max(0, $0.contentSize.height + $0.contentInsets.bottom - $0.containerSize.height + top)
            return min($0.contentOffset.y + top, furthest)
        } action: { _, y in if tabActive { chrome?.scrolled(to: y, dragging: dragging) } }
        .onScrollPhaseChange { _, phase in dragging = phase == .interacting }
    }
}

/// The top buttons while the page moves: they shrink together into one small pill at the right, under the thumb, and cannot be tapped meanwhile.
/// Tapping that pill spreads them out again.
struct ChromeFold: ViewModifier {
    @Environment(ScrollChrome.self) private var chrome: ScrollChrome?
    func body(content: Content) -> some View {
        let folded = chrome?.topMerged ?? false
        content
            .scaleEffect(folded ? 0.3 : 1, anchor: .trailing)
            .opacity(folded ? 0 : 1)
            .allowsHitTesting(!folded)
            .overlay(alignment: .trailing) {
                Button { chrome?.reset() } label: { Image(systemName: "ellipsis").pillIcon() }
                    .buttonStyle(.press)
                    .scaleEffect(folded ? 1 : 0.4, anchor: .trailing)
                    .opacity(folded ? 1 : 0)
                    .allowsHitTesting(folded)
                    .accessibilityLabel("Show buttons").accessibilityHidden(!folded)
            }
    }
}
