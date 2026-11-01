package app.streamsetu.tv

import androidx.compose.ui.graphics.Color
import app.streamsetu.tv.ui.theme.Accent
import app.streamsetu.tv.ui.theme.Theme
import app.streamsetu.tv.ui.theme.Tokens
import org.junit.Assert.*
import org.junit.Test

/** The shared TV design system (the 1280 x 720 canvas) stays inside the agreed ranges, so a later tweak cannot quietly make the interface unreadable from a sofa or fussy. */
class DesignTokensTests {
    @Test fun theDefaultThemeIsAmoledBlack() {
        assertEquals(Theme.AMOLED, Theme.of(null)); assertEquals(Theme.AMOLED, Theme.of("no such theme")); assertEquals(Color(0xFF000000), Theme.AMOLED.background)
        assertEquals(Color(0xFF0D0D0D), Theme.AMOLED.card); assertEquals(Color(0xFF181818), Theme.AMOLED.elevated); assertEquals(Color(0xFF262626), Theme.AMOLED.focused)
    }
    @Test fun theCinemaCharcoalIsStillThere() { assertEquals(Color(0xFF0B0D10), Theme.CINEMA.background); assertEquals(Color(0xFF14171B), Theme.CINEMA.card); assertEquals(Theme.CINEMA, Theme.of("CINEMA")) }
    @Test fun theDefaultAccentIsBlue() { assertEquals(Accent.BLUE, Accent.of(null)); assertEquals(Accent.BLUE, Accent.of("no such accent")); assertEquals(Accent.CYAN, Accent.of("CYAN")) }
    @Test fun focusIsWhiteAndTextOnBrightFillsIsDark() {
        assertEquals(Color.White, Tokens.focusRing); assertTrue(Tokens.onBright.red < 0.1f && Tokens.onBright.green < 0.1f)
    }
    @Test fun cornersAreRestrained() {
        listOf(Tokens.radiusSmall, Tokens.radius, Tokens.radiusPanel, Tokens.radiusLarge).forEach { assertTrue(it.value in 6f..18f) }
    }
    @Test fun typeIsReadableFromTheSofa() {
        // The type scale was made about 12% smaller on request (the screens read as too big). These are the floors it must not go below: text still has to be read from the sofa.
        assertTrue(Tokens.hero.value in 30f..56f); assertTrue(Tokens.display.value in 24f..34f); assertTrue(Tokens.title.value in 18f..26f)
        assertTrue(Tokens.nav.value in 14f..20f); assertTrue(Tokens.small.value in 12f..17f); assertTrue(Tokens.row.value in 14f..19f)
        assertTrue(Tokens.body.value >= 14f); assertTrue(Tokens.caption.value >= 11f)
    }
    @Test fun marginsAreTelevisionSafe() = assertTrue(Tokens.safeHorizontal.value in 24f..64f)
    @Test fun everyThemeKeepsTextReadable() {
        Theme.entries.forEach { t -> assertTrue("${t.name} is dark", t.background.red + t.background.green + t.background.blue < 0.6f) }
    }
}
