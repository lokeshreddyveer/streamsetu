package app.streamsetu.tv.ui

import androidx.compose.runtime.*
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import app.streamsetu.core.data.repo.*
import app.streamsetu.core.model.Movie
import app.streamsetu.tv.ui.screens.*
import app.streamsetu.tv.ui.theme.Accent
import app.streamsetu.tv.ui.theme.Theme
import app.streamsetu.tv.ui.theme.Tokens
import app.streamsetu.tv.ui.theme.UiScale
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

internal object PersonSamples {
    private fun credit(id: Long, title: String, year: Int, tv: Boolean = false, rating: Double? = 7.2, pop: Double = id.toDouble()) = Credit(id, tv, title, null, year, "$year-03-01", null, rating, pop, "A story about $title.", "Role")
    private fun movie(id: String, title: String, year: Int) = Movie(id, "A", null, title, null, year, null, null, "ref:$id", 1L)
    val info = PersonInfo(7, "Mahesh Babu", "A very long biography. ".repeat(30), null, "Acting", "1975-08-09", null, "Chennai, India", listOf("Mahesh"), emptyList())
    val tiles = listOf(
        FilmTile(credit(1, "Pokiri", 2006), LibraryHit(movie("m1", "Pokiri", 2006), null, 2)),
        FilmTile(credit(2, "Dookudu", 2011), null),
        FilmTile(credit(3, "Businessman", 2012), null),
        FilmTile(credit(4, "Srimanthudu", 2015), LibraryHit(movie("m4", "Srimanthudu", 2015), null, 1)),
        FilmTile(credit(5, "Some Show", 2020, tv = true, rating = null), null),
        FilmTile(credit(6, "Maharshi", 2019), null),
    )
    val full = PersonPageState(info, tiles, false, null, true)
}

/** The person page with the remote: the two buttons, the grid, coming back to the poster that was opened. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1280dp-h720dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class PersonScreenFocusTests {
    @get:Rule val rule = createComposeRule()
    @get:Rule val patient = PatientIdle()
    @Before fun setup() { UiScale.apply(1280f, 720f); Tokens.apply(Theme.AMOLED, Accent.BLUE, false); PersonMemory.clear() }
    @After fun reset() { PersonMemory.clear() }
    private fun assertFilmFocused(tag: String) = rule.onNode(isFocused() and hasAnyAncestor(hasTestTag(tag)), useUnmergedTree = true).assertExists()
    private fun press(tag: String, k: Key) { rule.onNodeWithTag(tag).performKeyInput { pressKey(k) }; rule.waitForIdle() }

    private fun page(state: PersonPageState = PersonSamples.full, only: Boolean = false, kids: Boolean = false, opened: MutableList<String> = ArrayList(), set: (Boolean) -> Unit = {}) = rule.setContent {
        var libOnly by remember { mutableStateOf(only) }
        PersonContent("Mahesh Babu", null, state, true, libOnly, { libOnly = it; set(it) }, { opened += it.credit.title }, kids)
    }

    @Test fun leftAndRightMoveBetweenTheTwoButtonsAndDownReachesTheGrid() {
        page()
        rule.onNodeWithTag("seg-all").requestFocus(); rule.onNodeWithTag("seg-all").assertIsFocused()
        press("seg-all", Key.DirectionRight); rule.onNodeWithTag("seg-library").assertIsFocused()
        press("seg-library", Key.DirectionLeft); rule.onNodeWithTag("seg-all").assertIsFocused()
        press("seg-all", Key.DirectionDown); press("chip-Newest", Key.DirectionDown)          // the sort and filter chips are between the buttons and the grid
        assertFilmFocused("film-tv5")          // newest first: the series of 2020 leads
        press("film-tv5", Key.DirectionRight); assertFilmFocused("film-movie6")
    }

    @Test fun buttonsSpeakTheirCountAndSelection() {
        page()
        rule.onNodeWithTag("seg-all").assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.ContentDescription, listOf("All films, 6, selected")))
        rule.onNodeWithTag("seg-library").assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.ContentDescription, listOf("In your library, 2")))
        rule.onNodeWithTag("film-movie1").assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.ContentDescription, listOf("Pokiri, 2006, in your library, 2 versions")))
    }

    @Test fun inYourLibraryShowsOnlyMatchedTitlesAndRemembersTheChoice() {
        var saved: Boolean? = null
        page(set = { saved = it })
        rule.onNodeWithTag("seg-library").requestFocus(); press("seg-library", Key.Enter)
        assertEquals(true, saved)
        rule.onNodeWithTag("film-movie1").assertExists(); rule.onNodeWithTag("film-movie4").assertExists(); rule.onNodeWithTag("film-movie2").assertDoesNotExist()
    }

    @Test fun nothingInTheLibraryShowsAFriendlyLine() {
        page(PersonSamples.full.copy(tiles = PersonSamples.tiles.map { it.copy(hit = null) }), only = true)
        rule.onNodeWithTag("person-empty").assertExists()
        rule.onNodeWithText("None of Mahesh's films are in your library yet.").assertExists()
    }

    @Test fun aKidsProfileHasNoWayToBrowseBeyondTheLibrary() {
        page(kids = true)
        rule.onNodeWithTag("seg-all").assertDoesNotExist()
        rule.onNodeWithTag("film-movie2").assertDoesNotExist(); rule.onNodeWithTag("film-movie1").assertExists()
    }

    @Test fun notInYourLibraryOpensAnInfoSheetWithNoPlayButton() {
        val opened = ArrayList<String>()
        page(opened = opened)
        rule.onNodeWithTag("seg-all").requestFocus()
        press("seg-all", Key.DirectionDown); press("chip-Newest", Key.DirectionDown)
        press("film-tv5", Key.Enter)          // "Some Show" is not in the library
        rule.onNodeWithTag("film-sheet").assertExists()
        assertTrue("nothing opened a title page", opened.isEmpty())
        rule.onAllNodesWithText("Play", substring = true, ignoreCase = true).assertCountEquals(0)
        press("film-sheet-close", Key.Enter)
        rule.onNodeWithTag("film-sheet").assertDoesNotExist()
    }

    @Test fun voiceAndCameoCreditsAreTaggedGroupedAndActingOnlyHidesThem() {
        fun cr(id: Long, t: String, y: Int, role: String?, order: Int) = FilmTile(Credit(id, false, t, null, y, "$y-01-01", null, null, id.toDouble(), null, role, order), null)
        val tiles = listOf(cr(1, "Lead Film", 2015, "Pandu", 0), cr(2, "Narrated Film", 2020, "Narrator (voice)", 23), cr(3, "Cameo Film", 2019, "Cameo", 40))
        var acting by mutableStateOf(false)
        rule.setContent { PersonContent("Mahesh Babu", null, PersonPageState(PersonSamples.info, tiles, false, null, true), true, false, {}, {}, false, acting, { acting = it }) }
        rule.onNodeWithTag("person-grid").performScrollToNode(hasTestTag("secondary-head"))
        rule.onNodeWithTag("secondary-head").assertExists()
        rule.onNodeWithTag("tag-movie2", useUnmergedTree = true).assertExists(); rule.onNodeWithTag("tag-movie3", useUnmergedTree = true).assertExists(); rule.onNodeWithTag("tag-movie1", useUnmergedTree = true).assertDoesNotExist()
        rule.onNodeWithTag("as-movie1", useUnmergedTree = true).assertTextEquals("as Pandu")
        rule.onNodeWithTag("film-movie2").assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.ContentDescription, listOf("Narrated Film, 2020, narrator, not in your library")))
        rule.onNodeWithTag("person-grid").performScrollToIndex(0)
        rule.onNodeWithTag("seg-all").requestFocus()
        press("seg-all", Key.DirectionDown); rule.onNodeWithTag("chip-Acting only").performClick(); rule.waitForIdle()
        assertTrue(acting)
        rule.onNodeWithTag("film-movie2").assertDoesNotExist(); rule.onNodeWithTag("secondary-head").assertDoesNotExist(); rule.onNodeWithTag("film-movie1").assertExists()
        rule.onNodeWithTag("seg-all").assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.ContentDescription, listOf("All films, 1, selected")))
    }

    @Test fun comingBackFromATitleLandsOnTheSamePoster() {
        var shown by mutableStateOf(true)
        rule.setContent { if (shown) PersonContent("Mahesh Babu", null, PersonSamples.full, true, false, {}, { shown = false }, false) }
        rule.onNodeWithTag("seg-all").requestFocus()
        press("seg-all", Key.DirectionDown); press("chip-Newest", Key.DirectionDown)
        press("film-tv5", Key.DirectionRight); press("film-movie6", Key.DirectionRight)
        assertFilmFocused("film-movie4")
        press("film-movie4", Key.Enter)          // an In your library poster opens its page: this screen leaves
        rule.onNodeWithTag("film-movie4").assertDoesNotExist()
        shown = true; rule.waitForIdle(); rule.mainClock.advanceTimeBy(500); rule.waitForIdle()
        assertFilmFocused("film-movie4")          // back on the same poster
    }
}
