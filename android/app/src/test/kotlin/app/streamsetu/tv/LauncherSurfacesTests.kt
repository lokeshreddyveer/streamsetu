package app.streamsetu.tv

import app.streamsetu.core.model.MoviePlayable
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import app.streamsetu.tv.PrivacyFixture.Companion as F

/** What the launcher shows (widget, Play-next row) never names a restricted title, and nothing is added before the folder rules have been read. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class LauncherSurfacesTests {
    private lateinit var fx: PrivacyFixture
    @Before fun open() { fx = PrivacyFixture().build(); LauncherSurfaces.reset() }
    @After fun close() { LauncherSurfaces.reset(); fx.close() }

    private fun movie(id: String) = MoviePlayable(runBlocking { fx.catalog.movie(id)!! })

    @Test fun nothingIsAddedBeforeTheRulesAreRead() { assertFalse(LauncherSurfaces.allowed(movie(F.OPEN_FILM_A))) }

    @Test fun restrictedTitlesAndTheirTwinsAreRefusedAndOpenOnesAllowed() {
        runBlocking { LauncherSurfaces.refresh(fx.folders.visibility) }
        assertTrue(LauncherSurfaces.allowed(movie(F.OPEN_FILM_A)))
        for (id in F.restrictedMovies) assertFalse("$id", LauncherSurfaces.allowed(movie(id)))
    }
}
