package app.streamsetu.tv.ui

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.repo.TitlePageText
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.phone.Ph
import app.streamsetu.tv.ui.phone.TitlePageScaffold
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

/** The title page (movie, series, and a title with no wide picture) on a phone and a television in two themes. Synthetic data. Set SCREENSHOT_DIR to keep the PNG files. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1280dp-h720dp-mdpi")
class TitlePageScreenshots {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()
    @After fun reset() { Tokens.apply(Theme.AMOLED, Accent.BLUE, false) }

    private val rows = TitlePageText.details("S. Director", "Mahesh Babu, Ileana D'Cruz, Prakash Raj", "India", "Studio One", "2006-04-28", false)

    @Composable private fun Page(tv: Boolean, top: TitleTop, series: Boolean) {
        val extra: androidx.compose.foundation.lazy.LazyListScope.() -> Unit = {
            if (series) item { Column(Modifier.padding(horizontal = if (tv) Tokens.safeHorizontal else Ph.gutter)) { SectionLabel("Episodes", tv); Label("Season 1   Season 2   Season 3", if (tv) Tokens.body else Ph.body, Tokens.textSecondary) } }
            item { Box(Modifier.padding(horizontal = if (tv) Tokens.safeHorizontal else Ph.gutter)) { DetailsList(rows, tv, {}, null) } }
        }
        if (!tv) TitlePageScaffold(top, extra)
        else Box(Modifier.fillMaxSize().androidxBg()) { LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            item { TitleHero(true, top, inset = Tokens.safeHorizontal) }
            item { TitleBody(true, top, Modifier.padding(horizontal = Tokens.safeHorizontal).widthIn(max = 720.dp)) }
            extra()
        } }
    }
    private fun Modifier.androidxBg() = this.then(Modifier.fillMaxSize()).let { it }

    private fun scene(tv: Boolean, theme: Theme, accent: Accent, name: String, series: Boolean = false, backdrop: Boolean = true) {
        UiScale.apply(1280f, 720f); Tokens.apply(theme, accent, false)
        val top = sampleTop(backdrop = if (backdrop) "https://example.invalid/b.jpg" else null, poster = "https://example.invalid/p.jpg").let { if (series) TitleTop(it.title, it.backdrop, it.poster, "2020 · 3 seasons · ★ 8.1", it.pickerLabel, it.onPicker, "Play S1 E3", null, {}, null, it.actions.filter { a -> a.tag != "action-trailer" }, it.synopsis, emptyList(), it.onBack, it.onMenu) else it }
        rule.setContent { androidx.compose.foundation.layout.Box(if (tv) Modifier.width(1280.dp).height(720.dp) else Modifier.width(390.dp).height(800.dp)) { androidx.compose.foundation.layout.Box(Modifier.fillMaxSize().then(Modifier)) { Page(tv, top, series) } } }
        rule.waitForIdle()
        val root = rule.activity.window.decorView
        val bmp = android.graphics.Bitmap.createBitmap(root.width.coerceAtLeast(1), root.height.coerceAtLeast(1), android.graphics.Bitmap.Config.ARGB_8888)
        root.draw(android.graphics.Canvas(bmp))
        System.getenv("SCREENSHOT_DIR")?.let { d -> File(d).mkdirs(); File(d, "$name.png").outputStream().use { bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) } }
        var lit = 0; val bg = bmp.getPixel(0, 0)
        for (y in 0 until bmp.height step 4) for (x in 0 until bmp.width step 4) if (bmp.getPixel(x, y) != bg) lit++
        assertTrue("$name drew something ($lit)", lit > 300)
    }

    @Test fun tvMovieAmoled() = scene(true, Theme.AMOLED, Accent.BLUE, "tv-title-movie-amoled")
    @Test fun tvMovieCinematic() = scene(true, Theme.CINEMATIC, Accent.EMBER, "tv-title-movie-cinematic")
    @Test fun tvSeriesAmoled() = scene(true, Theme.AMOLED, Accent.BLUE, "tv-title-series-amoled", series = true)
    @Test fun tvNoBackdropCinematic() = scene(true, Theme.CINEMATIC, Accent.EMBER, "tv-title-nobackdrop-cinematic", backdrop = false)
    @Test fun phoneMovieAmoled() = scene(false, Theme.AMOLED, Accent.BLUE, "phone-title-movie-amoled")
    @Test fun phoneMovieCinematic() = scene(false, Theme.CINEMATIC, Accent.EMBER, "phone-title-movie-cinematic")
    @Test fun phoneSeriesCinematic() = scene(false, Theme.CINEMATIC, Accent.EMBER, "phone-title-series-cinematic", series = true)
    @Test fun phoneNoBackdropAmoled() = scene(false, Theme.AMOLED, Accent.BLUE, "phone-title-nobackdrop-amoled", backdrop = false)
}
