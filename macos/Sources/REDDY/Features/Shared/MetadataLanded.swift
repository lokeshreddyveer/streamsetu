import SwiftUI

extension View {
    /// Runs `action` when artwork or details for this title were written down (by the background matcher or by opening the title), so a page already on screen picks them up.
    func onMetadataLanded(for id: String, perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .titleMetadataLanded).receive(on: DispatchQueue.main)) { n in
            if TitleMetadataEvent(n).ids.contains(id) { action() }
        }
    }

    /// Tells the background matcher these titles are on screen, so they are matched first. Cheap and debounced; only titles without a poster are worth sending.
    func prioritizesArtwork(_ ids: [String]) -> some View { modifier(PrioritizeArtwork(ids: ids)) }
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
