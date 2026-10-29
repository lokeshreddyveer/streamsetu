package app.streamsetu.tv.ui

import androidx.compose.ui.test.requestFocus
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.ExitTransition
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GridView
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.Browse
import app.streamsetu.core.model.Folder
import app.streamsetu.tv.nav.FolderNav
import app.streamsetu.tv.ui.components.FolderActions
import app.streamsetu.tv.ui.components.FolderPanel
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.LocalFocusEnabled
import app.streamsetu.tv.ui.components.Shortcut
import app.streamsetu.tv.ui.components.folderEnter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * Entering Movies, Series or Live TV from the main sidebar: the folder column is asked for, the whole page beside it cannot take the remote (not even for a moment), and the page is
 * enabled only after Right or OK from the folders. The page here is built exactly the way the three screens build theirs (the same enabled flag around the same kind of row).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1280dp-h720dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class FolderFirstFocusTest {
    @get:Rule val rule = createComposeRule()

    private val noActions = object : FolderActions {
        override fun toggleFavorite(f: Folder) {}; override fun togglePinned(f: Folder) {}; override fun toggleHidden(f: Folder) {}; override fun toggleLocked(f: Folder) {}
        override fun rename(f: Folder, alias: String?) {}; override fun move(f: Folder, to: app.streamsetu.core.data.repo.MoveTo) {}; override fun restoreOrder() {}
        override fun resetPosition(f: Folder) {}; override fun resetFolder(f: Folder) {}; override fun createFolder(name: String) {}
        override fun isUnlocked(folderId: String) = true; override val hasPin = false; override fun checkPin(pin: String) = true; override fun setPin(pin: String) {}; override fun unlock(folderId: String) {}
    }
    private val contentFocusEvents = ArrayList<String>()
    private val folders = (1..8).map { Folder("f$it", "s", "Folder $it", it) }

    private fun enter(nav: FolderNav, requested: () -> Boolean, panelEntry: FocusRequester) {
        rule.setContent {
            CompositionLocalProvider(LocalFocusEnabled provides !(nav.open || requested())) {
                Row(Modifier.fillMaxSize()) {
                    AnimatedVisibility(nav.open, Modifier.fillMaxHeight(), enter = folderEnter(), exit = ExitTransition.None) {
                        CompositionLocalProvider(LocalFocusEnabled provides true) {
                            FolderPanel("Movies", listOf(Shortcut(Browse.All, "All", Icons.Filled.GridView)), folders, Browse.All, {}, noActions, Modifier.width(256.dp).fillMaxHeight(),
                                entry = panelEntry, onRight = { nav.hide(); true }, onConfirm = { nav.hide() })
                        }
                    }
                    Row(Modifier.fillMaxSize()) {
                        for (i in 0 until 4) Focusable({}, Modifier.testTag("content$i").size(154.dp, 230.dp), onFocus = { if (it) contentFocusEvents += "content$i" }) { Label("c$i") }
                    }
                }
            }
        }
    }

    /** Enters the page from the sidebar [times] times in a row, each time asking for the folders, trying everything that could give the page the remote, and then handing over. */
    private fun entries(times: Int) {
        val nav = FolderNav(); val panelEntry = FocusRequester(); var requested by mutableStateOf(true)
        enter(nav, { requested }, panelEntry)
        rule.waitForIdle()
        for (n in 1..times) {
            contentFocusEvents.clear()
            requested = true; nav.show(); rule.waitForIdle(); rule.mainClock.advanceTimeBy(300); rule.waitForIdle()
            // Everything that could hand the remote to the page while the folders are asked for: asking each card directly, a first-focus search, and a burst of keys.
            for (i in 0 until 4) runCatching { rule.onNodeWithTag("content$i").requestFocus() }
            rule.runOnIdle { runCatching { panelEntry.requestFocus() } }
            rule.waitForIdle()
            repeat(12) { k -> rule.onNode(isFocused()).performKeyInput { pressKey(if (k % 2 == 0) Key.DirectionDown else Key.DirectionUp) } }
            for (i in 0 until 4) runCatching { rule.onNodeWithTag("content$i").requestFocus() }
            rule.waitForIdle()
            assertEquals("entry $n: the page took the remote while the folders were open: $contentFocusEvents", emptyList<String>(), contentFocusEvents.toList())
            // Right (or OK on a folder): the folders go, the page is enabled, and the remote can go there.
            requested = false; nav.hide(); rule.waitForIdle(); rule.mainClock.advanceTimeBy(400); rule.waitForIdle()
            rule.onNodeWithTag("content0").requestFocus(); rule.waitForIdle()
            rule.onNodeWithTag("content0").assertIsFocused()
            assertTrue("entry $n: ${contentFocusEvents}", contentFocusEvents.isNotEmpty() && contentFocusEvents.first() == "content0")
        }
    }

    @Test fun moviesKeepTheRemoteOffThePageUntilTheFoldersHandItOver() = entries(5)
    @Test fun seriesKeepTheRemoteOffThePageUntilTheFoldersHandItOver() = entries(5)
    @Test fun liveTvKeepsTheRemoteOffThePageUntilTheFoldersHandItOver() = entries(5)

    private val root = generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "settings.gradle.kts").exists() }
    private fun source(name: String) = root.walkTopDown().first { it.name == name && "/src/main/" in it.path }.readText()

    @Test fun theThreeScreensGateTheirPageWithTheSameFlagAndKeepTheClaimUntilAFolderHasTheRemote() {
        for (screen in listOf("SectionScreen.kt", "LiveScreen.kt")) {
            val s = source(screen)
            assertTrue("$screen: the page is disabled while folders are open or requested", "LocalFocusEnabled provides !(folderNav.open || nav.foldersRequested)" in s)
            assertTrue("$screen: the folder column is its own enabled scope", "LocalFocusEnabled provides true" in s)
            assertTrue("$screen: the request is released only when a folder row holds the remote", "if (nav.foldersRequested && (folderFocused || !folderNav.open)) nav.foldersRequested = false" in s)
        }
        val nav = source("Navigation.kt")
        assertTrue("Live TV is a folder-first destination", "t == Tab.MOVIES || t == Tab.SERIES || t == Tab.LIVE" in nav)
        assertTrue(!nav.contains("liveFromSidebar"))
    }
}
