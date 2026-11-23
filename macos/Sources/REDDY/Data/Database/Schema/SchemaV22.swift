import Foundation

enum SchemaV22 {
    /// The ids a provider itself gives for a title (TMDB's and IMDb's): an exact match for artwork, no search. Not personal data; rows of titles that are gone are harmless.
    static let sql = """
    CREATE TABLE IF NOT EXISTS provider_ids(
        item_id TEXT PRIMARY KEY,
        tmdb_id INTEGER,
        imdb_id TEXT
    );
    """
}
