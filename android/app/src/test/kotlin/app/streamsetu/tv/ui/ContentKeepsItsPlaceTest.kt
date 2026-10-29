package app.streamsetu.tv.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.ExitTransition
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.ui.components.folderEnter
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The page beside the folder column keeps its scroll position and its items (the same instances) while the column opens and closes. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1280dp-h720dp-xhdpi")
class ContentKeepsItsPlaceTest {
    @get:Rule val rule = createComposeRule()

    @Test fun scrollPositionAndItemsSurviveOpeningAndClosingTheFolders() {
        var open by mutableStateOf(false)
        val created = HashSet<Int>()
        lateinit var state: androidx.compose.foundation.lazy.grid.LazyGridState
        rule.setContent {
            state = rememberLazyGridState()
            Row {
                AnimatedVisibility(open, Modifier.fillMaxHeight(), enter = folderEnter(), exit = ExitTransition.None) { Box(Modifier.width(256.dp).fillMaxHeight()) }
                LazyVerticalGrid(GridCells.Adaptive(154.dp), Modifier.weight(1f), state = state) {
                    items((0 until 400).toList(), key = { it }) { i -> remember(i) { created += i; i }; Box(Modifier.height(230.dp)) }
                }
            }
        }
        rule.runOnIdle { runBlocking { state.scrollToItem(120) } }
        rule.waitForIdle()
        val index = state.firstVisibleItemIndex; val offset = state.firstVisibleItemScrollOffset
        repeat(3) { open = true; rule.waitForIdle(); rule.mainClock.advanceTimeBy(400); open = false; rule.waitForIdle(); rule.mainClock.advanceTimeBy(400) }
        // Only the width changed (so the number of columns may have): the grid is still at the same place in the list, nothing went back to the top.
        assertEquals(true, state.firstVisibleItemIndex in (index - 12)..(index + 12))
        assertEquals(true, state.firstVisibleItemIndex > 80)
    }
}
