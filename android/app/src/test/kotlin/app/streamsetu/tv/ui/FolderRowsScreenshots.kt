package app.streamsetu.tv.ui

import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.repo.smartmix.FolderNaming
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.PosterCard
import app.streamsetu.tv.ui.phone.Ph
import app.streamsetu.tv.ui.phone.PhoneFolderHeader
import app.streamsetu.tv.ui.phone.PhonePoster
import app.streamsetu.tv.ui.screens.folders.*
import app.streamsetu.tv.ui.theme.Accent
import app.streamsetu.tv.ui.theme.Theme
import app.streamsetu.tv.ui.theme.Tokens
import app.streamsetu.tv.ui.theme.UiScale
import app.streamsetu.core.model.Browse
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/**
 * The folder rows and Home shelves as drawn (Robolectric's native renderer) in two themes and accents and in Projector Mode, on a television-sized and a phone-sized screen. The real
 * header, tile and More components are used; the data is synthetic and the pictures are the app's own placeholders (no network). Set SCREENSHOT_DIR to keep the PNG files.
 * What this cannot show: a whole Home or Movies page (they need the app's container) and how it looks and performs on a real television.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1280dp-h720dp-mdpi")
class FolderRowsScreenshots {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()
    @After fun reset() { Tokens.apply(Theme.AMOLED, Accent.BLUE, false) }

    private val rows = listOf(
        FolderRow("a", null, FolderNaming.clean("EN | 4K UHD"), 1058, false, Browse.All),
        FolderRow("b", null, FolderNaming.clean("NETFLIX HD | ENGLISH MOVIES"), 3420, false, Browse.All),
        FolderRow("c", null, "Private", 0, true, Browse.All),
    )
    private val titles = listOf("Midnight River", "Silent Garden", "Iron Paper", "Echo Winter", "Golden Hollow", "Lantern Harbor", "Velvet Cinder")

    private fun shot(name: String): android.graphics.Bitmap {
        rule.waitForIdle()
        val root = rule.activity.window.decorView
        val bmp = android.graphics.Bitmap.createBitmap(root.width.coerceAtLeast(1), root.height.coerceAtLeast(1), android.graphics.Bitmap.Config.ARGB_8888)
        root.draw(android.graphics.Canvas(bmp))
        System.getenv("SCREENSHOT_DIR")?.let { d -> File(d).mkdirs(); File(d, "$name.png").outputStream().use { bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) } }
        return bmp
    }
    private fun lit(b: android.graphics.Bitmap): Int { var n = 0; for (y in 0 until b.height step 4) for (x in 0 until b.width step 4) if ((b.getPixel(x, y) and 0xFFFFFF) != (b.getPixel(0, 0) and 0xFFFFFF)) n++; return n }

    @Composable private fun TvScene() {
        Column(Modifier.fillMaxSize().background(Tokens.background).padding(top = 12.dp)) {
            Label("Home", Tokens.title, Tokens.text)
            rows.forEach { r ->
                TvFolderHeader(r) {}
                if (r.locked) Row(Modifier.padding(start = Tokens.safeHorizontal)) { MoreTile("Locked", Icons.Filled.ChevronRight, 154.dp, false, {}, Modifier) }
                else LazyRow(horizontalArrangement = Arrangement.spacedBy(Tokens.gutter), contentPadding = PaddingValues(start = Tokens.safeHorizontal, top = 8.dp, bottom = 8.dp)) {
                    items(5) { i -> PosterCard(titles[i], null, {}, width = 154.dp, subtitle = (2020 + i).toString()) }
                    item { MoreTile("More", Icons.Filled.ChevronRight, 154.dp, false, {}, Modifier) }
                }
            }
        }
    }

    @Composable private fun PhoneScene() {
        Column(Modifier.fillMaxSize().background(Tokens.background).padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            rows.forEach { r ->
                PhoneFolderHeader(r) {}
                if (!r.locked) LazyRow(contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(5) { i -> PhonePoster(titles[i], null, {}, Modifier.width(112.dp), subtitle = (2020 + i).toString()) }
                }
            }
        }
    }

    private fun scene(tv: Boolean, theme: Theme, accent: Accent, projector: Boolean, name: String) {
        UiScale.apply(1280f, 720f); Tokens.apply(theme, accent, projector)
        rule.setContent { if (tv) TvScene() else PhoneScene() }
        val b = shot(name)
        assertTrue("$name drew something", lit(b) > 200)
    }

    @Test fun tvAmoledBlue() = scene(true, Theme.AMOLED, Accent.BLUE, false, "tv-folder-rows-amoled-blue")
    @Test fun tvCinematicEmber() = scene(true, Theme.CINEMATIC, Accent.EMBER, false, "tv-folder-rows-cinematic-ember")
    @Test fun tvProjector() = scene(true, Theme.AMOLED, Accent.BLUE, true, "tv-folder-rows-projector")
    @Test fun phoneAmoledBlue() = scene(false, Theme.AMOLED, Accent.BLUE, false, "phone-folder-rows-amoled-blue")
    @Test fun phoneCinematicEmber() = scene(false, Theme.CINEMATIC, Accent.EMBER, false, "phone-folder-rows-cinematic-ember")
    @Test fun phoneProjector() = scene(false, Theme.AMOLED, Accent.BLUE, true, "phone-folder-rows-projector")

    @Test fun headerSpeaksTheCountInWordsAndHidesItForALockedFolder() {
        assertEquals("4K UHD EN, 1,058 titles", folderRowDescription(rows[0]))
        assertEquals("Private, locked", folderRowDescription(rows[2]))
    }
}
