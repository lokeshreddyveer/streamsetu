package app.streamsetu.tv

import app.streamsetu.core.data.repo.SearchScope
import app.streamsetu.core.model.ContentKind
import kotlinx.coroutines.flow.first
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
 * Privacy matrix, existing surfaces (step A1): a title in a locked, hidden or adult-blocked folder, or whose twin copy is in one, never comes out of search, suggestions, versions, similar titles,
 * the banner mix or a shared link; and the count of a locked folder is not shown. Written against the repositories the screens use.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class PrivacyLeakTests {
    private lateinit var fx: PrivacyFixture
    @Before fun open() { fx = PrivacyFixture().build() }
    @After fun close() = fx.close()

    private fun searchIds(q: String, kids: Boolean = false): Set<String> = runBlocking {
        fx.parental.setKids(kids)
        val r = fx.search.search(q, SearchScope(setOf(ContentKind.MOVIE, ContentKind.SERIES)))
        (r.movies.map { it.id } + r.series.map { it.id }).toSet()
    }

    @Test fun searchNeverReturnsALockedFolderTitle() { val ids = searchIds("film"); assertFalse(ids.toString(), F.SECRET_A in ids) }

    @Test fun searchNeverReturnsTheTwinOfALockedFolderTitle() { val ids = searchIds("film"); assertFalse("the same folder in the second playlist is locked too: $ids", F.SECRET_B in ids) }

    @Test fun searchNeverReturnsAHiddenFolderTitle() { val ids = searchIds("film"); assertFalse(ids.toString(), F.HIDDEN_FILM_A in ids) }

    @Test fun searchNeverReturnsTheTwinOfAHiddenFolderTitle() { val ids = searchIds("film"); assertFalse(ids.toString(), F.HIDDEN_FILM_B in ids) }

    @Test fun searchHidesAdultFoldersWhileAdultContentIsHidden() { val ids = searchIds("film"); assertFalse(ids.toString(), F.ADULT_FILM_A in ids || F.ADULT_FILM_B in ids) }

    @Test fun aKidsProfileNeverSeesAdultFoldersInSearchEvenWithTheAdultSwitchOff() {
        fx.parental.setHideAdult(false)
        val ids = searchIds("film", kids = true)
        assertFalse(ids.toString(), F.ADULT_FILM_A in ids || F.ADULT_FILM_B in ids)
    }

    @Test fun suggestionsNeverComeFromRestrictedFolders() = runBlocking {
        val s = fx.search.suggestions("hidden").map { it.lowercase() } + fx.search.suggestions("adult").map { it.lowercase() } + fx.search.suggestions("secret").map { it.lowercase() }
        assertTrue(s.toString(), s.isEmpty())
    }

    @Test fun otherCopiesOfATitleNeverIncludeARestrictedCopy() = runBlocking {
        val ids = fx.search.movieVariants("Hidden Film").map { it.id } + fx.search.movieVariants("Adult Film").map { it.id } + fx.search.movieVariants("Secret Film").map { it.id }
        assertTrue(ids.toString(), ids.isEmpty())
    }

    @Test fun similarTitlesNeverIncludeARestrictedCopy() = runBlocking {
        val open = fx.catalog.movie(F.OPEN_FILM_A)!!
        val ids = fx.search.similarMovies(open, null) { null }.first().map { it.item.id }.toSet()
        assertTrue(ids.toString(), ids.none { it in F.restrictedMovies })
    }

    @Test fun similarTitlesOfAKidsProfileNeverIncludeAdultFolders() = runBlocking {
        fx.parental.setHideAdult(false); fx.parental.setKids(true)
        val open = fx.catalog.movie(F.OPEN_FILM_A)!!
        val ids = fx.search.similarMovies(open, null) { null }.first().map { it.item.id }.toSet()
        assertFalse(ids.toString(), F.ADULT_FILM_A in ids || F.ADULT_FILM_B in ids)
    }

    @Test fun theBannerMixNeverContainsARestrictedTitleOrItsTwin() = runBlocking {
        repeat(25) {
            val ids = fx.catalog.featured(12).map { it.id }.toSet()
            assertTrue("banner: $ids", ids.none { it in F.restrictedMovies || it == F.SERIES_SECRET })
        }
    }

    @Test fun aSharedLinkNeverResolvesToARestrictedTitle() = runBlocking {
        val hits = listOf("Secret Film", "Hidden Film", "Adult Film", "Split Title").flatMap { fx.catalog.search(it, 1).movies }.map { it.id }
        assertTrue("a link by name resolved to: $hits", hits.none { it in setOf(F.SECRET_A, F.SECRET_B, F.HIDDEN_FILM_A, F.HIDDEN_FILM_B, F.ADULT_FILM_A, F.ADULT_FILM_B, F.SPLIT_B) })
    }

    @Test fun theCountOfALockedFolderIsNotShown() = runBlocking {
        val list = fx.folders.folders(ContentKind.MOVIE).first()
        val locked = list.first { it.id == F.LOCKED_A }
        assertEquals("a locked folder shows its name and a lock, no number", 0, locked.count)
        assertTrue(list.first { it.id == F.OPEN_A }.count > 0)
    }
}
