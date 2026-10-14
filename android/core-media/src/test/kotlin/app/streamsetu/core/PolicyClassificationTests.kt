package app.streamsetu.core

import app.streamsetu.core.playback.*
import org.junit.Assert.*
import org.junit.Test

class PolicyClassificationTests {
    private val policy = RecoveryPolicy()
    @Test fun loginRefusalIsNotRetriedAndExplainsWhatToDo() {
        val d = policy.decide(PlaybackError(ErrorKind.AUTH, "x", 401), 0, true, online = true)
        assertTrue(d is RecoveryPolicy.Decision.GiveUp)
        assertTrue((d as RecoveryPolicy.Decision.GiveUp).error.message.contains("login"))
    }
    @Test fun protectedContentIsNotRetried() = assertTrue(policy.decide(PlaybackError(ErrorKind.DRM, "x"), 0, false, online = true) is RecoveryPolicy.Decision.GiveUp)
    @Test fun noNetworkWaitsInsteadOfRetrying() = assertEquals(ErrorKind.NO_NETWORK, ((policy.decide(PlaybackError(ErrorKind.TIMEOUT, "x"), 0, true, online = false)) as RecoveryPolicy.Decision.GiveUp).error.kind)
    @Test fun timeoutIsRetriedWithGrowingDelay() {
        val a = policy.decide(PlaybackError(ErrorKind.TIMEOUT, "x"), 0, true, true) as RecoveryPolicy.Decision.Retry
        val b = policy.decide(PlaybackError(ErrorKind.TIMEOUT, "x"), 1, true, true) as RecoveryPolicy.Decision.Retry
        assertTrue(b.delayMs > a.delayMs)
    }
    @Test fun turningRetriesOffGivesUpAtOnce() = assertTrue(policy.decide(PlaybackError(ErrorKind.TIMEOUT, "x"), Int.MAX_VALUE / 2, true, true) is RecoveryPolicy.Decision.GiveUp)
}
