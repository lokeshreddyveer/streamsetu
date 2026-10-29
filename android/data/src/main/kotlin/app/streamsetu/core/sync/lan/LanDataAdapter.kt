package app.streamsetu.core.sync.lan

import android.content.ContentValues
import androidx.sqlite.db.SupportSQLiteDatabase
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

/** Local item ids ("<source id>:mv:<provider id>") and the shape they take on the wire: the playlist's key, the kind, and the provider's own id. */
object LanIds {
    data class Item(val sourceId: String, val kind: String, val provider: String)
    private val pattern = Regex("^([0-9a-fA-F-]{36}):(mv|sr|ep|ch):(.+)$", RegexOption.DOT_MATCHES_ALL)
    private val tags = mapOf("movie" to "mv", "series" to "sr", "episode" to "ep", "channel" to "ch")

    fun parse(id: String): Item? = pattern.matchEntire(id)?.let { m -> Item(m.groupValues[1], tags.entries.first { it.value == m.groupValues[2] }.key, m.groupValues[3]) }
    fun local(sourceId: String, kind: String, provider: String): String? = tags[kind]?.let { "$sourceId:$it:$provider" }
}

/**
 * Reads favorites, Watch Later, collections and resume points from the database as records for another device, and applies the records that come back. Items are named by the
 * playlist's key (the same on every device that has that playlist), so a playlist this device does not have is ignored and its items are left alone.
 */
class LanDataAdapter(
    private val database: () -> SupportSQLiteDatabase, private val invalidate: () -> Unit = {},
    private val nowKey: String = "", private val deviceName: String = "", private val now: () -> Now? = { null }, private val board: (List<LanRecord>) -> Unit = {},
) : LanData {
    /** What this device is playing right now, for the other devices' "Now playing" strip. Null when nothing is, or when watching privately. */
    class Now(val itemId: String, val title: String, val positionMs: Long)

    /** The local item id for an item named by playlist key, kind and provider id (null when this device does not have that playlist). */
    fun localItemId(key: List<String>): String? = if (key.size < 3) null else local(sources(database()), key)

    private val lists = mapOf("favourites" to "favorites", "watch-later" to "later")
    private val localList = lists.entries.associate { it.value to it.key }

    private class Sources(val keyOf: Map<String, String>, val idOf: Map<String, String>)

    private fun sources(db: SupportSQLiteDatabase): Sources {
        val keyOf = HashMap<String, String>(); val idOf = LinkedHashMap<String, String>()
        db.query("SELECT id, address FROM sources WHERE draft = 0 AND address != '' ORDER BY enabled DESC, sortOrder").use { c ->
            while (c.moveToNext()) { val key = SourceKey.of(c.getString(1)); keyOf[c.getString(0)] = key; idOf.putIfAbsent(key, c.getString(0)) }
        }
        return Sources(keyOf, idOf)
    }

    private fun wire(src: Sources, localId: String): List<String>? = LanIds.parse(localId)?.let { item -> src.keyOf[item.sourceId]?.let { listOf(it, item.kind, item.provider) } }
    private fun local(src: Sources, key: List<String>): String? = src.idOf[key[0]]?.let { LanIds.local(it, key[1], key[2]) }

    override fun snapshot(): List<LanRecord> {
        val db = database(); val src = sources(db); val out = ArrayList<LanRecord>()
        // favorites and Watch Later
        db.query("SELECT f.itemId, f.listId, f.addedAt, l.ts, l.deleted FROM favorites f LEFT JOIN lan_log l ON l.kind = 'fav' AND l.key = f.itemId || char(1) || f.listId").use { c ->
            while (c.moveToNext()) {
                val list = lists[c.getString(1)] ?: continue; val key = wire(src, c.getString(0)) ?: continue
                val ts = if (!c.isNull(3) && c.getInt(4) == 0) c.getLong(3) else c.getLong(2)
                out += LanRecord("fav", key + list, ts, false, buildJsonObject { put("at", c.getLong(2)) })
            }
        }
        db.query("SELECT key, ts FROM lan_log WHERE kind = 'fav' AND deleted = 1").use { c ->
            while (c.moveToNext()) {
                val parts = c.getString(0).split('\u0001'); if (parts.size != 2) continue
                val list = lists[parts[1]] ?: continue; val key = wire(src, parts[0]) ?: continue
                out += LanRecord("fav", key + list, c.getLong(1), true)
            }
        }
        // resume points
        db.query("SELECT p.itemId, p.seriesId, p.positionMs, p.durationMs, p.updatedAt, p.completed, l.ts, l.deleted FROM progress p LEFT JOIN lan_log l ON l.kind = 'prog' AND l.key = p.itemId").use { c ->
            while (c.moveToNext()) {
                val key = wire(src, c.getString(0)) ?: continue
                val series = c.getString(1)?.let { LanIds.parse(it)?.provider }
                val ts = if (!c.isNull(6) && c.getInt(7) == 0) c.getLong(6) else c.getLong(4)
                out += LanRecord("prog", key, ts, false, buildJsonObject {
                    put("pos", c.getLong(2) / 1000.0); put("dur", c.getLong(3) / 1000.0); put("done", c.getInt(5) != 0); series?.let { put("series", it) }
                })
            }
        }
        db.query("SELECT key, ts FROM lan_log WHERE kind = 'prog' AND deleted = 1").use { c ->
            while (c.moveToNext()) { val key = wire(src, c.getString(0)) ?: continue; out += LanRecord("prog", key, c.getLong(1), true) }
        }
        // collections and what is in them
        db.query("SELECT c.id, c.name, c.scope, c.createdAt, l.ts, l.deleted FROM collections c LEFT JOIN lan_log l ON l.kind = 'col' AND l.key = c.id").use { c ->
            while (c.moveToNext()) {
                val ts = if (!c.isNull(4) && c.getInt(5) == 0) c.getLong(4) else c.getLong(3)
                out += LanRecord("col", listOf(c.getString(0)), ts, false, buildJsonObject { put("name", c.getString(1)); put("scope", c.getString(2).lowercase()) })
            }
        }
        db.query("SELECT key, ts FROM lan_log WHERE kind = 'col' AND deleted = 1").use { c ->
            while (c.moveToNext()) out += LanRecord("col", listOf(c.getString(0)), c.getLong(1), true)
        }
        db.query("SELECT i.collectionId, i.itemId, i.addedAt, l.ts, l.deleted FROM collection_items i LEFT JOIN lan_log l ON l.kind = 'colitem' AND l.key = i.collectionId || char(1) || i.itemId").use { c ->
            while (c.moveToNext()) {
                val key = wire(src, c.getString(1)) ?: continue
                val ts = if (!c.isNull(3) && c.getInt(4) == 0) c.getLong(3) else c.getLong(2)
                out += LanRecord("colitem", listOf(c.getString(0)) + key, ts, false, buildJsonObject { put("at", c.getLong(2)) })
            }
        }
        db.query("SELECT key, ts FROM lan_log WHERE kind = 'colitem' AND deleted = 1").use { c ->
            while (c.moveToNext()) {
                val parts = c.getString(0).split('\u0001'); if (parts.size != 2) continue
                val key = wire(src, parts[1]) ?: continue
                out += LanRecord("colitem", listOf(parts[0]) + key, c.getLong(1), true)
            }
        }
        if (nowKey.isNotEmpty()) {
            val playing = now(); val stamp = System.currentTimeMillis()
            val key = playing?.let { wire(src, it.itemId) }
            out += if (playing != null && key != null) LanRecord("now", listOf(nowKey), stamp, false, buildJsonObject {
                put("title", playing.title); put("pos", playing.positionMs / 1000.0); put("dev", deviceName); put("src", key[0]); put("kind", key[1]); put("prov", key[2])
            }) else LanRecord("now", listOf(nowKey), stamp, true)
        }
        return out
    }

    override fun apply(all: List<LanRecord>): Int {
        val nowRecords = all.filter { it.kind == "now" && it.key.firstOrNull() != nowKey }
        if (nowRecords.isNotEmpty()) board(nowRecords)
        val records = all.filter { it.kind != "now" }
        val db = database(); val src = sources(db); var applied = 0
        // a collection before the things in it, and a removal after an addition of the same thing
        val order = mapOf("col" to 0, "fav" to 1, "prog" to 1, "colitem" to 2)
        val sorted = records.sortedWith(compareBy({ order[it.kind] ?: 9 }, { if (it.deleted) 1 else 0 }))
        db.beginTransaction()
        try {
            db.execSQL("UPDATE lan_flag SET applying = 1")
            for (r in sorted) if (applyOne(db, src, r)) applied++
            db.setTransactionSuccessful()
        } finally {
            runCatching { db.endTransaction() }
            runCatching { db.execSQL("UPDATE lan_flag SET applying = 0") }
        }
        if (applied > 0) invalidate()
        return applied
    }

    /** The time of the last change to this thing here: from the log, or failing that from the row itself. Null when it is not here at all. */
    private fun localTs(db: SupportSQLiteDatabase, kind: String, logKey: String, naturalSql: String, args: Array<Any>): Long? {
        val logged = db.query("SELECT ts FROM lan_log WHERE kind = ? AND key = ?", arrayOf(kind, logKey)).use { c -> if (c.moveToFirst()) c.getLong(0) else null }
        if (logged != null) return logged
        return db.query(naturalSql, args).use { c -> if (c.moveToFirst()) c.getLong(0) else null }
    }

    private fun log(db: SupportSQLiteDatabase, kind: String, key: String, ts: Long, deleted: Boolean) {
        db.execSQL("INSERT OR REPLACE INTO lan_log(kind, key, ts, deleted) VALUES(?, ?, ?, ?)", arrayOf(kind, key, ts, if (deleted) 1 else 0))
    }

    private fun applyOne(db: SupportSQLiteDatabase, src: Sources, r: LanRecord): Boolean {
        val v: JsonObject? = r.value
        when (r.kind) {
            "fav" -> {
                if (r.key.size != 4) return false
                val itemId = local(src, r.key) ?: return false; val list = localList[r.key[3]] ?: return false
                val logKey = itemId + "\u0001" + list
                if (!shouldApply(localTs(db, "fav", logKey, "SELECT addedAt FROM favorites WHERE itemId = ? AND listId = ?", arrayOf(itemId, list)), r.ts)) return false
                if (r.deleted) db.execSQL("DELETE FROM favorites WHERE itemId = ? AND listId = ?", arrayOf(itemId, list))
                else db.execSQL("INSERT OR REPLACE INTO favorites(itemId, kind, listId, addedAt) VALUES(?, ?, ?, ?)", arrayOf(itemId, r.key[1].uppercase(), list, v?.get("at")?.jsonPrimitive?.longOrNull ?: r.ts))
                log(db, "fav", logKey, r.ts, r.deleted); return true
            }
            "prog" -> {
                if (r.key.size != 3) return false
                val itemId = local(src, r.key) ?: return false
                if (!shouldApply(localTs(db, "prog", itemId, "SELECT updatedAt FROM progress WHERE itemId = ?", arrayOf(itemId)), r.ts)) return false
                if (r.deleted) db.execSQL("DELETE FROM progress WHERE itemId = ?", arrayOf(itemId))
                else {
                    val seriesId = v?.get("series")?.jsonPrimitive?.contentOrNull?.let { src.idOf[r.key[0]]?.let { s -> LanIds.local(s, "series", it) } }
                    val pos = ((v?.get("pos")?.jsonPrimitive?.doubleOrNull ?: 0.0) * 1000).toLong(); val dur = ((v?.get("dur")?.jsonPrimitive?.doubleOrNull ?: 0.0) * 1000).toLong()
                    db.execSQL("INSERT OR REPLACE INTO progress(itemId, kind, seriesId, positionMs, durationMs, updatedAt, completed) VALUES(?, ?, ?, ?, ?, ?, ?)",
                        arrayOf<Any?>(itemId, r.key[1].uppercase(), seriesId, pos, dur, r.ts, if (v?.get("done")?.jsonPrimitive?.booleanOrNull == true) 1 else 0))
                }
                log(db, "prog", itemId, r.ts, r.deleted); return true
            }
            "col" -> {
                if (r.key.size != 1) return false
                val id = r.key[0]
                if (!shouldApply(localTs(db, "col", id, "SELECT createdAt FROM collections WHERE id = ?", arrayOf(id)), r.ts)) return false
                if (r.deleted) { db.execSQL("DELETE FROM collections WHERE id = ?", arrayOf(id)); db.execSQL("DELETE FROM collection_items WHERE collectionId = ?", arrayOf(id)) }
                else {
                    val name = v?.get("name")?.jsonPrimitive?.contentOrNull ?: "Collection"; val scope = (v?.get("scope")?.jsonPrimitive?.contentOrNull ?: "movie").uppercase()
                    // update, then insert when it was not there (no upsert: that needs SQLite 3.24, newer than the oldest supported Android and Fire OS have)
                    db.execSQL("UPDATE collections SET name = ?, scope = ? WHERE id = ?", arrayOf(name, scope, id))
                    db.execSQL("INSERT OR IGNORE INTO collections(id, name, scope, createdAt) VALUES(?, ?, ?, ?)", arrayOf(id, name, scope, r.ts))
                }
                log(db, "col", id, r.ts, r.deleted); return true
            }
            "colitem" -> {
                if (r.key.size != 4) return false
                val collection = r.key[0]; val itemId = local(src, r.key.drop(1)) ?: return false
                val logKey = collection + "\u0001" + itemId
                if (!shouldApply(localTs(db, "colitem", logKey, "SELECT addedAt FROM collection_items WHERE collectionId = ? AND itemId = ?", arrayOf(collection, itemId)), r.ts)) return false
                if (r.deleted) db.execSQL("DELETE FROM collection_items WHERE collectionId = ? AND itemId = ?", arrayOf(collection, itemId))
                else {
                    // the collection may not have arrived yet: keep a placeholder, its own record names it later
                    db.execSQL("INSERT OR IGNORE INTO collections(id, name, scope, createdAt) VALUES(?, 'Collection', ?, ?)", arrayOf(collection, r.key[2].uppercase(), r.ts))
                    db.execSQL("INSERT OR REPLACE INTO collection_items(collectionId, itemId, addedAt) VALUES(?, ?, ?)", arrayOf(collection, itemId, v?.get("at")?.jsonPrimitive?.longOrNull ?: r.ts))
                }
                log(db, "colitem", logKey, r.ts, r.deleted); return true
            }
        }
        return false
    }
}
