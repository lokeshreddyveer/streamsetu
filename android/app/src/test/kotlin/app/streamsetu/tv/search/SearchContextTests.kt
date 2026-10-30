package app.streamsetu.tv.search

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.repo.SearchContext
import app.streamsetu.core.data.repo.SearchHistory
import app.streamsetu.tv.nav.SearchSession
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class SearchContextTests {
    private lateinit var h: SearchHistory
    private var who = "main|lib1"
    @Before fun setUp() {
        ApplicationProvider.getApplicationContext<Context>().getSharedPreferences("search-test", Context.MODE_PRIVATE).edit().clear().commit()
        h = SearchHistory(ApplicationProvider.getApplicationContext<Context>().getSharedPreferences("search-test", Context.MODE_PRIVATE)); h.contextOf = { who }; h.contextChanged()
    }
    private fun switchTo(w: String) { who = w; h.contextChanged() }

    @Test fun recentSearchesOfOneProfileAreNeverShownToAnother() {
        h.rememberIn("ALL", "adult thriller"); h.remember("adult thriller"); h.setLastIn("ALL", "adult thriller")
        switchTo("kid|lib1")
        assertTrue(h.recentIn("ALL").isEmpty()); assertTrue(h.recent.value.isEmpty()); assertEquals("", h.lastIn("ALL"))
        h.rememberIn("ALL", "cartoons")
        switchTo("main|lib1")
        assertEquals(listOf("adult thriller"), h.recentIn("ALL")); assertEquals(listOf("adult thriller"), h.recent.value)
    }

    @Test fun anotherLibraryOfTheSameProfileHasItsOwnHistoryAndEachScreenKeepsItsOwn() {
        h.rememberIn("MOVIES", "inception"); h.rememberIn("LIVE", "bbc")
        assertEquals(listOf("inception"), h.recentIn("MOVIES")); assertEquals(listOf("bbc"), h.recentIn("LIVE"))
        switchTo("main|lib2"); assertTrue(h.recentIn("MOVIES").isEmpty())
    }

    @Test fun theWordsLastTypedDoNotSurviveAChangeOfWho() {
        h.setLastIn("MOVIES", "secret"); assertEquals("secret", h.lastIn("MOVIES"))
        switchTo("kid|lib1"); assertEquals("", h.lastIn("MOVIES"))
        switchTo("main|lib1"); assertEquals("the words typed before the switch were forgotten, not parked", "", h.lastIn("MOVIES"))
    }

    @Test fun removingAProfileRemovesItsSearchesEverywhere() {
        switchTo("kid|lib1"); h.rememberIn("ALL", "kid words"); h.remember("kid words")
        switchTo("kid|lib2"); h.rememberIn("MOVIES", "more kid words")
        switchTo("main|lib1"); h.rememberIn("ALL", "main words")
        h.forgetProfile("kid")
        switchTo("kid|lib1"); assertTrue(h.recentIn("ALL").isEmpty()); assertTrue(h.recent.value.isEmpty())
        switchTo("kid|lib2"); assertTrue(h.recentIn("MOVIES").isEmpty())
        switchTo("main|lib1"); assertEquals("another profile's words stay", listOf("main words"), h.recentIn("ALL"))
    }

    @Test fun clearingRecentSearchesClearsOnlyTheCurrentProfilesList() {
        h.rememberIn("ALL", "a"); h.remember("aa"); switchTo("kid|lib1"); h.rememberIn("ALL", "bb"); h.remember("bb")
        h.clearIn("ALL"); h.clearHistory()
        assertTrue(h.recentIn("ALL").isEmpty()); switchTo("main|lib1"); assertEquals(listOf("a").filter { it.length >= 2 }, h.recentIn("ALL").filter { it.length >= 2 }); assertEquals(listOf("aa"), h.recent.value)
    }

    // ---- the context word and what a page holds

    @Test fun theContextWordChangesWithEveryPermissionAndOnlyThen() {
        val base = SearchContext.key("main", listOf("A", "B"), false, listOf("f1"), listOf("c1"))
        assertEquals("order does not matter", base, SearchContext.key("main", listOf("B", "A"), false, listOf("f1"), listOf("c1")))
        assertNotEquals("profile", base, SearchContext.key("kid", listOf("A", "B"), false, listOf("f1"), listOf("c1")))
        assertNotEquals("library or playlists", base, SearchContext.key("main", listOf("A"), false, listOf("f1"), listOf("c1")))
        assertNotEquals("kids or adult filter", base, SearchContext.key("main", listOf("A", "B"), true, listOf("f1"), listOf("c1")))
        assertNotEquals("folder relock", base, SearchContext.key("main", listOf("A", "B"), false, listOf("f1", "f2"), listOf("c1")))
        assertNotEquals("hidden channel", base, SearchContext.key("main", listOf("A", "B"), false, listOf("f1"), listOf("c1", "c2")))
    }

    @Test fun thePageForgetsWordsResultsPositionFocusAndWhatTheAiSuggestedWhenTheContextChanges() {
        val s = SearchSession().open("k")
        s.query = "words"; s.scrollIndex = 4; s.scrollOffset = 9; s.focusedId = "movie:1"; s.aiFor = "words"; s.aiAsked = true; s.aiNote = "note"
        s.forgetContext()
        assertEquals("", s.query); assertEquals(0, s.scrollIndex); assertNull(s.focusedId); assertNull(s.aiFor); assertFalse(s.aiAsked); assertNull(s.aiNote); assertTrue(s.aiFound.isEmpty())
    }

    // ---- the Search screen's wiring (source checks: the screen needs the whole app to run)

    private val screen get() = java.io.File("src/main/kotlin/app/streamsetu/tv/ui/screens/search/SearchContent.kt").readText()

    @Test fun resultsAreShownOnlyForTheContextTheyWereFoundUnderAndTheSearchRestartsWhenItChanges() {
        val t = screen
        assertTrue(t.contains("val results = if (shownCtx == ctx) resultsRaw else null"))
        assertTrue("the search effect is keyed on the context, so a change cancels the search in flight", t.contains("LaunchedEffect(query, tab, retryTick, ctx, asked)"))
        assertTrue("a change drops the words, position, focus and AI answer the page held", t.contains("held?.forgetContext(); session?.clear()"))
        assertTrue(java.io.File("src/main/kotlin/app/streamsetu/tv/ui/screens/search/SearchActions.kt").readText().contains("var found by remember(typed, ctx)"))
        val app = java.io.File("src/main/kotlin/app/streamsetu/tv/StreamSetuApp.kt").readText()
        for (w in listOf("profiles.activeId", "library.sourceIds", "parental.hideAdult", "folders.lockedIds(ContentKind.CHANNEL)", "folders.lockedIds(ContentKind.MOVIE)", "folders.lockedIds(ContentKind.SERIES)", "channelPrefs()")) assertTrue("$w is part of the context", app.contains(w))
        assertTrue("a removed profile takes its searches with it", app.contains("profiles.onRemoved = { search.forgetProfile(it) }"))
    }

    @Test fun focusInSearchIsDrivenByFramesNotByFixedWaits() {
        val t = screen
        val focusCode = t.lines().filter { it.contains("requestFocus") || it.contains("focusTarget") || it.contains("firstAction") }
        assertTrue("no delay() next to a focus request", Regex("delay\\(\\d+\\)\\s*;\\s*runCatching \\{[^}]*requestFocus").findAll(t).none())
        assertTrue(t.contains("requestFocusOnFrames(6, { requester.requestFocus() }") && t.contains("requestFocusOnFrames(8, { focusTarget.requestFocus() }") && t.contains("requestFocusOnFrames(8, { first.requestFocus() }"))
        val delays = Regex("delay\\((\\d+)\\)").findAll(t).map { it.groupValues[1] }.toList()
        assertEquals("the only wait left is the 150 ms typing pause, in the two search effects", listOf("150", "150"), delays)
        assertTrue(focusCode.isNotEmpty())
    }

    @Test fun rightIsNotSwallowedAndTheListsComeFromTheProgressiveSearch() {
        val t = screen
        assertFalse("a result row no longer eats DPAD Right", t.contains("Key.DirectionRight }"))
        assertTrue(t.contains("c.globalSearch.searchProgressive(query, tab, base)") && t.contains("c.globalSearch.search(query, tab, base, asked)"))
        assertTrue("one order for drawing, Best Match and Done", t.contains("shownOrder.filter") && !t.contains("SearchResultOrder.forEach"))
        assertEquals("only a section's own result handler sits in the Search page", 1, Regex("onProgramme = \\{ ch, start -> nav.openGuideAt").findAll(t).count())
    }
}
