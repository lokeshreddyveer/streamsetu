package app.streamsetu.tv

import app.streamsetu.tv.ui.components.SelectKeyGuard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HoldToSelectTests {
    /** A clock and a timer the test turns by hand. */
    private class Rig(var handler: Boolean = true) {
        var pending: (() -> Unit)? = null
        var fired = 0
        val hold = HoldToSelect(hasHandler = { handler }, schedule = { _, run -> pending = run }, cancel = { pending = null }, fire = { fired++ })
        fun elapse() { pending?.also { pending = null }?.invoke() }
    }

    @Test fun aShortPressIsAClickAndNeverALongPress() {
        val r = Rig()
        assertFalse(r.hold.onSelect(down = true, repeatCount = 0))
        assertFalse(r.hold.onSelect(down = false, repeatCount = 0))       // released before the hold time: passes through as a click
        r.elapse(); assertEquals(0, r.fired)                              // the timer was cancelled
    }

    @Test fun aHoldFiresOnceAndTheWholePressIsSwallowed() {
        val r = Rig()
        r.hold.onSelect(true, 0)
        r.elapse(); assertEquals(1, r.fired)
        assertTrue(r.hold.onSelect(true, 1)); assertTrue(r.hold.onSelect(true, 2))   // repeats while held
        assertTrue(r.hold.onSelect(false, 0))                                          // the release is not a click
        assertEquals(1, r.fired)
    }

    @Test fun theNextPressAfterAHoldIsAnOrdinaryClick() {
        val r = Rig()
        r.hold.onSelect(true, 0); r.elapse(); r.hold.onSelect(false, 0)
        assertFalse(r.hold.onSelect(true, 0)); assertFalse(r.hold.onSelect(false, 0))
        assertEquals(1, r.fired)
    }

    @Test fun nothingIsScheduledWhenTheRemoteIsOnNothingThatHasAHoldMenu() {
        val r = Rig(handler = false)
        assertFalse(r.hold.onSelect(true, 0)); assertTrue(r.pending == null)
        assertFalse(r.hold.onSelect(false, 0))
    }

    @Test fun keyRepeatsBeforeTheHoldTimeDoNotRestartTheTimer() {
        val r = Rig()
        r.hold.onSelect(true, 0); val first = r.pending
        r.hold.onSelect(true, 1); r.hold.onSelect(true, 2)
        assertTrue(r.pending === first)
        r.elapse(); assertEquals(1, r.fired)
    }

    // ---- the menu that opens from the hold ----

    @Test fun theMenuIgnoresOkUntilTheOpeningPressIsOver() {
        var now = 0L
        val g = SelectKeyGuard(now = { now }, quietMs = 400)
        assertTrue(g.swallow(down = true)); assertTrue(g.swallow(down = true))    // repeats of the key that opened it
        assertTrue(g.swallow(down = false)); assertTrue(g.armed)                   // its release: swallowed, and from now on OK works
        assertFalse(g.swallow(down = true)); assertFalse(g.swallow(down = false))
    }

    @Test fun aMenuOpenedAfterTheKeyWasAlreadyReleasedBecomesUsableAfterAMoment() {
        var now = 0L
        val g = SelectKeyGuard(now = { now }, quietMs = 400)
        now = 300; g.tick(); assertFalse(g.armed)
        now = 500; g.tick(); assertTrue(g.armed)
        assertFalse(g.swallow(down = true))
    }

    @Test fun aKeyStillBeingHeldKeepsTheMenuFromArmingEarly() {
        var now = 0L
        val g = SelectKeyGuard(now = { now }, quietMs = 400)
        now = 300; g.swallow(true); now = 600; g.tick(); assertFalse(g.armed)     // a repeat 300 ms ago: still held
        now = 800; g.tick(); assertTrue(g.armed)
    }
}
