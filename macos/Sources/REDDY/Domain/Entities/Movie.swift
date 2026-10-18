import Foundation

struct Movie: Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: UUID
    let providerID: String
    var title: String
    var normalizedTitle: String
    var overview: String?
    var posterURL: String?
    var backdropURL: String?
    var releaseYear: Int?
    var durationSeconds: Double?
    var genre: String?
    var rating: String?
    var categoryID: String?
    var categoryName: String?
    var streamRef: String
    var addedAt: Date?
    var detailFetchedAt: Date?
    var isFavorite: Bool = false
}

/// Extra metadata fetched on demand (get_vod_info) and cached.
/// What a provider says about a title beyond the basics (many Xtream panels send a trailer, the cast and the director).
struct ProviderExtras: Sendable, Equatable {
    var trailerKey: String?
    var cast: [String] = []
    var directors: [String] = []
    var country: String?
    var ageRating: String?
    var tmdbID: Int?
    var isEmpty: Bool { trailerKey == nil && cast.isEmpty && directors.isEmpty && country == nil && ageRating == nil }

    /// The names in a provider's "A, B / C" style string.
    static func names(_ s: String?) -> [String] {
        (s ?? "").split(whereSeparator: { ",/|".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Builds extras from the raw strings a provider sends; nil when there is nothing useful in them.
    static func make(trailer: String?, cast: String?, director: String?, country: String?, age: String?, tmdb: String?) -> ProviderExtras? {
        func list(_ s: String?) -> [String] {
            (s ?? "").split(whereSeparator: { ",/|".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let e = ProviderExtras(trailerKey: youTubeKey(trailer), cast: list(cast), directors: list(director),
                               country: country?.trimmingCharacters(in: .whitespaces).nilIfEmpty, ageRating: age?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                               tmdbID: tmdb.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil })
        return e.isEmpty && e.tmdbID == nil ? nil : e
    }

    /// A YouTube video id from a bare id or any common YouTube link.
    static func youTubeKey(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.count == 11, raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) { return raw }
        guard let r = raw.range(of: #"(?:v=|youtu\.be/|embed/|shorts/)([A-Za-z0-9_-]{11})"#, options: .regularExpression) else { return nil }
        return String(raw[r].suffix(11))
    }
}

struct MovieDetail: Sendable {
    var overview: String?
    var backdropURL: String?
    var posterURL: String?
    var genre: String?
    var releaseYear: Int?
    var durationSeconds: Double?
    var rating: String?
    var extras: ProviderExtras?
}
