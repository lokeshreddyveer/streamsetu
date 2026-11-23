import SwiftUI

extension View {
    /// Runs `action` when artwork or details for this title were written down (by the background matcher or by opening the title), so a page already on screen picks them up.
    /// One shared observer serves every tile (see `MetadataLandedHub`); a tile only registers while it is on screen.
    func onMetadataLanded(for id: String, perform action: @escaping () -> Void) -> some View { modifier(MetadataLandedModifier(id: id, action: action)) }

    /// Tells the background matcher these titles are on screen, so they are matched first. Cheap and debounced; only titles without a poster are worth sending.
    func prioritizesArtwork(_ ids: [String]) -> some View { modifier(PrioritizeArtwork(ids: ids)) }
}

private struct MetadataLandedModifier: ViewModifier {
    let id: String
    let action: () -> Void
    @State private var token = UUID()
    func body(content: Content) -> some View {
        content
            .onAppear { MetadataLandedHub.shared.register(id: id, token: token, action: action); MetadataLandedHub.shared.noteActivity() }
            .onDisappear { MetadataLandedHub.shared.unregister(id: id, token: token) }
            .onChange(of: id) { old, new in MetadataLandedHub.shared.unregister(id: old, token: token); MetadataLandedHub.shared.register(id: new, token: token, action: action) }
    }
}

/// The single subscriber to `titleMetadataLanded` for all tiles. It keeps callbacks only for the titles on screen, so an event costs one dictionary lookup per id in it
/// (not one closure, one main-queue hop and one linear search per tile). It also notes when tiles come and go, which is a cheap "the list is being scrolled" signal.
@MainActor final class MetadataLandedHub {
    static let shared = MetadataLandedHub()
    private var handlers: [String: [UUID: () -> Void]] = [:]
    private var observer: NSObjectProtocol?
    private var lastActivity: TimeInterval = -.infinity
    /// Injected in tests.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// How long after the last tile appeared the list still counts as scrolling.
    var scrollQuietPeriod: TimeInterval = 0.8

    init() {}

    func register(id: String, token: UUID, action: @escaping () -> Void) {
        guard !id.isEmpty else { return }
        handlers[id, default: [:]][token] = action
        startObserving()
    }

    func unregister(id: String, token: UUID) {
        guard var h = handlers[id] else { return }
        h[token] = nil
        handlers[id] = h.isEmpty ? nil : h
    }

    /// Tiles appear and disappear all the time while a list scrolls.
    func noteActivity() { lastActivity = clock() }
    var isScrolling: Bool { clock() - lastActivity < scrollQuietPeriod }

    /// True when a tile showing one of these ids is on screen.
    func hasVisible(anyOf ids: [String]) -> Bool { ids.contains { handlers[$0] != nil } }
    var visibleCount: Int { handlers.count }

    /// Calls the handlers of the tiles showing these ids; ids nobody shows cost one lookup.
    func deliver(_ ids: [String]) {
        for id in ids {
            guard let h = handlers[id] else { continue }
            for action in h.values { action() }
        }
    }

    private func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .titleMetadataLanded, object: nil, queue: .main) { n in
            let ids = TitleMetadataEvent(n).ids
            MainActor.assumeIsolated { MetadataLandedHub.shared.deliver(ids) }
        }
    }
}

/// Decides when a "the catalog changed" publish may go out: not more often than `minInterval`, only when something on screen changed, and not while the list is being scrolled
/// (the change is held and offered again by `retry`). Pure, with the time passed in.
struct LandedPublishGate {
    var minInterval: TimeInterval
    private(set) var last: TimeInterval = -.infinity
    private(set) var pending = false
    init(minInterval: TimeInterval) { self.minInterval = minInterval }

    /// A batch of landed titles arrived. `changedVisible`: at least one is on screen. Returns true when the screen should refresh now.
    mutating func offer(now: TimeInterval, changedVisible: Bool, busy: Bool) -> Bool {
        if changedVisible { pending = true }
        return release(now: now, busy: busy)
    }

    /// Asks again for a change that was held back.
    mutating func retry(now: TimeInterval, busy: Bool) -> Bool { release(now: now, busy: busy) }

    private mutating func release(now: TimeInterval, busy: Bool) -> Bool {
        guard pending, !busy, now - last >= minInterval else { return false }
        pending = false; last = now
        return true
    }
}

private struct PrioritizeArtwork: ViewModifier {
    let ids: [String]
    @Environment(\.container) private var container
    func body(content: Content) -> some View { content.onAppear { if !ids.isEmpty { container?.artworkMatcher.prioritize(ids) } }.onDisappear { if !ids.isEmpty { container?.artworkMatcher.cancelPriority(ids) } } }
}


// MARK: Go to Cast

extension View {
    /// When "Go to Cast" opened this title's page, the cast row is scrolled to the top of the page once it has its size.
    func castRowFocus(_ itemID: String) -> some View { modifier(CastRowFocus(itemID: itemID)) }
}

private struct CastRowFocus: ViewModifier {
    let itemID: String
    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.id(CastFocus.rowID)
                .task(id: itemID) {
                    guard CastFocus.consume(itemID) else { return }
                    try? await Task.sleep(nanoseconds: 450_000_000)          // the row is drawn and sized first
                    if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(CastFocus.rowID, anchor: .top) } }
                }
        }
    }
}

// MARK: express lane for tiles that are not poster cards (hero, search results, person tiles)

extension View {
    /// A title on screen outside the poster cards: without a poster it is matched first (express lane); with `needsBackdrop`, a title with no backdrop gets match + details at once (the open-title fast path).
    func expressArtwork(_ item: LibraryItem, needsBackdrop: Bool = false) -> some View { modifier(ExpressArtwork(item: item, needsBackdrop: needsBackdrop)) }
}

private struct ExpressArtwork: ViewModifier {
    let item: LibraryItem
    let needsBackdrop: Bool
    @Environment(\.container) private var container
    func body(content: Content) -> some View {
        content
            .onAppear {
                guard let c = container else { return }
                if (item.posterURL ?? "").isEmpty { c.artworkMatcher.prioritize([item.id]) }
                if needsBackdrop, (item.backdropURL ?? "").isEmpty {
                    let cand = MetadataMatchService.Candidate(id: item.id, isSeries: item.isSeries, title: item.title, year: item.year)
                    Task.detached(priority: .userInitiated) { _ = await c.metadata.details(for: cand) }          // match + one details call; stored, and the page or tile refreshes when it lands
                }
            }
            .onDisappear { container?.artworkMatcher.cancelPriority([item.id]) }
    }
}
