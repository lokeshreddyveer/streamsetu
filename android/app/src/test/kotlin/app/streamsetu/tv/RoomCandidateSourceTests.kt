package app.streamsetu.tv

import app.streamsetu.core.data.db.*
import app.streamsetu.core.data.repo.smartmix.*
import app.streamsetu.core.data.smartmix.*
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import app.streamsetu.tv.PrivacyFixture.Companion as F

/** The Room candidate source and the persisted Smart Mix state, on the privacy matrix library (twin playlists with locked, hidden and adult folders). Synthetic titles only. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class RoomCandidateSourceTests {
    private lateinit var fx: PrivacyFixture
    private lateinit var source: RoomCandidateSource
    private lateinit var home: SmartMixHome

    @Before fun open() {
        fx = PrivacyFixture().build()
        runBlocking { val ids = IdentityStore(fx.db); while (ids.backfillStep() > 0) { } }
        val src = { listOf("A", "B") }
        source = RoomCandidateSource(fx.db, fx.folders.visibility, src, { null })
        home = SmartMixHome(fx.db, fx.folders.visibility, src, { null }, null)
    }
    @After fun close() = fx.close()

    private fun pool(shelf: String): List<Candidate> { runBlocking { source.prepare() }; return source.pool(PoolRequest("main", shelf, "2026-11-21", emptyList(), 2000)) }

    @Test fun everyCopyOfARestrictedTitleIsFlaggedWhateverFolderItSitsIn() {
        for (shelf in listOf(ShelfSpec.HERO, ShelfSpec.TOP_WEEK, ShelfSpec.FOR_YOU)) {
            val byId = pool(shelf).associateBy { it.id }
            for (id in F.restrictedMovies) byId[id]?.let { assertTrue("$shelf: $id must be restricted", it.restricted) }
            assertTrue("$shelf: the open copies are present and unrestricted", byId.getValue(F.OPEN_FILM_A).let { !it.restricted })
        }
    }

    @Test fun shelvesNeverHoldARestrictedTitleAndTheRowsStayStable() {
        val built = runBlocking { home.home("main") }
        val ids = built.flatMap { it.result.ids }.toSet()
        assertTrue("something is recommended", ids.isNotEmpty())
        assertTrue("restricted titles leaked: ${ids intersect F.restrictedMovies}", (ids intersect F.restrictedMovies).isEmpty())
        assertFalse(F.SERIES_SECRET in ids)
        val again = runBlocking { home.home("main") }
        assertEquals("same day, same counter: same shelves", built.map { it.result.ids }, again.map { it.result.ids })
    }

    @Test fun aTitleTakenOutOfContinueWatchingStopsBeingRecommendedButItsProgressStays() = runBlocking {
        fx.db.openHelper.writableDatabase.execSQL("INSERT INTO progress(itemId, kind, seriesId, positionMs, durationMs, updatedAt, completed) VALUES('m-plain-a', 'MOVIE', NULL, 1000, 9000, 5, 0)")
        val state = SmartMixState(fx.db, fx.folders.visibility)
        assertTrue(state.dismiss("main", "MOVIE", "m-plain-a", "Plain Story", F.OPEN_A, 2020))
        source.invalidate()
        val plain = pool(ShelfSpec.FOR_YOU).filter { it.identityKey == IdentityKey.ofOrFallback("Plain Story") }
        assertTrue("both copies carry the marker", plain.isNotEmpty() && plain.all { it.dismissed })
        val shelves = home.home("main").flatMap { it.result.ids }
        assertFalse("m-plain-a" in shelves || "m-plain-b" in shelves)
        fx.db.openHelper.readableDatabase.query("SELECT COUNT(*) FROM progress WHERE itemId = 'm-plain-a'").use { c -> c.moveToFirst(); assertEquals(1, c.getInt(0)) }
        state.undismiss("main", "m-plain-a"); source.invalidate()
        assertTrue(pool(ShelfSpec.FOR_YOU).none { it.dismissed })
    }

    @Test fun aRestrictedTitleCannotBeDismissedOrRecorded() = runBlocking {
        val state = SmartMixState(fx.db, fx.folders.visibility)
        assertFalse(state.dismiss("main", "MOVIE", F.SECRET_A, "Secret Film", F.LOCKED_A, 2020))
        assertTrue(state.dismissed("main").isEmpty())
    }

    @Test fun stateIsKeyedByProfileAndBounded() {
        val store = RoomSmartMixStore(fx.db)
        store.saveState("main", "hero", ShelfState(3, "d|3", 7))
        store.saveState("kid", "hero", ShelfState(1, "d|1", 2))
        assertEquals(3, store.state("main", "hero").refreshCounter); assertEquals(1, store.state("kid", "hero").refreshCounter)
        store.replaceShown("main", "hero", (1..200).map { ShownRow("k$it", 2020, "i$it", it) })
        assertEquals(RoomSmartMixStore.MAX_ROWS, store.shown("main", "hero").size)
        assertTrue(store.shown("kid", "hero").isEmpty())
        store.clearProfile("main")
        assertEquals(0, store.state("main", "hero").refreshCounter); assertTrue(store.shown("main", "hero").isEmpty())
        assertEquals(1, store.state("kid", "hero").refreshCounter)
    }

    @Test fun reshuffleBumpsTheCounterAndNeverTouchesTheCatalog() = runBlocking {
        val before = fx.db.catalog().movieTotal()
        home.reshuffle("main", listOf(ShelfSpec.HERO))
        assertEquals(1, RoomSmartMixStore(fx.db).state("main", ShelfSpec.HERO).refreshCounter)
        assertEquals(before, fx.db.catalog().movieTotal())
    }

    @Test fun repeatSuppressionIsPersistedWhenARenderIsCommitted() = runBlocking {
        val b = home.shelf("main", ShelfSpec.HERO)
        home.committed("main", b)
        val st = RoomSmartMixStore(fx.db).state("main", ShelfSpec.HERO)
        assertEquals(1, st.loadSeq); assertEquals(b.loadKey, st.loadKey)
        assertTrue(RoomSmartMixStore(fx.db).shown("main", ShelfSpec.HERO).none { it.itemId in F.restrictedMovies })
    }

    @Test fun aVisibleTwinIsExcludedWhenTheRestrictedCopyHasNoIdentityYetButAnUnrelatedSameNameTitleStays() {
        val raw = fx.db.openHelper.writableDatabase
        // the restricted copy (locked folder, playlist A) has not been given an identity yet
        raw.execSQL("DELETE FROM content_identity WHERE itemId = '${F.LONE_A}'")
        // an unrelated film with the same name from 1950 sits in an open folder, with its identity
        raw.execSQL("INSERT INTO movies(id, sourceId, categoryId, title, posterUrl, year, rating, plot, streamRef, addedAt) VALUES('m-old-lone', 'A', '${F.OPEN_A}', 'Lone Copy', 'http://img/x.jpg', 1950, NULL, NULL, 'ref', 10)")
        runBlocking { val ids = IdentityStore(fx.db); while (ids.backfillStep() > 0) { } }
        raw.execSQL("DELETE FROM content_identity WHERE itemId = '${F.LONE_A}'")
        source.invalidate()
        val byId = pool(ShelfSpec.HERO).associateBy { it.id }
        assertTrue("the visible twin of a copy with no identity is restricted", byId.getValue(F.LONE_B).restricted)
        assertFalse("an unrelated title of the same name with an incompatible year stays allowed", byId.getValue("m-old-lone").restricted)
        val shelves = runBlocking { home.home("main") }.flatMap { it.result.ids }
        assertFalse(F.LONE_B in shelves)
    }

    @Test fun episodeStillsOfARestrictedSeriesAreEvictedAndShownHistoryOfItsTitlesIsDropped() = runBlocking {
        val raw = fx.db.openHelper.writableDatabase
        raw.execSQL("INSERT INTO episodes(id, seriesId, season, number, title, plot, imageUrl, durationSec, streamRef) VALUES('e1', '${F.SERIES_SECRET}', 1, 1, 'Pilot', NULL, 'http://img/still-secret.jpg', NULL, 'ref')")
        val urls = app.streamsetu.core.data.repo.RestrictedPictures.urlsIn(fx.db, setOf("a-s-locked"))
        assertTrue("the episode still is among the pictures to drop", "http://img/still-secret.jpg" in urls)
        val store = RoomSmartMixStore(fx.db)
        store.replaceShown("main", ShelfSpec.FOR_YOU, listOf(ShownRow(IdentityKey.ofOrFallback("Secret Film"), 2020, F.SECRET_A, 1), ShownRow(IdentityKey.ofOrFallback("Open Film"), 2020, F.OPEN_FILM_A, 1)))
        SmartMixState(fx.db, fx.folders.visibility).purgeShown(setOf(F.LOCKED_A))
        val left = store.shown("main", ShelfSpec.FOR_YOU).map { it.itemId }
        assertEquals(listOf(F.OPEN_FILM_A), left)
    }
}
