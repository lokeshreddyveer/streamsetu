package app.streamsetu.tv.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.repo.TitlePageText
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Accent
import app.streamsetu.tv.ui.theme.Theme
import app.streamsetu.tv.ui.theme.Tokens
import app.streamsetu.tv.ui.theme.UiScale
import org.junit.Assert.*
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

internal fun sampleTop(picker: String? = "English · 2 versions ▾", fav: Boolean = false, trailer: Boolean = true, play: FocusRequester? = null, onPicker: () -> Unit = {}, onFav: () -> Unit = {}, backdrop: String? = null, poster: String? = null, synopsis: String = "A long story. ".repeat(20)) = TitleTop(
    title = "Pokiri", backdrop = backdrop, poster = poster, meta = TitlePageText.metaLine(2006, "2h 48m", null, "FHD", "7.4"), pickerLabel = picker, onPicker = onPicker,
    playLabel = "Resume · 34m left", playProgress = 0.4f, onPlay = {}, playFocus = play,
    actions = buildList {
        add(TitleAction(Icons.Filled.Favorite, "Favourite", fav, "Favourite, " + if (fav) "on" else "off", "action-favourite", onFav))
        add(TitleAction(Icons.Filled.Bookmark, "Watch Later", false, "Watch Later, off", "action-later") {})
        if (trailer) add(TitleAction(Icons.Filled.Movie, "Trailer", tag = "action-trailer") {})
        add(TitleAction(Icons.Filled.Share, "Share", tag = "action-share") {})
    }, synopsis = synopsis, genres = listOf("Action", "Crime"), onBack = {}, onMenu = {})

private fun desc(s: String) = SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.ContentDescription, listOf(s))

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1280dp-h720dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class TitlePageUiTests {
    @get:Rule val rule = createComposeRule()
    @get:Rule val patient = PatientIdle()
    @Before fun setup() { UiScale.apply(1280f, 720f); Tokens.apply(Theme.AMOLED, Accent.BLUE, false) }
    @After fun reset() { Tokens.apply(Theme.AMOLED, Accent.BLUE, false) }
    private fun press(tag: String, k: Key) { rule.onNodeWithTag(tag).performKeyInput { pressKey(k) }; rule.waitForIdle() }

    @Test fun theLineIsQuietAndTheRatingIsCredible() {
        var junk by mutableStateOf(false)
        rule.setContent { TitleBody(false, if (junk) TitleTop("T", null, null, TitlePageText.metaLine(2006, null, null, null, "10.0"), null, {}, "Play", null, {}, null, emptyList(), null, emptyList()) else sampleTop()) }
        rule.onNodeWithTag("title-meta").assertTextEquals("2006 · 2h 48m · FHD · ★ 7.4")
        junk = true; rule.waitForIdle()
        rule.onNodeWithTag("title-meta").assertTextEquals("2006")
    }

    @Test fun versionPickerIsHiddenWithOneVersionAndOpensWithMore() {
        var opened = 0
        var picker by mutableStateOf<String?>(null)
        rule.setContent { TitleBody(false, sampleTop(picker = picker, onPicker = { opened++ })) }
        rule.onNodeWithTag("version-picker").assertDoesNotExist()
        picker = "English · 2 versions ▾"; rule.waitForIdle()
        rule.onNodeWithTag("version-picker").assertExists().performClick(); assertEquals(1, opened)
        rule.onNodeWithTag("version-picker").assert(desc("English · 2 versions, choose version"))
    }

    @Test fun actionRowShowsFiveOrFewerItemsWithStateAndNoTrailerWhenThereIsNone() {
        var fav by mutableStateOf(false)
        rule.setContent { TitleBody(false, sampleTop(fav = fav, trailer = false, onFav = { fav = !fav })) }
        rule.onNodeWithTag("action-trailer").assertDoesNotExist()
        rule.onNodeWithTag("action-favourite").assert(desc("Favourite, off")).performClick(); rule.waitForIdle()
        rule.onNodeWithTag("action-favourite").assert(desc("Favourite, on"))
        rule.onNodeWithText("Favourite").assertExists(); rule.onNodeWithText("Share").assertExists()
    }

    @Test fun detailsListWrapsAtALargeFontAndLinksOpenThePerson() {
        val opened = ArrayList<String>()
        val rows = TitlePageText.details("A Very Long Director Name Here", "Mahesh Babu, Anushka Shetty, Prakash Raj, Ali, Brahmanandam, Another Actor", "India", null, "2006-04-28", false)
        rule.setContent {
            val d = LocalDensity.current
            androidx.compose.runtime.CompositionLocalProvider(LocalDensity provides Density(d.density, 2.0f)) {
                Box(Modifier.width(360.dp)) { DetailsList(rows, false, { opened += it }, null) }
            }
        }
        rule.onNodeWithTag("details-list").assertIsDisplayed()
        val w = rule.onNodeWithTag("details-list").fetchSemanticsNode().size.width
        rule.onNodeWithTag("detail-Starring").fetchSemanticsNode().let { assertTrue("wraps inside the column", it.size.width <= w) }
        rule.onNodeWithTag("person-link-Mahesh Babu").performClick()
        assertEquals(listOf("Mahesh Babu"), opened)
        rule.onNodeWithTag("person-link-Mahesh Babu").assert(desc("Mahesh Babu, open page"))
    }

    @Test fun synopsisIsThreeLinesWithAMoreThatExpands() {
        rule.setContent { Synopsis("A long story. ".repeat(40), false) }
        rule.onNodeWithTag("synopsis-more").assertTextEquals("More").performClick(); rule.waitForIdle()
        rule.onNodeWithTag("synopsis-more").assertTextEquals("Less")
    }

    @Test fun noBackdropUsesThePosterWashNotAnEmptyBox() {
        rule.setContent { TitleHero(false, sampleTop(poster = "https://example.invalid/p.jpg")) }
        rule.onNodeWithTag("hero-poster-wash").assertExists()
    }
}

/** The remote on a television: Play first, the picker just above it, the five actions below it. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1280dp-h720dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class TitlePageFocusTests {
    @get:Rule val rule = createComposeRule()
    @get:Rule val patient = PatientIdle()
    @Before fun setup() { UiScale.apply(1280f, 720f); Tokens.apply(Theme.AMOLED, Accent.BLUE, false) }
    private fun press(tag: String, k: Key) { rule.onNodeWithTag(tag).performKeyInput { pressKey(k) }; rule.waitForIdle() }
    private fun focused(tag: String) = rule.onNode(isFocused() and (hasTestTag(tag) or hasAnyAncestor(hasTestTag(tag))), useUnmergedTree = true).assertExists()

    @Test fun focusOrderIsPlayThenPickerAboveAndActionsBelow() {
        val play = FocusRequester()
        rule.setContent { Column(Modifier.fillMaxWidth()) { TitleBody(true, sampleTop(play = play)) } }
        rule.runOnIdle { play.requestFocus() }
        rule.waitForIdle()
        focused("title-play")
        press("title-play", Key.DirectionUp); focused("version-picker")
        press("version-picker", Key.DirectionDown)
        focused("title-play")
        press("title-play", Key.DirectionDown)
        focused("action-favourite")
        press("action-favourite", Key.DirectionRight)
        focused("action-later")
    }

    @Test fun moreOnTheSynopsisIsFocusableOnTv() {
        rule.setContent { Synopsis("A long story. ".repeat(40), true) }
        rule.onNodeWithTag("synopsis-more").requestFocus(); rule.onNodeWithTag("synopsis-more").assertIsFocused()
        press("synopsis-more", Key.Enter); rule.onNodeWithTag("synopsis-more").assertTextEquals("Less")
    }
}
