package app.streamsetu.tv

import org.junit.Assert.*
import org.junit.Test

class SoundPolicyTests {
    private val on = SoundSettings()
    @Test fun offAndSilentPlayNothing() {
        assertNull(SoundPolicy().decide(UISoundEvent.SELECT, 0, on.copy(enabled = false), false))
        assertNull(SoundPolicy().decide(UISoundEvent.SELECT, 0, on.copy(theme = "SILENT"), false))
        assertNull(SoundPolicy().decide(UISoundEvent.SELECT, 0, on.copy(volume = 0), false))
    }
    @Test fun minimalKeepsOnlyTheImportantTones() {
        val m = on.copy(theme = "MINIMAL")
        assertNull(SoundPolicy().decide(UISoundEvent.FOCUS_MOVE, 0, m, false)); assertNull(SoundPolicy().decide(UISoundEvent.MENU_CLOSE, 0, m, false))
        assertNotNull(SoundPolicy().decide(UISoundEvent.SELECT, 0, m, false)); assertNotNull(SoundPolicy().decide(UISoundEvent.ERROR, 0, m, false))
    }
    @Test fun eachGroupCanBeTurnedOff() {
        assertNull(SoundPolicy().decide(UISoundEvent.FOCUS_MOVE, 0, on.copy(navigation = false), false))
        assertNull(SoundPolicy().decide(UISoundEvent.SELECT, 0, on.copy(selection = false), false))
        assertNull(SoundPolicy().decide(UISoundEvent.FAVORITE_ADD, 0, on.copy(confirmation = false), false))
        assertNull(SoundPolicy().decide(UISoundEvent.ERROR, 0, on.copy(error = false), false))
    }
    @Test fun defaultVolumeIsSubtle() { val g = SoundPolicy().decide(UISoundEvent.SELECT, 0, on, false)!!; assertTrue(g in 0.15f..0.25f) }
    @Test fun duringPlaybackItIsOffReducedOrOn() {
        assertNull(SoundPolicy().decide(UISoundEvent.SELECT, 0, on.copy(duringPlayback = "OFF"), true))
        val normal = SoundPolicy().decide(UISoundEvent.SELECT, 0, on, false)!!
        assertEquals(normal * 0.5f, SoundPolicy().decide(UISoundEvent.SELECT, 0, on.copy(duringPlayback = "REDUCED"), true)!!, 0.001f)
        assertEquals(normal, SoundPolicy().decide(UISoundEvent.SELECT, 0, on.copy(duringPlayback = "ON"), true)!!, 0.001f)
    }
    @Test fun rapidFocusIsRateLimitedAndQuieter() {
        val p = SoundPolicy(); var played = 0; var firstGain = 0f; var lastGain = 0f
        for (i in 0 until 40) { val g = p.decide(UISoundEvent.FOCUS_MOVE, i * 30L, on, false); if (g != null) { played++; if (played == 1) firstGain = g; lastGain = g } }
        assertTrue("40 quick moves must not make 40 ticks (made $played)", played < 15)
        assertTrue(lastGain < firstGain)
    }
    @Test fun slowMovementTicksEveryTime() {
        val p = SoundPolicy(); var played = 0
        for (i in 0 until 10) if (p.decide(UISoundEvent.FOCUS_MOVE, i * 400L, on, false) != null) played++
        assertEquals(10, played)
    }
    @Test fun confirmationsAreNeverRateLimited() {
        val p = SoundPolicy(); assertNotNull(p.decide(UISoundEvent.FAVORITE_ADD, 0, on, false)); assertNotNull(p.decide(UISoundEvent.FAVORITE_ADD, 5, on, false))
    }
}
