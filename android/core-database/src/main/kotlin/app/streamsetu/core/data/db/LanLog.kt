package app.streamsetu.core.data.db

import androidx.sqlite.db.SupportSQLiteDatabase

/**
 * A small log of when favorites, resume points and collections last changed, kept by database triggers so no screen has to remember to write it. Sync on this network reads it to
 * know when each thing changed and which ones were removed. While a change from another device is being applied the flag is set, so that change is not logged as new.
 */
object LanLog {
    private const val NOW = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)"

    fun create(db: SupportSQLiteDatabase) {
        db.execSQL("CREATE TABLE IF NOT EXISTS lan_log(kind TEXT NOT NULL, key TEXT NOT NULL, ts INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(kind, key))")
        db.execSQL("CREATE TABLE IF NOT EXISTS lan_flag(applying INTEGER NOT NULL)")
        db.execSQL("INSERT INTO lan_flag(applying) SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM lan_flag)")
        val on = "WHEN (SELECT applying FROM lan_flag) = 0"
        fun put(kind: String, key: String, deleted: Int) = "INSERT OR REPLACE INTO lan_log(kind, key, ts, deleted) VALUES('$kind', $key, $NOW, $deleted);"
        val tables = listOf(
            Triple("favorites", "fav", "%s.itemId || char(1) || %s.listId"),
            Triple("progress", "prog", "%s.itemId"),
            Triple("collections", "col", "%s.id"),
            Triple("collection_items", "colitem", "%s.collectionId || char(1) || %s.itemId"),
        )
        for ((table, kind, keyPattern) in tables) {
            fun key(row: String) = keyPattern.replace("%s", row)
            db.execSQL("CREATE TRIGGER IF NOT EXISTS lan_${table}_ai AFTER INSERT ON $table $on BEGIN ${put(kind, key("NEW"), 0)} END")
            db.execSQL("CREATE TRIGGER IF NOT EXISTS lan_${table}_au AFTER UPDATE ON $table $on BEGIN ${put(kind, key("OLD"), 1)} ${put(kind, key("NEW"), 0)} END")
            db.execSQL("CREATE TRIGGER IF NOT EXISTS lan_${table}_ad AFTER DELETE ON $table $on BEGIN ${put(kind, key("OLD"), 1)} END")
        }
    }
}
