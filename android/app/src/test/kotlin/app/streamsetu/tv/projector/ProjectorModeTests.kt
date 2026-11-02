package app.streamsetu.tv.projector

import android.content.Context
import androidx.compose.ui.graphics.Color
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.settings.UiPrefs
import app.streamsetu.tv.effectiveHighContrast
import app.streamsetu.tv.ui.screens.settings.Category
import app.streamsetu.tv.ui.screens.settings.Exposure
import app.streamsetu.tv.ui.screens.settings.SettingsRegistry
import app.streamsetu.tv.ui.theme.Accent
import app.streamsetu.tv.ui.theme.ProjectorPalette
import app.streamsetu.tv.ui.theme.Theme
import app.streamsetu.tv.ui.theme.Tokens
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import kotlin.math.pow

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class ProjectorModeTests {
    private val ctx get() = ApplicationProvider.getApplicationContext<Context>()
    @Before fun fresh() { ctx.getSharedPreferences("ui", Context.MODE_PRIVATE).edit().clear().commit(); Tokens.apply(Theme.AMOLED, Accent.BLUE, false) }
    @After fun reset() { Tokens.apply(Theme.AMOLED, Accent.BLUE, false) }

    // ---- the saved choice

    @Test fun projectorModeIsOffUntilTheyTurnItOn() { assertFalse(UiPrefs(ctx).projectorMode.value) }

    @Test fun theChoiceSurvivesARestart() {
        UiPrefs(ctx).setProjectorMode(true)
        assertTrue("a new object on the same saved preferences", UiPrefs(ctx).projectorMode.value)
        UiPrefs(ctx).setProjectorMode(false); assertFalse(UiPrefs(ctx).projectorMode.value)
    }

    @Test fun turningItOnChangesNoOtherChoiceTheyMade() {
        val ui = UiPrefs(ctx); ui.setTheme("MIDNIGHT"); ui.setAccent("ROSE"); ui.setHighContrastFocus(false)
        ui.setProjectorMode(true)
        assertEquals("MIDNIGHT", ui.theme.value); assertEquals("ROSE", ui.accent.value); assertFalse("the saved High-contrast focus is not overwritten", ui.highContrastFocus.value)
    }

    @Test fun theStrongerFocusFrameIsInEffectWhileTheModeIsOnWithoutChangingTheSavedChoice() {
        assertFalse(effectiveHighContrast(highContrastFocus = false, projectorMode = false))
        assertTrue(effectiveHighContrast(highContrastFocus = false, projectorMode = true))
        assertTrue(effectiveHighContrast(highContrastFocus = true, projectorMode = false)); assertTrue(effectiveHighContrast(true, true))
    }

    @Test fun itNeverTravelsThroughBackupOrSync() {
        assertTrue("projectorMode" in UiPrefs.DEVICE_ONLY)
        val src = File(root(), "../../../../data/src/main/kotlin/app/streamsetu/core/data/repo/MaintenanceService.kt").takeIf { it.exists() } ?: File("../data/src/main/kotlin/app/streamsetu/core/data/repo/MaintenanceService.kt")
        val text = src.readText()
        assertTrue("the backup leaves it out", text.contains("UiPrefs.DEVICE_ONLY)) o.put")); assertTrue("a restore ignores it", text.contains("DEVICE_ONLY.forEach { vals.remove(it) }"))
    }

    @Test fun thePhoneLayoutNeverTurnsItOn() {
        val offenders = tvSources().filter { it.path.contains("/ui/phone/") && it.readText().contains("setProjectorMode") }.map { it.name }
        assertTrue("the phone layout must not set Projector Mode: $offenders", offenders.isEmpty())
        val setters = tvSources().filter { it.readText().contains("setProjectorMode(") && !it.path.contains("/test/") }.map { it.name }
        assertEquals("only the Appearance page and the adb test switch set it", listOf("SettingsScreen2.kt", "StreamSetuApp.kt"), setters.sorted())
        // The adb test switch exists only when the test hooks are on (off in the real app unless the device was told so over adb).
        val app = tvSources().first { it.name == "StreamSetuApp.kt" }.readText()
        val gate = app.substringBefore("setProjectorMode(").substringAfterLast("if (")
        assertTrue("the switch is registered only behind TestHooks.on: $gate", gate.startsWith("app.streamsetu.tv.trace.TestHooks.on"))
    }

    // ---- the palette

    @Test fun theMiddleOfTheAppChangesAtOnceAndComesBackExactly() {
        Tokens.apply(Theme.MIDNIGHT, Accent.ROSE, false)
        val bg = Tokens.background; val accent = Tokens.accent; val text = Tokens.text
        Tokens.apply(Theme.MIDNIGHT, Accent.ROSE, true)
        assertEquals(ProjectorPalette.background, Tokens.background); assertEquals(ProjectorPalette.card, Tokens.card); assertEquals(Color.White, Tokens.text)
        assertNotEquals(accent, Tokens.accent); assertEquals(ProjectorPalette.accent(Accent.ROSE.color), Tokens.accent)
        Tokens.apply(Theme.MIDNIGHT, Accent.ROSE, false)
        assertEquals("the chosen theme and accent are back, unchanged", Triple(bg, accent, text), Triple(Tokens.background, Tokens.accent, Tokens.text))
    }

    @Test fun noPageCardOrPanelIsEverBlackInProjectorMode() {
        Theme.entries.forEach { t -> Tokens.apply(t, Accent.BLUE, true); listOf(Tokens.background, Tokens.panel, Tokens.card, Tokens.elevated, Tokens.focusedSurface).forEach { assertNotEquals(Color.Black, it); assertTrue(luminance(it) > 0.005) } }
    }

    @Test fun everyDimmingRoleIsASlateNeverBlackInProjectorModeAndTheNormalOnesAreUnchanged() {
        Tokens.apply(Theme.AMOLED, Accent.BLUE, false)
        assertEquals(Color(0x73000000), Tokens.scrim); assertEquals(Color(0x8C000000), Tokens.scrimStrong); assertEquals(Color(0xB3000000), Tokens.playerControlsScrim); assertEquals(Color(0xF2000000), Tokens.playerMenuScrim)
        Tokens.apply(Theme.AMOLED, Accent.BLUE, true)
        listOf(Tokens.scrim, Tokens.scrimStrong, Tokens.heroTextScrimStrong, Tokens.heroTextScrimMiddle, Tokens.heroTopScrim, Tokens.playerControlsScrim, Tokens.playerMenuScrim, Tokens.playerChip, Tokens.chipScrim, Tokens.progressTrack)
            .forEach { assertTrue("not black: $it", it.red > 0.05f || it.green > 0.05f || it.blue > 0.05f) }
        assertEquals(Color(0xE61B222B), Tokens.heroTextScrimStrong); assertEquals(Color(0xA61B222B), Tokens.heroTextScrimMiddle); assertEquals(Color.Transparent, Tokens.heroTextScrimClear); assertEquals(ProjectorPalette.background, Tokens.heroBottomScrim)
    }

    // ---- readability, measured

    private fun lin(c: Float) = if (c <= 0.03928f) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
    private fun luminance(c: Color) = 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue)
    private fun over(top: Color, base: Color) = Color(top.red * top.alpha + base.red * (1 - top.alpha), top.green * top.alpha + base.green * (1 - top.alpha), top.blue * top.alpha + base.blue * (1 - top.alpha))
    private fun ratio(a: Color, b: Color): Double { val (x, y) = luminance(a) to luminance(b); return (maxOf(x, y) + 0.05) / (minOf(x, y) + 0.05) }
    private val surfaces get() = listOf("background" to ProjectorPalette.background, "panel" to ProjectorPalette.panel, "card" to ProjectorPalette.card, "elevated" to ProjectorPalette.elevated, "focused" to ProjectorPalette.focusedSurface)

    @Test fun primaryTextIsAtLeastSevenToOneOnEverySurface() { surfaces.forEach { (n, s) -> assertTrue("primary on $n = ${ratio(ProjectorPalette.text, s)}", ratio(ProjectorPalette.text, s) >= 7.0) } }
    @Test fun secondaryTextIsAtLeastFourPointFiveToOneOnEverySurface() { surfaces.forEach { (n, s) -> assertTrue("secondary on $n = ${ratio(ProjectorPalette.textSecondary, s)}", ratio(ProjectorPalette.textSecondary, s) >= 4.5) } }
    @Test fun tertiaryTextIsAtLeastFourPointFiveToOneOnEverySurface() { surfaces.forEach { (n, s) -> assertTrue("tertiary on $n = ${ratio(ProjectorPalette.textTertiary, s)}", ratio(ProjectorPalette.textTertiary, s) >= 4.5) } }
    @Test fun successWarningAndDangerAreAtLeastFourPointFiveToOneOnEverySurface() {
        listOf("success" to ProjectorPalette.success, "warning" to ProjectorPalette.warning, "danger" to ProjectorPalette.danger).forEach { (name, c) -> surfaces.forEach { (n, s) -> assertTrue("$name on $n = ${ratio(c, s)}", ratio(c, s) >= 4.5) } }
    }
    @Test fun theStatusColoursOfTheAppFollowTheProjectorPaletteAndComeBackWhenTheModeIsOff() {
        Tokens.apply(Theme.AMOLED, Accent.BLUE, true)
        assertEquals(ProjectorPalette.danger, Tokens.danger); assertEquals(ProjectorPalette.warning, Tokens.warning); assertEquals(ProjectorPalette.success, Tokens.success)
        assertEquals("Settings' red is the same lifted danger colour", ProjectorPalette.danger, app.streamsetu.tv.ui.screens.settings.Mac.red); assertEquals("the play button uses the lifted accent", Tokens.accent, Tokens.playPill)
        Tokens.apply(Theme.AMOLED, Accent.BLUE, false)
        assertEquals(Color(0xFFD9534F), Tokens.danger); assertEquals(Color(0xFFFF453A), app.streamsetu.tv.ui.screens.settings.Mac.red); assertEquals(Accent.BLUE.color, Tokens.playPill)
    }
    @Test fun theFocusFrameIsAtLeastThreeToOneAgainstEveryNeighbouringSurface() { surfaces.forEach { (n, s) -> assertTrue("frame against $n = ${ratio(ProjectorPalette.focusRing, s)}", ratio(ProjectorPalette.focusRing, s) >= 3.0) } }
    @Test fun textOnABrightFillIsAtLeastSevenToOne() { assertTrue(ratio(ProjectorPalette.onBright, Color.White) >= 7.0); assertTrue(ratio(ProjectorPalette.onBright, ProjectorPalette.accent(Accent.BLUE.color)) >= 4.5) }
    @Test fun theLinesAreStrongEnoughToSeeAndEachSurfaceIsToldApartFromTheNext() {
        assertTrue(ratio(over(ProjectorPalette.lineStrong, ProjectorPalette.card), ProjectorPalette.card) >= 1.8)
        // A card stands clearly apart from the page it sits on, and each step up (panel, card, raised, focused) is a visible step.
        assertTrue("card / page = ${ratio(ProjectorPalette.card, ProjectorPalette.background)}", ratio(ProjectorPalette.card, ProjectorPalette.background) >= 1.25)
        listOf(ProjectorPalette.background to ProjectorPalette.panel, ProjectorPalette.panel to ProjectorPalette.card, ProjectorPalette.card to ProjectorPalette.elevated, ProjectorPalette.elevated to ProjectorPalette.focusedSurface)
            .forEach { (a, b) -> assertTrue("$a / $b = ${ratio(a, b)}", ratio(a, b) >= 1.08) }
    }

    // ---- where it is, and what it must not touch

    @Test fun theSettingIsInTheRegistryOnTheAppearancePageAndEssentialShowsIt() {
        val d = SettingsRegistry.all.single { it.id == "appearance.projector-mode" }
        assertEquals("Projector mode", d.title); assertEquals(Category.APPEARANCE, d.category); assertEquals(Exposure.ESSENTIAL, d.exposure); assertFalse(d.sensitive)
        assertTrue(d.description.startsWith("Makes pages, cards, text and focus controls easier to see on projectors.")); assertTrue(d.description.contains("does not change video brightness or HDR"))
        listOf("projector", "brightness", "bright", "dark screen", "washed out", "contrast", "cannot see", "hdmi", "display").forEach { w -> assertTrue("alias $w", d.aliases.any { it.equals(w, true) }) }
        assertTrue(SettingsRegistry.visible(advanced = false).any { it.id == d.id })
    }

    @Test fun settingsSearchFindsItByTheWordsPeopleUse() {
        listOf("projector", "brightness", "dark screen", "cannot see", "washed out", "hdmi").forEach { q -> assertTrue("'$q' -> ${SettingsRegistry.search(q, false).map { it.title }}", SettingsRegistry.search(q, false).take(3).any { it.id == "appearance.projector-mode" }) }
    }

    @Test fun itSitsDirectlyBelowTheThemeRowOnTheAppearancePage() {
        val text = File(root(), "src/main/kotlin/app/streamsetu/tv/ui/screens/settings/SettingsScreen2.kt").readText()
        val theme = text.indexOf("ChoiceRow(\"Theme\""); val projector = text.indexOf("ToggleRow(\"Projector mode\""); val accent = text.indexOf("ChoiceRow(\"Accent colour\"")
        assertTrue(theme in 0 until projector && projector < accent)
    }

    @Test fun theVideoAndTheEnginesNeverKnowAboutIt() {
        val touched = tvSources().filter { f ->
            val p = f.path; (p.contains("/playback/") || p.contains("PersistentVideo") || p.contains("EngineSurface") || p.contains("MultiViewScreen") || p.contains("/core-media/")) && f.readText().contains(Regex("projector|Projector"))
        }.map { it.name }
        assertTrue("the video path mentions Projector Mode in $touched", touched.isEmpty())
        assertTrue("the black behind the video is untouched", File(root(), "src/main/kotlin/app/streamsetu/tv/ui/components/PersistentVideo.kt").readText().contains("Color.Black"))
        val player = File(root(), "src/main/kotlin/app/streamsetu/tv/ui/screens/PlayerScreen.kt").readText()
        listOf("setBrightness", "setGamma", "setContrast", "RenderEffect", "ColorMatrix", "colorFilter = ColorFilter.lighting").forEach { assertFalse("the player must not adjust the picture ($it)", player.contains(it)) }
    }

    @Test fun theFocusFrameAndTheCentralPaletteAddNoGraphicsLayerBlurShadowOrAnimation() {
        val tokens = File(root(), "src/main/kotlin/app/streamsetu/tv/ui/theme/Tokens.kt").readText()
        listOf("graphicsLayer", "blur(", "shadow(", "RenderEffect", "animate").forEach { assertFalse("Tokens.kt uses $it", tokens.contains(it)) }
        val basics = File(root(), "src/main/kotlin/app/streamsetu/tv/ui/components/Basics.kt").readText()
        val block = basics.substringAfter("if (projector) {\n                        // Inside the edge").substringBefore("return@drawWithContent")
        assertTrue("the projector frame code was not found", block.contains("strokeOutline"))
        listOf("graphicsLayer", "blur(", "shadow(", "RenderEffect", "animate", "Brush").forEach { assertFalse("the projector frame uses $it", block.contains(it)) }
    }

    // ---- helpers

    private fun root() = listOf("", "app/").map { File(it.ifEmpty { "." }) }.first { File(it, "src/main/kotlin").exists() }
    private fun tvSources() = File(root(), "src/main/kotlin/app/streamsetu/tv").walkTopDown().filter { it.extension == "kt" }.toList()
}
