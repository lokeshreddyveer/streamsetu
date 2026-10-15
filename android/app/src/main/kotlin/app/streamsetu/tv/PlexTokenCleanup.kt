package app.streamsetu.tv

import androidx.sqlite.db.SupportSQLiteDatabase

/** Plex pictures used to be saved with the access token in their address. This removes it from what an earlier version stored; addresses without it are not touched. */
object PlexTokenCleanup {
    private val columns = listOf("movies" to "posterUrl", "series" to "posterUrl", "series" to "backdropUrl", "episodes" to "imageUrl")

    fun run(db: SupportSQLiteDatabase) {
        for ((table, column) in columns)
            db.execSQL("UPDATE $table SET $column = substr($column, 1, instr($column, '?X-Plex-Token=') - 1) WHERE $column LIKE '%?X-Plex-Token=%'")
    }
}
