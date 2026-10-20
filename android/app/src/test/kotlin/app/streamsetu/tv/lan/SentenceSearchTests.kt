package app.streamsetu.tv.lan

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.MovieEntity
import app.streamsetu.core.data.db.PeopleIndex
import app.streamsetu.core.data.db.SourceEntity
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class SentenceSearchTests {
    private lateinit var db: AppDatabase

    @Before fun setUp() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext<Context>(), AppDatabase::class.java).allowMainThreadQueries().build()
        PeopleIndex.create(db.openHelper.writableDatabase)
        runBlocking { db.sources().upsert(SourceEntity("a", "A", "XTREAM", "http://x", "u", null, true, 0, "OK", 0, false)) }
    }
    @After fun tearDown() { db.close() }

    private fun movie(id: String, title: String, year: Int?, rating: String? = null) = MovieEntity(id, "a", null, title, null, year, rating, null, "ref", 1)
    private suspend fun find(text: String = "", people: List<String> = emptyList(), year: Int = 0, language: String = "", minRating: Double = 0.0, unwatched: Int = 0) =
        db.catalog().moviesForSentence(listOf("a"), text, people, year, 0, language, "", "", "", minRating, unwatched, 0, 0L, 50).map { it.id }

    @Test fun filtersCombineAndOnlyWhatMatchesEveryOneStays() = runBlocking {
        db.catalog().putMovies(listOf(movie("1", "Salaar (Telugu)", 2023, "8.1"), movie("2", "Kalki (Telugu)", 2024, "7.0"), movie("3", "Jawan (Hindi)", 2023, "7.5")))
        assertEquals(listOf("1"), find(year = 2023, language = "Telugu"))
        assertEquals(listOf("1", "3").sorted(), find(year = 2023).sorted())
        assertEquals(listOf("1"), find(minRating = 8.0))
        assertEquals(listOf("2"), find(text = "kalki"))
    }

    @Test fun aWatchedFilmIsLeftOutOfUnwatchedAndSomebodyInItFindsIt() = runBlocking {
        db.catalog().putMovies(listOf(movie("1", "Sarkaru Vaari Paata", 2022), movie("2", "Another Film", 2022)))
        db.openHelper.writableDatabase.execSQL("INSERT INTO watch_log(itemId, kind, title, playedAt) VALUES('2', 'MOVIE', 'Another Film', 1)")
        assertEquals(listOf("1"), find(unwatched = 1))
        assertEquals(listOf("1"), find(text = "mahesh babu", people = listOf("1")))
    }
}
