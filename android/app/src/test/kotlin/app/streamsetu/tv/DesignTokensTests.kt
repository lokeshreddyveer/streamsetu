package app.streamsetu.tv

import androidx.compose.ui.graphics.Color
import app.streamsetu.tv.ui.theme.Accent
import app.streamsetu.tv.ui.theme.Theme
import app.streamsetu.tv.ui.theme.Tokens
import org.junit.Assert.*
import org.junit.Test

/** The shared TV design system (the 1280 x 720 canvas) stays inside the agreed ranges, so a later tweak cannot quietly make the interface unreadable from a sofa or fussy. */
class DesignTokensTests {
    @Test fun theDefaultThemeIsTheNeutralCharcoal() {
        assertEquals(Theme.CINEMA, Theme.of(null)); assertEquals(Color(0xFF0B0D10), Theme.CINEMA.background)
        assertEquals(Color(0xFF14171B), Theme.CINEMA.card); assertEquals(Color(0xFF20242A), Theme.CINEMA.elevated); assertEquals(Color(0xFF303740), Theme.CINEMA.focused)
    }
    @Test fun theDefaultAccentIsACalmCyan() = assertEquals(Accent.CYAN, Accent.of(null))
    @Test fun focusIsWhiteAndTextOnBrightFillsIsDark() {
        assertEquals(Color.White, Tokens.focusRing); assertTrue(Tokens.onBright.red < 0.1f && Tokens.onBright.green < 0.1f)
    }
    @Test fun cornersAreRestrained() {
        listOf(Tokens.radiusSmall, Tokens.radius, Tokens.radiusPanel, Tokens.radiusLarge).forEach { assertTrue(it.value in 6f..18f) }
    }
    @Test fun typeIsReadableFromTheSofa() {
        assertTrue(Tokens.hero.value in 36f..56f); assertTrue(Tokens.display.value in 28f..34f); assertTrue(Tokens.title.value in 22f..26f)
        assertTrue(Tokens.nav.value in 16f..20f); assertTrue(Tokens.small.value in 14f..17f); assertTrue(Tokens.row.value in 16f..19f)
    }
    @Test fun marginsAreTelevisionSafe() = assertTrue(Tokens.safeHorizontal.value in 24f..64f)
    @Test fun everyThemeKeepsTextReadable() {
        Theme.entries.forEach { t -> assertTrue("${t.name} is dark", t.background.red + t.background.green + t.background.blue < 0.6f) }
    }
}
