package app.streamsetu.tv

import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.semantics.getOrNull
import app.streamsetu.core.data.repo.smartmix.SmartMixState
import app.streamsetu.tv.ui.phone.PhonePoster
import app.streamsetu.tv.ui.screens.home.*
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import app.streamsetu.tv.PrivacyFixture.Companion as F

/** One menu for every tile: the same items in the same order on every screen and device; marker-only writes with Undo; a TalkBack action to reach the menu. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class TileMenuTests {
    @get:Rule val rule = createComposeRule()
    @get:Rule val patient = app.streamsetu.tv.ui.PatientIdle()
    private lateinit var fx: PrivacyFixture
    @Before fun open() { fx = PrivacyFixture().build() }
    @After fun close() = fx.close()

    private val all = HomeAction.entries
    private fun states(): List<TargetState> = buildList {
        for (kind in TargetKind.entries) for (cont in listOf(false, true)) for (res in listOf(false, true)) for (fav in listOf(false, true)) for (later in listOf(false, true))
            for (folder in listOf(false, true)) for (cast in listOf(false, true)) for (share in listOf(false, true)) for (fromList in listOf(false, true))
                add(TargetState(kind, inContinue = cont, isFavorite = fav, isWatchLater = later, hasResumePoint = res, hasFolder = folder, hasCast = cast, canShare = share, fromEpisodeList = fromList, hasNextEpisode = res, hasVariants = cast))
    }

    @Test fun everyMenuIsInTheSameGroupOrderAndOnlyOffersWhatApplies() {
        for (st in states()) {
            val a = actionsFor(st)
            assertEquals("no duplicates for $st", a.size, a.toSet().size)
            assertEquals("grouped in the one order for $st: $a", a.sortedBy { it.group().ordinal }, a)
            if (a.isNotEmpty()) assertTrue("a safe primary action first for $st", a.first().group() == MenuGroup.PLAY || st.kind == TargetKind.EPISODE && st.fromEpisodeList && a.first().group() == MenuGroup.PLAY)
            assertEquals("destructive last", a.filter { it.group() == MenuGroup.DESTRUCTIVE }, a.takeLastWhile { it.group() == MenuGroup.DESTRUCTIVE })
            if (st.kind == TargetKind.CHANNEL) assertTrue("a channel is never recommended or shared as a title", HomeAction.DONT_RECOMMEND !in a && HomeAction.SHARE !in a && HomeAction.GO_TO_CAST !in a && HomeAction.OPEN_FOLDER !in a)
            assertEquals(HomeAction.OPEN_FOLDER in a, st.hasFolder && (st.kind == TargetKind.MOVIE || st.kind == TargetKind.SERIES))
            assertEquals(HomeAction.SHARE in a, st.canShare && st.kind != TargetKind.CHANNEL && !(st.kind == TargetKind.EPISODE && st.fromEpisodeList))
            assertEquals(HomeAction.GO_TO_CAST in a, st.hasCast && st.kind != TargetKind.CHANNEL && !(st.kind == TargetKind.EPISODE && st.fromEpisodeList))
            if (st.kind == TargetKind.EPISODE && st.fromEpisodeList) assertFalse("an episode in a list has no title-level actions", HomeAction.DONT_RECOMMEND in a)
        }
        assertEquals("every action belongs to a group", all.size, all.map { it.group() }.size)
    }

    @Test fun theContinueWatchingCardOffersTheFullSet() {
        for (kind in listOf(TargetKind.MOVIE, TargetKind.EPISODE)) {
            val a = actionsFor(TargetState(kind, inContinue = true, hasResumePoint = true, hasCast = true, canShare = true))
            for (x in listOf(HomeAction.RESUME, HomeAction.DETAILS, HomeAction.REMOVE_FROM_CONTINUE, HomeAction.FAVORITE, HomeAction.WATCH_LATER, HomeAction.WATCH_PRIVATELY, HomeAction.DONT_RECOMMEND, HomeAction.SHARE, HomeAction.GO_TO_CAST)) assertTrue("$kind lacks $x: $a", x in a)
            assertEquals("remove is last", HomeAction.REMOVE_FROM_CONTINUE, a.last())
            assertTrue("don't recommend comes before share, share before remove", a.indexOf(HomeAction.DONT_RECOMMEND) < a.indexOf(HomeAction.SHARE) && a.indexOf(HomeAction.SHARE) < a.indexOf(HomeAction.REMOVE_FROM_CONTINUE))
        }
    }

    @Test fun aPosterTileGetsFolderCastAndDontRecommendAfterTheExistingActions() {
        val a = actionsFor(TargetState(TargetKind.MOVIE, hasFolder = true, hasCast = true))
        assertEquals(HomeAction.PLAY, a.first()); assertTrue(a.indexOf(HomeAction.DETAILS) < a.indexOf(HomeAction.OPEN_FOLDER) && a.indexOf(HomeAction.OPEN_FOLDER) < a.indexOf(HomeAction.FAVORITE) && a.indexOf(HomeAction.FAVORITE) < a.indexOf(HomeAction.DONT_RECOMMEND))
    }

    @Test fun dontRecommendWritesOnlyItsMarkerAndUndoTakesItAway() = runBlocking {
        val state = SmartMixState(fx.db, fx.folders.visibility)
        fun count(t: String) = fx.db.openHelper.readableDatabase.query("SELECT COUNT(*) FROM $t").use { it.moveToFirst(); it.getInt(0) }
        val progressBefore = count("progress"); val favBefore = count("favorites")
        assertTrue(state.dismiss("p1", "MOVIE", F.OPEN_FILM_A, "Open Film", F.OPEN_A, 2020))
        assertEquals(1, count("rec_dismissed")); assertEquals("progress untouched", progressBefore, count("progress")); assertEquals("favourites untouched", favBefore, count("favorites"))
        state.undismiss("p1", F.OPEN_FILM_A)
        assertEquals("undo takes exactly the marker away", 0, count("rec_dismissed"))
        assertFalse("nothing is written for a restricted title", state.dismiss("p1", "MOVIE", F.SECRET_A, "Secret Film", F.LOCKED_A, 2020)); assertEquals(0, count("rec_dismissed"))
    }

    @Test fun aCardWithAMenuOffersMoreOptionsToTalkBackAndItOpensTheSameMenu() {
        var opened = 0
        rule.setContent { PhonePoster("Open Film", null, {}, onLong = { opened++ }, itemId = "x") }
        val node = rule.onNode(SemanticsMatcher("has a custom action") { n -> n.config.getOrNull(SemanticsActions.CustomActions)?.any { it.label == "More options" } == true })
        node.assertExists()
        val action: CustomAccessibilityAction = node.fetchSemanticsNode().config.getOrNull(SemanticsActions.CustomActions)!!.first { it.label == "More options" }
        rule.runOnUiThread { action.action() }
        assertEquals(1, opened)
    }

    @Test fun aCardWithoutAMenuOffersNoActionToTalkBack() {
        rule.setContent { PhonePoster("Open Film", null, {}, itemId = "x") }
        rule.onAllNodes(androidx.compose.ui.test.hasText("Open Film")).assertCountEquals(2)
        assertTrue(rule.onAllNodes(SemanticsMatcher("has a custom action") { n -> n.config.getOrNull(SemanticsActions.CustomActions)?.isNotEmpty() == true }).fetchSemanticsNodes().isEmpty())
    }

    // ---- no hand-written tile menus remain ----
    private fun mainFiles() = java.io.File("src/main/kotlin").walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()

    @Test fun everyTileMenuComesFromTheSharedTable() {
        val labelWords = listOf("\"Watch privately\"", "Add to favorites", "Remove from favorites", "\"Watch later\"", "Add to Watch Later", "Move to front of favorites")
        val owners = mainFiles().filter { f -> val t = f.readText(); labelWords.any { it in t } }.map { it.name }.sorted()
        // Only the shared menu (HomeMenu.kt: the labels and the queue and order items), the player's own controls and the detail pages' own "more" menus say these words.
        val allowed = setOf("HomeMenu.kt", "PlayerScreen.kt", "DetailScreens.kt", "SectionScreen.kt")
        assertTrue("hand-written tile menus in ${owners - allowed}", (owners - allowed).isEmpty())
        // The phone's long presses and the television's all open HomeMenuHost: no phone file builds a sheet of title actions any more.
        for (name in listOf("PhoneHome.kt", "PhoneBrowse.kt")) {
            val t = mainFiles().first { it.name == name }.readText()
            assertTrue("$name opens the shared menu", "HomeMenuHost(" in t)
            assertFalse("$name still builds a title sheet by hand", Regex("SheetItem\\(\"(Play|Open|Details|Watch privately)\"").containsMatchIn(t))
        }
        // Every kind of tile reaches it: posters without a menu of their own (search, person, folder rows, related) through the root's LocalTileMenu.
        val root = mainFiles().first { it.name == "TileMenuRoot.kt" }.readText(); assertTrue("HomeMenuHost(" in root && "actionsFor(" in root)
        assertTrue("LocalTileMenu" in mainFiles().first { it.name == "PhoneKit.kt" }.readText())
        assertTrue("LocalTileMenu" in mainFiles().first { it.name == "SearchContent.kt" }.readText()); assertTrue("LocalTileMenu" in mainFiles().first { it.name == "PersonContent.kt" }.readText())
        // The TalkBack actions of a card use the same labels as the menu.
        assertTrue("homeActionLabel(" in root)
    }

    @Test fun everyMenuItemIsAScreenReaderActionOfItsOwnWithTheMenusLabel() {
        val ran = ArrayList<String>()
        val labels = actionsFor(TargetState(TargetKind.MOVIE, hasFolder = true, hasCast = true, canShare = true)).map { homeActionLabel(it) }
        val source = app.streamsetu.tv.ui.phone.TileActionSource(1) { _ -> labels.map { l -> app.streamsetu.tv.ui.phone.TileA11yAction(l) { ran += l } } }
        rule.setContent {
            androidx.compose.runtime.CompositionLocalProvider(app.streamsetu.tv.ui.phone.LocalScreenReaderOn provides true, app.streamsetu.tv.ui.phone.LocalTileActions provides source, app.streamsetu.tv.ui.phone.LocalTileMenu provides { _: String -> ran += "menu" }) {
                PhonePoster("Open Film", null, {}, itemId = "x")
            }
        }
        rule.waitForIdle()
        val node = rule.onNode(SemanticsMatcher("has custom actions") { n -> n.config.getOrNull(SemanticsActions.CustomActions)?.isNotEmpty() == true })
        val actions = node.fetchSemanticsNode().config.getOrNull(SemanticsActions.CustomActions)!!
        assertEquals("every item plus More options", labels + "More options", actions.map { it.label })
        assertTrue("Don't recommend this" in labels && "Open folder" in labels && "Go to cast" in labels)
        rule.runOnUiThread { actions.forEach { it.action() } }
        assertEquals(labels + "menu", ran)
    }
}
