import Foundation

struct CatalogCategory: Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: UUID
    let kind: ContentKind
    let providerID: String
    var name: String
    var sortOrder: Int
    var itemCount: Int = 0

    static func makeID(source: UUID, kind: ContentKind, provider: String) -> String {
        ItemID.make(source: source, kind: kind, provider: "cat:\(provider)")
    }
}

extension CatalogCategory {
    /// Pseudo-folder for items the provider did not file under any category. It exists only in the interface; nothing is stored.
    static let uncategorizedID = "uncategorized"
}

/// What a provider returned for one content type, before it is stored.
struct CategoryFetch: Sendable {
    var categories: [CatalogCategory]
    /// Entries the provider listed (including ones that could not be used).
    var providerCount: Int
    /// One human-readable reason per entry that was not usable. Never contains credentials or URLs.
    var rejected: [String]

    var parsedCount: Int { categories.count }
}

/// What reconciling a fetched list with the stored categories did.
struct CategoryReconcile: Sendable, Equatable {
    var inserted = 0
    var updated = 0
    var removed = 0
    /// Categories that would have been deleted but were kept because the fetch looked incomplete.
    var keptStale = 0
    /// Categories created only because items referred to them while the provider did not list them.
    var synthesized = 0
    var note: String?
}

/// What the last sync saw for one source and content type.
struct CategoryStatsRow: Sendable, Equatable {
    let sourceID: UUID
    let kind: ContentKind
    var providerCount: Int
    var parsedCount: Int
    var rejectedCount: Int
    var rejectedReasons: [String]
    var reconcile: CategoryReconcile
    var syncedAt: Date
}
