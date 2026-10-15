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

    // A remote that sends no repeats while the key is held: the press is still recognised as the one that opened the menu.
    @Test fun aLongHoldWithoutRepeatsIsStillTheOpeningPress() {
        var now = 0L
        val g = SelectKeyGuard(now = { now }, quietMs = 400, opening = { 5_000L })
        now = 900; g.tick(); assertFalse(g.armed)                                  // far longer than the quiet time, key still down
        assertTrue(g.swallow(down = false, downTime = 5_000L)); assertTrue(g.armed)   // its release is swallowed
        assertFalse(g.swallow(down = true, downTime = 9_000L))                      // a new press works
    }

    @Test fun aNewPressWorksEvenIfTheReleaseOfTheOpeningOneNeverArrived() {
        val g = SelectKeyGuard(now = { 0 }, quietMs = 400, opening = { 5_000L })
        assertTrue(g.swallow(down = true, downTime = 5_000L))
        assertFalse(g.swallow(down = true, downTime = 7_000L))
    }

    @Test fun theHoldRecordsWhichPressItWas() {
        var pending: (() -> Unit)? = null
        val hold = HoldToSelect(hasHandler = { true }, schedule = { _, run -> pending = run }, cancel = { pending = null }, fire = {})
        OpeningPress.downTime = 0
        hold.onSelect(down = true, repeatCount = 0, downTime = 1234L)
        pending?.invoke()
        assertEquals(1234L, OpeningPress.downTime)
    }
}
