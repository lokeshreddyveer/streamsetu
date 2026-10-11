import Foundation

enum LiveFilter: Hashable {
    case all, favorites, recent, added
    case category(String)
    /// One of the person's own named lists (a collection), such as Sports or Kids.
    case list(String)

    init(_ selection: SidebarSelection) {
        switch selection {
        case .shortcut(.favorites): self = .favorites
        case .shortcut(.recentlyWatched): self = .recent
        case .shortcut(.recentlyAdded): self = .added
        case .folder(let id): self = .category(id)
        default: self = .all
        }
    }
}
