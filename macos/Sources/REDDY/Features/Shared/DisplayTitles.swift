import Foundation

/// What a tile in a shelf calls a title. The provider's bracketed language, quality and year tags are noise on a tile ("Nocturne (English)"), so a tile shows the
/// name the artwork matching searches for. The original title is kept wherever it identifies a version (detail page, search, library grid).
enum DisplayTitle {
    /// The cleaned title; never empty.
    static func clean(_ title: String) -> String { ArtworkNameCleaner.clean(title) }

    private static func key(_ s: String) -> String { MetadataNormalizer.normalize(s) }

    /// Display titles for the tiles of one row, by item id. Tiles whose cleaned titles are the same keep their original title, so two versions of a film stay tellable apart.
    static func labels(_ items: [(id: String, title: String)]) -> [String: String] { labels(items.map { ($0.id, $0.title, nil) }) }

    /// With the library's year, a year left on the end of a name ("Arcane 2021" under "2021 - Series") is dropped, since the tile shows the year anyway.
    static func labels(_ items: [(id: String, title: String, year: Int?)]) -> [String: String] {
        let cleaned = items.map { (id: $0.id, original: $0.title, clean: ArtworkNameCleaner.clean($0.title, year: $0.year)) }
        var count: [String: Int] = [:]
        for c in cleaned { count[key(c.clean), default: 0] += 1 }
        var out: [String: String] = [:]
        for c in cleaned { out[c.id] = (count[key(c.clean)] ?? 0) > 1 ? c.original : c.clean }
        return out
    }
}

/// One rule for whether a provider's rating may be shown as a badge: the same one the ranking uses (a text such as "7.4"; 0, 10, 10.0 and anything unreadable are junk).
enum RatingRule {
    static func credible(_ text: String?) -> Double? { SmartMixScoring.ratingTenths(text).map { Double($0) / 10 } }

    /// The same rule as SQL, for ordering and filtering in the database: a stored rating text counts only between 0.1 and 9.9; everything else (0, 10, 10.0, text) counts as 0.
    /// `credible` stays the exact reader (it also rejects forms like "+8" or "9.95"), so use this for order-by and pre-filters and `credible` for what is shown.
    static func sqlValue(_ column: String) -> String { "(CASE WHEN CAST(\(column) AS REAL) >= 0.1 AND CAST(\(column) AS REAL) < 10 THEN CAST(\(column) AS REAL) ELSE 0 END)" }
    /// SQL true when the stored rating is NOT credible (empty, junk, out of range, or not plain digits).
    static func sqlIsJunk(_ column: String) -> String { "(\(column) IS NULL OR \(column) = '' OR \(sqlValue(column)) = 0 OR \(column) GLOB '*[^0-9.]*')" }
}
