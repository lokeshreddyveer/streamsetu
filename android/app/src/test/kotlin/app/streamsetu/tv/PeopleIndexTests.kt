package app.streamsetu.tv

import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.PeopleIndex
import app.streamsetu.core.data.repo.SearchText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class PeopleIndexTests {
    private lateinit var db: SupportSQLiteDatabase
    private val norm: (String) -> String = SearchText::normalize

    @Before fun open() {
        val config = SupportSQLiteOpenHelper.Configuration.builder(ApplicationProvider.getApplicationContext()).name(null)
            .callback(object : SupportSQLiteOpenHelper.Callback(1) {
                override fun onCreate(db: SupportSQLiteDatabase) {
                    db.execSQL("CREATE TABLE sources(id TEXT, enabled INTEGER, draft INTEGER)")
                    db.execSQL("CREATE TABLE movies(id TEXT, sourceId TEXT, categoryId TEXT, title TEXT, rating TEXT, addedAt INTEGER)")
                    db.execSQL("CREATE TABLE series(id TEXT, sourceId TEXT, categoryId TEXT, title TEXT, rating TEXT)")
                }
                override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) {}
            }).build()
        db = FrameworkSQLiteOpenHelperFactory().create(config).writableDatabase
        PeopleIndex.create(db)
        db.execSQL("INSERT INTO sources VALUES('s1', 1, 0)")
        db.execSQL("INSERT INTO movies VALUES('s1:mv:1', 's1', NULL, 'John Wick (2014)', '7.4', 2), ('s1:mv:2', 's1', NULL, 'The Matrix (1999)', '8.7', 1)")
        db.execSQL("INSERT INTO series VALUES('s1:sr:9', 's1', NULL, 'Some Show', '7.0')")
    }

    private fun find(vararg words: String, kinds: List<String> = listOf("MOVIE", "SERIES")) = PeopleIndex.hits(db, words.toList(), listOf("s1"), kinds, 20).map { it.itemId }.toSet()

    @Test fun aPersonIsFoundByAnyPartOfTheirName() {
        PeopleIndex.save(db, "s1:mv:1", "MOVIE", "s1", listOf("Keanu Reeves", "Chad Stahelski"), norm)
        PeopleIndex.save(db, "s1:mv:2", "MOVIE", "s1", listOf("Keanu Reeves", "Carrie-Anne Moss"), norm)
        assertEquals(setOf("s1:mv:1", "s1:mv:2"), find("keanu"))
        assertEquals(setOf("s1:mv:1", "s1:mv:2"), find("reeves", "keanu"))
        assertEquals(setOf("s1:mv:1"), find("stahelski"))
        assertEquals(setOf("s1:mv:2"), find("carrie", "anne"))
    }

    @Test fun tooLittleTypedFindsNobody() {
        PeopleIndex.save(db, "s1:mv:1", "MOVIE", "s1", listOf("Keanu Reeves"), norm)
        assertTrue(find("ke").isEmpty())
        assertTrue(find("eanu").isEmpty())            // a name is searched from the start of a word
    }

    @Test fun aSeriesCastIsFoundToo() {
        PeopleIndex.save(db, "s1:sr:9", "SERIES", "s1", listOf("Pedro Pascal"), norm)
        assertEquals(setOf("s1:sr:9"), find("pascal"))
        assertTrue(find("pascal", kinds = listOf("MOVIE")).isEmpty())       // only the kinds being searched
    }

    @Test fun moviesAskedAboutAreNotAskedAgain() {
        assertEquals(2, PeopleIndex.pendingMovies(db, 10).size)
        assertEquals("s1:mv:2", PeopleIndex.pendingMovies(db, 10).first().first)       // the better rated first
        PeopleIndex.save(db, "s1:mv:2", "MOVIE", "s1", emptyList(), norm)               // nobody named, but it was asked
        assertEquals(listOf("s1:mv:1"), PeopleIndex.pendingMovies(db, 10).map { it.first })
        assertEquals(1 to 2, PeopleIndex.progress(db))
    }

    @Test fun savingAgainReplacesTheNames() {
        PeopleIndex.save(db, "s1:mv:1", "MOVIE", "s1", listOf("Wrong Name"), norm)
        PeopleIndex.save(db, "s1:mv:1", "MOVIE", "s1", listOf("Keanu Reeves"), norm)
        assertTrue(find("wrong").isEmpty())
        assertEquals(setOf("s1:mv:1"), find("keanu"))
    }

    @Test fun aPlaylistThatKeepsFailingIsSkipped() {
        assertTrue(PeopleIndex.pendingMovies(db, 10, setOf("s1")).isEmpty())
    }

    @Test fun removingAPlaylistRemovesItsPeople() {
        PeopleIndex.save(db, "s1:mv:1", "MOVIE", "s1", listOf("Keanu Reeves"), norm)
        PeopleIndex.clear(db, "s1")
        assertTrue(find("keanu").isEmpty())
    }
}
