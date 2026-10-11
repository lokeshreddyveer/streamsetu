enum SchemaV5 {
    /// The order the user gave their folders. Folders without a row keep the provider's order and follow the ordered ones, so a
    /// folder that appears in a later sync never lands in the middle of a list the user arranged.
    static let sql = """
    CREATE TABLE IF NOT EXISTS folder_order(
        category_id TEXT PRIMARY KEY,
        position INTEGER NOT NULL);
    """
}
