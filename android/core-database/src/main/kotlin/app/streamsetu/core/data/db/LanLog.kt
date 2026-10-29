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
        // An update followed by an insert that only happens when there was nothing to update: not INSERT OR REPLACE (SQLite uses the conflict rule of the statement that fired a trigger
        // instead of the trigger's own, which could fail with a UNIQUE error) and not an upsert (ON CONFLICT ... DO UPDATE needs SQLite 3.24; Android 9, API 28, has 3.22 and Fire OS 5 to 7 are older still).
        fun put(kind: String, key: String, deleted: Int) =
            "UPDATE lan_log SET ts = $NOW, deleted = $deleted WHERE kind = '$kind' AND key = $key; " +
            "INSERT INTO lan_log(kind, key, ts, deleted) SELECT '$kind', $key, $NOW, $deleted WHERE NOT EXISTS (SELECT 1 FROM lan_log WHERE kind = '$kind' AND key = $key);"
        val tables = listOf(
            Triple("favorites", "fav", "%s.itemId || char(1) || %s.listId"),
            Triple("progress", "prog", "%s.itemId"),
            Triple("collections", "col", "%s.id"),
            Triple("collection_items", "colitem", "%s.collectionId || char(1) || %s.itemId"),
        )
        for ((table, kind, keyPattern) in tables) {
            fun key(row: String) = keyPattern.replace("%s", row)
            for (suffix in listOf("ai", "au", "ad")) db.execSQL("DROP TRIGGER IF EXISTS lan_${table}_$suffix")
            db.execSQL("CREATE TRIGGER IF NOT EXISTS lan_${table}_ai AFTER INSERT ON $table $on BEGIN ${put(kind, key("NEW"), 0)} END")
            db.execSQL("CREATE TRIGGER IF NOT EXISTS lan_${table}_au AFTER UPDATE ON $table $on BEGIN ${put(kind, key("OLD"), 1)} ${put(kind, key("NEW"), 0)} END")
            db.execSQL("CREATE TRIGGER IF NOT EXISTS lan_${table}_ad AFTER DELETE ON $table $on BEGIN ${put(kind, key("OLD"), 1)} END")
        }
    }
}
