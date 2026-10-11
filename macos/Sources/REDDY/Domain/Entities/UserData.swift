import Foundation

struct Favorite: Hashable, Sendable {
    let itemID: String
    let kind: ContentKind
    let createdAt: Date
    var sortOrder: Int
}

struct WatchProgress: Hashable, Sendable {
    let itemID: String
    let kind: ContentKind
    var seriesID: String?
    var positionSeconds: Double
    var durationSeconds: Double
    var updatedAt: Date
    var completed: Bool

    var fraction: Double { durationSeconds > 0 ? min(1, positionSeconds / durationSeconds) : 0 }
}

struct CatalogCollection: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var createdAt: Date
    var itemCount: Int = 0
}
