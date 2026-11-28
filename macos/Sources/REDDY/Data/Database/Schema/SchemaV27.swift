import Foundation

enum SchemaV27 {
    /// Removes the tables of a feature that was withdrawn before release. Development builds had created them (version 26); nothing else in the database refers to them.
    /// `IF EXISTS` throughout: a database that never had them is left as it is.
    static let sql = """
    DROP TABLE IF EXISTS music_fts;
    DROP TABLE IF EXISTS music_library_fts;
    DROP TABLE IF EXISTS music_trgm;
    DROP TABLE IF EXISTS music_favorites;
    DROP TABLE IF EXISTS music_history;
    DROP TABLE IF EXISTS music_queue_state;
    DROP TABLE IF EXISTS music_queue_items;
    DROP TABLE IF EXISTS music_canonical;
    DROP TABLE IF EXISTS music_track_refs;
    DROP TABLE IF EXISTS music_artist_alias;
    DROP TABLE IF EXISTS music_playlist_items;
    DROP TABLE IF EXISTS music_playlists;
    DROP TABLE IF EXISTS music_playlist_folders;
    DROP TABLE IF EXISTS music_play_events;
    DROP TABLE IF EXISTS music_followed_artists;
    DROP TABLE IF EXISTS music_user_sources;
    DROP TABLE IF EXISTS music_local_files;
    DROP TABLE IF EXISTS music_local_folders;
    DROP TABLE IF EXISTS music_link_refs;
    DROP TABLE IF EXISTS music_radio_favorites;
    DROP TABLE IF EXISTS lyrics_documents;
    DROP TABLE IF EXISTS lyrics_negative;
    DROP TABLE IF EXISTS lyrics_offsets;
    DROP TABLE IF EXISTS lyrics_blocked;
    DROP TABLE IF EXISTS lyrics_derived;
    """
}
