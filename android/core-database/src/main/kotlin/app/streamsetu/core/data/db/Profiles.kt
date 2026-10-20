package app.streamsetu.core.data.db

import androidx.sqlite.db.SupportSQLiteDatabase
import java.security.MessageDigest

class Profile(val id: String, val name: String, val kids: Boolean, val hasPin: Boolean, val color: Int)

/**
 * Profiles: people who share one device and one playlist, each with their own favorites, collections, watch history and resume points.
 *
 * The live tables always hold the active profile's rows, so nothing else in the app has to know about profiles. Switching saves the active profile's rows into `profile_rows` and
 * loads the other's, in one transaction, with the change log paused so the move is not mistaken for the person deleting everything. Sync on this network carries the first
 * profile only, so it is paused while another profile is active.
 */
object Profiles {
    const val MAIN = "main"
    /** Everyone who shares a device: the first profile and up to three more. */
    const val MAX = 4
    /** The tables that hold one person's own data. Collections come before their items. */
    val personalTables = listOf("favorites", "collections", "collection_items", "progress", "watch_log", "watch_time", "new_episodes")

    fun create(db: SupportSQLiteDatabase) {
        db.execSQL("CREATE TABLE IF NOT EXISTS profiles(id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, kids INTEGER NOT NULL DEFAULT 0, pin_salt TEXT, pin_hash TEXT, color INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS profile_state(active TEXT NOT NULL)")
        db.execSQL("INSERT INTO profile_state(active) SELECT '$MAIN' WHERE NOT EXISTS (SELECT 1 FROM profile_state)")
        db.execSQL("INSERT OR IGNORE INTO profiles(id, name, kids, color, sort_order, created_at) VALUES('$MAIN', 'Me', 0, 0, 0, 0)")
    }

    fun hash(pin: String, salt: String): String = MessageDigest.getInstance("SHA-256").digest((salt + pin).toByteArray()).joinToString("") { "%02x".format(it) }
    /** Four digits, so the remote's number pad can enter it. */
    fun validPin(pin: String) = pin.length == 4 && pin.all { it in '0'..'9' }

    fun list(db: SupportSQLiteDatabase): List<Profile> = db.query("SELECT id, name, kids, pin_hash IS NOT NULL, color FROM profiles ORDER BY sort_order, created_at").use { c ->
        buildList { while (c.moveToNext()) add(Profile(c.getString(0), c.getString(1), c.getInt(2) != 0, c.getInt(3) != 0, c.getInt(4))) }
    }

    fun active(db: SupportSQLiteDatabase): String = db.query("SELECT active FROM profile_state").use { if (it.moveToFirst()) it.getString(0) else MAIN }

    /** Adds a profile; a kids profile must have a PIN, which is asked when leaving it. Returns null when the name is taken, empty, or the PIN is not four digits. */
    fun add(db: SupportSQLiteDatabase, name: String, kids: Boolean, pin: String?): Profile? {
        val clean = name.trim()
        val all = list(db)
        if (clean.isEmpty() || all.size >= MAX || all.any { it.name.equals(clean, ignoreCase = true) }) return null
        if (kids && (pin == null || !validPin(pin))) return null
        if (pin != null && !validPin(pin)) return null
        val id = java.util.UUID.randomUUID().toString()
        val salt = java.util.UUID.randomUUID().toString()
        db.execSQL("INSERT INTO profiles(id, name, kids, pin_salt, pin_hash, color, sort_order, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
            arrayOf(id, clean, if (kids) 1 else 0, if (pin == null) null else salt, pin?.let { hash(it, salt) }, all.size % 6, all.size, System.currentTimeMillis()))
        return list(db).first { it.id == id }
    }

    fun rename(db: SupportSQLiteDatabase, id: String, name: String) {
        val clean = name.trim()
        if (clean.isEmpty() || list(db).any { it.id != id && it.name.equals(clean, ignoreCase = true) }) return
        db.execSQL("UPDATE profiles SET name = ? WHERE id = ?", arrayOf(clean, id))
    }

    /** Removes a profile and everything it kept. The main profile and the one in use cannot be removed. */
    fun remove(db: SupportSQLiteDatabase, id: String): Boolean {
        if (id == MAIN || id == active(db)) return false
        db.beginTransaction()
        try {
            for (t in personalTables) if (db.query("SELECT 1 FROM sqlite_master WHERE name = 'pf_$t'").use { it.moveToFirst() }) db.execSQL("DELETE FROM pf_$t WHERE profile_id = ?", arrayOf(id))
            db.execSQL("DELETE FROM profiles WHERE id = ?", arrayOf(id)); db.setTransactionSuccessful()
        } finally { db.endTransaction() }
        return true
    }

    fun checkPin(db: SupportSQLiteDatabase, id: String, pin: String): Boolean =
        db.query("SELECT pin_salt, pin_hash FROM profiles WHERE id = ?", arrayOf(id)).use { c -> c.moveToFirst() && !c.isNull(1) && hash(pin, c.getString(0)) == c.getString(1) }

    private class Col(val name: String, val type: String)

    private fun columns(db: SupportSQLiteDatabase, table: String): List<Col> =
        db.query("PRAGMA table_info($table)").use { c -> buildList { while (c.moveToNext()) add(Col(c.getString(1), c.getString(2))) } }.filter { !(table == "watch_log" && it.name == "id") }

    /** Each table has a twin, `pf_<table>`, with the same columns plus the profile they belong to (older Android has no JSON functions, so rows are kept as rows). */
    private fun ensureTwin(db: SupportSQLiteDatabase, table: String, cols: List<Col>) {
        db.execSQL("CREATE TABLE IF NOT EXISTS pf_$table(profile_id TEXT NOT NULL)")
        val have = db.query("PRAGMA table_info(pf_$table)").use { c -> buildList { while (c.moveToNext()) add(c.getString(1)) } }
        for (c in cols) if (c.name !in have) db.execSQL("ALTER TABLE pf_$table ADD COLUMN \"${c.name}\" ${c.type}")
    }

    /** Saves the rows of profile [from] and loads those of [to], in one transaction. */
    fun swap(db: SupportSQLiteDatabase, from: String, to: String) {
        db.beginTransaction()
        try {
            db.execSQL("UPDATE lan_flag SET applying = 1")
            for (t in personalTables) {
                val cols = columns(db, t); ensureTwin(db, t, cols)
                val names = cols.joinToString(", ") { "\"${it.name}\"" }
                db.execSQL("DELETE FROM pf_$t WHERE profile_id = ?", arrayOf(from))
                db.execSQL("INSERT INTO pf_$t(profile_id, $names) SELECT ?, $names FROM $t", arrayOf(from))
            }
            for (t in personalTables.reversed()) db.execSQL("DELETE FROM $t")
            for (t in personalTables) {
                val names = columns(db, t).joinToString(", ") { "\"${it.name}\"" }
                db.execSQL("INSERT OR IGNORE INTO $t($names) SELECT $names FROM pf_$t WHERE profile_id = ?", arrayOf(to))
                db.execSQL("DELETE FROM pf_$t WHERE profile_id = ?", arrayOf(to))
            }
            db.execSQL("UPDATE profile_state SET active = ?", arrayOf(to))
            db.execSQL("UPDATE lan_flag SET applying = 0")
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }
}
