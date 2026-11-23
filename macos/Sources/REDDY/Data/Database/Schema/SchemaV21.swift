import Foundation

enum SchemaV21 {
    /// "Remove from Continue Watching" writes only this marker: the title is left out of the Continue Watching list until it is played again (progress newer than the marker). Progress, resume position,
    /// watched state and history are never touched. Personal data: it travels with the profile like the progress rows do.
    static let sql = """
    CREATE TABLE IF NOT EXISTS continue_hidden(
        item_id TEXT PRIMARY KEY,
        hidden_at REAL NOT NULL
    );
    """
}
