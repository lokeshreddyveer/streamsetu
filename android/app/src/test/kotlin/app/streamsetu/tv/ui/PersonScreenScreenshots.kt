package app.streamsetu.tv.ui

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.ui.screens.PersonContent
import app.streamsetu.tv.ui.screens.PersonMemory
import app.streamsetu.tv.ui.screens.PersonPageState
import app.streamsetu.tv.ui.theme.Accent
import app.streamsetu.tv.ui.theme.Theme
import app.streamsetu.tv.ui.theme.Tokens
import app.streamsetu.tv.ui.theme.UiScale
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/** The person page as drawn on a television and on a phone, in two themes (Robolectric's native renderer; synthetic data, no network). Set SCREENSHOT_DIR to keep the PNG files. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1280dp-h720dp-mdpi")
class PersonScreenScreenshots {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()
    @After fun reset() { Tokens.apply(Theme.AMOLED, Accent.BLUE, false); PersonMemory.clear() }

    private fun scene(tv: Boolean, theme: Theme, accent: Accent, name: String, state: PersonPageState = PersonSamples.full) {
        UiScale.apply(1280f, 720f); Tokens.apply(theme, accent, false)
        rule.setContent { Box(if (tv) Modifier.width(1280.dp).height(720.dp) else Modifier.width(390.dp).height(780.dp)) { PersonContent("Mahesh Babu", null, state, tv, false, {}, {}) } }
        rule.waitForIdle()
        val root = rule.activity.window.decorView
        val bmp = android.graphics.Bitmap.createBitmap(root.width.coerceAtLeast(1), root.height.coerceAtLeast(1), android.graphics.Bitmap.Config.ARGB_8888)
        root.draw(android.graphics.Canvas(bmp))
        System.getenv("SCREENSHOT_DIR")?.let { d -> File(d).mkdirs(); File(d, "$name.png").outputStream().use { bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) } }
        var lit = 0; val bg = bmp.getPixel(0, 0)
        for (y in 0 until bmp.height step 4) for (x in 0 until bmp.width step 4) if (bmp.getPixel(x, y) != bg) lit++
        assertTrue("$name drew something ($lit)", lit > 300)
    }

    @Test fun tvAmoledBlue() = scene(true, Theme.AMOLED, Accent.BLUE, "tv-person-amoled-blue")
    @Test fun tvCinematicEmber() = scene(true, Theme.CINEMATIC, Accent.EMBER, "tv-person-cinematic-ember")
    @Test fun phoneAmoledBlue() = scene(false, Theme.AMOLED, Accent.BLUE, "phone-person-amoled-blue")
    @Test fun phoneCinematicEmber() = scene(false, Theme.CINEMATIC, Accent.EMBER, "phone-person-cinematic-ember")
    @Test fun phoneLoadingSkeleton() = scene(false, Theme.AMOLED, Accent.BLUE, "phone-person-loading", PersonPageState())
    @Test fun phoneOfflineFallback() = scene(false, Theme.AMOLED, Accent.BLUE, "phone-person-fallback", PersonSamples.full.copy(info = null, fullList = false, note = app.streamsetu.tv.ui.screens.PersonNotes.NO_KEY))
}
