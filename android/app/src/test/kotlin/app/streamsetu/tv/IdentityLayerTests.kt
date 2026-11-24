package app.streamsetu.tv

import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.*
import app.streamsetu.core.data.repo.Visibility
import app.streamsetu.core.data.repo.smartmix.*
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.sync.CatalogStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import app.streamsetu.tv.PrivacyFixture.Companion as F

/**
 * The canonical identity layer on a real (in-memory) database: written beside the catalog by the same read, never changing a playlist row, kept in step by small change sets, filled in for
 * what was read before, and read back as one title per film with every copy reachable. Synthetic titles only.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class IdentityLayerTests {
    private lateinit var db: AppDatabase
    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), AppDatabase::class.java).allowMainThreadQueries()
            .addCallback(object : androidx.room.RoomDatabase.Callback() { override fun onCreate(db: SupportSQLiteDatabase) { SearchIndex.create(db); PeopleIndex.create(db); LanLog.create(db); Profiles.create(db) } }).build()
        runBlocking { for ((i, id) in listOf("A", "B").withIndex()) db.sources().upsert(SourceEntity(id, "Playlist $id", "M3U", "http://x/$id", null, null, true, 1_000L, "OK", sortOrder = i)) }
    }
    @After fun close() = db.close()

    private fun cats(src: String) = listOf(CategoryEntity("$src-c1", src, "MOVIE", "ENGLISH | MOVIES", 0), CategoryEntity("$src-c2", src, "MOVIE", "HINDI DUBBED", 1), CategoryEntity("$src-s1", src, "SERIES", "ENGLISH | SERIES", 0))
    private fun movies(src: String, n: Int, from: Int = 0, suffix: (Int) -> String = { "" }) = (from until from + n).map { i ->
        MovieEntity("$src:m$i", src, if (i % 3 == 0) "$src-c2" else "$src-c1", "Title $i ${(2000 + i % 24)}${suffix(i)}", "http://img/$i.jpg", 2000 + i % 24, null, null, "ref:$src:$i", 1_000L + i)
    }
    private fun series(src: String, n: Int) = (0 until n).map { i -> SeriesEntity("$src:s$i", src, "$src-s1", "Show $i", "http://img/s$i.jpg", null, 2010 + i % 10, null, null, "p$i", 500L + i) }
    private fun write(src: String, mv: List<MovieEntity>, sr: List<SeriesEntity> = series(src, 5)) = runBlocking { CatalogStore(db).replace(src, cats(src), emptyList(), mv, sr) }
    private fun dump(table: String) = db.openHelper.readableDatabase.query("SELECT * FROM $table ORDER BY 1").use { c -> buildList { while (c.moveToNext()) add((0 until c.columnCount).joinToString("|") { c.getString(it) ?: "NULL" }) } }
    private fun identityDump() = db.openHelper.readableDatabase.query("SELECT * FROM content_identity ORDER BY itemId").use { c -> buildList { while (c.moveToNext()) add((0 until c.columnCount).joinToString("|") { c.getString(it) ?: "NULL" }) } }

    @Test fun aReadWritesAnIdentityRowForEveryMovieAndSeriesAndChangesNoPlaylistRow() {
        val mv = movies("A", 40); val sr = series("A", 5)
        write("A", mv, sr)
        assertEquals(45, runBlocking { db.identity().identityTotal() })
        assertEquals("movies are exactly what was read", mv.sortedBy { it.id }.map { listOf(it.id, it.sourceId, it.categoryId, it.title, it.posterUrl, it.year, it.rating, it.plot, it.streamRef, it.addedAt) },
            runBlocking { db.catalog().moviesByIds(mv.map { it.id }) }.sortedBy { it.id }.map { listOf(it.id, it.sourceId, it.categoryId, it.title, it.posterUrl, it.year, it.rating, it.plot, it.streamRef, it.addedAt) })
        assertEquals("series are exactly what was read, with the sort key the write saves with the row", sr.map { it.copy(titleSort = app.streamsetu.core.model.SortKey.of(it.title)) }.sortedBy { it.id }, runBlocking { db.catalog().seriesByIds(sr.map { it.id }) }.sortedBy { it.id })
        val row = runBlocking { db.identity().byItemIds(listOf("A:m3")).single() }
        val d = Derive.derive("MOVIE", mv[3].title, "HINDI DUBBED", mv[3].year)
        assertEquals(d.identityKey, row.identityKey); assertEquals(d.folderKey, row.folderKey); assertEquals("MOVIE|hindi dubbed", row.folderKey); assertEquals(IdentityKey.VERSION, row.identVer)
    }

    @Test fun theBackgroundFillAndTheTwinReadNeverChangeAPlaylistRow() {
        val mv = movies("A", 30) + movies("B", 30)
        runBlocking { db.catalog().putCategories(cats("A") + cats("B")); db.catalog().putMovies(mv); db.catalog().putSeries(series("A", 3)) }          // read before the identity table existed: no identity rows
        val before = listOf("movies", "series", "categories", "channels", "favorites", "progress", "watch_log").associateWith(::dump)
        val store = IdentityStore(db)
        assertEquals(0.0, runBlocking { store.coverage() }, 0.0)
        while (runBlocking { store.backfillStep(25) } > 0) { }
        runBlocking { SourceTwins.recompute(db) }
        assertEquals(1.0, runBlocking { store.coverage() }, 0.0)
        for ((t, rows) in before) assertEquals("table $t unchanged", rows, dump(t))
    }

    @Test fun theFillResumesWhereItStoppedAndAnOldRuleIsDerivedAgain() {
        runBlocking { db.catalog().putCategories(cats("A")); db.catalog().putMovies(movies("A", 100)) }
        val first = IdentityStore(db)
        assertEquals(30, runBlocking { first.backfillStep(30) })          // stopped here (the app was closed)
        val second = IdentityStore(db)                                      // the next start
        assertEquals(0.3, runBlocking { second.coverage() }, 0.001)
        var total = 30; while (true) { val n = runBlocking { second.backfillStep(40) }; if (n == 0) break; total += n }
        assertEquals(100, total); assertEquals(1.0, runBlocking { second.coverage() }, 0.0)
        db.openHelper.writableDatabase.execSQL("UPDATE content_identity SET identVer = 0 WHERE itemId LIKE 'A:m1%'")          // rows made by an older rule
        assertTrue(runBlocking { second.coverage() } < 1.0)
        while (runBlocking { second.backfillStep(1000) } > 0) { }
        assertEquals(1.0, runBlocking { second.coverage() }, 0.0)
    }

    @Test fun anUnchangedReadWritesNothingAndAnnouncesNothing() = runBlocking {
        val mv = movies("A", 50); write("A", mv)
        val before = identityDump()
        val seen = ArrayList<ChangeSet>(); val job = kotlinx.coroutines.GlobalScope.launch(kotlinx.coroutines.Dispatchers.Unconfined) { IdentityStore.changes.collect { seen += it } }
        write("A", mv)
        job.cancel()
        assertEquals(before, identityDump()); assertTrue(seen.toString(), seen.isEmpty())
    }

    @Test fun aReadWithAddedRemovedAndChangedTitlesDerivesOnlyThose() = runBlocking {
        val base = movies("A", 400); write("A", base)
        val seen = ArrayList<ChangeSet>(); val job = kotlinx.coroutines.GlobalScope.launch(kotlinx.coroutines.Dispatchers.Unconfined) { IdentityStore.changes.collect { seen += it } }
        // +300 new, -300 gone, +30 whose title changed
        val next = base.drop(300).map { if (it.id.removePrefix("A:m").toInt() in 300 until 330) it.copy(title = it.title + " Part Two") else it } + movies("A", 300, from = 1000)
        write("A", next)
        job.cancel()
        val m = seen.single { it.kind == "MOVIE" }
        assertEquals(300, m.added); assertEquals(300, m.removed); assertEquals(30, m.changed); assertFalse(m.bulk)
        assertEquals(m.addedIds.toSet(), movies("A", 300, from = 1000).map { it.id }.toSet())
        // patched == rebuilt from nothing
        val patched = identityDump().filter { it.startsWith("A:m") }
        db.openHelper.writableDatabase.execSQL("DELETE FROM content_identity"); while (IdentityStore(db).backfillStep(500) > 0) { }
        assertEquals(patched, identityDump().filter { it.startsWith("A:m") })
        assertEquals(0, db.openHelper.readableDatabase.query("SELECT COUNT(*) FROM content_identity i LEFT JOIN movies m ON m.id = i.itemId WHERE i.kind = 'MOVIE' AND m.id IS NULL").use { it.moveToFirst(); it.getInt(0) })
    }

    @Test fun aReadThatStopsHalfWayLeavesRowsTheFillRepairs() = runBlocking {
        write("A", movies("A", 600))
        // a later read that was killed after its first steps: new rows in, identity missing for some
        db.catalog().putMovies(movies("A", 200, from = 5000))
        val s = IdentityStore(db)
        assertTrue(s.coverage() < 1.0)
        while (s.backfillStep(77) > 0) { }
        assertEquals(1.0, s.coverage(), 0.0)
    }

    @Test fun twinPlaylistsKeepBothCopiesAndReadAsOneTitle() = runBlocking {
        write("A", movies("A", 60)); write("B", movies("B", 60))
        assertEquals(120, db.catalog().movieTotal())          // both playlists stay whole: nothing was merged or removed
        SourceTwins.recompute(db)
        val t = db.identity().twins().single { it.kind == "MOVIE" }
        assertEquals(60, t.matched); assertTrue(SourceTwins.isTwin(t))
        val copies = db.openHelper.readableDatabase.query("SELECT i.itemId, i.kind, i.sourceId, m.categoryId, i.identityKey, i.year, i.lang, i.qualityRank, m.addedAt FROM content_identity i JOIN movies m ON m.id = i.itemId WHERE i.kind = 'MOVIE'").use { c ->
            buildList { while (c.moveToNext()) add(CanonicalPick.Copy(c.getString(0), c.getString(1), c.getString(2), c.getString(3), c.getString(4), if (c.isNull(5)) null else c.getInt(5), c.getString(6), c.getInt(7), c.getLong(8))) } }
        val groups = CanonicalPick.group(copies, CanonicalPick.Context(sourceRank = mapOf("A" to 0, "B" to 1)))
        assertEquals(60, groups.size); assertTrue(groups.all { it.canonical.sourceId == "A" && it.alternatives.single().sourceId == "B" })
    }

    @Test fun overlapDecidesWhetherTwoPlaylistsAreTwins() = runBlocking {
        write("A", movies("A", 100)); write("B", movies("B", 92) + movies("B", 8, from = 900))
        SourceTwins.recompute(db)
        assertTrue("92 of 100 in common", SourceTwins.isTwin(db.identity().twins().single { it.kind == "MOVIE" }))
        write("B", movies("B", 60) + movies("B", 40, from = 900))
        SourceTwins.recompute(db)
        assertFalse("60 of 100 in common", SourceTwins.isTwin(db.identity().twins().single { it.kind == "MOVIE" }))
    }

    @Test fun removingAPlaylistTakesItsIdentityWithIt() = runBlocking {
        write("A", movies("A", 20)); write("B", movies("B", 20)); SourceTwins.recompute(db)
        db.identity().clearSource("B"); db.identity().clearTwinsOf("B")
        assertEquals(0, db.identity().countOf("B", "MOVIE")); assertTrue(db.identity().countOf("A", "MOVIE") > 0); assertTrue(db.identity().twins().isEmpty())
    }

    @Test fun aTitleWithACopyInALockedFolderIsRestrictedAndNoRestrictedCopyIsOffered() = runBlocking {
        val fx = PrivacyFixture().build()
        try {
            val s = IdentityStore(fx.db); while (s.backfillStep(500) > 0) { }
            val snap = fx.folders.visibility.snapshot(Visibility.Surface.SEARCH)
            val copies = fx.db.openHelper.readableDatabase.query("SELECT i.itemId, i.kind, i.sourceId, m.categoryId, i.identityKey, i.year, i.lang, i.qualityRank, m.addedAt FROM content_identity i JOIN movies m ON m.id = i.itemId").use { c ->
                buildList { while (c.moveToNext()) add(CanonicalPick.Copy(c.getString(0), c.getString(1), c.getString(2), c.getString(3), c.getString(4), if (c.isNull(5)) null else c.getInt(5), c.getString(6), c.getInt(7), c.getLong(8))) } }
            val groups = CanonicalPick.group(copies, CanonicalPick.Context(sourceRank = mapOf("A" to 0, "B" to 1), folderRestricted = { !snap.folderOk(ContentKind.MOVIE, it.folderId) })).associateBy { it.identityKey }
            assertTrue("split title: one copy in a locked folder", groups.getValue("split title").restricted)
            assertTrue(groups.getValue("secret film").restricted); assertTrue(groups.getValue("hidden film").restricted); assertTrue(groups.getValue("adult film").restricted)
            assertFalse(groups.getValue("open film").restricted); assertEquals(listOf(F.OPEN_FILM_B), groups.getValue("open film").alternatives.map { it.itemId })
            assertTrue(groups.values.flatMap { it.alternatives }.none { !snap.folderOk(ContentKind.MOVIE, it.folderId) })
        } finally { fx.close() }
    }

    @Test fun removingFromRecommendationsWritesAMarkerOnlyAndRefusesARestrictedTitle() = runBlocking {
        val fx = PrivacyFixture().build()
        try {
            val state = SmartMixState(fx.db, fx.folders.visibility)
            fx.db.user().putProgress(ProgressEntity(F.OPEN_FILM_A, "MOVIE", null, 600_000, 6_000_000, 1_000, false))
            val progress = fx.db.user().allProgressNow()
            assertTrue(state.dismiss("main", "MOVIE", F.OPEN_FILM_A, "Open Film", F.OPEN_A, 2020))
            assertFalse("a title in a locked folder is never recorded", state.dismiss("main", "MOVIE", F.SECRET_A, "Secret Film", F.LOCKED_A, 2020))
            assertEquals(progress, fx.db.user().allProgressNow())
            assertEquals(listOf("open film"), state.dismissed("main").map { it.identityKey })
            state.undismiss("main", F.OPEN_FILM_A); assertTrue(state.dismissed("main").isEmpty())
        } finally { fx.close() }
    }

    @Test fun whatAShelfShowedIsRecordedOnlyForTitlesThatMayBeRecommendedAndPurgedWhenAFolderIsRestricted() = runBlocking {
        val fx = PrivacyFixture().build()
        try {
            val state = SmartMixState(fx.db, fx.folders.visibility)
            fun c(id: String, folder: String, key: String) = CanonicalPick.Copy(id, "MOVIE", "A", folder, key, 2020, null, 2)
            assertEquals(1, state.recordShown("main", "for-you", 1, listOf(c(F.OPEN_FILM_A, F.OPEN_A, "open film"), c(F.SECRET_A, F.LOCKED_A, "secret film"))))
            assertEquals(listOf("open film"), fx.db.identity().shown("main").map { it.identityKey })
            // the person locks the folder of that film afterwards: what was saved for it goes at once
            fx.folders.toggleLocked(ContentKind.MOVIE, fx.folder(F.OPEN_A, "A", PrivacyFixture.names["open"]!!))
            state.purgeShown(fx.folders.visibility.excludedFolders(ContentKind.MOVIE, Visibility.Surface.RECOMMEND))
            assertTrue(fx.db.identity().shown("main").isEmpty())
        } finally { fx.close() }
    }

    @Test fun removingAProfileRemovesItsSmartMixRows() = runBlocking {
        db.identity().putDismissed(RecDismissedEntity("kid", "m1", "MOVIE", "leo", 2023, 1)); db.identity().putState(SmartMixStateEntity("kid", "for-you", 1, "k", 2))
        db.identity().putRecent(FolderRecentEntity("kid", "c1", 5, 1)); db.identity().putShown(listOf(SmartMixShownEntity("kid", "for-you", "leo", 2023, "m1", 1, 1)))
        db.identity().putDismissed(RecDismissedEntity("main", "m1", "MOVIE", "leo", 2023, 1))
        val raw = db.openHelper.writableDatabase
        raw.execSQL("INSERT INTO profiles(id, name, kids, color, sort_order, created_at) VALUES('kid', 'Kid', 1, 0, 1, 0)")
        assertTrue(Profiles.remove(raw, "kid"))
        assertTrue(db.identity().dismissed("kid").isEmpty()); assertTrue(db.identity().shown("kid").isEmpty()); assertNull(db.identity().state("kid", "for-you")); assertTrue(db.identity().recent("kid").isEmpty())
        assertEquals(1, db.identity().dismissed("main").size)
    }
}
