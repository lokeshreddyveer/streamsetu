package app.streamsetu.tv

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.repo.*
import app.streamsetu.core.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.Random

/**
 * The whole-library "A to Z" and "newest year" pages before (OFFSET, sorted) and after (index, from where the last page ended), on synthetic libraries of 66,540 and 200,000 movies in two playlists
 * with locked folders. Runs only when BROWSE_BENCH=1. JVM and Robolectric SQLite on the development Mac: ratios carry over to a TV stick, the milliseconds do not.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class BrowseBenchmark {
    private val ctx get() = ApplicationProvider.getApplicationContext<Context>()

    private fun median(n: Int, f: () -> Unit): Double { val t = (0 until n).map { val s = System.nanoTime(); f(); (System.nanoTime() - s) / 1e6 }.sorted(); return t[n / 2] }

    private fun measure(movies: Int) = runBlocking {
        val db = Room.inMemoryDatabaseBuilder(ctx, AppDatabase::class.java).allowMainThreadQueries().build()
        val raw = db.openHelper.writableDatabase
        raw.execSQL("INSERT INTO sources (id, name, type, address, enabled, lastSyncAt, status, sortOrder, draft, channelCount, movieCount, seriesCount, lastOpenedAt) VALUES ('A','A','XTREAM','x',1,1,'OK',0,0,0,0,0,0), ('B','B','XTREAM','x',1,1,'OK',1,0,0,0,0,0)")
        val rnd = Random(9)
        val words = listOf("Midnight", "River", "Crimson", "Silent", "Garden", "Iron", "Paper", "Echo", "Winter", "Golden", "Hollow", "Lantern", "Harbor", "Velvet", "Cinder", "Meadow")
        raw.beginTransaction()
        val st = raw.compileStatement("INSERT INTO movies (id, sourceId, categoryId, title, posterUrl, year, rating, plot, streamRef, addedAt) VALUES (?,?,?,?,?,?,?,?,?,?)")
        for (i in 0 until movies) { st.clearBindings(); st.bindString(1, "m%07d".format(i)); st.bindString(2, if (i % 2 == 0) "A" else "B"); st.bindString(3, "c${rnd.nextInt(600)}"); st.bindString(4, "${words[rnd.nextInt(16)]} ${words[rnd.nextInt(16)]} ${rnd.nextInt(900)}"); if (rnd.nextInt(10) > 0) st.bindLong(6, 1985L + rnd.nextInt(41)); st.bindString(9, "r$i"); st.bindLong(10, i.toLong()); st.executeInsert() }
        raw.setTransactionSuccessful(); raw.endTransaction()
        val library = LibraryRepository(db, ctx, CoroutineScope(Dispatchers.Unconfined + SupervisorJob()))
        val browse = BrowseRepository(db, library, FolderRepository(db, library, ParentalControls(ctx), CoroutineScope(Dispatchers.Unconfined + SupervisorJob())), ctx)
        val locked = (0 until 5).map { "c$it" }.toSet(); val srcs = listOf("A", "B")
        fun page(sort: SortSpec, off: Int, after: PageAfter? = null) = runBlocking { browse.moviesPage(Browse.All, sort, 90, off, srcs, locked, after) }
        val name = SortSpec(SortField.NAME); val year = SortSpec(SortField.YEAR)
        val deep = movies * 9 / 10
        // BEFORE: the titleSort column is empty, so every page is read the old way (sort all rows, OFFSET).
        val before = listOf("NAME first page" to median(5) { page(name, 0) }, "NAME deep page (offset $deep)" to median(5) { page(name, deep) }, "YEAR first page" to median(5) { page(year, 0) }, "YEAR deep page (offset $deep)" to median(5) { page(year, deep) })
        // AFTER: the lower-case copy and the indexes (what the 11 to 12 step and the triggers make).
        AppDatabase.MIGRATION_11_12.let { raw.execSQL("UPDATE movies SET titleSort = lower(title)"); raw.execSQL("CREATE INDEX IF NOT EXISTS index_movies_titleSort_id ON movies (titleSort, id)"); raw.execSQL("CREATE INDEX IF NOT EXISTS index_movies_year_id ON movies (year DESC, id ASC)") }
        raw.execSQL("ANALYZE")
        val nameDeep = page(name, 0).let { var a: PageAfter? = null; var last: List<Movie> = emptyList(); var n = 0; while (n < deep) { last = page(name, 0, a); a = last.last().let { PageAfter(it.id, it.title, it.year) }; n += 90 * 40; if (n > deep) break; a = a }; a }
        val after = listOf("NAME first page" to median(5) { page(name, 0) }, "NAME deep page (keyset)" to median(5) { page(name, 0, nameDeep) }, "YEAR first page" to median(5) { page(year, 0) }, "YEAR deep page (keyset)" to median(5) { page(year, 0, PageAfter("m0100001", "x", 1990)) })
        println("BENCH browse $movies movies: before " + before.joinToString("; ") { "${it.first} %.1f ms".format(it.second) } + " | after " + after.joinToString("; ") { "${it.first} %.1f ms".format(it.second) })
        db.close()
    }

    @Test fun pages() {
        assumeTrue("set BROWSE_BENCH=1", System.getenv("BROWSE_BENCH") == "1")
        measure(66_540); measure(200_000)
    }
}
