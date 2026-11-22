package app.streamsetu.tv

import app.streamsetu.core.data.db.ProgressEntity
import app.streamsetu.core.data.repo.LinkTarget
import app.streamsetu.core.data.repo.Visibility.Surface
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
 * Privacy matrix, the rules themselves (step A1): which surface may show what, the toggle sequence lock / unlock / relock, a title whose other copy is restricted, a shared link, and that
 * Continue Watching's data is never touched by any of it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class PrivacyMatrixTests {
    private lateinit var fx: PrivacyFixture
    @Before fun open() { fx = PrivacyFixture().build() }
    @After fun close() = fx.close()

    private fun movie(id: String) = runBlocking { fx.catalog.movie(id)!! }
    private suspend fun snap(s: Surface) = fx.folders.visibility.snapshot(s)

    @Test fun historyHidesLockedAndAdultFoldersButNotHiddenOnes() = runBlocking {
        val h = snap(Surface.HISTORY)
        assertFalse(h.movieOk(movie(F.SECRET_A))); assertFalse(h.movieOk(movie(F.SECRET_B)))          // the twin's folder is locked too
        assertFalse(h.movieOk(movie(F.ADULT_FILM_A)))
        assertTrue("a hidden folder is hidden from discovery, not from what was already watched", h.movieOk(movie(F.HIDDEN_FILM_A)))
        assertTrue(h.movieOk(movie(F.OPEN_FILM_A)))
        assertTrue("the history surface has no title-copy rule", h.movieOk(movie(F.SPLIT_A)))
    }

    @Test fun anUnlockBringsHistoryBackButNeverWidensARecommendation() = runBlocking {
        fx.folders.unlock(F.LOCKED_A); fx.folders.unlock(F.LOCKED_B)
        assertTrue("entries return when unlocked", snap(Surface.HISTORY).movieOk(movie(F.SECRET_A)))
        assertTrue(snap(Surface.SEARCH).movieOk(movie(F.SECRET_A)))
        val r = snap(Surface.RECOMMEND)
        assertFalse("a locked folder stays out of every recommendation even while unlocked", r.movieOk(movie(F.SECRET_A)))
        repeat(15) { assertTrue(fx.catalog.featured(12).none { it.id in F.restrictedMovies }) }
        fx.folders.lockAgain()
        assertFalse(snap(Surface.HISTORY).movieOk(movie(F.SECRET_A)))
    }

    @Test fun aTitleIsRestrictedForRecommendationsWhenAnyCopyIs() = runBlocking {
        val r = snap(Surface.RECOMMEND)
        assertFalse("copy in an open folder, other copy in a locked one", r.movieOk(movie(F.SPLIT_A)))
        assertFalse("the other copy sits in a folder with a different name", r.movieOk(movie(F.LONE_B)))
        assertTrue(snap(Surface.SEARCH).movieOk(movie(F.LONE_B)))          // search is not a recommendation: a title found by name opens
        assertTrue(r.movieOk(movie(F.OPEN_FILM_A)) && r.movieOk(movie(F.OPEN_FILM_B)))
    }

    @Test fun lockingAFolderTakesEffectAtOnceOnEverySurface() = runBlocking {
        val before = fx.folders.restrictRev.first()
        assertTrue(snap(Surface.RECOMMEND).movieOk(movie("m-plain-a")))
        fx.folders.toggleLocked(ContentKind.MOVIE, fx.folder(F.OPEN_A, "A", PrivacyFixture.names["open"]!!))
        assertNotEquals("the revision screens watch moved", before, fx.folders.restrictRev.first())
        assertFalse(snap(Surface.RECOMMEND).movieOk(movie("m-plain-a")))
        assertFalse("the twin playlist's folder of the same name is locked with it", snap(Surface.SEARCH).movieOk(movie("m-plain-b")))
        assertFalse(snap(Surface.HISTORY).movieOk(movie("m-plain-a")))
        repeat(10) { assertTrue(fx.catalog.featured(12).none { it.id.startsWith("m-plain") || it.id.startsWith("m-open") || it.id.startsWith("m-other") || it.id == F.SPLIT_A }) }
        assertTrue(fx.search.suggestions("plain").isEmpty())
    }

    @Test fun hidingAFolderTakesItOutOfSearchAndRecommendationsAtOnce() = runBlocking {
        fx.folders.toggleHidden(ContentKind.MOVIE, fx.folder(F.OPEN_A, "A", PrivacyFixture.names["open"]!!))
        assertFalse(snap(Surface.SEARCH).movieOk(movie("m-plain-a"))); assertFalse(snap(Surface.RECOMMEND).movieOk(movie("m-plain-a")))
        assertTrue("watched titles are still listed", snap(Surface.HISTORY).movieOk(movie("m-plain-a")))
    }

    @Test fun theBannerShowsOneCardForATitleThatSitsInBothTwinPlaylists() = runBlocking {
        repeat(25) {
            val ids = fx.catalog.featured(12).map { it.id }
            assertFalse("both copies of one film: $ids", F.OPEN_FILM_A in ids && F.OPEN_FILM_B in ids)
            assertFalse(ids.toString(), "m-plain-a" in ids && "m-plain-b" in ids)
        }
    }

    @Test fun aKidsProfileHidesAdultFoldersEverywhereEvenWithTheAdultSwitchOff() = runBlocking {
        fx.parental.setHideAdult(false)
        assertTrue(snap(Surface.HISTORY).movieOk(movie(F.ADULT_FILM_A)))
        fx.parental.setKids(true)
        assertFalse(snap(Surface.HISTORY).movieOk(movie(F.ADULT_FILM_A))); assertFalse(snap(Surface.SEARCH).movieOk(movie(F.ADULT_FILM_B))); assertFalse(snap(Surface.RECOMMEND).movieOk(movie(F.ADULT_FILM_A)))
    }

    @Test fun aSharedLinkOpensALockedTitlesFolderNeverTheTitle() = runBlocking {
        assertTrue(fx.catalog.linkTarget("movie", "Open Film") is LinkTarget.Movie)
        val locked = fx.catalog.linkTarget("movie", "Secret Film")
        assertTrue(locked.toString(), locked is LinkTarget.Locked && locked.folderId == F.LOCKED_A)
        assertEquals(LinkTarget.None, fx.catalog.linkTarget("movie", "Hidden Film"))
        assertEquals(LinkTarget.None, fx.catalog.linkTarget("movie", "Adult Film"))
        assertTrue(fx.catalog.linkTarget("series", "Secret Show") is LinkTarget.Locked)
        fx.folders.unlock(F.LOCKED_A)
        assertTrue("with the PIN given, the link plays", fx.catalog.linkTarget("movie", "Secret Film") is LinkTarget.Movie)
    }

    @Test fun theCountOfALockedFolderReturnsWithTheUnlock() = runBlocking {
        assertEquals(0, fx.folders.folders(ContentKind.MOVIE).first().first { it.id == F.LOCKED_A }.count)
        fx.folders.unlock(F.LOCKED_A)
        assertTrue(fx.folders.folders(ContentKind.MOVIE).first().first { it.id == F.LOCKED_A }.count > 0)
        fx.folders.lockAgain()
        assertEquals(0, fx.folders.folders(ContentKind.MOVIE).first().first { it.id == F.LOCKED_A }.count)
    }

    @Test fun theArtworkOfAFolderThatBecomesRestrictedIsNamedForEviction() = runBlocking {
        val urls = app.streamsetu.core.data.repo.RestrictedPictures.urlsIn(fx.db, fx.folders.visibility.excludedFolders(ContentKind.MOVIE, Surface.RECOMMEND))
        assertTrue(urls.toString(), "http://img/${F.SECRET_A}.jpg" in urls && "http://img/${F.SECRET_B}.jpg" in urls && "http://img/${F.HIDDEN_FILM_A}.jpg" in urls && "http://img/${F.ADULT_FILM_A}.jpg" in urls)
        assertFalse("pictures of open folders stay", "http://img/${F.OPEN_FILM_A}.jpg" in urls)
    }

    @Test fun continueWatchingDataIsNeverTouchedByAnyLockHideOrUnlock() = runBlocking {
        fx.db.user().putProgress(ProgressEntity(F.SECRET_A, "MOVIE", null, 600_000, 6_000_000, 1_000, false))
        fx.db.user().putProgress(ProgressEntity(F.OPEN_FILM_A, "MOVIE", null, 300_000, 6_000_000, 2_000, false))
        val before = fx.db.user().allProgressNow().sortedBy { it.itemId }
        fx.folders.unlock(F.LOCKED_A); fx.folders.lockAgain()
        fx.folders.toggleHidden(ContentKind.MOVIE, fx.folder(F.OPEN_A, "A", PrivacyFixture.names["open"]!!))
        fx.folders.toggleLocked(ContentKind.MOVIE, fx.folder(F.OPEN_A, "A", PrivacyFixture.names["open"]!!))
        snap(Surface.HISTORY); snap(Surface.RECOMMEND)
        assertEquals("progress rows are identical", before, fx.db.user().allProgressNow().sortedBy { it.itemId })
        assertEquals(2, fx.db.user().continueWatching(50).first().size)          // the data still lists both; only the display filters
    }
}
