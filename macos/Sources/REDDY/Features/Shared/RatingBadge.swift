import SwiftUI

/// The star badge of a tile (the same look on every card): theme tokens, hidden when there is no credible rating.
struct RatingBadge: View {
    let value: Double
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill").font(.system(size: 8))
            Text(String(format: "%.1f", value)).font(.system(size: 9, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(ColorTokens.starRating).padding(.horizontal, 5).padding(.vertical, 3)
        .background(Color(hex: 0x080A0D, opacity: 0.72), in: Capsule())
        .accessibilityElement(children: .ignore).accessibilityLabel(Text("Rated \(String(format: "%.1f", value))"))
    }
}

/// The inline star and number used on detail pages and banners (one place for the format).
struct RatingLabel: View {
    let value: Double
    var body: some View { Label(String(format: "%.1f", value), systemImage: "star.fill").labelStyle(.titleAndIcon).foregroundStyle(.yellow) }
}

extension View {
    /// The one way a tile shows its rating: the star badge, top right, only when there is a credible rating. Every view that draws a film or series poster uses this (or `RatingBadge`); a source scan in the tests enforces it.
    func ratingBadge(_ value: Double?, scale: CGFloat = 1) -> some View {
        overlay(alignment: .topTrailing) { if let value { RatingBadge(value: value).scaleEffect(scale, anchor: .topTrailing).padding(max(2, 6 * scale)) } }
    }
}

extension LibraryItem {
    /// The rating worth showing for this title (TMDB's when matched, else the provider's when credible), or nil.
    var credibleRating: Double? { switch self { case .movie(let m): RatingRule.credible(m.rating); case .series(let s): RatingRule.credible(s.rating) } }
}

extension SearchResult {
    /// The title to ask the express lane about when this row has no rating yet (films and series only).
    var ratingTileIDs: [String] {
        guard rating == nil else { return [] }
        switch destination { case .movie(let id): return [id]; case .series(let id): return [id]; default: return [] }
    }
}
