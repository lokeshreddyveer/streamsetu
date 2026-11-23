import SwiftUI

/// A title or collection named by id, so a screen can push it with a value link even when it only has the id (a search result).
struct TitleRef: Hashable { let id: String; let isSeries: Bool }
struct CollectionRef: Hashable { let id: String }
/// The search and the TV guide pushed from a screen's toolbar.
enum ToolRoute: Hashable { case search(SearchTab), guide }

/// Registers every destination a page in this stack may push: a title, a person, a title by id and a collection by id. Every stack root that can show titles applies it,
/// so a title page and a person page are always reachable by a value link, whichever screen the stack began with (and a new screen cannot forget one).
extension View {
    func titleAndPersonDestinations() -> some View {
        navigationDestination(for: LibraryItem.self) { DetailView(item: $0).id($0.id) }
            .navigationDestination(for: PersonRoute.self) { PersonPage(route: $0).navigationBarTitleDisplayMode(.inline) }
            .navigationDestination(for: TitleRef.self) { TitleByID(ref: $0) }
            .navigationDestination(for: CollectionRef.self) { CollectionByID(ref: $0) }
            .navigationDestination(for: ToolRoute.self) { route in
                switch route {
                case .search(let tab): SearchView(embedded: true, tab: tab)
                case .guide: GuideView(embedded: true)
                }
            }
    }

    /// For a screen that is pushed into a stack whose root already registered the destinations (embedded Search): registering the same types again on the pushed screen
    /// gives the stack two handlers for one value, and a title opened from the results could land under the search screen. Only a screen that owns its stack registers them.
    @ViewBuilder func titleAndPersonDestinations(ownsStack: Bool) -> some View {
        if ownsStack { titleAndPersonDestinations() } else { self }
    }
}

private struct TitleByID: View {
    let ref: TitleRef
    @Environment(\.container) private var container
    @State private var item: LibraryItem?
    @State private var missing = false
    var body: some View {
        Group {
            if let item { DetailView(item: item).id(item.id) }
            else if missing { EmptyState(symbol: "film", title: "Not available", message: "This title is no longer in your library.") }
            else { BrandLoader(size: 32).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: ref) {
            guard let c = container else { return }
            let found: LibraryItem? = ref.isSeries ? ((try? c.catalog.seriesItem(id: ref.id)) ?? nil).map { .series($0) } : ((try? c.catalog.movie(id: ref.id)) ?? nil).map { .movie($0) }
            item = found; missing = found == nil
        }
    }
}

private struct CollectionByID: View {
    let ref: CollectionRef
    @Environment(\.container) private var container
    @State private var found: CatalogCollection?
    @State private var missing = false
    var body: some View {
        Group {
            if let found { CollectionDetailView(collection: found) }
            else if missing { EmptyState(symbol: "square.stack", title: "Not available", message: "That collection no longer exists.") }
            else { BrandLoader(size: 32).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: ref) {
            guard let c = container else { return }
            let r = await Task.detached { (try? c.favoritesRepo.collections())?.first { $0.id == ref.id } }.value
            found = r; missing = r == nil
        }
    }
}
