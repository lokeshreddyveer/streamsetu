package app.streamsetu.tv

import app.streamsetu.core.data.db.ContentIdentityEntity
import app.streamsetu.core.data.repo.*
import app.streamsetu.core.data.repo.smartmix.IdentityKey
import app.streamsetu.core.model.ContentKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import app.streamsetu.tv.PrivacyFixture.Companion as F

/** The TMDB id kept for every matched title: found by the person screen as an exact match, removed with the rest of TMDB's data, and never exposed for a restricted title. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class TmdbIdStoreTests {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var fx: PrivacyFixture
    private var t = 1_000_000_000_000L
    @Before fun open() {
        fx = PrivacyFixture().build()
        fx.db.openHelper.writableDatabase.execSQL("UPDATE movies SET posterUrl = NULL")
    }
    @After fun close() = fx.close()

    private fun titleOf(u: String) = java.net.URLDecoder.decode(u.substringAfter("query=").substringBefore("&"), "UTF-8")
    private fun idOf(title: String) = 1000L + (title.hashCode() and 0xfff)
    private fun service(dir: java.io.File, store: TmdbIdStore) = TmdbService(fx.db, { "0123456789abcdef0123456789abcdef" }, fx.folders.visibility, dir, { t }) { u, _ ->
        val q = titleOf(u); """{"results":[{"id":${idOf(q)},"title":"$q","release_date":"2020-01-01","first_air_date":"2020-01-01","popularity":5,"poster_path":"/p.jpg","overview":"s"}]}"""
    }.also { it.idStore = store }
    private fun credit(id: Long, title: String = "Whatever Else") = Credit(id, false, title, null, 1999, "1999-01-01", null, null, 1.0, null, null)

    @Test fun aMatchedTitleIsFoundByItsExactIdAndTheDataGoesWithTheRestOfWhatTmdbGave() = runBlocking {
        val store = TmdbIdStore(fx.db, { t }); val dir = tmp.newFolder(); val svc = service(dir, store)
        val e = ArtworkMatchEngine(fx.db, svc, fx.folders.visibility, dir, { "p" }, { true }, { true }, ArtworkMatchEngine.Config(concurrency = 1, page = 10), { t }, Dispatchers.Unconfined)
        e.runOnce()
        val id = idOf("Plain Story")
        assertEquals(setOf("m-plain-a", "m-plain-b"), store.itemIds(id, false).toSet())
        // the person screen: an exact id wins although the credit's name and year do not match
        fx.db.identity().putAll(listOf(ContentIdentityEntity("m-plain-a", "MOVIE", "A", IdentityKey.ofOrFallback("Plain Story"), 2020, null, 2, false, null, 0L, IdentityKey.VERSION)))
        val hit = LibraryMatcher(fx.db, fx.folders.visibility, store).match(listOf(credit(id)), listOf("A", "B")).getValue("movie$id")
        assertTrue(hit.movie!!.id in setOf("m-plain-a", "m-plain-b"))
        // a title locked later: its id is taken back by the purge, and is never exposed even before it
        fx.folders.toggleLocked(ContentKind.MOVIE, fx.folder(F.OPEN_B, "B", F.names["open"]!!))
        assertTrue("a restricted copy keeps the whole title out", LibraryMatcher(fx.db, fx.folders.visibility, store).match(listOf(credit(id)), listOf("A", "B")).isEmpty())
        svc.purge()
        assertTrue("purged with the lock", store.itemIds(id, false).none { it == "m-plain-b" })
        // 180 days
        t += 181L * 86_400_000L; svc.purge(); assertEquals(0, store.count())
    }

    @Test fun restrictedIdsAreNeverMatchedAndClearAllEmptiesTheStore() {
        val store = TmdbIdStore(fx.db, { t })
        store.put(F.SECRET_A, 7, false); store.put(F.SPLIT_A, 8, false); store.put("m-plain-a", 9, false)
        assertTrue(LibraryMatcher(fx.db, fx.folders.visibility, store).let { m -> runBlocking { m.match(listOf(credit(7), credit(8)), listOf("A", "B")) } }.isEmpty())
        assertEquals(listOf("m-plain-a"), store.itemIds(9, false)); assertTrue("a series id is not a film id", store.itemIds(9, true).isEmpty())
        store.clearAll(); assertEquals(0, store.count()); assertTrue(store.itemIds(9, false).isEmpty())
    }
}
