package app.streamsetu.tv.ui

import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.safeFocusRestorer
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Home shelves joining, leaving and swapping while the remote is on a card (what a library import does to the page). It must not stop the app. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
@OptIn(ExperimentalTestApi::class)
class RailChurnTest {
    @get:Rule val rule = createComposeRule()
    @get:Rule val patient = app.streamsetu.tv.ui.PatientIdle()

    private val rails = mutableStateListOf<Int>().also { it.addAll(0 until 6) }

    @Test fun shelvesSwapUnderTheRemoteWithoutReleasingTwice() {
        rule.setContent {
            LazyColumn(Modifier.width(1200.dp).height(800.dp)) {
                items(rails.toList(), key = { "rail:$it" }) { r ->
                    Label("Shelf $r")
                    run {
                        LazyRow(Modifier.safeFocusRestorer()) {
                            items((0 until 8).toList(), key = { "$r-$it" }) { i -> Focusable({}, Modifier.testTag("card-$r-$i").width(160.dp).height(90.dp)) { Label("Card $r $i") } }
                        }
                    }
                }
            }
        }
        rule.onNodeWithTag("card-1-2").requestFocus(); rule.waitForIdle()
        repeat(12) { n ->
            // The remote leaves a shelf (its focus restorer pins that shelf's page item), then that shelf leaves the page while others
            // change places and new ones join: the order of events behind the "Release should only be called once" stop.
            val away = rails.firstOrNull { it != rails.first() } ?: rails.first()
            runCatching { rule.onNodeWithTag("card-$away-1").requestFocus() }; rule.waitForIdle()
            val back = rails.first()
            runCatching { rule.onNodeWithTag("card-$back-3").requestFocus() }; rule.waitForIdle()
            rails.remove(away); rails.remove(back)
            rails.add(100 + n); rails.add(0.coerceAtMost(rails.size), 200 + n)
            rails.addAll(listOf(away, back).filter { n % 2 == 0 })
            rails.shuffle(java.util.Random(n.toLong())); while (rails.size > 9) rails.removeAt(rails.size - 1)
            rule.waitForIdle()
            rails.firstOrNull()?.let { r -> runCatching { rule.onNodeWithTag("card-$r-0").requestFocus() } }
            rule.waitForIdle()
        }
    }
}
