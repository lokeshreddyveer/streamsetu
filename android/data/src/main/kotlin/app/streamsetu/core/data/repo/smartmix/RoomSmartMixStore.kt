package app.streamsetu.core.data.repo.smartmix

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.smartmix.ShelfState
import app.streamsetu.core.data.smartmix.ShownRow
import app.streamsetu.core.data.smartmix.SmartMixStore

/**
 * The persisted Smart Mix state (`smartmix_state`, `smartmix_shown`), keyed by profile and shelf and bounded: [MAX_SHELVES] shelves of [MAX_ROWS] titles for each profile, nothing else.
 * It holds identities and ids only (never a title or an address). Blocking calls, for the service's background dispatcher.
 */
class RoomSmartMixStore(private val db: AppDatabase) : SmartMixStore {
    companion object { const val MAX_ROWS = 48; const val MAX_SHELVES = 64 }
    private val raw get() = db.openHelper.writableDatabase

    override fun state(profileId: String, shelfId: String): ShelfState =
        raw.query("SELECT refreshCounter, loadKey, loadSeq FROM smartmix_state WHERE profileId = ? AND shelfId = ?", arrayOf(profileId, shelfId)).use { c ->
            if (c.moveToFirst()) ShelfState(c.getInt(0), c.getString(1), c.getInt(2)) else ShelfState()
        }

    override fun saveState(profileId: String, shelfId: String, state: ShelfState) {
        raw.execSQL("INSERT OR REPLACE INTO smartmix_state(profileId, shelfId, refreshCounter, loadKey, loadSeq) VALUES(?, ?, ?, ?, ?)", arrayOf(profileId, shelfId, state.refreshCounter, state.loadKey, state.loadSeq))
        // A bound on the shelves too (folder rows come and go): the least recently written beyond the limit are dropped.
        raw.execSQL("DELETE FROM smartmix_state WHERE profileId = ? AND rowid NOT IN (SELECT rowid FROM smartmix_state WHERE profileId = ? ORDER BY loadSeq DESC, rowid DESC LIMIT $MAX_SHELVES)", arrayOf(profileId, profileId))
    }

    override fun shown(profileId: String, shelfId: String): List<ShownRow> =
        raw.query("SELECT identityKey, year, itemId, loadSeq FROM smartmix_shown WHERE profileId = ? AND shelfId = ? ORDER BY loadSeq DESC", arrayOf(profileId, shelfId)).use { c ->
            buildList { while (c.moveToNext()) add(ShownRow(c.getString(0), if (c.isNull(1)) null else c.getInt(1), c.getString(2), c.getInt(3))) }
        }

    override fun replaceShown(profileId: String, shelfId: String, rows: List<ShownRow>) {
        raw.beginTransaction()
        try {
            raw.execSQL("DELETE FROM smartmix_shown WHERE profileId = ? AND shelfId = ?", arrayOf(profileId, shelfId))
            val now = System.currentTimeMillis()
            for (r in rows.take(MAX_ROWS)) raw.execSQL("INSERT OR REPLACE INTO smartmix_shown(profileId, shelfId, identityKey, year, itemId, loadSeq, shownAt) VALUES(?, ?, ?, ?, ?, ?, ?)", arrayOf<Any?>(profileId, shelfId, r.identityKey, r.year, r.itemId, r.loadSeq, now))
            raw.setTransactionSuccessful()
        } finally { raw.endTransaction() }
    }

    override fun clearProfile(profileId: String) {
        raw.execSQL("DELETE FROM smartmix_state WHERE profileId = ?", arrayOf(profileId))
        raw.execSQL("DELETE FROM smartmix_shown WHERE profileId = ?", arrayOf(profileId))
    }
}
