package app.streamsetu.core

import app.streamsetu.core.playback.*
import org.junit.Assert.*
import org.junit.Test

class RecoveryPolicyTests {
    private val p = RecoveryPolicy()
    private fun err(k: ErrorKind) = PlaybackError(k, "x")

    @Test fun offlineWaitsForTheNetworkInsteadOfRetrying() {
        val d = p.decide(err(ErrorKind.TIMEOUT), 0, isLive = true, online = false)
        assertTrue(d is RecoveryPolicy.Decision.GiveUp && d.error.kind == ErrorKind.NO_NETWORK)
    }

    @Test fun liveStreamsAreRetriedMoreOftenThanMovies() {
        assertTrue(p.decide(err(ErrorKind.TIMEOUT), 4, true, true) is RecoveryPolicy.Decision.Retry)
        assertTrue(p.decide(err(ErrorKind.TIMEOUT), 4, false, true) is RecoveryPolicy.Decision.GiveUp)
    }

    @Test fun aMissingStreamIsNotRetried() {
        assertTrue(p.decide(err(ErrorKind.NOT_FOUND), 0, true, true) is RecoveryPolicy.Decision.GiveUp)
        assertTrue(p.decide(err(ErrorKind.FORMAT), 0, false, true) is RecoveryPolicy.Decision.GiveUp)
    }

    @Test fun aRefusalIsTriedTwiceThenExplained() {
        assertTrue(p.decide(err(ErrorKind.SERVER_REFUSED), 1, true, true) is RecoveryPolicy.Decision.Retry)
        val d = p.decide(err(ErrorKind.SERVER_REFUSED), 2, true, true)
        assertTrue(d is RecoveryPolicy.Decision.GiveUp && d.error.message.contains("refused"))
    }

    @Test fun waitsGrowAndAreCapped() {
        assertTrue(p.backoffMs(1, ErrorKind.TIMEOUT) < p.backoffMs(3, ErrorKind.TIMEOUT))
        assertEquals(15_000L, p.backoffMs(9, ErrorKind.SERVER_REFUSED))
    }
}
