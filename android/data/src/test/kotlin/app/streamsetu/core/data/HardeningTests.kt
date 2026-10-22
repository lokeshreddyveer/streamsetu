package app.streamsetu.core.data

import app.streamsetu.core.model.PinThrottle
import org.junit.Assert.*
import org.junit.Test

class HardeningTests {
    private class Clock(var ms: Long = 1_800_000_000_000L)
    private fun throttle(clock: Clock, store: MutableMap<String, String> = HashMap()) =
        PinThrottle("t", { store[it] }, { k, v -> if (v == null) store.remove(k) else store[k] = v }, { clock.ms })

    @Test fun fiveWrongTriesLockAndEvenTheRightPinIsRefusedUntilItPasses() {
        val clock = Clock(); val t = throttle(clock)
        for (left in 4 downTo 1) assertEquals(PinThrottle.Outcome.Wrong(left), t.attempt { false })
        assertEquals(PinThrottle.Outcome.Wrong(0), t.attempt { false })
        var asked = false
        assertTrue(t.attempt { asked = true; true } is PinThrottle.Outcome.Locked)
        assertFalse("the PIN must not even be compared while locked", asked)
        clock.ms += PinThrottle.LOCKOUT_MS + 1
        assertEquals(PinThrottle.Outcome.Right, t.attempt { true })
    }

    @Test fun aRightPinResetsTheCount() {
        val clock = Clock(); val t = throttle(clock)
        t.attempt { false }; t.attempt { false }
        assertEquals(PinThrottle.Outcome.Right, t.attempt { true })
        assertEquals(PinThrottle.Outcome.Wrong(4), t.attempt { false })
    }

    @Test fun theCountIsKeptAcrossInstancesSoEveryScreenSharesIt() {
        val clock = Clock(); val store = HashMap<String, String>()
        repeat(4) { throttle(clock, store).attempt { false } }
        assertEquals(PinThrottle.Outcome.Wrong(0), throttle(clock, store).attempt { false })
        assertNotNull(throttle(clock, store).lockedForMs())
    }

    @Test fun eachNamedPinHasItsOwnCount() {
        val clock = Clock(); val store = HashMap<String, String>()
        fun named(n: String) = PinThrottle(n, { store[it] }, { k, v -> if (v == null) store.remove(k) else store[k] = v }, { clock.ms })
        repeat(5) { named("a").attempt { false } }
        assertNotNull(named("a").lockedForMs()); assertNull(named("b").lockedForMs())
    }

    @Test fun basicAuthWorksWithoutJavaUtilBase64() {
        assertEquals("Basic dXNlcjpwYXNz", app.streamsetu.core.net.Http.basic("user", "pass"))
    }
}
