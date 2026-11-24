package app.streamsetu.tv

import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.*
import app.streamsetu.core.data.repo.smartmix.IdentityStore
import app.streamsetu.core.model.SortKey
import app.streamsetu.core.sync.CatalogStore
import app.streamsetu.core.sync.SyncProgress
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The speed work of a big first read, on a real (in-memory) database: the sort key is written with the row and is byte-for-byte what the database trigger makes, a read reports honest progress, and a first read
 * leaves the identity rows to the background fill. Synthetic titles only.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class ImportSpeedTests {
    private lateinit var db: AppDatabase
    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), AppDatabase::class.java).allowMainThreadQueries()
            .addCallback(object : androidx.room.RoomDatabase.Callback() {
                override fun onCreate(db: SupportSQLiteDatabase) { SearchIndex.create(db); PeopleIndex.create(db); LanLog.create(db); Profiles.create(db); AppDatabase.ensureSortTriggers(db) }
            }).build()
        runBlocking { db.sources().upsert(SourceEntity("A", "Playlist A", "XTREAM", "http://x/a", null, null, true, 1_000L, "OK", sortOrder = 0)) }
    }
    @After fun close() = db.close()

    private val raw get() = db.openHelper.writableDatabase
    private fun scalar(sql: String) = raw.query(sql).use { it.moveToFirst(); it.getString(0) }
    private fun cats() = listOf(CategoryEntity("A-c1", "A", "MOVIE", "ENGLISH | MOVIES", 0), CategoryEntity("A-s1", "A", "SERIES", "ENGLISH | SERIES", 0), CategoryEntity("A-l1", "A", "CHANNEL", "News", 0))
    private fun movie(i: Int, title: String = "Title $i (${2000 + i % 24})") = MovieEntity("A:m$i", "A", "A-c1", title, "http://img/$i", 2000 + i % 24, null, null, "movie:$i:mp4", 1_000L + i)
    private fun show(i: Int, title: String = "Show $i") = SeriesEntity("A:s$i", "A", "A-s1", title, null, null, 2010 + i % 10, null, null, "p$i", 500L + i)
    private fun chan(i: Int) = ChannelEntity("A:c$i", "A", "A-l1", "Channel $i", i, null, "live:$i:m3u8", null, 0, i)

    private val titles = listOf(
        "The Matrix", "THE MATRIX RELOADED", "A Quiet Place: Part II", "Émile", "Ørsted", "Ünal", "Straße", "Ålesund", "Œuvre", "Æon Flux", "Çiçek", "Łódź", "Ñandú", "ÀÉÎÕÜ ÿ", "Škoda", "Žižek", "Ħal", "ĳ ǅ İstanbul ı",
        "2001: A Space Odyssey", "007 - No Time To Die", "x-men", "Spider-Man: No Way Home (2021)", "Mr. & Mrs. Smith", "It's a Wonderful Life", "Ocean's 11", "100% Wolf", "  leading spaces", "tab\tand\nnewline", "'quoted'", "\"double\"",
        "తెలుగు సినిమా", "हिन्दी फ़िल्म", "العربية", "日本語のタイトル", "한국어 제목", "Русский Фильм", "Ελληνικά", "emoji 🎬 title", "ÉÉÉÉÉÉÉÉÉÉÉÉÉÉÉÉÉÉÉÉ", "", "a",
    )

    /** The titles whose key can be compared on this host: when its SQLite lower() also changes letters outside A to Z (the device's does not), a letter the key table does not fold ("\u01C5", "\u0130", Cyrillic, Greek) would come out differently, so such titles are left out. */
    private val comparableTitles: List<String> by lazy {
        if (scalar("SELECT lower('\u0416')") == "\u0416") titles
        else titles.filter { t -> t.none { it.code > 127 && SortKey.table[it] == null && it.lowercaseChar() != it } }
    }

    @Test fun theKotlinKeyIsTheKeyTheTriggerMakes() {
        // On the device SQLite's lower() changes only A to Z (see SortKey). If this test host's SQLite lower-cases other scripts too, the cased non-Latin titles cannot be compared here and are left out.
        val titles = comparableTitles
        titles.forEachIndexed { i, t ->
            raw.execSQL("INSERT INTO movies (id, sourceId, categoryId, title, streamRef, addedAt) VALUES (?, 'A', NULL, ?, 'r', 1)", arrayOf("m$i", t))          // no key given: the trigger makes it
            raw.execSQL("INSERT INTO series (id, sourceId, categoryId, title, providerId, addedAt) VALUES (?, 'A', NULL, ?, 'p', 1)", arrayOf("s$i", t))
        }
        titles.forEachIndexed { i, t ->
            assertEquals("movie \"$t\"", SortKey.of(t), scalar("SELECT titleSort FROM movies WHERE id = 'm$i'"))
            assertEquals("series \"$t\"", SortKey.of(t), scalar("SELECT titleSort FROM series WHERE id = 's$i'"))
        }
        raw.execSQL("UPDATE movies SET title = 'Zorro Ünal' WHERE id = 'm0'")          // a changed title is still kept right by the update trigger
        assertEquals(SortKey.of("Zorro Ünal"), scalar("SELECT titleSort FROM movies WHERE id = 'm0'"))
    }

    @Test fun aKeyWrittenWithTheRowIsKeptAndTheInsertTriggerHasNothingToDo() {
        runBlocking { db.catalog().putMovies(listOf(movie(1).copy(titleSort = "kept as given"), movie(2).copy(title = "Émile", titleSort = ""))) }
        assertEquals("kept as given", scalar("SELECT titleSort FROM movies WHERE id = 'A:m1'"))          // the trigger did not run (it would have overwritten the key)
        assertEquals("emile", scalar("SELECT titleSort FROM movies WHERE id = 'A:m2'"))                    // no key given: the trigger covers it
        assertTrue(scalar("SELECT sql FROM sqlite_master WHERE name = 'movies_titlesort_ai'").contains("WHEN NEW.titleSort = ''"))
    }

    @Test fun theCatalogWriteSavesTheSameKeyTheTriggerWouldHaveMade() {
        val mv = comparableTitles.mapIndexed { i, t -> movie(i, t) }; val sr = comparableTitles.mapIndexed { i, t -> show(i, t) }
        runBlocking { CatalogStore(db).replace("A", cats(), emptyList(), mv, sr) }
        for (m in mv) assertEquals(SortKey.of(m.title), scalar("SELECT titleSort FROM movies WHERE id = '${m.id}'"))
        for (s in sr) assertEquals(SortKey.of(s.title), scalar("SELECT titleSort FROM series WHERE id = '${s.id}'"))
        // the same rows written by the trigger alone (a key left empty) give the very same column
        val viaTrigger = HashMap<String, String>()
        raw.execSQL("DELETE FROM movies"); runBlocking { db.catalog().putMovies(mv) }
        raw.query("SELECT id, titleSort FROM movies").use { while (it.moveToNext()) viaTrigger[it.getString(0)] = it.getString(1) }
        for (m in mv) assertEquals(SortKey.of(m.title), viaTrigger[m.id])
    }

    @Test fun aBigFirstReadWritesEverythingAndLeavesIdentityToTheFill() {
        val mv = (1..2500).map { movie(it) }; val sr = (1..1200).map { show(it) }; val ch = (1..1100).map { chan(it) }
        val store = CatalogStore(db, deferFirstIdentity = true)
        runBlocking { store.replace("A", cats(), ch, mv, sr) }
        assertEquals("2500", scalar("SELECT COUNT(*) FROM movies")); assertEquals("1200", scalar("SELECT COUNT(*) FROM series")); assertEquals("1100", scalar("SELECT COUNT(*) FROM channels"))
        assertEquals("one search row per item", "4800", scalar("SELECT COUNT(*) FROM ${SearchIndex.TABLE}"))
        assertNotNull(runBlocking { db.catalog().fingerprint("A") })
        assertEquals("no identity row was derived inside the read", 0, runBlocking { db.identity().identityTotal() })
        val ids = IdentityStore(db)
        assertEquals(0.0, runBlocking { ids.coverage() }, 0.0)
        while (runBlocking { ids.backfillStep(1000) } > 0) { }
        assertEquals("the background fill makes them", 3700, runBlocking { db.identity().identityTotal() }); assertEquals(1.0, runBlocking { ids.coverage() }, 0.0)
        // a fill is the same as what a read with identities writes
        val filled = raw.query("SELECT * FROM content_identity ORDER BY itemId").use { c -> buildList { while (c.moveToNext()) add((0 until c.columnCount).joinToString("|") { c.getString(it) ?: "NULL" }) } }
        raw.execSQL("DELETE FROM content_identity"); raw.execSQL("DELETE FROM catalog_fingerprints")
        runBlocking { CatalogStore(db).replace("A", cats(), ch, mv, sr) }
        assertEquals(filled, raw.query("SELECT * FROM content_identity ORDER BY itemId").use { c -> buildList { while (c.moveToNext()) add((0 until c.columnCount).joinToString("|") { c.getString(it) ?: "NULL" }) } })
    }

    @Test fun aLaterReadReplacesChangedRowsRemovesGoneOnesAndDerivesOnlyTheDifference() {
        val store = CatalogStore(db, deferFirstIdentity = true)
        runBlocking { store.replace("A", cats(), emptyList(), (1..1500).map { movie(it) }, (1..50).map { show(it) }) }
        val ids = IdentityStore(db); while (runBlocking { ids.backfillStep(1000) } > 0) { }
        val seen = ArrayList<app.streamsetu.core.data.repo.smartmix.ChangeSet>()
        val job = kotlinx.coroutines.GlobalScope.launch(kotlinx.coroutines.Dispatchers.Unconfined) { IdentityStore.changes.collect { seen += it } }
        val next = (101..1600).map { if (it in 101..110) movie(it, "Renamed $it") else movie(it) }          // 100 gone, 100 new, 10 renamed
        runBlocking { store.replace("A", cats(), emptyList(), next, (1..50).map { show(it) }) }
        job.cancel()
        assertEquals("1500", scalar("SELECT COUNT(*) FROM movies")); assertEquals("0", scalar("SELECT COUNT(*) FROM movies WHERE id IN ('A:m1','A:m100')"))
        assertEquals("Renamed 105", scalar("SELECT title FROM movies WHERE id = 'A:m105'")); assertEquals("renamed 105", scalar("SELECT titleSort FROM movies WHERE id = 'A:m105'"))
        val m = seen.single { it.kind == "MOVIE" }; assertEquals(100, m.added); assertEquals(100, m.removed); assertEquals(10, m.changed)
        assertEquals("1550", scalar("SELECT COUNT(*) FROM content_identity"))
        // an identical read afterwards writes nothing
        raw.execSQL("UPDATE movies SET title = 'TAMPERED' WHERE id = 'A:m500'")
        runBlocking { store.replace("A", cats(), emptyList(), next, (1..50).map { show(it) }) }
        assertEquals("TAMPERED", scalar("SELECT title FROM movies WHERE id = 'A:m500'"))
    }

    @Test fun progressOnlyGoesUpWithinAStageAndEndsAtTheTotal() {
        val events = ArrayList<SyncProgress>()
        runBlocking { CatalogStore(db).replace("A", cats(), (1..2300).map { chan(it) }, (1..3100).map { movie(it) }, (1..1900).map { show(it) }) { events += it } }
        val byStage = events.groupBy { it.stage }
        assertEquals(listOf(SyncProgress.Stage.SAVING_CHANNELS, SyncProgress.Stage.SAVING_MOVIES, SyncProgress.Stage.SAVING_SERIES), events.map { it.stage }.distinct())
        for ((stage, list) in byStage) {
            assertEquals("$stage starts at 0", 0, list.first().done)
            assertTrue("$stage never goes down", list.zipWithNext().all { (a, b) -> b.done >= a.done && b.total == a.total })
            assertEquals("$stage ends at its total", list.last().total, list.last().done)
        }
        assertEquals(2300, byStage.getValue(SyncProgress.Stage.SAVING_CHANNELS).last().total); assertEquals(3100, byStage.getValue(SyncProgress.Stage.SAVING_MOVIES).last().total); assertEquals(1900, byStage.getValue(SyncProgress.Stage.SAVING_SERIES).last().total)
    }

    @Test fun aReadThatIsCancelledPartWayKeepsTheRowsAndLeavesNoFingerprint() {
        runBlocking { CatalogStore(db).replace("A", cats(), emptyList(), (1..100).map { movie(it) }, emptyList()) }
        var job: Job? = null
        runBlocking {
            job = launch { CatalogStore(db).replace("A", cats(), emptyList(), (1..5000).map { movie(it + 1000) }, emptyList()) { p -> if (p.stage == SyncProgress.Stage.SAVING_MOVIES && p.done >= 1000) job?.cancel() } }
            job!!.join()
        }
        assertTrue(job!!.isCancelled)
        assertNull(runBlocking { db.catalog().fingerprint("A") })
        assertTrue("the old rows are all still there", scalar("SELECT COUNT(*) FROM movies WHERE id IN (${(1..100).joinToString(",") { "'A:m$it'" }})") == "100")
        runBlocking { CatalogStore(db).replace("A", cats(), emptyList(), (1..5000).map { movie(it + 1000) }, emptyList()) }          // done again from the start
        assertEquals("5000", scalar("SELECT COUNT(*) FROM movies")); assertNotNull(runBlocking { db.catalog().fingerprint("A") })
    }
}
