import Foundation

final class FavoritesService: Sendable {
    let repo: FavoritesRepository
    let catalog: CatalogRepository

    init(repo: FavoritesRepository, catalog: CatalogRepository) { self.repo = repo; self.catalog = catalog }

    func toggle(id: String, kind: ContentKind) throws -> Bool {
        let now = !(try repo.isFavorite(id))
        try repo.setFavorite(id, kind: kind, on: now)
        return now
    }

    func channels(sourceID: UUID? = nil) throws -> [Channel] { try ordered(try repo.favoriteIDs(kind: .channel)) { try catalog.channels(ChannelQuery(sourceID: sourceID, collapseVariants: false, ids: $0)) } }
    func movies(sourceID: UUID? = nil) throws -> [Movie] { try ordered(try repo.favoriteIDs(kind: .movie)) { try catalog.movies(VODQuery(sourceID: sourceID, ids: $0)) } }
    func series(sourceID: UUID? = nil) throws -> [Series] { try ordered(try repo.favoriteIDs(kind: .series)) { try catalog.series(VODQuery(sourceID: sourceID, ids: $0)) } }

    private func ordered<T: Identifiable>(_ ids: [String], _ fetch: ([String]) throws -> [T]) throws -> [T] where T.ID == String {
        let by = Dictionary(try fetch(ids).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { by[$0] }          // keeps the user's drag-and-drop order
    }
}
