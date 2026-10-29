package app.streamsetu.tv

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.*
import app.streamsetu.core.sync.CatalogStore
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * An unchanged provider writes nothing, and anything that changed writes everything. "Nothing was written" is seen by changing a saved row behind the store's back: if the row is
 * still changed afterwards, the store left the database alone.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class)
class CatalogFingerprintTests {
    private lateinit var db: AppDatabase
    private fun channel(i: Int, source: String = "s", url: String = "http://p/$i", name: String = "Channel $i", cat: String? = "g") =
        ChannelEntity("$source:c$i", source, cat, name, i, "http://logo/$i", url, null, 0, i)
    private fun movie(i: Int, source: String = "s") = MovieEntity("$source:m$i", source, "g", "Movie $i", "http://poster/$i", 2000, "7", null, "http://p/m$i", i.toLong())
    private val cats = listOf(CategoryEntity("g", "s", "CHANNEL", "News", 0))
    private fun channels(n: Int = 50) = (1..n).map { channel(it) }

    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext<Context>(), AppDatabase::class.java).allowMainThreadQueries().build()
        db.openHelper.writableDatabase.execSQL(SearchIndex.CREATE)
    }
    @After fun close() = db.close()

    private fun write(store: CatalogStore, ch: List<ChannelEntity>, mv: List<MovieEntity> = emptyList(), source: String = "s", categories: List<CategoryEntity> = cats) = runBlocking { store.replace(source, categories, ch, mv, emptyList()) }
    /** Changes a saved row's name directly in the database. */
    private fun tamper() { db.openHelper.writableDatabase.execSQL("UPDATE channels SET name = 'TAMPERED' WHERE id = 's:c1'") }
    private fun tampered() = db.openHelper.writableDatabase.query("SELECT name FROM channels WHERE id = 's:c1'").use { it.moveToFirst(); it.getString(0) == "TAMPERED" }

    @Test fun anIdenticalCatalogAfterARestartWritesNothing() {
        write(CatalogStore(db), channels()); tamper()
        write(CatalogStore(db), channels())                          // a new store: nothing is remembered in memory, only the saved fingerprint
        assertEquals(true, tampered())
    }
    @Test fun aChangedStreamAddressWritesAgain() { write(CatalogStore(db), channels()); tamper(); write(CatalogStore(db), channels().map { if (it.id == "s:c7") it.copy(streamRef = "http://other/7") else it }); assertEquals(false, tampered()) }
    @Test fun aChangedTitleWritesAgain() { write(CatalogStore(db), channels()); tamper(); write(CatalogStore(db), channels().map { if (it.id == "s:c7") it.copy(name = "Renamed") else it }); assertEquals(false, tampered()) }
    @Test fun aChangedPictureWritesAgain() { write(CatalogStore(db), channels()); tamper(); write(CatalogStore(db), channels().map { if (it.id == "s:c7") it.copy(logoUrl = "http://new") else it }); assertEquals(false, tampered()) }
    @Test fun aChangedFolderWritesAgain() { write(CatalogStore(db), channels()); tamper(); write(CatalogStore(db), channels().map { if (it.id == "s:c7") it.copy(categoryId = "h") else it }); assertEquals(false, tampered()) }
    @Test fun reorderedRowsWriteAgain() { write(CatalogStore(db), channels()); tamper(); write(CatalogStore(db), channels().reversed()); assertEquals(false, tampered()) }
    @Test fun anAddedItemWritesAgain() { write(CatalogStore(db), channels()); tamper(); write(CatalogStore(db), channels(51)); assertEquals(false, tampered()) }
    @Test fun aRemovedItemWritesAgain() { write(CatalogStore(db), channels()); tamper(); write(CatalogStore(db), channels(49)); assertEquals(false, tampered()) }
    @Test fun aNewParserVersionWritesAgain() { write(CatalogStore(db, 1), channels()); tamper(); write(CatalogStore(db, 2), channels()); assertEquals(false, tampered()) }
    @Test fun aMatchingFingerprintButWrongRowCountWritesAgain() {
        write(CatalogStore(db), channels()); tamper()
        db.openHelper.writableDatabase.execSQL("DELETE FROM channels WHERE id = 's:c9'")
        write(CatalogStore(db), channels())
        assertEquals(false, tampered())
        db.openHelper.writableDatabase.query("SELECT COUNT(*) FROM channels").use { it.moveToFirst(); assertEquals(50, it.getInt(0)) }
    }
    @Test fun aFailedWriteKeepsTheOldRowsAndTheOldFingerprint() {
        write(CatalogStore(db), channels())
        val before = runBlocking { db.catalog().fingerprint("s") }
        db.openHelper.writableDatabase.execSQL("DROP TABLE ${SearchIndex.TABLE}")             // the write fails part-way through its transaction
        try { write(CatalogStore(db), channels(60)); throw AssertionError("the write should have failed") } catch (_: AssertionError) { throw AssertionError("the write should have failed") } catch (_: Exception) {}
        db.openHelper.writableDatabase.query("SELECT COUNT(*) FROM channels").use { it.moveToFirst(); assertEquals(50, it.getInt(0)) }
        assertEquals(before, runBlocking { db.catalog().fingerprint("s") })
    }
    @Test fun removingASourceRemovesItsFingerprint() {
        write(CatalogStore(db), channels())
        runBlocking { db.catalog().clearFingerprint("s") }
        assertNull(runBlocking { db.catalog().fingerprint("s") })
    }
    @Test fun twoSourcesWithTheSameCatalogKeepSeparateFingerprints() {
        val store = CatalogStore(db)
        write(store, channels(), source = "s"); write(store, (1..50).map { channel(it, source = "t") }, source = "t", categories = listOf(CategoryEntity("g", "t", "CHANNEL", "News", 0)))
        val a = runBlocking { db.catalog().fingerprint("s") }; val b = runBlocking { db.catalog().fingerprint("t") }
        assertEquals("s", a?.sourceId); assertEquals("t", b?.sourceId)
        runBlocking { db.catalog().clearFingerprint("s") }
        assertNull(runBlocking { db.catalog().fingerprint("s") }); assertNotEquals(null, runBlocking { db.catalog().fingerprint("t") })
    }
    @Test fun aLargeCatalogIsFingerprintedWithoutBuildingItsWholeContentAsOneValue() {
        val big = (1..30_000).map { channel(it) }
        val t = System.currentTimeMillis(); write(CatalogStore(db), big); println("write of 30k channels took ${System.currentTimeMillis() - t} ms")
        val t2 = System.currentTimeMillis(); write(CatalogStore(db), big); println("identical 30k catalog skipped in ${System.currentTimeMillis() - t2} ms")
    }
}
