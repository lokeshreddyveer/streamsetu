import Foundation

enum SchemaV23 {
    /// Titles whose TMDB rating was looked up once (found or not), so a title without a credible rating is not asked about again until the record expires.
    static let sql = """
    CREATE TABLE IF NOT EXISTS rating_checks(
        item_id TEXT PRIMARY KEY,
        checked_at REAL NOT NULL
    );
    """
}
