import Foundation

struct Series: Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: UUID
    let providerID: String
    var title: String
    var normalizedTitle: String
    var overview: String?
    var posterURL: String?
    var backdropURL: String?
    var genre: String?
    var releaseYear: Int?
    var rating: String?
    var categoryID: String?
    var categoryName: String?
    var addedAt: Date?
    var lastMetadataRefresh: Date?
    var isFavorite: Bool = false
}

struct Season: Identifiable, Hashable, Sendable {
    let id: String
    let seriesID: String
    var number: Int
    var name: String?
}

struct Episode: Identifiable, Hashable, Sendable {
    let id: String
    let seriesID: String
    var seasonID: String?
    var seasonNumber: Int
    var providerEpisodeID: String
    var episodeNumber: Int
    var title: String
    var overview: String?
    var imageURL: String?
    var durationSeconds: Double?
    var streamRef: String
}

struct SeriesDetail: Sendable {
    var series: Series
    var seasons: [Season]
    var episodes: [Episode]
    var extras: ProviderExtras?
}
