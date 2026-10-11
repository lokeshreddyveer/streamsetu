import Foundation

struct ToggleFavoriteUseCase: Sendable {
    let favorites: FavoritesService
    @discardableResult
    func callAsFunction(id: String, kind: ContentKind) throws -> Bool { try favorites.toggle(id: id, kind: kind) }
}
