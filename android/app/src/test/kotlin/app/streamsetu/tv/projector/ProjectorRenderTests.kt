package app.streamsetu.tv.projector

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.platform.testTag
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.LocalHighContrast
import app.streamsetu.tv.ui.components.PosterCard
import app.streamsetu.tv.ui.components.TvButton
import app.streamsetu.tv.ui.components.TvFocusStyle
import app.streamsetu.tv.ui.components.pageBackground
import app.streamsetu.tv.ui.screens.settings.ChoiceRow
import app.streamsetu.tv.ui.screens.settings.SettingGroup
import app.streamsetu.tv.ui.screens.settings.SettingRow
import app.streamsetu.tv.ui.screens.settings.ToggleRow
import app.streamsetu.tv.ui.theme.Accent
import app.streamsetu.tv.ui.theme.Theme
import app.streamsetu.tv.ui.theme.Tokens
import app.streamsetu.tv.ui.theme.UiScale
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/** Draws real components in Projector Mode and looks at the pixels. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1280dp-h720dp-mdpi")
open class ProjectorRenderTests {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    /** The pixels of the window as drawn (the real renderer of Robolectric's native graphics), cropped to one component by its position. */
    protected fun capture(tag: String): android.graphics.Bitmap {
        rule.waitForIdle()
        val root = rule.activity.window.decorView
        val whole = android.graphics.Bitmap.createBitmap(root.width.coerceAtLeast(1), root.height.coerceAtLeast(1), android.graphics.Bitmap.Config.ARGB_8888)
        root.draw(android.graphics.Canvas(whole))
        val b = rule.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot
        return android.graphics.Bitmap.createBitmap(whole, b.left.toInt().coerceAtLeast(0), b.top.toInt().coerceAtLeast(0), b.width.toInt().coerceAtMost(whole.width - b.left.toInt()), b.height.toInt().coerceAtMost(whole.height - b.top.toInt()))
    }
    @After fun reset() { Tokens.apply(Theme.AMOLED, Accent.BLUE, false) }

    protected fun white(p: Int) = (p ushr 24) >= 0xF0 && ((p shr 16) and 0xff) >= 0xF0 && ((p shr 8) and 0xff) >= 0xF0 && (p and 0xff) >= 0xF0

    @OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)
    @Test fun theFocusFrameIsFourPixelsWideLiesInsideTheComponentAndSurvivesAClippedEdge() {
        UiScale.apply(1280f, 720f); Tokens.apply(Theme.AMOLED, Accent.BLUE, true)
        rule.setContent {
            // The component sits flush in the corner of a parent that clips to its bounds, as a grid cell at the edge of a screen does.
            Box(Modifier.size(200.dp, 100.dp).clipToBounds().testTag("cell")) {
                CompositionLocalProvider(LocalHighContrast provides true) {
                    Focusable({}, Modifier.fillMaxSize().testTag("f"), shape = RoundedCornerShape(14.dp), container = Tokens.card, focusedContainer = Tokens.focusedSurface, style = TvFocusStyle.DENSE) { Label("Poster", 15.sp, Tokens.text) }
                }
            }
        }
        rule.onNodeWithTag("f").requestFocus(); rule.waitForIdle()
        val bmp = capture("cell")
        val w = bmp.width; val h = bmp.height; val my = h / 2; val mx = w / 2
        for (i in 0..3) { assertTrue("left edge column $i", white(bmp.getPixel(i, my))); assertTrue("right edge column $i", white(bmp.getPixel(w - 1 - i, my)))
            assertTrue("top edge row $i", white(bmp.getPixel(mx, i))); assertTrue("bottom edge row $i", white(bmp.getPixel(mx, h - 1 - i))) }
        assertFalse("the frame is 4 px, not wider", white(bmp.getPixel(5, my)) && white(bmp.getPixel(6, my)) && white(bmp.getPixel(7, my)))
    }

    @OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)
    @Test fun aRowWhoseFocusWasOnlyAFillGetsTheFrameToo() {
        UiScale.apply(1280f, 720f); Tokens.apply(Theme.AMOLED, Accent.BLUE, true)
        rule.setContent { Box(Modifier.size(400.dp, 60.dp).testTag("cell")) { SettingRow("Projector mode", "Detail", "Off", modifier = Modifier.testTag("row")) {} } }
        rule.onNodeWithTag("row").requestFocus(); rule.waitForIdle()
        val bmp = capture("cell")
        assertTrue(white(bmp.getPixel(1, bmp.height / 2))); assertTrue(white(bmp.getPixel(bmp.width / 2, 1)))
    }

    @Test fun withTheModeOffNothingChanges() {
        UiScale.apply(1280f, 720f); Tokens.apply(Theme.AMOLED, Accent.BLUE, false)
        rule.setContent { Box(Modifier.size(200.dp, 100.dp).testTag("cell")) { Focusable({}, Modifier.fillMaxSize().testTag("f"), container = Tokens.card, style = TvFocusStyle.DENSE) { } } }
        rule.waitForIdle()
        val bmp = capture("cell")
        val p = bmp.getPixel(bmp.width / 2, bmp.height / 2)
        assertEquals("the card is the AMOLED card colour", 0x0D, (p shr 16) and 0xff)
    }

    protected fun gallery(w: Int, h: Int, name: String) {
        UiScale.apply(w.toFloat(), h.toFloat()); Tokens.apply(Theme.AMOLED, Accent.BLUE, true)
        rule.setContent {
            CompositionLocalProvider(LocalHighContrast provides true) {
                Row(Modifier.size(w.dp, h.dp).testTag("screen").pageBackground().padding(Tokens.safeHorizontal), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    Column(Modifier.weight(0.4f)) { SettingGroup("Look") { ToggleRow("Projector mode", "Makes pages, cards, text and focus controls easier to see on projectors.", true) {}; ChoiceRow("Theme", "The colour of pages and cards.", listOf("a" to "Amoled black"), "a") {}; SettingRow("Poster size", "Standard", chevron = true, modifier = Modifier.testTag("focused")) {} } }
                    Row(Modifier.weight(0.6f), horizontalArrangement = Arrangement.spacedBy(16.dp)) { repeat(3) { PosterCard("Title $it", null, {}, progress = 0.4f, subtitle = "2024") }; TvButton("Play", {}, primary = true) }
                }
            }
        }
        rule.onNodeWithTag("focused").requestFocus(); rule.waitForIdle()
        val bmp = capture("screen")
        assertEquals(w, bmp.width); assertEquals(h, bmp.height)
        val dir = File("build/projector-screens").also { it.mkdirs() }
        File(dir, "$name.png").outputStream().use { bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        // The page is the slate, not black: the corner pixel is the Projector background.
        // (The page has a faint top-to-bottom lift, so the corner is the slate or a little above it.)
        val corner = bmp.getPixel(2, 2); val r = (corner shr 16) and 0xff; val g = (corner shr 8) and 0xff; val b = corner and 0xff
        assertTrue("corner is the slate, not black: $r,$g,$b", r in 0x15..0x20 && g in 0x1A..0x26 && b in 0x20..0x30)
        var whitePixels = 0; for (x in 0 until bmp.width step 2) for (y in 0 until bmp.height step 2) if (white(bmp.getPixel(x, y))) whitePixels++
        assertTrue("text and the frame are drawn in white ($whitePixels)", whitePixels > 50)
    }

    @Test fun galleryAt1280x720() = gallery(1280, 720, "gallery_1280x720")
}

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-mdpi")
class ProjectorRenderTests1080 : ProjectorRenderTests() {
    @Test fun galleryAt1920x1080() = gallery(1920, 1080, "gallery_1920x1080")
}
