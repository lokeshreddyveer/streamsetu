import Foundation
import Observation

/// The titles lined up to play after the one on screen: movies, and series (which play the episode a person would watch next). A title added
/// twice stays once. The line is kept between launches.
@MainActor @Observable
final class WatchQueue {
    private(set) var items: [LibraryItem] = []
    private let catalog: CatalogRepository
    private let defaults: UserDefaults
    private static let key = "watchQueue"

    init(catalog: CatalogRepository, defaults: UserDefaults = .standard) {
        self.catalog = catalog; self.defaults = defaults
        items = (defaults.stringArray(forKey: Self.key) ?? []).compactMap { Self.item(from: $0, catalog: catalog) }
    }

    /// "movie:<id>" or "series:<id>" to the title, or nil when it is no longer in the library.
    private static func item(from entry: String, catalog: CatalogRepository) -> LibraryItem? {
        guard let colon = entry.firstIndex(of: ":") else { return nil }
        let id = String(entry[entry.index(after: colon)...])
        switch entry[..<colon] {
        case "movie": return ((try? catalog.movie(id: id)) ?? nil).map { LibraryItem.movie($0) }
        case "series": return ((try? catalog.seriesItem(id: id)) ?? nil).map { LibraryItem.series($0) }
        default: return nil
        }
    }

    private func save() { defaults.set(items.map { ($0.isSeries ? "series:" : "movie:") + $0.id }, forKey: Self.key) }

    func contains(_ id: String) -> Bool { items.contains { $0.id == id } }

    /// Puts a title at the end of the line, or at the front when [next] (it plays as soon as the current one ends).
    func add(_ item: LibraryItem, next: Bool = false) {
        items.removeAll { $0.id == item.id }
        if next { items.insert(item, at: 0) } else { items.append(item) }
        save()
    }

    func remove(_ id: String) { items.removeAll { $0.id == id }; save() }
    func clear() { items = []; save() }

    /// Takes the title at the front of the line, or nil when the line is empty.
    func popNext() -> LibraryItem? {
        guard !items.isEmpty else { return nil }
        let first = items.removeFirst(); save()
        return first
    }
}
