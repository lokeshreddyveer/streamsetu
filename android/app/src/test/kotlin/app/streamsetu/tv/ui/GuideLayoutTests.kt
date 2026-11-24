package app.streamsetu.tv.ui

import app.streamsetu.tv.ui.screens.guide.GuideLayout
import org.junit.Assert.*
import org.junit.Test

/** The guide's visible window follows the room there is, and the minutes are stretched so the grid reaches the right margin. */
class GuideLayoutTests {
    @Test fun trackIsWhatIsLeftBesideTheChannelColumn() {
        assertEquals(960f - 52f - 48f - 195f, GuideLayout.trackWidthDp(960f, 52f, 48f, 195f), 0.001f)
        assertEquals(0f, GuideLayout.trackWidthDp(100f, 52f, 48f, 195f), 0.001f)
    }
    @Test fun windowIsWholeHalfHoursWithinBounds() {
        listOf(300f, 500f, 665f, 900f, 1400f, 4000f).forEach { w ->
            val m = GuideLayout.windowMinutes(w, 3.25f)
            assertEquals(0, m % 30); assertTrue(m in GuideLayout.MIN_WINDOW_MIN..GuideLayout.MAX_WINDOW_MIN)
        }
        assertEquals(180, GuideLayout.windowMinutes(665f, 3.25f))
        assertEquals(GuideLayout.MIN_WINDOW_MIN, GuideLayout.windowMinutes(0f, 3.25f))
        assertEquals(GuideLayout.MAX_WINDOW_MIN, GuideLayout.windowMinutes(5000f, 3.25f))
    }
    @Test fun gridFillsTheTrackExactly() {
        listOf(300f, 665f, 1100f, 5000f).forEach { track ->
            val m = GuideLayout.windowMinutes(track, 3.25f)
            assertEquals(track, GuideLayout.dpPerMinute(track, m) * m, 0.01f)
        }
        assertEquals(0f, GuideLayout.dpPerMinute(0f, 180), 0f)
    }
    @Test fun aWiderScreenShowsMoreTimeNotBlankSpace() {
        assertTrue(GuideLayout.windowMinutes(1100f, 3.25f) > GuideLayout.windowMinutes(500f, 3.25f))
    }
    @Test fun theNowMarkerNeverSitsOnARulerLabel() {
        assertTrue(GuideLayout.rulerLabelVisible(100f, null))
        assertFalse(GuideLayout.rulerLabelVisible(100f, 101f))
        assertFalse(GuideLayout.rulerLabelVisible(100f, 160f))
        assertTrue(GuideLayout.rulerLabelVisible(100f, 200f))
        assertTrue(GuideLayout.rulerLabelVisible(100f, 90f))
    }
}
