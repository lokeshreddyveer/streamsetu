package app.streamsetu.tv

import android.content.Context
import androidx.room.Room
import androidx.room.testing.MigrationTestHelper
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.streamsetu.core.data.db.*
import app.streamsetu.core.data.repo.*
import app.streamsetu.core.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.Random

/** "A to Z" and "newest year" over the whole library read from an index, page by page from where the last one ended; the 11 to 12 step that makes the indexes. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class)
class BrowseIndexTests {
    @get:Rule val helper = MigrationTestHelper(InstrumentationRegistry.getInstrumentation(), AppDatabase::class.java)
    private val ctx get() = ApplicationProvider.getApplicationContext<Context>()
    private val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
    private lateinit var db: AppDatabase
    private lateinit var browse: BrowseRepository

    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ctx, AppDatabase::class.java).allowMainThreadQueries().build()
        AppDatabase.ensureSortTriggers(db.openHelper.writableDatabase)
        val library = LibraryRepository(db, ctx, scope)
        browse = BrowseRepository(db, library, FolderRepository(db, library, ParentalControls(ctx), scope), ctx)
    }
    @After fun close() { scope.cancel(); db.close() }

    private val words = listOf("alpha", "Bravo", "CHARLIE", "delta", "Echo", "foxtrot", "Golf", "hotel", "India", "Juliet")
    private fun fill(n: Int) = runBlocking {
        val rnd = Random(3)
        for (id in listOf("A", "B")) db.sources().upsert(SourceEntity(id, "Playlist $id", "M3U", "http://x/$id", null, null, true, 1, "OK"))
        db.catalog().putMovies((0 until n).map { i -> MovieEntity("m%04d".format(i), if (i % 5 == 0) "B" else "A", if (i % 7 == 0) "locked" else "open", "${words[rnd.nextInt(words.size)]} ${words[rnd.nextInt(words.size)]} ${rnd.nextInt(30)}", null, if (rnd.nextInt(6) == 0) null else 1990 + rnd.nextInt(30), null, null, "r", i.toLong()) })
    }
    private fun lower(s: String) = s.map { if (it in 'A'..'Z') it + 32 else it }.joinToString("")
    private fun pages(sort: SortSpec, size: Int, restricted: Set<String>, sources: List<String>): List<Movie> {
        val out = ArrayList<Movie>(); var after: PageAfter? = null
        while (true) { val p = runBlocking { browse.moviesPage(Browse.All, sort, size, out.size, sources, restricted, after) }; if (p.isEmpty()) break; out += p; after = p.last().let { PageAfter(it.id, it.title, it.year) }; if (p.size < size) break }
        return out
    }
    private val allowed = { m: Movie -> m.sourceId == "A" && m.categoryId != "locked" }

    @Test fun nameOrderPagedFromWhereTheLastPageEndedIsTheWholeListInOrderWithEveryRestrictionApplied() {
        fill(900)
        val expected = runBlocking { db.openHelper.readableDatabase.query("SELECT id, title, sourceId, categoryId FROM movies").use { c -> buildList { while (c.moveToNext()) add(listOf(c.getString(0), c.getString(1), c.getString(2), c.getString(3))) } } }
            .filter { it[2] == "A" && it[3] != "locked" }.sortedWith(compareBy({ lower(it[1]) }, { it[0] })).map { it[0] }
        val got = pages(SortSpec(SortField.NAME), 50, setOf("locked"), listOf("A")).map { it.id }
        assertEquals(expected, got)
        assertEquals("the same list by offset (the old way) is the same list", expected, (0 until expected.size step 70).flatMap { off -> runBlocking { browse.moviesPage(Browse.All, SortSpec(SortField.NAME, ascending = false).copy(ascending = true), 70, off, listOf("A"), setOf("locked")).map { it.id } } })
    }

    @Test fun newestYearFirstPagedThroughTheTitlesWithNoYearToo() {
        fill(900)
        val expected = runBlocking { db.openHelper.readableDatabase.query("SELECT id, year, sourceId, categoryId FROM movies").use { c -> buildList { while (c.moveToNext()) add(Triple(c.getString(0), if (c.isNull(1)) null else c.getInt(1), c.getString(2) to c.getString(3))) } } }
            .filter { it.third.first == "A" && it.third.second != "locked" }.sortedWith(compareBy<Triple<String, Int?, Pair<String, String>>>({ it.second == null }, { -(it.second ?: 0) }, { it.first })).map { it.first }
        for (size in listOf(37, 90, 500)) assertEquals("page size $size", expected, pages(SortSpec(SortField.YEAR), size, setOf("locked"), listOf("A")).map { it.id })
    }

    @Test fun theIndexIsUsedAndNothingIsSorted() {
        fill(300)
        val raw = db.openHelper.readableDatabase
        fun plan(sql: String) = raw.query("EXPLAIN QUERY PLAN $sql").use { c -> buildString { while (c.moveToNext()) append(c.getString(3)).append(" | ") } }
        val name = plan("SELECT x.* FROM movies x INDEXED BY index_movies_titleSort_id WHERE x.sourceId IN ('A') AND x.titleSort >= 'c' AND (x.titleSort > 'c' OR x.id > 'm1') ORDER BY x.titleSort ASC, x.id ASC LIMIT 90")
        assertTrue(name, "index_movies_titleSort_id" in name && "TEMP B-TREE" !in name)
        val year = plan("SELECT x.* FROM movies x INDEXED BY index_movies_year_id WHERE x.sourceId IN ('A') ORDER BY x.year DESC, x.id ASC LIMIT 90")
        assertTrue(year, "index_movies_year_id" in year && "TEMP B-TREE" !in year)
    }

    @Test fun aDatabaseWhoseRowsLackTheLowerCaseTitleIsReadTheOldWayAndStaysCorrect() {
        fill(120)
        db.openHelper.writableDatabase.execSQL("UPDATE movies SET titleSort = '' WHERE id = 'm0001'")          // as a database made without the triggers would have it
        val a = pages(SortSpec(SortField.NAME), 40, setOf("locked"), listOf("A")).map { it.id }
        val expected = runBlocking { browse.moviesPage(Browse.All, SortSpec(SortField.NAME), 1000, 0, listOf("A"), setOf("locked")).map { it.id } }
        assertEquals(expected, a)
    }

    @Test fun versionElevenBecomesTwelveWithTheCopyTheIndexesAndTheTriggers() {
        helper.createDatabase("up", 11).apply {
            execSQL("INSERT INTO movies (id, sourceId, categoryId, title, streamRef, addedAt, year) VALUES ('m1','s','c','Zed Film','r',1,2001), ('m2','s','c','alpha Film','r',2,NULL)")
            execSQL("INSERT INTO series (id, sourceId, categoryId, title, providerId, addedAt) VALUES ('s1','s','c','Some SHOW','p',1)")
            close()
        }
        val d = helper.runMigrationsAndValidate("up", 12, true, *AppDatabase.MIGRATIONS)
        fun one(sql: String) = d.query(sql).use { it.moveToFirst(); it.getString(0) }
        assertEquals("zed film", one("SELECT titleSort FROM movies WHERE id = 'm1'")); assertEquals("alpha film", one("SELECT titleSort FROM movies WHERE id = 'm2'")); assertEquals("some show", one("SELECT titleSort FROM series WHERE id = 's1'"))
        for (i in listOf("index_movies_titleSort_id", "index_movies_year_id", "index_series_titleSort_id", "index_series_year_id")) assertEquals(i, "1", one("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = '$i'"))
        // the copy stays right for new rows, replaced rows and renamed rows, with no help from the app
        d.execSQL("INSERT OR REPLACE INTO movies (id, sourceId, categoryId, title, streamRef, addedAt) VALUES ('m3','s','c','NEW Film','r',3), ('m1','s','c','Replaced FILM','r',1)")
        assertEquals("new film", one("SELECT titleSort FROM movies WHERE id = 'm3'")); assertEquals("replaced film", one("SELECT titleSort FROM movies WHERE id = 'm1'"))
        d.execSQL("UPDATE movies SET title = 'Renamed' WHERE id = 'm2'"); assertEquals("renamed", one("SELECT titleSort FROM movies WHERE id = 'm2'"))
        d.close()
    }
}
