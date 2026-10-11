import Foundation

struct Channel: Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: UUID
    let providerID: String
    var name: String
    var normalizedName: String
    var categoryID: String?
    var categoryName: String?
    var logoURL: String?
    var epgID: String?
    var language: String?
    var country: String?
    var resolutionHint: String?
    var sortOrder: Int
    /// Provider reference needed to build the playable URL at playback time (never a stored token URL for Xtream).
    var streamRef: String
    var groupKey: String?
    var isFavorite: Bool = false
    /// Days of catch-up the provider keeps for this channel (0 = none).
    var archiveDays: Int = 0
}

struct StreamVariant: Hashable, Sendable, Identifiable {
    var id: String { variantID }
    let channelID: String
    let variantID: String
    let label: String
}
