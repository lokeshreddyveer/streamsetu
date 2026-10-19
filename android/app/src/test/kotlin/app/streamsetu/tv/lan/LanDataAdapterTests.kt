package app.streamsetu.tv.lan

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.FavoriteEntity
import app.streamsetu.core.data.db.LanLog
import app.streamsetu.core.data.db.ProgressEntity
import app.streamsetu.core.data.db.SourceEntity
import app.streamsetu.core.sync.lan.LanDataAdapter
import app.streamsetu.core.sync.lan.LanIds
import app.streamsetu.core.sync.lan.LanRecord
import app.streamsetu.core.sync.lan.SourceKey
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class LanDataAdapterTests {
    private val sourceA = "11111111-1111-1111-1111-111111111111"   // this device's id for the playlist
    private val address = "http://Provider.example:8080/"
    private lateinit var phone: AppDatabase
    private lateinit var tv: AppDatabase
    private lateinit var phoneAdapter: LanDataAdapter
    private lateinit var tvAdapter: LanDataAdapter

    private fun database(context: Context) = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java).allowMainThreadQueries()
        .addCallback(object : androidx.room.RoomDatabase.Callback() { override fun onCreate(db: SupportSQLiteDatabase) { LanLog.create(db) } }).build()

    private fun source(id: String) = SourceEntity(id, "Provider", "XTREAM", address, "u", null, true, 0, "OK", 0, false)

    @Before fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        phone = database(context); tv = database(context)
        runBlocking { phone.sources().upsert(source(sourceA)); tv.sources().upsert(source("22222222-2222-2222-2222-222222222222")) }
        phoneAdapter = LanDataAdapter({ phone.openHelper.writableDatabase }); tvAdapter = LanDataAdapter({ tv.openHelper.writableDatabase })
    }

    @After fun tearDown() { phone.close(); tv.close() }

    private fun movie(source: String, provider: String) = "$source:mv:$provider"

    @Test fun aFavoriteAddedOnTheTvAppearsOnThePhoneUnderThePhonesOwnPlaylistId() = runBlocking {
        val tvSource = "22222222-2222-2222-2222-222222222222"
        tv.user().putFavorite(FavoriteEntity(movie(tvSource, "77"), "MOVIE", "favourites", 1000))
        val applied = phoneAdapter.apply(tvAdapter.snapshot())
        assertEquals(1, applied)
        val favs = phone.user().allFavorites()
        assertEquals(listOf(movie(sourceA, "77")), favs.map { it.itemId })
        assertEquals(1000L, favs.first().addedAt)
    }

    @Test fun aRemovalTravelsAndTheNewerChangeWins() = runBlocking {
        val tvSource = "22222222-2222-2222-2222-222222222222"
        tv.user().putFavorite(FavoriteEntity(movie(tvSource, "5"), "MOVIE", "favourites", 1000))
        phoneAdapter.apply(tvAdapter.snapshot())
        Thread.sleep(5)
        phone.user().removeFavorite(movie(sourceA, "5"), "favourites")        // removed on the phone, later
        tvAdapter.apply(phoneAdapter.snapshot())
        assertTrue(tv.user().allFavorites().isEmpty())
        // an older addition coming back does not undo the removal
        phoneAdapter.apply(listOf(LanRecord("fav", listOf(SourceKey.of(address), "movie", "5", "favorites"), 1, false, buildJsonObject { put("at", 1L) })))
        assertTrue(phone.user().allFavorites().isEmpty())
    }

    @Test fun resumePointsKeepTheirPositionAndSeries() = runBlocking {
        val tvSource = "22222222-2222-2222-2222-222222222222"
        tv.user().putProgress(ProgressEntity("$tvSource:ep:9", "EPISODE", "$tvSource:sr:3", 90_000, 1_800_000, 5000, false))
        phoneAdapter.apply(tvAdapter.snapshot())
        val p = phone.user().progress("$sourceA:ep:9")!!
        assertEquals(90_000L, p.positionMs); assertEquals("$sourceA:sr:3", p.seriesId); assertFalse(p.completed)
    }

    @Test fun itemsOfAPlaylistThisDeviceLacksAreIgnored() = runBlocking {
        val other = LanRecord("fav", listOf("ffffffffffffffff", "movie", "1", "favorites"), 10, false, buildJsonObject { put("at", 10L) })
        assertEquals(0, phoneAdapter.apply(listOf(other)))
        assertTrue(phone.user().allFavorites().isEmpty())
    }

    @Test fun whatWasAppliedIsNotSentBackAsANewChange() = runBlocking {
        val tvSource = "22222222-2222-2222-2222-222222222222"
        tv.user().putFavorite(FavoriteEntity(movie(tvSource, "8"), "MOVIE", "favourites", 1000))
        val sent = tvAdapter.snapshot().single { it.kind == "fav" }
        Thread.sleep(5)
        phoneAdapter.apply(listOf(sent))
        val back = phoneAdapter.snapshot().single { it.kind == "fav" }
        assertEquals(sent.ts, back.ts)                // the time it was made on the TV, not the time it arrived
        assertEquals(0, tvAdapter.apply(listOf(back)))
    }

    @Test fun idsRoundTrip() {
        assertEquals(LanIds.Item(sourceA, "series", "42"), LanIds.parse("$sourceA:sr:42"))
        assertNull(LanIds.parse("not an id")); assertEquals("$sourceA:ch:7", LanIds.local(sourceA, "channel", "7"))
    }
}
