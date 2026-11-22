package app.streamsetu.tv

import app.streamsetu.core.data.db.PeopleIndex
import app.streamsetu.core.data.repo.SearchText
import app.streamsetu.tv.ui.screens.personTitles
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import app.streamsetu.tv.PrivacyFixture.Companion as F

/** A person's page: only titles of the library, each once with its language versions, and nothing restricted or with a copy in a restricted folder. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class PersonTitlesTests {
    private lateinit var fx: PrivacyFixture
    @Before fun open() {
        fx = PrivacyFixture().build()
        val raw = fx.db.openHelper.writableDatabase
        for ((id, src) in listOf(F.OPEN_FILM_A to "A", F.OPEN_FILM_B to "B", "m-plain-a" to "A", F.SECRET_A to "A", F.SECRET_B to "B", F.SPLIT_A to "A", F.HIDDEN_FILM_A to "A", F.ADULT_FILM_A to "A", F.LONE_B to "B"))
            PeopleIndex.save(raw, id, "MOVIE", src, listOf("Ann Actor"), SearchText::normalize)
        PeopleIndex.save(raw, F.SERIES_SECRET, "SERIES", "A", listOf("Ann Actor"), SearchText::normalize)
    }
    @After fun close() = fx.close()

    private fun titles(name: String) = runBlocking { personTitles(fx.db, fx.catalog, fx.folders.visibility, listOf("A", "B"), name) }

    @Test fun eachTitleAppearsOnceWithItsVersionsAndNothingRestrictedLeaks() {
        val t = titles("Ann Actor")
        val names = t.map { it.title }.sorted()
        assertEquals(listOf("Open Film", "Plain Story"), names)
        assertEquals("the two playlists' copies are one title", 2, t.first { it.title == "Open Film" }.versions)
        val ids = t.map { it.id }.toSet()
        assertTrue("restricted leaked: ${ids intersect F.restrictedMovies}", (ids intersect F.restrictedMovies).isEmpty())
        assertFalse(F.SERIES_SECRET in ids)
    }

    @Test fun anUnknownPersonOrAShortNameFindsNothing() {
        assertTrue(titles("Nobody Known").isEmpty())
        assertTrue(titles("An").isEmpty())
    }
}
