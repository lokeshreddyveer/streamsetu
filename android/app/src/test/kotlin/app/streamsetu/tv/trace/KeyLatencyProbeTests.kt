package app.streamsetu.tv.trace

import org.junit.Assert.*
import org.junit.Test

class KeyLatencyProbeTests {
    private val lines = mutableListOf<String>()
    private val probe = KeyLatencyProbe({ lines += it }, { if (it == android.view.KeyEvent.KEYCODE_BACK) "BACK" else "DPAD_RIGHT" })
    private fun ms(v: Int) = v * 1_000_000L
    private val right = android.view.KeyEvent.KEYCODE_DPAD_RIGHT

    @Test fun aKeyEndsAtTheFrameThatWasBeingDrawnWhenFocusMoved() {
        probe.key(right, 0, "HOME", ms(0), ms(2))
        probe.focus(ms(10))
        probe.frame(ms(8), ms(24))
        assertEquals(1, lines.size)
        assertTrue(lines[0], "screen=HOME key=DPAD_RIGHT rep=0 queue=2.0 focus=8.0 frame=16.0 total=24.0 kind=focus thinned=0" == lines[0])
    }

    @Test fun aFrameThatFinishedBeforeFocusMovedIsNotTheAnswer() {
        probe.key(right, 0, "HOME", ms(0), ms(1))
        probe.frame(ms(0), ms(9))
        probe.focus(ms(10))
        assertTrue(lines.isEmpty())
        probe.frame(ms(16), ms(30))
        assertEquals(1, lines.size); assertTrue(lines[0], "total=30.0 kind=focus" in lines[0])
    }

    @Test fun aKeyThatMovesNoFocusEndsAtTheFirstFrameDrawnAfterIt() {
        probe.key(android.view.KeyEvent.KEYCODE_BACK, 0, "Dialog", ms(0), ms(1))
        probe.frame(ms(16), ms(40))
        assertTrue("it waits a moment in case focus is still to move", lines.isEmpty())
        probe.frame(ms(100), ms(125))
        assertEquals(1, lines.size); assertTrue(lines[0], "key=BACK" in lines[0] && "total=40.0 kind=render" in lines[0])
    }

    @Test fun aKeyThatChangedNothingIsReportedAsNone() {
        probe.key(right, 0, "HOME", ms(0), ms(1))
        probe.key(right, 1, "HOME", ms(50), ms(51))
        assertEquals(1, lines.size); assertTrue(lines[0], "rep=0" in lines[0] && "kind=none" in lines[0] && "total=-" in lines[0])
    }

    @Test fun thinnedPressesAreCountedOnTheNextKey() {
        probe.thinned(); probe.thinned()
        probe.key(right, 0, "HOME", ms(0), ms(1)); probe.focus(ms(3)); probe.frame(ms(0), ms(16))
        assertTrue(lines[0], "thinned=2" in lines[0])
    }

    @Test fun aKeyThatIsStillWaitingAfterAMomentIsReportedAsNone() {
        probe.key(right, 0, "HOME", ms(0), ms(1))
        probe.flush(ms(200)); assertTrue("too soon", lines.isEmpty())
        probe.flush(ms(301)); assertEquals(1, lines.size); assertTrue(lines[0], "kind=none" in lines[0])
        probe.flush(ms(900)); assertEquals("reported once", 1, lines.size)
    }

    @Test fun framesAndFocusWithNoKeyWaitingAreIgnored() {
        probe.focus(ms(5)); probe.frame(ms(0), ms(16))
        assertTrue(lines.isEmpty())
    }
}
