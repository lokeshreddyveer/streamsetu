import Foundation

/// The one rule for the rating a title shows, on every screen. TMDB's average counts only when enough people voted (`tmdbVoteFloor`): a film with two votes can score 10.0.
/// Otherwise the provider's own rating, if it passes the junk filter (0, 10, 10.0, impossible values are junk); otherwise none. Shared fixtures: artwork/fixtures/display-rating.json.
enum DisplayRating {
    /// Below this many votes a TMDB average is not trusted.
    static let tmdbVoteFloor = 10

    /// TMDB's average as the one-decimal text stored with the title, or nil when it is not credible.
    static func tmdbText(average: Double?, votes: Int?) -> String? {
        guard let average, average > 0, average <= 10, (votes ?? 0) >= tmdbVoteFloor else { return nil }
        return String(format: "%.1f", average)
    }

    static func value(tmdbAverage: Double?, tmdbVotes: Int?, provider: String?) -> Double? {
        if let t = tmdbText(average: tmdbAverage, votes: tmdbVotes) { return Double(t) }
        return RatingRule.credible(provider)
    }
}
